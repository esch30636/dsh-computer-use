#requires -Version 5.1
<#
.SYNOPSIS
  dsh-computer-use screen overlay: a click-through edge vignette plus a
  floating "dynamic island" status pill shown while the agent controls this
  desktop.

.DESCRIPTION
  Started by helper/ComputerUseAgent.ps1 as a separate STA PowerShell process:

    powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
      -File CuOverlay.ps1

  It reads its options from the environment (set by the plugin and forwarded by
  the helper), draws two transparent, topmost, click-through WPF windows on the
  primary display, and polls the ESC key. Pressing ESC writes escape.json into
  the shared state directory and closes the overlay; the helper then refuses
  further computer-use requests until the plugin re-arms it.

  Deliberately boring technique, vivid result: per-pixel-alpha WPF windows with
  a radial "liquid glass" vignette (clear center -> satin-navy edges) plus a
  thin cyan glass rim along the screen border, and a sapphire-gradient status
  pill with a diagonal sheen, bright rim and breathing blue glow. No DWM blur /
  acrylic APIs, no animations on the full-screen layer, no global keyboard
  hooks — those are the variants that break on some Windows builds,
  multi-monitor DPI setups, or after display changes.

  Lifecycle: exits when
    - the user presses ESC (writes escape.json first),
    - the stop file appears (turn ended / plugin shutdown),
    - the heartbeat file goes stale (no computer-use activity),
    - the parent helper process disappears.

.NOTES
  Environment:
    DSH_CU_STATE_DIR            state directory (required; empty -> exit 2)
    DSH_CU_PARENT_PID           helper PID (overlay exits when it disappears)
    DSH_CU_OVERLAY_MESSAGE      island text
    DSH_CU_OVERLAY_IDLE_MS      hide after this long without a heartbeat
    DSH_CU_OVERLAY_EDGE_OPACITY vignette strength, 0..100
#>

Set-StrictMode -Off
# Cosmetic failures must never take the whole overlay down; the lifecycle checks
# below still terminate the process when needed.
$ErrorActionPreference = 'Continue'

$stateDir = [string]$env:DSH_CU_STATE_DIR
if ([string]::IsNullOrWhiteSpace($stateDir)) { exit 2 }

$parentPid = 0
try { if ($env:DSH_CU_PARENT_PID) { $parentPid = [int]$env:DSH_CU_PARENT_PID } } catch { $parentPid = 0 }

$message = [string]$env:DSH_CU_OVERLAY_MESSAGE
if ([string]::IsNullOrWhiteSpace($message)) { $message = 'DeepSeek Harness 正在操控你的电脑　|　按 ESC 终止' }

$idleMs = 90000
try { if ($env:DSH_CU_OVERLAY_IDLE_MS) { $idleMs = [int]$env:DSH_CU_OVERLAY_IDLE_MS } } catch { $idleMs = 90000 }
if ($idleMs -lt 5000) { $idleMs = 5000 }

$edgeOpacity = 55
try { if ($env:DSH_CU_OVERLAY_EDGE_OPACITY) { $edgeOpacity = [int]$env:DSH_CU_OVERLAY_EDGE_OPACITY } } catch { $edgeOpacity = 55 }
if ($edgeOpacity -lt 0) { $edgeOpacity = 0 }
if ($edgeOpacity -gt 100) { $edgeOpacity = 100 }

$escapePath = Join-Path $stateDir 'escape.json'
$heartbeatPath = Join-Path $stateDir 'heartbeat'
$stopPath = Join-Path $stateDir 'stop'

# A pending ESC stop means the overlay must stay hidden until the plugin re-arms.
if ([System.IO.File]::Exists($escapePath)) { exit 0 }

try {
  Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
  Add-Type -AssemblyName PresentationCore -ErrorAction Stop
  Add-Type -AssemblyName WindowsBase -ErrorAction Stop
} catch {
  exit 3
}

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class CuOverlayNative
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
}
'@

try {
  Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop | Out-Null
} catch {
  exit 3
}

