#requires -Version 5.1
<#
.SYNOPSIS
  dsh-computer-use Windows helper: a long-lived JSON-lines RPC process that
  performs window-targeted UI Automation, screenshot capture, and SendInput
  mouse/keyboard injection for the dsh-computer-use DSH plugin.

.DESCRIPTION
  Protocol: docs/helper-protocol.md (newline-delimited JSON on stdin/stdout,
  one response line per request; stderr carries diagnostics only).

  Started by the plugin as:
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ComputerUseAgent.ps1

  No startup banner is printed; the first `ping` reports readiness.

.NOTES
  - Windows PowerShell 5.1 only (pwsh 7 is not required and not assumed).
  - Must run in the interactive desktop session; UAC/secure desktops and locked
    sessions are refused by design.
  - Screenshots are written under %TEMP%\dsh-computer-use and deleted by the
    caller (or by the 1-hour age cleanup at startup).
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native interop (compiled once; ~1-4 s of the first-call latency)
# ---------------------------------------------------------------------------
$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class CuNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] public static extern int DwmGetWindowAttributeRect(IntPtr hwnd, int attr, out RECT rect, int size);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] public static extern int DwmGetWindowAttributeInt(IntPtr hwnd, int attr, out int value, int size);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dest, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int len, out int needed);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);

    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION u; }

    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;
    public const int SM_CMONITORS = 80;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    public const int DWMWA_CLOAKED = 14;

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_SCANCODE = 0x0008;

    public static string Title(IntPtr h)
    {
        int len = GetWindowTextLength(h);
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 2);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(512);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static uint Pid(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static IntPtr Owner(IntPtr h) { return GetWindow(h, 4); }

    public static bool IsToolWindow(IntPtr h)
    {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        return (ex & 0x00000080L) != 0;
    }

    public static bool IsCloaked(IntPtr h)
    {
        int cloaked;
        return DwmGetWindowAttributeInt(h, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0;
    }

    public static void GetFrame(IntPtr h, out int left, out int top, out int width, out int height)
    {
        RECT r;
        if (DwmGetWindowAttributeRect(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0)
            GetWindowRect(h, out r);
        left = r.Left; top = r.Top; width = r.Right - r.Left; height = r.Bottom - r.Top;
    }

    public static void GetWindowBounds(IntPtr h, out int left, out int top, out int width, out int height)
    {
        RECT r;
        GetWindowRect(h, out r);
        left = r.Left; top = r.Top; width = r.Right - r.Left; height = r.Bottom - r.Top;
    }

    public static IntPtr[] TopLevelWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static RECT[] Monitors()
    {
        List<RECT> list = new List<RECT>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            delegate(IntPtr m, IntPtr hdc, ref RECT r, IntPtr d) { list.Add(r); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    private static int Normalized(int value, int origin, int size)
    {
        if (size <= 1) return 0;
        double n = (double)(value - origin) * 65535.0 / (double)(size - 1);
        if (n < 0) n = 0;
        if (n > 65535) n = 65535;
        return (int)Math.Round(n);
    }

    public static bool MouseMoveAbsolute(int x, int y)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        INPUT[] arr = new INPUT[1];
        arr[0].type = INPUT_MOUSE;
        arr[0].u.mi.dx = Normalized(x, vx, vw);
        arr[0].u.mi.dy = Normalized(y, vy, vh);
        arr[0].u.mi.mouseData = 0;
        arr[0].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        arr[0].u.mi.time = 0;
        arr[0].u.mi.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool MouseButton(int button, bool down, int x, int y)
    {
        MouseMoveAbsolute(x, y);
        Thread.Sleep(15);
        uint flag;
        if (button == 1) flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        else if (button == 2) flag = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        else flag = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        INPUT[] arr = new INPUT[1];
        arr[0].type = INPUT_MOUSE;
        arr[0].u.mi.dx = 0;
        arr[0].u.mi.dy = 0;
        arr[0].u.mi.mouseData = 0;
        arr[0].u.mi.dwFlags = flag;
        arr[0].u.mi.time = 0;
        arr[0].u.mi.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Wheel(int delta, bool horizontal)
    {
        INPUT[] arr = new INPUT[1];
        arr[0].type = INPUT_MOUSE;
        arr[0].u.mi.dx = 0;
        arr[0].u.mi.dy = 0;
        arr[0].u.mi.mouseData = unchecked((uint)delta);
        arr[0].u.mi.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
        arr[0].u.mi.time = 0;
        arr[0].u.mi.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Key(ushort vk, ushort scan, bool down, bool extended)
    {
        INPUT[] arr = new INPUT[1];
        arr[0].type = INPUT_KEYBOARD;
        uint flags = 0;
        if (scan != 0)
        {
            arr[0].u.ki.wVk = 0;
            arr[0].u.ki.wScan = scan;
            flags |= KEYEVENTF_SCANCODE;
        }
        else
        {
            arr[0].u.ki.wVk = vk;
            arr[0].u.ki.wScan = 0;
        }
        if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
        if (down == false) flags |= KEYEVENTF_KEYUP;
        arr[0].u.ki.dwFlags = flags;
        arr[0].u.ki.time = 0;
        arr[0].u.ki.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool UnicodeUnit(ushort unit, bool down)
    {
        INPUT[] arr = new INPUT[1];
        arr[0].type = INPUT_KEYBOARD;
        arr[0].u.ki.wVk = 0;
        arr[0].u.ki.wScan = unit;
        arr[0].u.ki.dwFlags = down ? KEYEVENTF_UNICODE : (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        arr[0].u.ki.time = 0;
        arr[0].u.ki.dwExtraInfo = IntPtr.Zero;
        return SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool Activate(IntPtr h)
    {
        if (IsIconic(h)) ShowWindow(h, 9);
        // Only force-show a window that is actually hidden or minimized. Some
        // Office windows (Visio observed) clear WS_VISIBLE when SW_SHOW is
        // applied to an already-visible, already-foreground window.
        if (!IsWindowVisible(h)) ShowWindow(h, 5);
        if (GetForegroundWindow() == h) return true;
        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out fgPid);
        uint myThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != myThread) attached = AttachThreadInput(myThread, fgThread, true);
        try
        {
            SetForegroundWindow(h);
            BringWindowToTop(h);
        }
        finally
        {
            if (attached) AttachThreadInput(myThread, fgThread, false);
        }
        Thread.Sleep(80);
        return GetForegroundWindow() == h;
    }

    public static string InputDesktopName()
    {
        IntPtr desk = OpenInputDesktop(0, false, 0x0100);
        if (desk == IntPtr.Zero) return null;
        try
        {
            StringBuilder sb = new StringBuilder(256);
            int needed;
            if (!GetUserObjectInformation(desk, 2, sb, 256 * 2, out needed)) return null;
            return sb.ToString();
        }
        finally
        {
            CloseDesktop(desk);
        }
    }
}
'@

Add-Type -TypeDefinition $script:NativeSource -Language CSharp | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Per-monitor DPI awareness v2: all window rects, UIA rectangles, screenshot
# pixels and SendInput absolute coordinates then share one physical-pixel space.
try { [void][CuNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
try { [void][CuNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------
$script:Version = '1.0.0'
$script:StateSeq = 0
$script:ShotSeq = 0
$script:States = @{}
$script:ProcCache = @{}
$script:StartAppsCache = $null
$script:Stopping = $false
$script:BlockedProcessNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:BlockedAppIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:BlockedWindowClasses = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-computer-use'
# Launch targets that must be refused even when they arrive as a Start-menu
# display name or an AUMID (no .exe path to inspect): terminals, shells, and
# interpreter prompts are never launched through computer use.
$script:BlockedLaunchPattern = '(?i)(windowsterminal|windowspowershell|powershell_ise|cmd\.exe|conhost|openconsole|terminal|终端|命令提示符|anaconda prompt|anaconda powershell|node\.js command prompt|git cmd)'

foreach ($name in @(
  'cmd.exe','powershell.exe','pwsh.exe','conhost.exe','windowsterminal.exe','wt.exe','openconsole.exe','consolehost.exe',
  'regedit.exe','taskmgr.exe','mmc.exe','control.exe','msconfig.exe','taskkill.exe','reg.exe','sc.exe','wscript.exe','cscript.exe',
  'mstsc.exe','quickassist.exe','lockapp.exe','logonui.exe','consent.exe','useraccountcontrol.exe','credentialuibroker.exe',
  'securityhealthsystray.exe','securityhealthui.exe','msmpeng.exe','nissrv.exe',
  'keepass.exe','keepassxc.exe','1password.exe','1passwordtray.exe','bitwarden.exe','lastpass.exe','dashlane.exe','enpass.exe','roboform.exe',
  'codex.exe','chatgpt.exe','deepseek harness.exe'
)) { [void]$script:BlockedProcessNames.Add($name) }
foreach ($cls in @('ConsoleWindowClass','CASCADING_HOSTING_WINDOW_CLASS','CASCADIA_HOSTING_WINDOW_CLASS')) {
  [void]$script:BlockedWindowClasses.Add($cls)
}

# ---------------------------------------------------------------------------
# Screen overlay + ESC kill switch
#
# While computer use is active the helper keeps a separate PowerShell/WPF child
# process (CuOverlay.ps1) alive. That child draws a click-through vignette over
# the primary display (transparent center, dark gradient toward the four edges)
# plus a "dynamic island" status pill at the top center, and polls the ESC key.
# Pressing ESC writes escape.json and closes the overlay; this helper then
# refuses every computer-use request with USER_ESCAPE until the plugin re-arms
# it (after the user speaks again).
# ---------------------------------------------------------------------------
$script:OverlayStateDir = [string]$env:DSH_CU_STATE_DIR
$script:OverlayEnabled = ($script:OverlayStateDir -ne '') -and ([string]$env:DSH_CU_OVERLAY -ne '0')
$script:OverlayScript = [string]$env:DSH_CU_OVERLAY_SCRIPT
if ($script:OverlayScript -eq '' -and $PSScriptRoot) { $script:OverlayScript = Join-Path $PSScriptRoot 'CuOverlay.ps1' }
$script:OverlayMessage = [string]$env:DSH_CU_OVERLAY_MESSAGE
if ($script:OverlayMessage -eq '') { $script:OverlayMessage = 'DeepSeek Harness 正在操控你的电脑　|　按 ESC 终止' }
$script:OverlayIdleMs = 90000
if ($env:DSH_CU_OVERLAY_IDLE_MS) { try { $script:OverlayIdleMs = [int]$env:DSH_CU_OVERLAY_IDLE_MS } catch { $script:OverlayIdleMs = 90000 } }
$script:OverlayEdgeOpacity = 55
if ($env:DSH_CU_OVERLAY_EDGE_OPACITY) { try { $script:OverlayEdgeOpacity = [int]$env:DSH_CU_OVERLAY_EDGE_OPACITY } catch { $script:OverlayEdgeOpacity = 55 } }
$script:OverlayProcess = $null
$script:OverlayFailures = 0
$script:HeartbeatPath = ''
$script:EscapePath = ''
$script:StopPath = ''
if ($script:OverlayEnabled) {
  try {
    if (-not (Test-Path -LiteralPath $script:OverlayStateDir)) {
      New-Item -ItemType Directory -Path $script:OverlayStateDir -Force | Out-Null
    }
  } catch {
    $script:OverlayEnabled = $false
  }
}
if ($script:OverlayEnabled) {
  $script:HeartbeatPath = Join-Path $script:OverlayStateDir 'heartbeat'
  $script:EscapePath = Join-Path $script:OverlayStateDir 'escape.json'
  $script:StopPath = Join-Path $script:OverlayStateDir 'stop'
}

function Write-Log([string]$Message) {
  try { [Console]::Error.WriteLine("[computer-use-helper] $Message") } catch { }
}

function New-CuError([string]$Code, [string]$Message) {
  $ex = New-Object System.Exception($Message)
  $ex.Data['cu_code'] = $Code
  return $ex
}

function Throw-Cu([string]$Code, [string]$Message) {
  throw (New-CuError $Code $Message)
}

# ---------------------------------------------------------------------------
# Overlay helpers (see the overlay block near the top of this script)
# ---------------------------------------------------------------------------
function Write-CuStateFile([string]$Path, [string]$Text) {
  if ($Path -eq '') { return $false }
  try {
    $temp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    [System.IO.File]::Move($temp, $Path)
    return $true
  } catch {
    return $false
  }
}

function Write-CuHeartbeat {
  if (-not $script:OverlayEnabled) { return }
  [void](Write-CuStateFile $script:HeartbeatPath ([string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
}

function Test-CuEscapeRequested {
  if (-not $script:OverlayEnabled) { return $false }
  try { return [System.IO.File]::Exists($script:EscapePath) } catch { return $false }
}

function Test-CuOverlayRunning {
  if ($script:OverlayProcess -eq $null) { return $false }
  try { return (-not $script:OverlayProcess.HasExited) } catch { return $false }
}

function Start-CuOverlay {
  if (-not $script:OverlayEnabled) { return }
  if (Test-CuOverlayRunning) { return }
  # A previous overlay child that died with a non-zero exit code is a real
  # failure (WPF missing, click-through unsafe, crash). Do not respawn it
  # forever at the cost of every call: disable the overlay for this helper.
  if ($script:OverlayProcess -ne $null) {
    try {
      $exitCode = $script:OverlayProcess.ExitCode
      if ($exitCode -ne 0) {
        $script:OverlayFailures = $script:OverlayFailures + 1
        Write-Log ("overlay exited with code " + $exitCode + " (failure " + $script:OverlayFailures + "/3)")
        if ($script:OverlayFailures -ge 3) {
          $script:OverlayEnabled = $false
          $script:OverlayProcess = $null
          Write-Log 'overlay disabled for this helper session after repeated failures'
          return
        }
      }
    } catch { }
    $script:OverlayProcess = $null
  }
  if (-not (Test-Path -LiteralPath $script:OverlayScript)) {
    Write-Log ("overlay script not found: " + $script:OverlayScript)
    return
  }
  try {
    # A pending ESC stop or a stop request must never resurrect the overlay.
    if ([System.IO.File]::Exists($script:EscapePath)) { return }
    if ([System.IO.File]::Exists($script:StopPath)) { try { [System.IO.File]::Delete($script:StopPath) } catch { } }
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe)) { $powerShellExe = 'powershell.exe' }
    $argumentLine = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $script:OverlayScript + '"'
    $env:DSH_CU_PARENT_PID = [string]$PID
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $argumentLine -WindowStyle Hidden -PassThru -ErrorAction Stop
    $script:OverlayProcess = $process
    Write-Log ("overlay started pid=" + $process.Id)
  } catch {
    $script:OverlayProcess = $null
    Write-Log ("overlay start failed: " + $_.Exception.Message)
  }
}

function Stop-CuOverlay {
  $process = $script:OverlayProcess
  $script:OverlayProcess = $null
  if ($process -eq $null) { return }
  try { if (-not $process.HasExited) { $process.Kill() } } catch { }
}

# Called at the start of every desktop request: refreshes the heartbeat (so the
# overlay's idle timer does not fire while the agent is working) and restarts
# the overlay after an idle hide. It deliberately does not restart the overlay
# while an ESC stop is pending.
function Invoke-CuOverlayActivity {
  if (-not $script:OverlayEnabled) { return }
  Write-CuHeartbeat
  if (Test-CuEscapeRequested) { return }
  Start-CuOverlay
}

function Get-ParamValue($Params, [string]$Name, $Default = $null) {
  if ($Params -eq $null) { return $Default }
  if ($Params -is [System.Collections.IDictionary]) {
    if ($Params.Contains($Name)) { return $Params[$Name] }
    return $Default
  }
  $prop = $Params.PSObject.Properties[$Name]
  if ($prop -ne $null) { return $prop.Value }
  return $Default
}

function Get-ParamInt($Params, [string]$Name, [int]$Default) {
  $value = Get-ParamValue $Params $Name $null
  if ($value -eq $null) { return $Default }
  try { return [int]$value } catch { Throw-Cu 'INVALID_PARAMS' "params.$Name must be an integer" }
}

function Get-ParamBool($Params, [string]$Name, [bool]$Default) {
  $value = Get-ParamValue $Params $Name $null
  if ($value -eq $null) { return $Default }
  return [bool]$value
}

function Get-ParamString($Params, [string]$Name, [string]$Default = '') {
  $value = Get-ParamValue $Params $Name $null
  if ($value -eq $null) { return $Default }
  return [string]$value
}

# ---------------------------------------------------------------------------
# Screenshot temp storage
# ---------------------------------------------------------------------------
function Initialize-TempRoot {
  if (-not (Test-Path -LiteralPath $script:TempRoot)) {
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
  }
  $cutoff = (Get-Date).AddHours(-1)
  try {
    Get-ChildItem -LiteralPath $script:TempRoot -Filter '*.png' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  } catch { }
}

function New-ScreenshotPath {
  $script:ShotSeq = $script:ShotSeq + 1
  return (Join-Path $script:TempRoot ("shot-{0}-{1:D5}.png" -f $PID, $script:ShotSeq))
}

# ---------------------------------------------------------------------------
# Process / window metadata
# ---------------------------------------------------------------------------
function Get-ProcInfo([uint32]$ProcessId) {
  $key = [string]$ProcessId
  if ($script:ProcCache.ContainsKey($key)) { return $script:ProcCache[$key] }
  $info = @{ name = ''; path = ''; title = ''; publisher = '' }
  try {
    $proc = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    if ($proc -ne $null) {
      $info.name = [string]$proc.ProcessName
      if (-not $info.name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $info.name = $info.name + '.exe' }
      try { $info.path = [string]$proc.Path } catch { }
      try {
        $vi = $proc.MainModule.FileVersionInfo
        if ($vi.FileDescription) { $info.title = [string]$vi.FileDescription }
        if ($vi.CompanyName) { $info.publisher = [string]$vi.CompanyName }
      } catch { }
    }
  } catch { }
  $script:ProcCache[$key] = $info
  return $info
}

function Get-DisplayIndex([int]$CenterX, [int]$CenterY) {
  try {
    $monitors = [CuNative]::Monitors()
  } catch { return 0 }
  for ($i = 0; $i -lt $monitors.Length; $i++) {
    $m = $monitors[$i]
    if ($CenterX -ge $m.Left -and $CenterX -lt $m.Right -and $CenterY -ge $m.Top -and $CenterY -lt $m.Bottom) { return $i }
  }
  return 0
}

function Get-WindowSnapshot([IntPtr]$Hwnd, [int]$ZOrder) {
  $left = 0; $top = 0; $width = 0; $height = 0
  [CuNative]::GetFrame($Hwnd, [ref]$left, [ref]$top, [ref]$width, [ref]$height)
  $pidValue = [CuNative]::Pid($Hwnd)
  $procInfo = Get-ProcInfo $pidValue
  $appId = ''
  if ($procInfo.path -ne '') { $appId = $procInfo.path.ToLowerInvariant() }
  elseif ($procInfo.name -ne '') { $appId = $procInfo.name.ToLowerInvariant() }
  $appName = $procInfo.title
  if ($appName -eq '') { $appName = $procInfo.name }
  $className = [CuNative]::ClassName($Hwnd)
  $blocked = $false
  if ($procInfo.name -ne '' -and $script:BlockedProcessNames.Contains($procInfo.name)) { $blocked = $true }
  if ($className -ne '' -and $script:BlockedWindowClasses.Contains($className)) { $blocked = $true }
  if ($script:BlockedAppIds.Contains($appId)) { $blocked = $true }
  $fg = [CuNative]::GetForegroundWindow()
  return @{
    window_id = [long]$Hwnd.ToInt64()
    title = [CuNative]::Title($Hwnd)
    class_name = $className
    process_id = [int]$pidValue
    process_name = $procInfo.name
    process_path = $procInfo.path
    app_id = $appId
    app_name = $appName
    publisher = $procInfo.publisher
    is_foreground = ($fg -eq $Hwnd)
    is_minimized = [CuNative]::IsIconic($Hwnd)
    is_visible = [CuNative]::IsWindowVisible($Hwnd)
    rect = @{ x = $left; y = $top; width = $width; height = $height }
    display_index = (Get-DisplayIndex ($left + [int]($width / 2)) ($top + [int]($height / 2)))
    z_order = $ZOrder
    blocked = $blocked
  }
}

function Test-TargetableWindow([IntPtr]$Hwnd) {
  if (-not [CuNative]::IsWindow($Hwnd)) { return $false }
  if (-not [CuNative]::IsWindowVisible($Hwnd)) { return $false }
  if ([CuNative]::IsCloaked($Hwnd)) { return $false }
  $title = [CuNative]::Title($Hwnd)
  if ([string]::IsNullOrWhiteSpace($title)) { return $false }
  if ([CuNative]::IsToolWindow($Hwnd)) {
    $owner = [CuNative]::Owner($Hwnd)
    if ($owner -eq [IntPtr]::Zero) { return $false }
  }
  return $true
}

function Get-TargetableWindows([bool]$IncludeMinimized = $true) {
  $handles = [CuNative]::TopLevelWindows()
  $result = New-Object System.Collections.Generic.List[object]
  $z = 0
  foreach ($h in $handles) {
    if (-not (Test-TargetableWindow $h)) { continue }
    if (-not $IncludeMinimized -and [CuNative]::IsIconic($h)) { continue }
    $snapshot = Get-WindowSnapshot $h $z
    $result.Add($snapshot)
    $z = $z + 1
    if ($z -ge 400) { break }
  }
  return $result
}

function Get-WindowById([long]$WindowId) {
  $hwnd = [IntPtr]::new($WindowId)
  if (-not [CuNative]::IsWindow($hwnd)) { Throw-Cu 'WINDOW_NOT_FOUND' "window $WindowId no longer exists" }
  return $hwnd
}

function Assert-WindowAllowed([IntPtr]$Hwnd) {
  $snapshot = Get-WindowSnapshot $Hwnd -1
  if ($snapshot.blocked) {
    Throw-Cu 'BLOCKED_APP' ("window " + $snapshot.window_id + " ('" + $snapshot.title + "', process " + $snapshot.process_name + ") is blocked by computer-use policy")
  }
  return $snapshot
}

function Assert-InteractiveDesktop {
  $fg = [CuNative]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { Throw-Cu 'DESKTOP_LOCKED' 'no interactive foreground window; the desktop may be locked' }
  $procInfo = Get-ProcInfo ([CuNative]::Pid($fg))
  if ($procInfo.name -in @('logonui.exe','lockapp.exe')) {
    Throw-Cu 'DESKTOP_LOCKED' 'the desktop is locked (logon/lock screen is foreground); unlock it before using computer use'
  }
  $deskName = $null
  try { $deskName = [CuNative]::InputDesktopName() } catch { }
  if ($deskName -eq $null -or $deskName -eq '') {
    Throw-Cu 'DESKTOP_LOCKED' 'the input desktop is not available; the session may be locked or not interactive'
  }
  if ($deskName -ne 'Default') {
    Throw-Cu 'SECURE_DESKTOP' "the active input desktop is '$deskName' (UAC/secure desktop); dismiss it before using computer use"
  }
}

function Assert-ForegroundTarget([IntPtr]$Hwnd) {
  $fg = [CuNative]::GetForegroundWindow()
  if ($fg -eq $Hwnd) { return }
  if ($fg -ne [IntPtr]::Zero) {
    $fgPid = [CuNative]::Pid($fg)
    $targetPid = [CuNative]::Pid($Hwnd)
    if ($fgPid -eq $targetPid) { return }
  }
  $activated = [CuNative]::Activate($Hwnd)
  if ($activated) {
    Start-Sleep -Milliseconds 60
    if ([CuNative]::GetForegroundWindow() -eq $Hwnd) { return }
  }
  Throw-Cu 'WINDOW_NOT_FOREGROUND' "window $($Hwnd.ToInt64()) could not be brought to the foreground; activate it with action=activate_window or ask the user to focus it"
}

# ---------------------------------------------------------------------------
# Screenshots (PrintWindow with DWM frame crop; visible-region fallback)
# ---------------------------------------------------------------------------
function Test-MostlyBlack([System.Drawing.Bitmap]$Bitmap) {
  $w = $Bitmap.Width
  $h = $Bitmap.Height
  if ($w -le 0 -or $h -le 0) { return $true }
  $stepX = [Math]::Max(1, [int]($w / 64))
  $stepY = [Math]::Max(1, [int]($h / 64))
  $total = 0
  $black = 0
  for ($y = 0; $y -lt $h; $y = $y + $stepY) {
    for ($x = 0; $x -lt $w; $x = $x + $stepX) {
      $color = $Bitmap.GetPixel($x, $y)
      $total = $total + 1
      if ($color.A -eq 0 -or ($color.R -lt 12 -and $color.G -lt 12 -and $color.B -lt 12)) { $black = $black + 1 }
    }
  }
  if ($total -eq 0) { return $true }
  return (([double]$black / [double]$total) -gt 0.995)
}

function Save-CuScreenshot([IntPtr]$Hwnd, [int]$MaxWidth, [int]$MaxHeight) {
  if ([CuNative]::IsIconic($Hwnd)) {
    [void][CuNative]::Activate($Hwnd)
    Start-Sleep -Milliseconds 250
  }
  $rectL = 0; $rectT = 0; $rectW = 0; $rectH = 0
  [CuNative]::GetWindowBounds($Hwnd, [ref]$rectL, [ref]$rectT, [ref]$rectW, [ref]$rectH)
  $frameL = 0; $frameT = 0; $frameW = 0; $frameH = 0
  [CuNative]::GetFrame($Hwnd, [ref]$frameL, [ref]$frameT, [ref]$frameW, [ref]$frameH)
  if ($rectW -le 0 -or $rectH -le 0) { Throw-Cu 'CAPTURE_FAILED' 'the window has no drawable size; restore/activate it and retry' }
  $method = 'printwindow'
  $originX = $frameL
  $originY = $frameT
  $bitmap = $null
  try {
    $full = New-Object System.Drawing.Bitmap($rectW, $rectH)
    $graphics = [System.Drawing.Graphics]::FromImage($full)
    $hdc = $graphics.GetHdc()
    $printed = $false
    try { $printed = [CuNative]::PrintWindow($Hwnd, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc); $graphics.Dispose() }
    if ($printed) {
      $cropX = $frameL - $rectL
      $cropY = $frameT - $rectT
      $cropRect = New-Object System.Drawing.Rectangle($cropX, $cropY, $frameW, $frameH)
      $bounds = New-Object System.Drawing.Rectangle(0, 0, $rectW, $rectH)
      $cropRect = [System.Drawing.Rectangle]::Intersect($cropRect, $bounds)
      if ($cropRect.Width -gt 0 -and $cropRect.Height -gt 0) {
        $bitmap = $full.Clone($cropRect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $full.Dispose()
        $full = $null
      } else {
        $bitmap = $full
        $full = $null
      }
      if (Test-MostlyBlack $bitmap) {
        $bitmap.Dispose()
        $bitmap = $null
        $printed = $false
      }
    } else {
      $full.Dispose()
      $full = $null
    }
  } catch {
    if ($bitmap -ne $null) { $bitmap.Dispose(); $bitmap = $null }
  }
  if ($null -eq $bitmap) {
    $virtX = [CuNative]::GetSystemMetrics(76)
    $virtY = [CuNative]::GetSystemMetrics(77)
    $virtW = [CuNative]::GetSystemMetrics(78)
    $virtH = [CuNative]::GetSystemMetrics(79)
    $visL = [Math]::Max($frameL, $virtX)
    $visT = [Math]::Max($frameT, $virtY)
    $visR = [Math]::Min($frameL + $frameW, $virtX + $virtW)
    $visB = [Math]::Min($frameT + $frameH, $virtY + $virtH)
    if ($visR -le $visL -or $visB -le $visT) {
      Throw-Cu 'CAPTURE_FAILED' 'PrintWindow failed and the window is off-screen; activate/move the window and retry, or use include_text=true'
    }
    $method = 'screen-bitblt'
    $originX = $visL
    $originY = $visT
    $bitmap = New-Object System.Drawing.Bitmap(($visR - $visL), ($visB - $visT))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($visL, $visT, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
  }
  if ($null -eq $bitmap) { Throw-Cu 'CAPTURE_FAILED' 'could not capture the window' }
  $screenWidth = $bitmap.Width
  $screenHeight = $bitmap.Height
  $captureScaleX = 1.0
  $captureScaleY = 1.0
  if ($screenWidth -gt $MaxWidth -or $screenHeight -gt $MaxHeight) {
    $factor = [Math]::Min([double]$MaxWidth / [double]$screenWidth, [double]$MaxHeight / [double]$screenHeight)
    $newW = [Math]::Max(1, [int][Math]::Round($screenWidth * $factor))
    $newH = [Math]::Max(1, [int][Math]::Round($screenHeight * $factor))
    $scaled = New-Object System.Drawing.Bitmap($newW, $newH)
    $graphics = [System.Drawing.Graphics]::FromImage($scaled)
    try {
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.DrawImage($bitmap, 0, 0, $newW, $newH)
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
    $bitmap = $scaled
    $captureScaleX = [double]$screenWidth / [double]$newW
    $captureScaleY = [double]$screenHeight / [double]$newH
  }
  $finalWidth = $bitmap.Width
  $finalHeight = $bitmap.Height
  $path = New-ScreenshotPath
  try { $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
  return @{
    path = $path
    width = $finalWidth
    height = $finalHeight
    origin_x = [int]$originX
    origin_y = [int]$originY
    capture_scale_x = [double]$captureScaleX
    capture_scale_y = [double]$captureScaleY
    capture_method = $method
  }
}

# ---------------------------------------------------------------------------
# UI Automation accessibility tree
# ---------------------------------------------------------------------------
function ConvertTo-CuInline([string]$Text, [int]$MaxLength) {
  if ($Text -eq $null) { return '' }
  $clean = $Text -replace "`r", ' ' -replace "`n", ' ' -replace "`t", ' '
  $clean = $clean -replace '\s{2,}', ' '
  $clean = $clean.Trim()
  if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) + '...' }
  return $clean
}

function ConvertTo-CuQuoted([string]$Text) {
  if ($Text -eq $null) { return '' }
  return ($Text -replace '\\', '\\\\' -replace '"', '\"')
}

function ConvertTo-CuToken([string]$Text) {
  if ($Text -eq $null) { return '' }
  $clean = ConvertTo-CuInline $Text 60
  if ($clean -match '\s') { return '"' + (ConvertTo-CuQuoted $clean) + '"' }
  return $clean
}

function Get-CuElementValue($Element, [int]$MaxLength = 120) {
  try {
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
      $value = [string]$pattern.Current.Value
      if ($value -ne '') { return (ConvertTo-CuInline $value $MaxLength) }
    }
  } catch { }
  return ''
}

function Test-CuDescendant($Element, $Root, $Walker) {
  $current = $Element
  for ($i = 0; $i -lt 40; $i++) {
    if ($current -eq $null) { return $false }
    try {
      if ($current.Equals($Root)) { return $true }
    } catch { return $false }
    try { $current = $Walker.GetParent($current) } catch { return $false }
  }
  return $false
}

function Format-CuElementLine($Element, [int]$Index, [int]$Depth) {
  $pad = ''
  for ($i = 0; $i -lt $Depth; $i++) { $pad = $pad + '  ' }
  try {
    $current = $Element.Current
    $typeName = [string]$current.ControlType.ProgrammaticName
    if ($typeName.StartsWith('ControlType.')) { $typeName = $typeName.Substring(12) }
    $name = ConvertTo-CuInline ([string]$current.Name) 120
    $line = $pad + "[$Index] " + $typeName + ' "' + (ConvertTo-CuQuoted $name) + '"'
    if ([string]$current.AutomationId -ne '') { $line = $line + ' id=' + (ConvertTo-CuToken ([string]$current.AutomationId)) }
    if ([string]$current.ClassName -ne '') { $line = $line + ' class=' + (ConvertTo-CuToken ([string]$current.ClassName)) }
    if ($typeName -eq 'Edit' -or $typeName -eq 'Document' -or $typeName -eq 'ComboBox' -or $typeName -eq 'Text') {
      $value = Get-CuElementValue $Element 120
      if ($value -ne '') { $line = $line + ' value="' + (ConvertTo-CuQuoted $value) + '"' }
    }
    if ([bool]$current.IsPassword) { $line = $line + ' password' }
    if (-not [bool]$current.IsEnabled) { $line = $line + ' disabled' }
    if ([bool]$current.IsOffscreen) { $line = $line + ' offscreen' }
    $rect = $current.BoundingRectangle
    if ($rect.Width -gt 0 -and $rect.Height -gt 0) {
      $line = $line + ' rect=' + [int]$rect.Left + ',' + [int]$rect.Top + ',' + [int]$rect.Width + ',' + [int]$rect.Height
    }
    return $line
  } catch {
    return $pad + "[$Index] Unknown `"`""
  }
}

function Get-CuAccessibility([IntPtr]$Hwnd, [int]$MaxDepth, [int]$MaxElements, [int]$MaxTextChars) {
  $root = $null
  try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd) } catch { }
  if ($null -eq $root) { Throw-Cu 'UIA_FAILED' 'could not attach UI Automation to this window; use the screenshot path instead' }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $lines = New-Object System.Collections.Generic.List[string]
  $elements = New-Object 'System.Collections.Generic.Dictionary[int,object]'
  $stack = New-Object System.Collections.Stack
  $stack.Push(@{ el = $root; depth = 0 })
  $count = 0
  $truncated = $false
  while ($stack.Count -gt 0) {
    if ($count -ge $MaxElements) { $truncated = $true; break }
    $item = $stack.Pop()
    $element = $item.el
    $depth = [int]$item.depth
    $index = $count
    $count = $count + 1
    $elements[$index] = $element
    $offscreen = $false
    $line = Format-CuElementLine $element $index $depth
    try { $offscreen = [bool]$element.Current.IsOffscreen } catch { }
    $lines.Add($line)
    if ($depth -ge $MaxDepth) { $truncated = $true; continue }
    if ($offscreen) { continue }
    $children = New-Object System.Collections.Generic.List[object]
    try {
      $child = $walker.GetFirstChild($element)
      while ($child -ne $null) {
        $children.Add($child)
        if ($children.Count -ge 200) { break }
        $child = $walker.GetNextSibling($child)
      }
    } catch { }
    for ($i = $children.Count - 1; $i -ge 0; $i--) {
      $stack.Push(@{ el = $children[$i]; depth = $depth + 1 })
    }
  }
  $focusedLine = ''
  $focusedIsPassword = $false
  $selectedText = ''
  $documentText = ''
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($focused -ne $null -and (Test-CuDescendant $focused $root $walker)) {
      $focusedIndex = -1
      foreach ($entry in $elements.GetEnumerator()) {
        try {
          if ($entry.Value.Equals($focused)) { $focusedIndex = $entry.Key; break }
        } catch { }
      }
      if ($focusedIndex -ge 0) { $focusedLine = Format-CuElementLine $focused $focusedIndex 0 }
      else { $focusedLine = Format-CuElementLine $focused -1 0 }
      try { $focusedIsPassword = [bool]$focused.Current.IsPassword } catch { }
      try {
        $textPattern = $null
        if ($focused.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) {
          $selection = $textPattern.GetSelection()
          if ($selection.Length -gt 0) { $selectedText = ConvertTo-CuInline ($selection[0].GetText(-1)) $MaxTextChars }
          $documentText = ConvertTo-CuInline ($textPattern.DocumentRange.GetText($MaxTextChars)) $MaxTextChars
        }
      } catch { }
      if ($documentText -eq '') { $documentText = Get-CuElementValue $focused $MaxTextChars }
    }
  } catch { }
  return @{
    tree = ($lines -join "`n") + "`n"
    focused_element = $focusedLine
    focused_is_password = $focusedIsPassword
    selected_text = $selectedText
    document_text = $documentText
    element_count = $count
    truncated = $truncated
    elements = $elements
  }
}

# ---------------------------------------------------------------------------
# Observation state cache
# ---------------------------------------------------------------------------
function New-CuWindowState([IntPtr]$Hwnd, $Snapshot, $Screenshots, $Accessibility) {
  $script:StateSeq = $script:StateSeq + 1
  $stateId = 's-' + $script:StateSeq
  foreach ($key in @($script:States.Keys)) {
    if ($script:States[$key].window_id -eq $Snapshot.window_id) { $script:States.Remove($key) }
  }
  if ($script:States.Count -ge 8) {
    $oldestKey = $null
    $oldestTime = $null
    foreach ($key in @($script:States.Keys)) {
      $created = $script:States[$key].created_at
      if ($oldestTime -eq $null -or $created -lt $oldestTime) { $oldestTime = $created; $oldestKey = $key }
    }
    if ($oldestKey -ne $null) { $script:States.Remove($oldestKey) }
  }
  $elements = $null
  if ($Accessibility -ne $null) { $elements = $Accessibility.elements }
  $script:States[$stateId] = @{
    state_id = $stateId
    window_id = $Snapshot.window_id
    hwnd = $Hwnd
    window = $Snapshot
    screenshots = @($Screenshots)
    accessibility = $Accessibility
    elements = $elements
    created_at = (Get-Date)
  }
  return $stateId
}

function Resolve-CuState([string]$StateId) {
  if ([string]::IsNullOrWhiteSpace($StateId)) { Throw-Cu 'INVALID_PARAMS' 'state_id is required; call get_window_state (computer_observe) first' }
  if (-not $script:States.ContainsKey($StateId)) {
    Throw-Cu 'STALE_STATE' "state_id '$StateId' is unknown or was invalidated by a newer observation; observe again"
  }
  return $script:States[$StateId]
}

function Convert-CuImagePoint($State, [double]$X, [double]$Y, $Params) {
  if ($State.screenshots.Count -eq 0) {
    Throw-Cu 'INVALID_PARAMS' 'this state was captured without a screenshot; coordinate actions need include_screenshot=true'
  }
  $scaleX = 1.0
  $scaleY = 1.0
  $imageScale = Get-ParamValue $Params 'image_scale' $null
  if ($imageScale -ne $null) {
    $sx = Get-ParamValue $imageScale 'x' 1.0
    $sy = Get-ParamValue $imageScale 'y' 1.0
    if ($sx -ne $null) { $scaleX = [double]$sx }
    if ($sy -ne $null) { $scaleY = [double]$sy }
  }
  if ($scaleX -le 0) { $scaleX = 1.0 }
  if ($scaleY -le 0) { $scaleY = 1.0 }
  $shot = $State.screenshots[0]
  $screenX = [int][Math]::Round([double]$shot.origin_x + $X * [double]$shot.capture_scale_x * $scaleX)
  $screenY = [int][Math]::Round([double]$shot.origin_y + $Y * [double]$shot.capture_scale_y * $scaleY)
  return @{ x = $screenX; y = $screenY }
}

function Get-CuForegroundWindowId {
  $fg = [CuNative]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return [long]0 }
  return [long]$fg.ToInt64()
}

function Get-CuCursor {
  $point = New-Object CuNative+POINT
  $ok = [CuNative]::GetCursorPos([ref]$point)
  if (-not $ok) { return @{ x = 0; y = 0 } }
  return @{ x = [int]$point.X; y = [int]$point.Y }
}

function Get-CuDisplays {
  $result = New-Object System.Collections.Generic.List[object]
  try {
    $monitors = [CuNative]::Monitors()
  } catch { $monitors = @() }
  $index = 0
  foreach ($monitor in $monitors) {
    $result.Add(@{
      index = $index
      primary = ($index -eq 0)
      x = [int]$monitor.Left
      y = [int]$monitor.Top
      width = [int]($monitor.Right - $monitor.Left)
      height = [int]($monitor.Bottom - $monitor.Top)
      scale_factor = 1.0
    })
    $index = $index + 1
  }
  return $result
}

function Get-CuVirtualScreen {
  return @{
    x = [CuNative]::GetSystemMetrics(76)
    y = [CuNative]::GetSystemMetrics(77)
    width = [CuNative]::GetSystemMetrics(78)
    height = [CuNative]::GetSystemMetrics(79)
  }
}

function Test-CuSecureDesktop {
  try {
    $name = [CuNative]::InputDesktopName()
    return (-not ($name -eq 'Default'))
  } catch { return $true }
}

# ---------------------------------------------------------------------------
# Keyboard mapping (X11-keysym-style names -> virtual keys / scan codes)
# ---------------------------------------------------------------------------
$script:KeyMap = @{}
$script:ShiftedKeys = @{}
$script:ModifierVk = @{
  'control' = 0x11; 'control_l' = 0x11; 'control_r' = 0x11; 'ctrl' = 0x11; 'ctrl_l' = 0x11; 'ctrl_r' = 0x11;
  'shift' = 0x10; 'shift_l' = 0x10; 'shift_r' = 0x10;
  'alt' = 0x12; 'alt_l' = 0x12; 'alt_r' = 0x12; 'altgr' = 0x12; 'option' = 0x12
}
foreach ($letter in [char[]]'abcdefghijklmnopqrstuvwxyz') {
  $script:KeyMap[[string]$letter] = @([int][char]::ToUpper($letter), 0, $false)
}
foreach ($digit in 0..9) {
  $script:KeyMap[[string]$digit] = @((0x30 + $digit), 0, $false)
}
foreach ($fIndex in 1..24) {
  $script:KeyMap['f' + $fIndex] = @((0x6F + $fIndex), 0, $false)
}
$namedKeys = @{
  'return' = @(0x0D, 0x1C, $false); 'enter' = @(0x0D, 0x1C, $false);
  'escape' = @(0x1B, 0x01, $false); 'esc' = @(0x1B, 0x01, $false);
  'tab' = @(0x09, 0x0F, $false);
  'backspace' = @(0x08, 0x0E, $false); 'back_space' = @(0x08, 0x0E, $false);
  'delete' = @(0x2E, 0x53, $true); 'del' = @(0x2E, 0x53, $true);
  'insert' = @(0x2D, 0x52, $true); 'ins' = @(0x2D, 0x52, $true);
  'home' = @(0x24, 0x47, $true); 'end' = @(0x23, 0x4F, $true);
  'page_up' = @(0x21, 0x49, $true); 'pageup' = @(0x21, 0x49, $true); 'prior' = @(0x21, 0x49, $true);
  'page_down' = @(0x22, 0x51, $true); 'pagedown' = @(0x22, 0x51, $true); 'next' = @(0x22, 0x51, $true);
  'up' = @(0x26, 0x48, $true); 'down' = @(0x28, 0x50, $true); 'left' = @(0x25, 0x4B, $true); 'right' = @(0x27, 0x4D, $true);
  'space' = @(0x20, 0x39, $false);
  'period' = @(0xBE, 0, $false); 'comma' = @(0xBC, 0, $false); 'slash' = @(0xBF, 0, $false); 'backslash' = @(0xDC, 0, $false);
  'semicolon' = @(0xBA, 0, $false); 'apostrophe' = @(0xDE, 0, $false); 'minus' = @(0xBD, 0, $false); 'equal' = @(0xBB, 0, $false);
  'grave' = @(0xC0, 0, $false); 'bracketleft' = @(0xDB, 0, $false); 'bracketright' = @(0xDD, 0, $false);
  'print' = @(0x2C, 0, $true); 'printscreen' = @(0x2C, 0, $true);
  'kp_0' = @(0x60, 0, $false); 'kp_1' = @(0x61, 0, $false); 'kp_2' = @(0x62, 0, $false); 'kp_3' = @(0x63, 0, $false);
  'kp_4' = @(0x64, 0, $false); 'kp_5' = @(0x65, 0, $false); 'kp_6' = @(0x66, 0, $false); 'kp_7' = @(0x67, 0, $false);
  'kp_8' = @(0x68, 0, $false); 'kp_9' = @(0x69, 0, $false);
  'numpad_0' = @(0x60, 0, $false); 'numpad_1' = @(0x61, 0, $false); 'numpad_2' = @(0x62, 0, $false); 'numpad_3' = @(0x63, 0, $false);
  'numpad_4' = @(0x64, 0, $false); 'numpad_5' = @(0x65, 0, $false); 'numpad_6' = @(0x66, 0, $false); 'numpad_7' = @(0x67, 0, $false);
  'numpad_8' = @(0x68, 0, $false); 'numpad_9' = @(0x69, 0, $false);
  'numpad_add' = @(0x6B, 0, $false); 'kp_add' = @(0x6B, 0, $false);
  'numpad_subtract' = @(0x6D, 0, $false); 'kp_subtract' = @(0x6D, 0, $false);
  'numpad_multiply' = @(0x6A, 0, $false); 'kp_multiply' = @(0x6A, 0, $false);
  'numpad_divide' = @(0x6F, 0, $true); 'kp_divide' = @(0x6F, 0, $true);
  'numpad_decimal' = @(0x6E, 0, $false); 'kp_decimal' = @(0x6E, 0, $false);
  'numpad_enter' = @(0x0D, 0x1C, $true); 'kp_enter' = @(0x0D, 0x1C, $true)
}
foreach ($key in $namedKeys.Keys) { $script:KeyMap[$key] = $namedKeys[$key] }
$shiftedNames = @{
  'less' = 'comma'; 'greater' = 'period'; 'question' = 'slash'; 'colon' = 'semicolon'; 'plus' = 'equal';
  'underscore' = 'minus'; 'quotedbl' = 'apostrophe'; 'asciitilde' = 'grave'; 'braceleft' = 'bracketleft';
  'braceright' = 'bracketright'; 'bar' = 'backslash'; 'exclam' = '1'; 'at' = '2'; 'numbersign' = '3';
  'dollar' = '4'; 'percent' = '5'; 'asciicircum' = '6'; 'ampersand' = '7'; 'asterisk' = '8';
  'parenleft' = '9'; 'parenright' = '0'
}
foreach ($name in $shiftedNames.Keys) { $script:ShiftedKeys[$name] = $shiftedNames[$name] }
$script:ForbiddenKeyNames = @('meta','windows','win','super','os','cmd','command','window','windowskey','lwin','rwin','lmeta','rmeta')

function Send-CuKeyTap([int]$Vk, [int]$Scan, [bool]$Extended) {
  if ($Scan -gt 0) {
    [void][CuNative]::Key([uint16]$Vk, [uint16]$Scan, $true, $Extended)
    Start-Sleep -Milliseconds 10
    [void][CuNative]::Key([uint16]$Vk, [uint16]$Scan, $false, $Extended)
  } else {
    [void][CuNative]::Key([uint16]$Vk, 0, $true, $Extended)
    Start-Sleep -Milliseconds 10
    [void][CuNative]::Key([uint16]$Vk, 0, $false, $Extended)
  }
}

function Resolve-CuKeyChord([string]$Chord) {
  if ([string]::IsNullOrWhiteSpace($Chord)) { Throw-Cu 'INVALID_PARAMS' 'key must be a non-empty chord such as "Control_L+a"' }
  $parts = @($Chord.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  if ($parts.Count -eq 0) { Throw-Cu 'INVALID_PARAMS' 'key must be a non-empty chord such as "Control_L+a"' }
  if ($parts.Count -gt 8) { Throw-Cu 'INVALID_PARAMS' 'key chord has too many parts (max 8)' }
  $modifiers = New-Object System.Collections.Generic.List[int]
  $mainEntry = $null
  $mainShifted = $false
  $mainName = ''
  foreach ($part in $parts) {
    $lower = $part.ToLowerInvariant()
    if ($script:ForbiddenKeyNames -contains $lower) {
      Throw-Cu 'FORBIDDEN_KEY' "the Windows/Meta key family ('$part') is a hard deny: it can drive the Start menu, system surfaces and window management outside the sandbox"
    }
    if ($script:ModifierVk.ContainsKey($lower)) {
      $vk = [int]$script:ModifierVk[$lower]
      if (-not ($modifiers -contains $vk)) { $modifiers.Add($vk) }
      continue
    }
    $entry = $null
    if ($script:ShiftedKeys.ContainsKey($lower)) {
      $mainShifted = $true
      $entry = $script:KeyMap[$script:ShiftedKeys[$lower]]
    } elseif ($script:KeyMap.ContainsKey($lower)) {
      $entry = $script:KeyMap[$lower]
    } else {
      Throw-Cu 'INVALID_PARAMS' "unknown key name '$part' (use names like Return, Escape, Tab, BackSpace, Delete, Up, Control_L, a, F5, KP_1, period)"
    }
    if ($mainEntry -ne $null) { Throw-Cu 'INVALID_PARAMS' 'a key chord must contain exactly one non-modifier key' }
    $mainEntry = $entry
    $mainName = $part
  }
  if ($mainEntry -eq $null) { Throw-Cu 'INVALID_PARAMS' 'a key chord must contain a non-modifier key' }
  $lowerChord = $Chord.ToLowerInvariant()
  if ($lowerChord -match 'control.*alt.*delete' -or $lowerChord -match 'ctrl.*alt.*del') {
    Throw-Cu 'FORBIDDEN_KEY' 'Ctrl+Alt+Delete is a secure attention sequence and cannot be injected'
  }
  return @{
    modifiers = @($modifiers)
    vk = [int]$mainEntry[0]
    scan = [int]$mainEntry[1]
    extended = [bool]$mainEntry[2]
    shifted = $mainShifted
    name = $mainName
  }
}

function Invoke-CuKeyChord([int]$Vk, [int]$Scan, [bool]$Extended, [bool]$Shifted, [int]$Repeat) {
  $pressed = New-Object System.Collections.Generic.List[int]
  $modifiers = $script:ActiveChordModifiers
  foreach ($modifier in $modifiers) {
    [void][CuNative]::Key([uint16]$modifier, 0, $true, $false)
    $pressed.Add($modifier)
    Start-Sleep -Milliseconds 12
  }
  $shiftVk = 0x10
  if ($Shifted -and -not ($pressed -contains $shiftVk)) {
    [void][CuNative]::Key([uint16]$shiftVk, 0, $true, $false)
    $pressed.Add($shiftVk)
    Start-Sleep -Milliseconds 12
  }
  for ($i = 0; $i -lt $Repeat; $i++) {
    Send-CuKeyTap $Vk $Scan $Extended
    if ($i -lt ($Repeat - 1)) { Start-Sleep -Milliseconds 40 }
  }
  for ($i = $pressed.Count - 1; $i -ge 0; $i--) {
    [void][CuNative]::Key([uint16]$pressed[$i], 0, $false, $false)
    Start-Sleep -Milliseconds 12
  }
}

# ---------------------------------------------------------------------------
# Input action helpers
# ---------------------------------------------------------------------------
function Start-CuInputTarget($State) {
  Assert-InteractiveDesktop
  Assert-WindowAllowed $State.hwnd | Out-Null
  [void][CuNative]::Activate($State.hwnd)
  Assert-ForegroundTarget $State.hwnd
}

function Get-CuFocusedSummary {
  $line = ''
  $isPassword = $false
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($focused -ne $null) {
      $line = Format-CuElementLine $focused -1 0
      try { $isPassword = [bool]$focused.Current.IsPassword } catch { }
    }
  } catch { }
  return @{ line = $line; is_password = $isPassword }
}

function Submit-CuClick($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $buttonName = (Get-ParamString $Params 'button' 'left').ToLowerInvariant()
  $button = 0
  if ($buttonName -eq 'right') { $button = 1 }
  elseif ($buttonName -eq 'middle') { $button = 2 }
  elseif ($buttonName -eq 'left') { $button = 0 }
  else { Throw-Cu 'INVALID_PARAMS' "button must be left, right, or middle (got '$buttonName')" }
  $count = Get-ParamInt $Params 'click_count' 1
  if ($count -lt 1 -or $count -gt 3) { Throw-Cu 'INVALID_PARAMS' 'click_count must be between 1 and 3' }
  $elementIndex = Get-ParamValue $Params 'element_index' $null
  $xValue = Get-ParamValue $Params 'x' $null
  $yValue = Get-ParamValue $Params 'y' $null
  $point = $null
  $target = ''
  if ($elementIndex -ne $null) {
    $index = 0
    try { $index = [int]$elementIndex } catch { Throw-Cu 'INVALID_PARAMS' 'element_index must be an integer' }
    if ($state.elements -eq $null -or -not $state.elements.ContainsKey($index)) {
      Throw-Cu 'ELEMENT_NOT_FOUND' "element_index $index is not in the tree of state '$($state.state_id)'; call get_window_state with include_text=true first"
    }
    $element = $state.elements[$index]
    $rect = $null
    $offscreen = $false
    try {
      $rect = $element.Current.BoundingRectangle
      $offscreen = [bool]$element.Current.IsOffscreen
    } catch {
      Throw-Cu 'ELEMENT_NOT_FOUND' "element_index $index is no longer available; observe again"
    }
    if ($offscreen -or $rect.Width -le 0 -or $rect.Height -le 0) {
      Throw-Cu 'ELEMENT_OFFSCREEN' "element_index $index is not visible; scroll it into view and observe again"
    }
    $point = @{ x = [int]($rect.Left + ($rect.Width / 2)); y = [int]($rect.Top + ($rect.Height / 2)) }
    $target = "element $index center ($($point.x),$($point.y))"
  } elseif ($xValue -ne $null -and $yValue -ne $null) {
    $point = Convert-CuImagePoint $state ([double]$xValue) ([double]$yValue) $Params
    $target = "image ($xValue,$yValue) -> screen ($($point.x),$($point.y))"
  } else {
    Throw-Cu 'INVALID_PARAMS' 'click requires either element_index or (x, y)'
  }
  Start-CuInputTarget $state
  for ($i = 0; $i -lt $count; $i++) {
    if (-not [CuNative]::MouseButton($button, $true, $point.x, $point.y)) { Throw-Cu 'INTERNAL' 'SendInput mouse-down failed' }
    Start-Sleep -Milliseconds 45
    if (-not [CuNative]::MouseButton($button, $false, $point.x, $point.y)) { Throw-Cu 'INTERNAL' 'SendInput mouse-up failed' }
    if ($i -lt ($count - 1)) { Start-Sleep -Milliseconds 90 }
  }
  return @{
    ok = $true
    window_id = $state.window_id
    target = $target
    foreground_window_id = (Get-CuForegroundWindowId)
    focused_element = (Get-CuFocusedSummary).line
  }
}

function Submit-CuMove($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $xValue = Get-ParamValue $Params 'x' $null
  $yValue = Get-ParamValue $Params 'y' $null
  if ($xValue -eq $null -or $yValue -eq $null) { Throw-Cu 'INVALID_PARAMS' 'move requires x and y' }
  $point = Convert-CuImagePoint $state ([double]$xValue) ([double]$yValue) $Params
  if (-not [CuNative]::MouseMoveAbsolute($point.x, $point.y)) { Throw-Cu 'INTERNAL' 'SendInput mouse-move failed' }
  Start-Sleep -Milliseconds 40
  $cursor = Get-CuCursor
  return @{ ok = $true; cursor = $cursor; window_id = $state.window_id }
}

function Submit-CuTypeText($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $text = Get-ParamString $Params 'text'
  if ($text -eq '') { Throw-Cu 'INVALID_PARAMS' 'text must be a non-empty string' }
  Assert-InteractiveDesktop
  Assert-WindowAllowed $state.hwnd | Out-Null
  $focusedSummary = Get-CuFocusedSummary
  if ($focusedSummary.is_password) {
    Throw-Cu 'PASSWORD_FIELD' 'the focused control is a password field; typing credentials is never allowed through computer use'
  }
  [void][CuNative]::Activate($state.hwnd)
  Assert-ForegroundTarget $state.hwnd
  $i = 0
  $typedUnits = 0
  while ($i -lt $text.Length) {
    $ch = $text[$i]
    if ($ch -eq "`r" -or $ch -eq "`n") {
      if ($ch -eq "`r" -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq "`n") { $i = $i + 1 }
      Send-CuKeyTap 0x0D 0x1C $false
      $typedUnits = $typedUnits + 1
    } elseif ($ch -eq "`t") {
      Send-CuKeyTap 0x09 0x0F $false
      $typedUnits = $typedUnits + 1
    } else {
      $unit = [uint16][int][char]$ch
      if (-not [CuNative]::UnicodeUnit($unit, $true)) { Throw-Cu 'INTERNAL' 'SendInput unicode key-down failed' }
      if (-not [CuNative]::UnicodeUnit($unit, $false)) { Throw-Cu 'INTERNAL' 'SendInput unicode key-up failed' }
      $typedUnits = $typedUnits + 1
      Start-Sleep -Milliseconds 2
    }
    $i = $i + 1
  }
  Start-Sleep -Milliseconds 80
  return @{
    ok = $true
    characters = $text.Length
    units = $typedUnits
    window_id = $state.window_id
    foreground_window_id = (Get-CuForegroundWindowId)
    focused_element = (Get-CuFocusedSummary).line
  }
}

function Submit-CuPressKey($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $chord = Resolve-CuKeyChord (Get-ParamString $Params 'key')
  $repeat = Get-ParamInt $Params 'repeat' 1
  if ($repeat -lt 1 -or $repeat -gt 20) { Throw-Cu 'INVALID_PARAMS' 'repeat must be between 1 and 20' }
  Start-CuInputTarget $state
  $script:ActiveChordModifiers = $chord.modifiers
  try { Invoke-CuKeyChord $chord.vk $chord.scan $chord.extended $chord.shifted $repeat } finally { $script:ActiveChordModifiers = @() }
  Start-Sleep -Milliseconds 60
  return @{
    ok = $true
    key = $chord.name
    modifiers = @($chord.modifiers)
    repeat = $repeat
    window_id = $state.window_id
    foreground_window_id = (Get-CuForegroundWindowId)
    focused_element = (Get-CuFocusedSummary).line
  }
}

function Submit-CuScroll($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $scrollX = 0.0
  $scrollY = 0.0
  $rawY = Get-ParamValue $Params 'scroll_y' $null
  $rawX = Get-ParamValue $Params 'scroll_x' $null
  if ($rawY -ne $null) { $scrollY = [double]$rawY }
  if ($rawX -ne $null) { $scrollX = [double]$rawX }
  if ($scrollX -eq 0 -and $scrollY -eq 0) { Throw-Cu 'INVALID_PARAMS' 'scroll requires a non-zero scroll_x or scroll_y' }
  $xValue = Get-ParamValue $Params 'x' $null
  $yValue = Get-ParamValue $Params 'y' $null
  if ($state.screenshots.Count -eq 0) { Throw-Cu 'INVALID_PARAMS' 'scrolling needs a screenshot-backed state (include_screenshot=true)' }
  if ($xValue -eq $null) { $xValue = [double]$state.screenshots[0].width / 2.0 }
  if ($yValue -eq $null) { $yValue = [double]$state.screenshots[0].height / 2.0 }
  $point = Convert-CuImagePoint $state ([double]$xValue) ([double]$yValue) $Params
  Start-CuInputTarget $state
  [void][CuNative]::MouseMoveAbsolute($point.x, $point.y)
  Start-Sleep -Milliseconds 40
  $messages = New-Object System.Collections.Generic.List[string]
  if ($scrollY -ne 0) {
    $notches = [Math]::Min(10, [Math]::Max(1, [int][Math]::Ceiling([Math]::Abs($scrollY) / 120.0)))
    $delta = if ($scrollY -lt 0) { 120 * $notches } else { -120 * $notches }
    if (-not [CuNative]::Wheel($delta, $false)) { Throw-Cu 'INTERNAL' 'SendInput vertical wheel failed' }
    $messages.Add(('y{0}{1} notch' -f ($(if ($scrollY -lt 0) { '-' } else { '+' })), $notches))
  }
  if ($scrollX -ne 0) {
    $notches = [Math]::Min(10, [Math]::Max(1, [int][Math]::Ceiling([Math]::Abs($scrollX) / 120.0)))
    $delta = if ($scrollX -lt 0) { -120 * $notches } else { 120 * $notches }
    if (-not [CuNative]::Wheel($delta, $true)) { Throw-Cu 'INTERNAL' 'SendInput horizontal wheel failed' }
    $messages.Add(('x{0}{1} notch' -f ($(if ($scrollX -lt 0) { '-' } else { '+' })), $notches))
  }
  Start-Sleep -Milliseconds 80
  return @{ ok = $true; scrolled = ($messages -join ', '); window_id = $state.window_id }
}

function Submit-CuDrag($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  foreach ($field in @('from_x', 'from_y', 'to_x', 'to_y')) {
    if ((Get-ParamValue $Params $field $null) -eq $null) { Throw-Cu 'INVALID_PARAMS' "drag requires numeric $field" }
  }
  $fromX = [double](Get-ParamValue $Params 'from_x' 0)
  $fromY = [double](Get-ParamValue $Params 'from_y' 0)
  $toX = [double](Get-ParamValue $Params 'to_x' 0)
  $toY = [double](Get-ParamValue $Params 'to_y' 0)
  $duration = Get-ParamInt $Params 'duration_ms' 600
  if ($duration -lt 100 -or $duration -gt 5000) { Throw-Cu 'INVALID_PARAMS' 'duration_ms must be between 100 and 5000' }
  $from = Convert-CuImagePoint $state $fromX $fromY $Params
  $to = Convert-CuImagePoint $state $toX $toY $Params
  Start-CuInputTarget $state
  [void][CuNative]::MouseMoveAbsolute($from.x, $from.y)
  Start-Sleep -Milliseconds 60
  [void][CuNative]::MouseButton(0, $true, $from.x, $from.y)
  Start-Sleep -Milliseconds 80
  $steps = [Math]::Max(10, [int]($duration / 20))
  for ($i = 1; $i -le $steps; $i++) {
    $ratio = [double]$i / [double]$steps
    $x = [int][Math]::Round($from.x + ($to.x - $from.x) * $ratio)
    $y = [int][Math]::Round($from.y + ($to.y - $from.y) * $ratio)
    [void][CuNative]::MouseMoveAbsolute($x, $y)
    Start-Sleep -Milliseconds ([Math]::Max(5, [int]($duration / $steps)))
  }
  [void][CuNative]::MouseButton(0, $false, $to.x, $to.y)
  Start-Sleep -Milliseconds 80
  return @{ ok = $true; from = $from; to = $to; window_id = $state.window_id }
}

function Submit-CuSetValue($Params) {
  $state = Resolve-CuState (Get-ParamString $Params 'state_id')
  $elementIndex = Get-ParamValue $Params 'element_index' $null
  $value = Get-ParamString $Params 'value'
  if ($elementIndex -eq $null) { Throw-Cu 'INVALID_PARAMS' 'set_value requires element_index' }
  $index = 0
  try { $index = [int]$elementIndex } catch { Throw-Cu 'INVALID_PARAMS' 'element_index must be an integer' }
  if ($state.elements -eq $null -or -not $state.elements.ContainsKey($index)) {
    Throw-Cu 'ELEMENT_NOT_FOUND' "element_index $index is not in the tree of state '$($state.state_id)'"
  }
  $element = $state.elements[$index]
  Assert-InteractiveDesktop
  Assert-WindowAllowed $state.hwnd | Out-Null
  try {
    if ([bool]$element.Current.IsPassword) { Throw-Cu 'PASSWORD_FIELD' 'refusing to set the value of a password field' }
  } catch {
    if ($_.Exception.Data.Contains('cu_code')) { throw }
  }
  $pattern = $null
  $supported = $false
  try { $supported = $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) } catch { $supported = $false }
  if (-not $supported -or $pattern -eq $null) {
    Throw-Cu 'ELEMENT_UNSUPPORTED' "element_index $index does not support the ValuePattern; click it and type instead"
  }
  try { $pattern.SetValue($value) } catch {
    Throw-Cu 'ELEMENT_UNSUPPORTED' ("element_index $index rejected ValuePattern.SetValue: " + $_.Exception.Message)
  }
  Start-Sleep -Milliseconds 60
  return @{
    ok = $true
    element = (Format-CuElementLine $element $index 0)
    value = $value
    window_id = $state.window_id
  }
}

function Submit-CuActivateWindow($Params) {
  $windowId = Get-ParamValue $Params 'window_id' $null
  if ($windowId -eq $null) { Throw-Cu 'INVALID_PARAMS' 'activate_window requires window_id' }
  $hwnd = Get-WindowById ([long]$windowId)
  Assert-InteractiveDesktop
  Assert-WindowAllowed $hwnd | Out-Null
  $ok = [CuNative]::Activate($hwnd)
  if (-not $ok) {
    Start-Sleep -Milliseconds 120
    $ok = [CuNative]::Activate($hwnd)
  }
  if (-not $ok) { Throw-Cu 'ACTIVATION_FAILED' "window $windowId could not be brought to the foreground; ask the user to activate it" }
  $snapshot = Get-WindowSnapshot $hwnd -1
  return @{ ok = $true; window_id = [long]$windowId; title = $snapshot.title; foreground_window_id = (Get-CuForegroundWindowId) }
}

function Submit-CuWait($Params) {
  $ms = Get-ParamInt $Params 'ms' 500
  if ($ms -lt 0 -or $ms -gt 10000) { Throw-Cu 'INVALID_PARAMS' 'ms must be between 0 and 10000' }
  # Sleep in slices so ESC can abort a long wait promptly.
  $deadline = (Get-Date).AddMilliseconds($ms)
  while ($true) {
    if (Test-CuEscapeRequested) { Throw-Cu 'USER_ESCAPE' 'the user pressed ESC during wait; computer use is stopped' }
    $remaining = ($deadline - (Get-Date)).TotalMilliseconds
    if ($remaining -le 0) { break }
    $slice = [int][Math]::Min(150, [Math]::Max(1, $remaining))
    Start-Sleep -Milliseconds $slice
    Write-CuHeartbeat
  }
  return @{ ok = $true; waited_ms = $ms }
}

# ---------------------------------------------------------------------------
# Window / app listing
# ---------------------------------------------------------------------------
function Submit-CuListWindows($Params) {
  $includeMinimized = Get-ParamBool $Params 'include_minimized' $true
  $max = Get-ParamInt $Params 'max' 200
  if ($max -lt 1) { $max = 200 }
  $windows = @(Get-TargetableWindows $includeMinimized)
  if ($windows.Count -gt $max) { $windows = @($windows[0..($max - 1)]) }
  return @{
    windows = $windows
    foreground_window_id = (Get-CuForegroundWindowId)
  }
}

function Get-CuStartApps {
  if ($script:StartAppsCache -ne $null) { return $script:StartAppsCache }
  $list = @()
  try { $list = @(Get-StartApps -ErrorAction Stop) } catch { $list = @() }
  $script:StartAppsCache = $list
  return $list
}

function Submit-CuListApps($Params) {
  $includeWindows = Get-ParamBool $Params 'include_windows' $true
  $includeLaunchable = Get-ParamBool $Params 'include_launchable' $false
  $max = Get-ParamInt $Params 'max' 100
  $windows = @(Get-TargetableWindows $true)
  $groups = @{}
  foreach ($window in $windows) {
    $key = [string]$window.app_id
    if ($key -eq '') { $key = [string]$window.process_name }
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = @{
        app_id = [string]$window.app_id
        name = [string]$window.app_name
        process_name = [string]$window.process_name
        process_path = [string]$window.process_path
        publisher = [string]$window.publisher
        is_running = $true
        blocked = [bool]$window.blocked
        windows = @()
      }
    }
    if ($includeWindows) {
      $groups[$key].windows += @(@{
        window_id = [long]$window.window_id
        title = [string]$window.title
        is_foreground = [bool]$window.is_foreground
        is_minimized = [bool]$window.is_minimized
        blocked = [bool]$window.blocked
      })
    }
  }
  $apps = New-Object System.Collections.Generic.List[object]
  foreach ($key in $groups.Keys) { $apps.Add($groups[$key]) }
  if ($includeLaunchable) {
    $startApps = Get-CuStartApps
    foreach ($startApp in $startApps) {
      $appId = ''
      try { $appId = [string]$startApp.AppID } catch { }
      if ($appId -eq '') { continue }
      $apps.Add(@{
        app_id = $appId
        name = [string]$startApp.Name
        process_name = ''
        process_path = ''
        publisher = ''
        is_running = $false
        blocked = $false
        launch_id = 'shell:AppsFolder\' + $appId
        windows = @()
      })
    }
  }
  $appArray = $apps.ToArray()
  if ($appArray.Length -gt $max) { $appArray = $appArray[0..($max - 1)] }
  return @{ apps = $appArray }
}

# ---------------------------------------------------------------------------
# Window state capture
# ---------------------------------------------------------------------------
function Submit-CuGetWindowState($Params) {
  $windowId = Get-ParamValue $Params 'window_id' $null
  if ($windowId -eq $null) { Throw-Cu 'INVALID_PARAMS' 'get_window_state requires window_id' }
  $hwnd = Get-WindowById ([long]$windowId)
  Assert-InteractiveDesktop
  $snapshot = Assert-WindowAllowed $hwnd
  $includeScreenshot = Get-ParamBool $Params 'include_screenshot' $true
  $includeText = Get-ParamBool $Params 'include_text' $false
  $maxDepth = Get-ParamInt $Params 'max_depth' 12
  $maxElements = Get-ParamInt $Params 'max_elements' 600
  $maxTextChars = Get-ParamInt $Params 'max_text_chars' 20000
  $maxWidth = Get-ParamInt $Params 'screenshot_max_width' 1600
  $maxHeight = Get-ParamInt $Params 'screenshot_max_height' 1200
  if ($maxDepth -lt 1) { $maxDepth = 12 }
  if ($maxDepth -gt 24) { $maxDepth = 24 }
  if ($maxElements -lt 1) { $maxElements = 600 }
  if ($maxElements -gt 2000) { $maxElements = 2000 }
  if ($maxTextChars -lt 100) { $maxTextChars = 20000 }
  if ($maxWidth -lt 64) { $maxWidth = 1600 }
  if ($maxWidth -gt 4000) { $maxWidth = 4000 }
  if ($maxHeight -lt 64) { $maxHeight = 1200 }
  if ($maxHeight -gt 3000) { $maxHeight = 3000 }
  $screenshots = @()
  if ($includeScreenshot) {
    $screenshots = @(Save-CuScreenshot $hwnd $maxWidth $maxHeight)
  }
  $walk = $null
  if ($includeText) {
    try {
      $walk = Get-CuAccessibility $hwnd $maxDepth $maxElements $maxTextChars
    } catch {
      if ($_.Exception.Data.Contains('cu_code')) { throw }
      Throw-Cu 'UIA_FAILED' ("accessibility capture failed: " + $_.Exception.Message)
    }
  }
  $stateId = New-CuWindowState $hwnd $snapshot $screenshots $walk
  $accessOut = $null
  if ($walk -ne $null) {
    $accessOut = @{
      tree = $walk.tree
      focused_element = $walk.focused_element
      focused_is_password = [bool]$walk.focused_is_password
      selected_text = $walk.selected_text
      document_text = $walk.document_text
      element_count = [int]$walk.element_count
      truncated = [bool]$walk.truncated
    }
  }
  return @{
    state_id = $stateId
    captured_at = (Get-Date).ToString('o')
    window = $snapshot
    screenshots = @($screenshots)
    accessibility = $accessOut
    cursor = (Get-CuCursor)
    foreground_window_id = (Get-CuForegroundWindowId)
  }
}

# ---------------------------------------------------------------------------
# App launching
# ---------------------------------------------------------------------------
function Find-CuLaunchTarget([string]$App) {
  $trimmed = $App.Trim()
  if ($trimmed -eq '') { Throw-Cu 'INVALID_PARAMS' 'app is required' }
  if ($trimmed -match $script:BlockedLaunchPattern) {
    Throw-Cu 'BLOCKED_APP' ("launching '" + $trimmed + "' is blocked: computer use never launches terminals, shells, or OS administration surfaces")
  }
  if ($trimmed.StartsWith('shell:', [System.StringComparison]::OrdinalIgnoreCase)) {
    return @{ kind = 'shell'; resolved = $trimmed; exe_name = '' }
  }
  $expanded = $trimmed.Trim('"')
  try { $expanded = [System.Environment]::ExpandEnvironmentVariables($expanded) } catch { }
  if ([System.IO.Path]::IsPathRooted($expanded) -or $expanded -match '[\\/]') {
    if (Test-Path -LiteralPath $expanded) {
      $resolved = (Resolve-Path -LiteralPath $expanded).Path
      return @{ kind = 'path'; resolved = $resolved; exe_name = [System.IO.Path]::GetFileName($resolved) }
    }
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
      try {
        $command = Get-Command $expanded -ErrorAction Stop
        return @{ kind = 'path'; resolved = [string]$command.Source; exe_name = [System.IO.Path]::GetFileName([string]$command.Source) }
      } catch { }
    }
  }
  if ($expanded -notmatch '[\\/]') {
    try {
      $command = Get-Command $expanded -ErrorAction Stop
      if ($command.Source) {
        return @{ kind = 'path'; resolved = [string]$command.Source; exe_name = [System.IO.Path]::GetFileName([string]$command.Source) }
      }
    } catch { }
  }
  $startApps = Get-CuStartApps
  $hits = @($startApps | Where-Object { [string]$_.Name -ieq $expanded })
  if ($hits.Count -eq 0) {
    $hits = @($startApps | Where-Object { ([string]$_.Name).StartsWith($expanded, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($hits.Count -gt 1) {
      $hits = @($hits | Where-Object { [string]$_.Name -ieq $expanded })
    }
  }
  if ($hits.Count -gt 1) {
    $names = ($hits | ForEach-Object { [string]$_.Name }) -join ', '
    Throw-Cu 'APP_AMBIGUOUS' "app '$App' matches multiple Start-menu entries: $names; use the exact display name or an exe path"
  }
  if ($hits.Count -eq 1) {
    $hitName = [string]$hits[0].Name
    $appId = [string]$hits[0].AppID
    if ($hitName -match $script:BlockedLaunchPattern -or $appId -match $script:BlockedLaunchPattern) {
      Throw-Cu 'BLOCKED_APP' ("launching '" + $hitName + "' is blocked: computer use never launches terminals, shells, or OS administration surfaces")
    }
    return @{ kind = 'shell'; resolved = 'shell:AppsFolder\' + $appId; exe_name = '' }
  }
  Throw-Cu 'APP_NOT_FOUND' "could not resolve app '$App'; pass an .exe/.lnk path, a Start-menu display name, or shell:AppsFolder\<AUMID>"
}

function Submit-CuLaunchApp($Params) {
  $app = Get-ParamString $Params 'app'
  Assert-InteractiveDesktop
  $target = Find-CuLaunchTarget $app
  if ($target.exe_name -ne '' -and $script:BlockedProcessNames.Contains($target.exe_name)) {
    Throw-Cu 'BLOCKED_APP' ("launching '" + $target.exe_name + "' is blocked by computer-use policy")
  }
  $process = $null
  try {
    if ($target.kind -eq 'shell') {
      # Shell namespace paths (shell:AppsFolder\...) cannot be launched with
      # -PassThru; hand them to explorer.exe, which owns the shell namespace.
      Start-Process -FilePath 'explorer.exe' -ArgumentList $target.resolved -ErrorAction Stop
    } else {
      $process = Start-Process -FilePath $target.resolved -PassThru -ErrorAction Stop
    }
  } catch {
    Throw-Cu 'APP_NOT_FOUND' ("launch failed for '" + $target.resolved + "': " + $_.Exception.Message)
  }
  $launchedPid = 0
  if ($process -ne $null) {
    try { $launchedPid = [int]$process.Id } catch { }
  }
  return @{
    ok = $true
    app = $app
    resolved = [string]$target.resolved
    pid = $launchedPid
    kind = [string]$target.kind
  }
}

# ---------------------------------------------------------------------------
# Policy / introspection
# ---------------------------------------------------------------------------
function Submit-CuSetPolicy($Params) {
  $names = Get-ParamValue $Params 'blocked_process_names' $null
  if ($names -ne $null) {
    $script:BlockedProcessNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($names)) {
      if ($name -ne $null -and ([string]$name).Trim() -ne '') { [void]$script:BlockedProcessNames.Add(([string]$name).Trim()) }
    }
  }
  $appIds = Get-ParamValue $Params 'blocked_app_ids' $null
  if ($appIds -ne $null) {
    $script:BlockedAppIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($appId in @($appIds)) {
      if ($appId -ne $null -and ([string]$appId).Trim() -ne '') { [void]$script:BlockedAppIds.Add(([string]$appId).Trim()) }
    }
  }
  $classes = Get-ParamValue $Params 'blocked_window_class_names' $null
  if ($classes -ne $null) {
    $script:BlockedWindowClasses = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($className in @($classes)) {
      if ($className -ne $null -and ([string]$className).Trim() -ne '') { [void]$script:BlockedWindowClasses.Add(([string]$className).Trim()) }
    }
  }
  return @{
    ok = $true
    blocked_process_count = $script:BlockedProcessNames.Count
    blocked_window_class_count = $script:BlockedWindowClasses.Count
  }
}

function Submit-CuPing {
  return @{
    ok = $true
    version = $script:Version
    pid = $PID
    dpi_aware = $true
    virtual_screen = (Get-CuVirtualScreen)
    displays = @(Get-CuDisplays)
    foreground_window_id = (Get-CuForegroundWindowId)
    secure_desktop = (Test-CuSecureDesktop)
  }
}

function Submit-CuScreenInfo {
  return @{
    ok = $true
    virtual_screen = (Get-CuVirtualScreen)
    displays = @(Get-CuDisplays)
    cursor = (Get-CuCursor)
    foreground_window_id = (Get-CuForegroundWindowId)
    secure_desktop = (Test-CuSecureDesktop)
  }
}

function Submit-CuCursorPosition {
  return @{
    x = (Get-CuCursor).x
    y = (Get-CuCursor).y
    foreground_window_id = (Get-CuForegroundWindowId)
  }
}

# ---------------------------------------------------------------------------
# Method dispatch
# ---------------------------------------------------------------------------
function Submit-CuSequence($Params) {
  $windowId = Get-ParamValue $Params 'window_id' $null
  $steps = Get-ParamValue $Params 'steps' $null
  if ($steps -eq $null) { Throw-Cu 'INVALID_PARAMS' 'sequence requires a steps array' }
  $stepList = @($steps)
  if ($stepList.Count -eq 0) { Throw-Cu 'INVALID_PARAMS' 'sequence requires at least one step' }
  if ($stepList.Count -gt 100) { Throw-Cu 'INVALID_PARAMS' 'sequence supports at most 100 steps' }
  $snapshot = $null
  if ($windowId -ne $null) {
    $hwnd = Get-WindowById ([long]$windowId)
    $snapshot = Get-WindowSnapshot $hwnd 0
  } else {
    $fg = [CuNative]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { Throw-Cu 'NO_FOREGROUND' 'there is no foreground window to target' }
    $hwnd = $fg
    $snapshot = Get-WindowSnapshot $fg 0
  }
  Assert-InteractiveDesktop
  Assert-WindowAllowed $hwnd | Out-Null
  [void][CuNative]::Activate($hwnd)
  Assert-ForegroundTarget $hwnd
  $index = 0
  $executed = New-Object System.Collections.Generic.List[string]
  $started = Get-Date
  foreach ($step in $stepList) {
    # Between steps the ESC kill switch aborts the rest of the batch.
    if (Test-CuEscapeRequested) {
      Throw-Cu 'USER_ESCAPE' ("the user pressed ESC after step " + $index + " of " + $stepList.Count + "; the sequence was stopped")
    }
    Write-CuHeartbeat
    $action = [string](Get-ParamValue $step 'action' '')
    $index = $index + 1
    if ([CuNative]::GetForegroundWindow() -ne $hwnd) {
      [void][CuNative]::Activate($hwnd)
      Assert-ForegroundTarget $hwnd
    }
    switch ($action) {
      'click' {
        $x = [int](Get-ParamValue $step 'x' 0)
        $y = [int](Get-ParamValue $step 'y' 0)
        $buttonName = (Get-ParamString $step 'button' 'left').ToLowerInvariant()
        $button = 0
        if ($buttonName -eq 'right') { $button = 1 } elseif ($buttonName -eq 'middle') { $button = 2 }
        $count = Get-ParamInt $step 'click_count' 1
        if ($count -lt 1 -or $count -gt 3) { Throw-Cu 'INVALID_PARAMS' 'click_count must be between 1 and 3' }
        [void][CuNative]::MouseMoveAbsolute($x, $y)
        Start-Sleep -Milliseconds 40
        for ($i = 0; $i -lt $count; $i++) {
          [void][CuNative]::MouseButton($button, $true, $x, $y)
          Start-Sleep -Milliseconds 45
          [void][CuNative]::MouseButton($button, $false, $x, $y)
          if ($i -lt ($count - 1)) { Start-Sleep -Milliseconds 90 }
        }
        Start-Sleep -Milliseconds 60
        $executed.Add("click ($x,$y)")
      }
      'move' {
        $x = [int](Get-ParamValue $step 'x' 0)
        $y = [int](Get-ParamValue $step 'y' 0)
        [void][CuNative]::MouseMoveAbsolute($x, $y)
        Start-Sleep -Milliseconds 30
        $executed.Add("move ($x,$y)")
      }
      'drag' {
        $fromX = [int](Get-ParamValue $step 'from_x' 0)
        $fromY = [int](Get-ParamValue $step 'from_y' 0)
        $toX = [int](Get-ParamValue $step 'to_x' 0)
        $toY = [int](Get-ParamValue $step 'to_y' 0)
        $duration = Get-ParamInt $step 'duration_ms' 600
        if ($duration -lt 100 -or $duration -gt 5000) { Throw-Cu 'INVALID_PARAMS' 'duration_ms must be between 100 and 5000' }
        [void][CuNative]::MouseMoveAbsolute($fromX, $fromY)
        Start-Sleep -Milliseconds 60
        [void][CuNative]::MouseButton(0, $true, $fromX, $fromY)
        Start-Sleep -Milliseconds 90
        $moveSteps = [Math]::Max(12, [int]($duration / 18))
        for ($i = 1; $i -le $moveSteps; $i++) {
          $ratio = [double]$i / [double]$moveSteps
          $x = [int][Math]::Round($fromX + ($toX - $fromX) * $ratio)
          $y = [int][Math]::Round($fromY + ($toY - $fromY) * $ratio)
          [void][CuNative]::MouseMoveAbsolute($x, $y)
          Start-Sleep -Milliseconds ([Math]::Max(8, [int]($duration / $moveSteps)))
        }
        Start-Sleep -Milliseconds 60
        [void][CuNative]::MouseButton(0, $false, $toX, $toY)
        Start-Sleep -Milliseconds 120
        $executed.Add("drag ($fromX,$fromY)->($toX,$toY)")
      }
      'type' {
        $text = Get-ParamString $step 'text'
        if ($text -eq '') { Throw-Cu 'INVALID_PARAMS' 'type step requires text' }
        $focusedSummary = Get-CuFocusedSummary
        if ($focusedSummary.is_password) { Throw-Cu 'PASSWORD_FIELD' 'the focused control is a password field; typing credentials is never allowed through computer use' }
        $i = 0
        while ($i -lt $text.Length) {
          $ch = $text[$i]
          if ($ch -eq "`r" -or $ch -eq "`n") {
            if ($ch -eq "`r" -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq "`n") { $i = $i + 1 }
            Send-CuKeyTap 0x0D 0x1C $false
          } elseif ($ch -eq "`t") {
            Send-CuKeyTap 0x09 0x0F $false
          } else {
            $unit = [uint16][int][char]$ch
            [void][CuNative]::UnicodeUnit($unit, $true)
            [void][CuNative]::UnicodeUnit($unit, $false)
            Start-Sleep -Milliseconds 2
          }
          $i = $i + 1
        }
        Start-Sleep -Milliseconds 80
        $executed.Add("type " + $text.Length + " chars")
      }
      'key' {
        $chord = Resolve-CuKeyChord (Get-ParamString $step 'key')
        $repeat = Get-ParamInt $step 'repeat' 1
        if ($repeat -lt 1 -or $repeat -gt 20) { Throw-Cu 'INVALID_PARAMS' 'repeat must be between 1 and 20' }
        $script:ActiveChordModifiers = $chord.modifiers
        try { Invoke-CuKeyChord $chord.vk $chord.scan $chord.extended $chord.shifted $repeat } finally { $script:ActiveChordModifiers = @() }
        Start-Sleep -Milliseconds 60
        $executed.Add("key " + $chord.name)
      }
      'wait' {
        $ms = Get-ParamInt $step 'ms' 300
        if ($ms -lt 0 -or $ms -gt 10000) { Throw-Cu 'INVALID_PARAMS' 'wait ms must be between 0 and 10000' }
        Start-Sleep -Milliseconds $ms
        $executed.Add("wait " + $ms + "ms")
      }
      'wheel' {
        $scrollY = Get-ParamValue $step 'scroll_y' $null
        $scrollX = Get-ParamValue $step 'scroll_x' $null
        $xValue = Get-ParamValue $step 'x' $null
        $yValue = Get-ParamValue $step 'y' $null
        if ($xValue -ne $null -and $yValue -ne $null) {
          [void][CuNative]::MouseMoveAbsolute([int]$xValue, [int]$yValue)
          Start-Sleep -Milliseconds 30
        }
        if ($scrollY -ne $null -and [double]$scrollY -ne 0) {
          $notches = [Math]::Min(10, [Math]::Max(1, [int][Math]::Ceiling([Math]::Abs([double]$scrollY) / 120.0)))
          $delta = if ([double]$scrollY -lt 0) { 120 * $notches } else { -120 * $notches }
          [void][CuNative]::Wheel($delta, $false)
          Start-Sleep -Milliseconds 50
        }
        if ($scrollX -ne $null -and [double]$scrollX -ne 0) {
          $notches = [Math]::Min(10, [Math]::Max(1, [int][Math]::Ceiling([Math]::Abs([double]$scrollX) / 120.0)))
          $delta = if ([double]$scrollX -lt 0) { -120 * $notches } else { 120 * $notches }
          [void][CuNative]::Wheel($delta, $true)
          Start-Sleep -Milliseconds 50
        }
        $executed.Add('wheel')
      }
      default { Throw-Cu 'INVALID_PARAMS' "unknown sequence step action '$action'" }
    }
  }
  $elapsed = [int](((Get-Date) - $started).TotalMilliseconds)
  return @{
    ok = $true
    window_id = $snapshot.window_id
    steps = $index
    elapsed_ms = $elapsed
    actions = $executed
    foreground_window_id = (Get-CuForegroundWindowId)
    focused_element = (Get-CuFocusedSummary).line
  }
}

function Invoke-CuMethod([string]$Method, $Params) {
  switch ($Method) {
    'ping' { return Submit-CuPing }
    'list_windows' { return Submit-CuListWindows $Params }
    'list_apps' { return Submit-CuListApps $Params }
    'get_window_state' { return Submit-CuGetWindowState $Params }
    'click' { return Submit-CuClick $Params }
    'move' { return Submit-CuMove $Params }
    'type_text' { return Submit-CuTypeText $Params }
    'press_key' { return Submit-CuPressKey $Params }
    'scroll' { return Submit-CuScroll $Params }
    'drag' { return Submit-CuDrag $Params }
    'sequence' { return Submit-CuSequence $Params }
    'set_value' { return Submit-CuSetValue $Params }
    'activate_window' { return Submit-CuActivateWindow $Params }
    'wait' { return Submit-CuWait $Params }
    'launch_app' { return Submit-CuLaunchApp $Params }
    'cursor_position' { return Submit-CuCursorPosition }
    'screen_info' { return Submit-CuScreenInfo }
    'set_policy' { return Submit-CuSetPolicy $Params }
    'shutdown' { $script:Stopping = $true; Stop-CuOverlay; return @{ ok = $true } }
    default { Throw-Cu 'UNKNOWN_METHOD' "unknown method '$Method'" }
  }
}

# ---------------------------------------------------------------------------
# JSON-lines transport loop
# ---------------------------------------------------------------------------
Initialize-TempRoot
$stdinStream = [Console]::OpenStandardInput()
$stdoutStream = [Console]::OpenStandardOutput()
$reader = New-Object System.IO.StreamReader($stdinStream, (New-Object System.Text.UTF8Encoding($false)), $false)
$writer = New-Object System.IO.StreamWriter($stdoutStream, (New-Object System.Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
Write-Log ("helper started version=" + $script:Version + " pid=" + $PID)
while ($true) {
  $line = $null
  try { $line = $reader.ReadLine() } catch { break }
  if ($line -eq $null) { break }
  if ($line.Trim() -eq '') { continue }
  $requestId = $null
  $response = $null
  try {
    $request = ConvertFrom-Json -InputObject $line
    $requestId = $null
    try { $requestId = $request.id } catch { }
    $method = ''
    try { $method = [string]$request.method } catch { }
    $params = $null
    try { $params = $request.params } catch { }
    if ($method -eq '') { Throw-Cu 'INVALID_PARAMS' 'request is missing method' }
    # ESC kill switch + overlay keep-alive. Infrastructure calls (handshake,
    # policy, shutdown) neither show the overlay nor get blocked by a pending stop.
    if ($method -ne 'ping' -and $method -ne 'set_policy' -and $method -ne 'shutdown') {
      if (Test-CuEscapeRequested) {
        Throw-Cu 'USER_ESCAPE' 'the user pressed ESC; computer use is stopped until the user asks again'
      }
      Invoke-CuOverlayActivity
    }
    $result = Invoke-CuMethod $method $params
    $response = @{ id = $requestId; ok = $true; result = $result }
  } catch {
    $code = 'INTERNAL'
    $message = ''
    try { $message = $_.Exception.Message } catch { }
    try {
      if ($_.Exception.Data.Contains('cu_code')) { $code = [string]$_.Exception.Data['cu_code'] }
    } catch { }
    if ($message -eq '') { $message = 'unexpected helper failure' }
    if ($code -eq 'INTERNAL') { Write-Log ("internal error: " + $message); try { Write-Log ("stack: " + $_.ScriptStackTrace) } catch { } }
    $response = @{ id = $requestId; ok = $false; error = @{ code = $code; message = $message } }
  }
  try {
    $json = ConvertTo-Json -InputObject $response -Depth 40 -Compress
  } catch {
    $json = '{"id":null,"ok":false,"error":{"code":"INTERNAL","message":"failed to serialize response"}}'
  }
  try { $writer.WriteLine($json) } catch { break }
  if ($script:Stopping) { break }
}
try { $writer.Flush() } catch { }
Stop-CuOverlay
Write-Log 'helper exiting'