# Per-monitor DPI awareness v2 keeps WPF layout units aligned with the primary
# display's physical pixels. When the call is refused (older Windows, manifest
# already fixed the mode) WPF's own virtualization keeps the window consistent.
try { [void][CuOverlayNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }

$script:StartedUtc = [DateTime]::UtcNow
$script:ExitCode = 0
$script:EscHandled = $false
$script:Application = $null
$script:Tick = 0

$WS_EX_TRANSPARENT = 0x00000020
$WS_EX_TOOLWINDOW = 0x00000080
$WS_EX_NOACTIVATE = 0x08000000
$WDA_EXCLUDEFROMCAPTURE = 0x00000011
$VK_ESCAPE = 0x1B
# Test-only escape hatch: lets a diagnostic screen capture include the overlay
# so its rendering can be verified. Never set in normal operation.
$script:CaptureVisible = ($env:DSH_CU_OVERLAY_CAPTURE_VISIBLE -eq '1')

function Write-CuLeaf([string]$Path, [string]$Text) {
  try {
    $temp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    [System.IO.File]::Move($temp, $Path)
  } catch { }
}

function Exit-CuOverlay([int]$Code) {
  $script:ExitCode = $Code
  try {
    if ($script:Application -ne $null) {
      $script:Application.Shutdown()
    }
  } catch { }
}

function Test-CuParentAlive {
  if ($parentPid -le 0) { return $true }
  try {
    $process = [System.Diagnostics.Process]::GetProcessById($parentPid)
    return (-not $process.HasExited)
  } catch {
    return $false
  }
}

function Get-CuHeartbeatAgeMs {
  $last = $script:StartedUtc
  try {
    if ([System.IO.File]::Exists($heartbeatPath)) {
      $stamp = [System.IO.File]::GetLastWriteTimeUtc($heartbeatPath)
      if ($stamp -gt $last) { $last = $stamp }
    }
  } catch { }
  return ([DateTime]::UtcNow - $last).TotalMilliseconds
}

function New-CuEdgeBrush([int]$Strength) {
  $scale = [double]$Strength / 100.0
  $brush = [System.Windows.Media.RadialGradientBrush]::new()
  $brush.GradientOrigin = [System.Windows.Point]::new(0.5, 0.5)
  $brush.Center = [System.Windows.Point]::new(0.5, 0.5)
  $brush.RadiusX = 0.5
  $brush.RadiusY = 0.5
  # "Liquid glass" vignette: fully clear center -> deep satin-navy edges. The
  # edge color is kept darker than typical content so the four edges always read
  # as DARK, while the separate thin rim highlight supplies the vivid accent.
  $stops = @(
    @(0.00, 0.00, 6, 10, 24),
    @(0.42, 0.02, 8, 16, 36),
    @(0.60, 0.10, 8, 20, 46),
    @(0.78, 0.36, 8, 22, 52),
    @(1.00, 0.85, 8, 24, 58)
  )
  foreach ($stopSpec in $stops) {
    $alpha = [int][Math]::Round(255.0 * $scale * [double]$stopSpec[1])
    if ($alpha -lt 0) { $alpha = 0 }
    if ($alpha -gt 255) { $alpha = 255 }
    $color = [System.Windows.Media.Color]::FromArgb([byte]$alpha, [byte]$stopSpec[2], [byte]$stopSpec[3], [byte]$stopSpec[4])
    $stop = [System.Windows.Media.GradientStop]::new($color, [double]$stopSpec[0])
    [void]$brush.GradientStops.Add($stop)
  }
  return $brush
}

function New-CuGlassBrush {
  $brush = [System.Windows.Media.LinearGradientBrush]::new()
  $brush.StartPoint = [System.Windows.Point]::new(0.5, 0.0)
  $brush.EndPoint = [System.Windows.Point]::new(0.5, 1.0)
  # Vivid "liquid glass" pill: bright sapphire top -> deep navy bottom.
  $top = [System.Windows.Media.Color]::FromArgb(0xEE, 0x25, 0x63, 0xEB)
  $mid = [System.Windows.Media.Color]::FromArgb(0xEE, 0x1D, 0x4E, 0xD8)
  $bottom = [System.Windows.Media.Color]::FromArgb(0xF2, 0x0B, 0x12, 0x2A)
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($top, 0.0))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($mid, 0.45))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($bottom, 1.0))
  return $brush
}

# Crisp cyan glass rim that hugs one screen edge for a few DIP and fades inward.
# Four of these (one per edge) are stacked over the vignette; kept narrow so the
# screen edges still read as DARK (the rim is an edge highlight, not a glow band).
function New-CuRimGlowBrush([string]$Direction) {
  $brush = [System.Windows.Media.LinearGradientBrush]::new()
  switch ($Direction) {
    'top' { $brush.StartPoint = [System.Windows.Point]::new(0.5, 0.0); $brush.EndPoint = [System.Windows.Point]::new(0.5, 1.0) }
    'bottom' { $brush.StartPoint = [System.Windows.Point]::new(0.5, 1.0); $brush.EndPoint = [System.Windows.Point]::new(0.5, 0.0) }
    'left' { $brush.StartPoint = [System.Windows.Point]::new(0.0, 0.5); $brush.EndPoint = [System.Windows.Point]::new(1.0, 0.5) }
    default { $brush.StartPoint = [System.Windows.Point]::new(1.0, 0.5); $brush.EndPoint = [System.Windows.Point]::new(0.0, 0.5) }
  }
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x60, 0x67, 0xE8, 0xF9), 0.0))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x40, 0x38, 0xBD, 0xF8), 0.08))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x14, 0x38, 0xBD, 0xF8), 0.30))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x00, 0x38, 0xBD, 0xF8), 1.0))
  return $brush
}

# Diagonal specular highlight that sells the glass material on the island pill.
function New-CuSheenBrush {
  $brush = [System.Windows.Media.LinearGradientBrush]::new()
  $brush.StartPoint = [System.Windows.Point]::new(0.0, 0.0)
  $brush.EndPoint = [System.Windows.Point]::new(1.0, 1.0)
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x42, 0xFF, 0xFF, 0xFF), 0.0))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x12, 0xFF, 0xFF, 0xFF), 0.42))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF), 0.75))
  return $brush
}

# Cyan -> lavender glass rim for the island border.
function New-CuRimBorderBrush {
  $brush = [System.Windows.Media.LinearGradientBrush]::new()
  $brush.StartPoint = [System.Windows.Point]::new(0.0, 0.0)
  $brush.EndPoint = [System.Windows.Point]::new(1.0, 1.0)
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0xE0, 0x7D, 0xD3, 0xFC), 0.0))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0x60, 0x93, 0xC5, 0xFD), 0.5))
  [void]$brush.GradientStops.Add([System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0xE8, 0xC4, 0xB5, 0xFD), 1.0))
  return $brush
}

function Set-CuOverlayWindowStyle($Window) {
  $Window.WindowStyle = [System.Windows.WindowStyle]::None
  $Window.AllowsTransparency = $true
  $Window.Background = [System.Windows.Media.Brushes]::Transparent
  $Window.Topmost = $true
  $Window.ShowInTaskbar = $false
  $Window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $Window.Focusable = $false
  $Window.ShowActivated = $false
  $Window.IsHitTestVisible = $false
  $Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  # Start far off-screen; the window is only moved into place after it is
  # provably click-through, so it can never swallow a click.
  $Window.Left = -32000
  $Window.Top = -32000
}

function Set-CuClickThrough($Window) {
  try {
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $exStyle = [CuOverlayNative]::GetWindowLong($hwnd, -20)
    $newStyle = $exStyle -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE
    [void][CuOverlayNative]::SetWindowLong($hwnd, -20, $newStyle)
    # Never capture the overlay in screenshots (PrintWindow/BitBlt fallbacks of
    # computer_observe must show the target app, not our decoration). The
    # test-only env var opts out so diagnostics can photograph the overlay.
    if (-not $script:CaptureVisible) {
      try { [void][CuOverlayNative]::SetWindowDisplayAffinity($hwnd, $WDA_EXCLUDEFROMCAPTURE) } catch { }
    }
    $verify = [CuOverlayNative]::GetWindowLong($hwnd, -20)
    return (($verify -band $WS_EX_TRANSPARENT) -ne 0)
  } catch {
    return $false
  }
}

try {
  $script:Application = [System.Windows.Application]::new()
  $script:Application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

  $screenWidth = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
  $screenHeight = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
  if ($screenWidth -lt 200) { $screenWidth = 1920 }
  if ($screenHeight -lt 200) { $screenHeight = 1080 }

  # --- edge vignette (full primary display) --------------------------------
  $vignetteWindow = [System.Windows.Window]::new()
  Set-CuOverlayWindowStyle $vignetteWindow
  $vignetteWindow.Width = $screenWidth
  $vignetteWindow.Height = $screenHeight

  $vignetteGrid = [System.Windows.Controls.Grid]::new()
  $vignetteRectangle = [System.Windows.Shapes.Rectangle]::new()
  $vignetteRectangle.Fill = New-CuEdgeBrush $edgeOpacity
  [void]$vignetteGrid.Children.Add($vignetteRectangle)

  # Liquid-glass rim light: four thin cyan gradients that hug the screen edges
  # and fade inward over ~20 DIP (narrow on purpose: the screen edges must stay
  # darker than the center, the rim is only a glass highlight).
  $rimBand = 20.0
  $rimTop = [System.Windows.Shapes.Rectangle]::new()
  $rimTop.Height = $rimBand
  $rimTop.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $rimTop.Fill = New-CuRimGlowBrush 'top'
  [void]$vignetteGrid.Children.Add($rimTop)

  $rimBottom = [System.Windows.Shapes.Rectangle]::new()
  $rimBottom.Height = $rimBand
  $rimBottom.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
  $rimBottom.Fill = New-CuRimGlowBrush 'bottom'
  [void]$vignetteGrid.Children.Add($rimBottom)

  $rimLeft = [System.Windows.Shapes.Rectangle]::new()
  $rimLeft.Width = $rimBand
  $rimLeft.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $rimLeft.Fill = New-CuRimGlowBrush 'left'
  [void]$vignetteGrid.Children.Add($rimLeft)

  $rimRight = [System.Windows.Shapes.Rectangle]::new()
  $rimRight.Width = $rimBand
  $rimRight.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $rimRight.Fill = New-CuRimGlowBrush 'right'
  [void]$vignetteGrid.Children.Add($rimRight)

  $vignetteWindow.Content = $vignetteGrid
  $vignetteWindow.Show()

  # --- dynamic island (top center) -----------------------------------------
  $islandWindow = [System.Windows.Window]::new()
  Set-CuOverlayWindowStyle $islandWindow

  $islandBorder = [System.Windows.Controls.Border]::new()
  $islandBorder.CornerRadius = [System.Windows.CornerRadius]::new(23.0)
  $islandBorder.Background = New-CuGlassBrush
  $islandBorder.BorderBrush = New-CuRimBorderBrush
  $islandBorder.BorderThickness = [System.Windows.Thickness]::new(1.4)
  $islandBorder.Padding = [System.Windows.Thickness]::new(18.0, 0.0, 20.0, 0.0)
  $islandShadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
  $islandShadow.Color = [System.Windows.Media.Color]::FromRgb(0x3B, 0x82, 0xF6)
  $islandShadow.BlurRadius = 28.0
  $islandShadow.ShadowDepth = 2.0
  $islandShadow.Opacity = 0.78
  $islandBorder.Effect = $islandShadow

  $islandContentGrid = [System.Windows.Controls.Grid]::new()
  $islandSheen = [System.Windows.Controls.Border]::new()
  $islandSheen.CornerRadius = [System.Windows.CornerRadius]::new(21.5)
  $islandSheen.Background = New-CuSheenBrush
  $islandSheen.IsHitTestVisible = $false
  [void]$islandContentGrid.Children.Add($islandSheen)

  $islandDot = [System.Windows.Shapes.Ellipse]::new()
  $islandDot.Width = 9.0
  $islandDot.Height = 9.0
  $islandDot.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x67, 0xE8, 0xF9))
  $islandDot.Margin = [System.Windows.Thickness]::new(0.0, 0.0, 10.0, 0.0)
  $islandDot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dotGlow = [System.Windows.Media.Effects.DropShadowEffect]::new()
  $dotGlow.Color = [System.Windows.Media.Color]::FromRgb(0x22, 0xD3, 0xEE)
  $dotGlow.BlurRadius = 10.0
  $dotGlow.ShadowDepth = 0.0
  $dotGlow.Opacity = 0.95
  $islandDot.Effect = $dotGlow

  $islandText = [System.Windows.Controls.TextBlock]::new()
  $islandText.Text = $message
  $islandText.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')
  $islandText.FontSize = 13.0
  $islandText.FontWeight = [System.Windows.FontWeights]::SemiBold
  $islandText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xF8, 0xFA, 0xFC))
  $islandText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $islandText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $textShadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
  $textShadow.Color = [System.Windows.Media.Color]::FromRgb(0x00, 0x00, 0x00)
  $textShadow.BlurRadius = 6.0
  $textShadow.ShadowDepth = 1.0
  $textShadow.Opacity = 0.7
  $islandText.Effect = $textShadow

  $islandPanel = [System.Windows.Controls.StackPanel]::new()
  $islandPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $islandPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  [void]$islandPanel.Children.Add($islandDot)
  [void]$islandPanel.Children.Add($islandText)
  [void]$islandContentGrid.Children.Add($islandPanel)
  $islandBorder.Child = $islandContentGrid
  $islandWindow.Content = $islandBorder

  $islandText.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
  $islandWidth = [Math]::Ceiling([double]$islandText.DesiredSize.Width + 9.0 + 10.0 + 18.0 + 20.0 + 3.0 + 14.0)
  if ($islandWidth -lt 280) { $islandWidth = 280 }
  if ($islandWidth -gt ($screenWidth - 32)) { $islandWidth = $screenWidth - 32 }
  $islandHeight = 46.0
  $islandWindow.Width = $islandWidth
  $islandWindow.Height = $islandHeight
  $islandWindow.Show()

  # --- make both windows click-through before they are visible -------------
  $vignetteClickThrough = Set-CuClickThrough $vignetteWindow
  $islandClickThrough = Set-CuClickThrough $islandWindow
  if (-not $vignetteClickThrough -or -not $islandClickThrough) {
    # An overlay that can eat input would make the desktop unusable; give up.
    try { $vignetteWindow.Close() } catch { }
    try { $islandWindow.Close() } catch { }
    exit 5
  }

  $vignetteWindow.Left = 0.0
  $vignetteWindow.Top = 0.0
  $islandWindow.Left = [Math]::Round(($screenWidth - $islandWidth) / 2.0)
  $islandWindow.Top = 12.0

  # --- status dot pulse (tiny element only; the full-screen layer is static) -
  try {
    $pulse = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.35, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1400)))
    $pulse.AutoReverse = $true
    $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $islandDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
  } catch { }

  # Breathing blue glow around the island (small element; cheap to animate).
  try {
    $glowPulse = [System.Windows.Media.Animation.DoubleAnimation]::new(0.55, 0.98, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(2600)))
    $glowPulse.AutoReverse = $true
    $glowPulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $islandShadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowPulse)
  } catch { }

  # --- lifecycle / ESC watcher ---------------------------------------------
  $script:OnTick = {
    $script:Tick = $script:Tick + 1
    if (-not $script:EscHandled) {
      try {
        $keyState = [CuOverlayNative]::GetAsyncKeyState($script:VkEscape)
        # 0x8000 = currently down, 0x0001 = pressed since the previous call
        # (catches a quick tap that falls between two 80 ms polls).
        if (($keyState -band 0x8001) -ne 0) {
          $script:EscHandled = $true
          Write-CuLeaf $script:EscapePath ([string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
          Exit-CuOverlay 0
          return
        }
      } catch { }
    }
    # Cheap file/process checks once per ~0.8 s.
    if (($script:Tick % 10) -ne 0) { return }
    if ([System.IO.File]::Exists($script:StopPath)) { Exit-CuOverlay 0; return }
    if (-not (Test-CuParentAlive)) { Exit-CuOverlay 0; return }
    if ((Get-CuHeartbeatAgeMs) -gt $script:IdleMs) { Exit-CuOverlay 0; return }
  }

  # ESC may have been pressed and released while WPF was still starting up;
  # sample the key once more before the message loop takes over.
  try {
    if ((([CuOverlayNative]::GetAsyncKeyState($VK_ESCAPE)) -band 0x8000) -ne 0) {
      Write-CuLeaf $escapePath ([string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
      try { $vignetteWindow.Close() } catch { }
      try { $islandWindow.Close() } catch { }
      exit 0
    }
  } catch { }

  $script:VkEscape = $VK_ESCAPE
  $script:EscapePath = $escapePath
  $script:StopPath = $stopPath
  $script:IdleMs = $idleMs

  $timer = [System.Windows.Threading.DispatcherTimer]::new()
  $timer.Interval = [TimeSpan]::FromMilliseconds(80)
  $timer.Add_Tick($script:OnTick)
  $timer.Start()

  [void]$script:Application.Run()
  exit $script:ExitCode
} catch {
  try {
    if ($script:Application -ne $null) { $script:Application.Shutdown() }
  } catch { }
  exit 4
}
