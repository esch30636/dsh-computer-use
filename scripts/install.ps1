#requires -Version 5.1
<#
.SYNOPSIS
  Install, update, or remove the dsh-computer-use plugin in a DSH profile.

.DESCRIPTION
  Copies the plugin package into <DSH_HOME>/profiles/<Profile>/node_modules/dsh-computer-use,
  adds it to the profile's dsh.profile.bundles list, and installs the computer-use
  skill into %USERPROFILE%\.agents\skills\computer-use.

  The plugin ships no client UI, so no client bundle rebuild is needed. After a
  successful install the running Web host recomposes through HMR (a restart is
  only needed if the host was started without the live-reload profile).

.PARAMETER Profile
  Profile name under $DSH_HOME/profiles (default: desktop).

.PARAMETER Source
  Plugin source directory (default: the parent of this script).

.PARAMETER Uninstall
  Remove the plugin from the profile and remove the installed skill.

.PARAMETER SkipSkill
  Do not install/remove the global computer-use skill.

.PARAMETER Verify
  After installing, run the profile's composition dump through the installed DSH
  executable to prove the plugin row resolves.

.PARAMETER DshExe
  Path to "DeepSeek Harness.exe" (only used with -Verify; auto-detected from
  common install locations when omitted).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Profile desktop

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Profile cu-test -Verify
#>
[CmdletBinding()]
param(
  [string]$Profile = 'desktop',
  [string]$Source = '',
  [switch]$Uninstall,
  [switch]$SkipSkill,
  [switch]$Verify,
  [string]$DshExe = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Read-TextFile([string]$Path) { return [System.IO.File]::ReadAllText($Path) }
function Write-TextFile([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

if ($Source -eq '') { $Source = Split-Path -Parent $PSScriptRoot }
$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not (Test-Path -LiteralPath (Join-Path $Source 'package.json'))) {
  throw "plugin source not found at $Source (package.json missing)"
}
$pluginManifest = Get-Content -LiteralPath (Join-Path $Source 'package.json') -Raw | ConvertFrom-Json
$pluginName = [string]$pluginManifest.name
$pluginVersion = [string]$pluginManifest.version
if ($pluginName -eq '') { throw "plugin package.json has no name" }

$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
$profileJson = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $profileJson)) {
  throw "DSH profile '$Profile' not found at $profileDir. Create it first, e.g.: `n  `"DeepSeek Harness.exe`" <dsh-cli-bin> --profile $Profile --from-default-profile headless --help"
}
$modulesDir = Join-Path $profileDir 'node_modules'
$targetDir = Join-Path $modulesDir $pluginName
$skillSource = Join-Path $Source 'skills\computer-use'
$skillTarget = Join-Path (Join-Path $HOME '.agents\skills') 'computer-use'

Write-Step "DSH home:   $dshHome"
Write-Step "Profile:    $Profile ($profileDir)"
Write-Step "Plugin:     $pluginName@$pluginVersion"

# --- package.json editing -----------------------------------------------------
$manifest = Read-TextFile $profileJson | ConvertFrom-Json
if ($manifest.dsh -eq $null -or $manifest.dsh.profile -eq $null) {
  throw "profile package.json has no dsh.profile section: $profileJson"
}
$bundles = @()
if ($manifest.dsh.profile.bundles -ne $null) { $bundles = @($manifest.dsh.profile.bundles) }
$hasBundle = $bundles -contains $pluginName

# --- copy / remove package ----------------------------------------------------
if ($Uninstall) {
  Write-Step "Uninstalling $pluginName from profile '$Profile'"
  if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
    Write-Ok "removed $targetDir"
  } else {
    Write-Ok "package directory already absent"
  }
  $bundles = @($bundles | Where-Object { $_ -ne $pluginName })
  $manifest.dsh.profile.bundles = @($bundles)
  $manifest | Add-Member -NotePropertyName _ignored -NotePropertyValue $null -Force
  $manifest.PSObject.Properties.Remove('_ignored')
  Write-TextFile $profileJson ($manifest | ConvertTo-Json -Depth 20)
  Write-Ok "removed '$pluginName' from dsh.profile.bundles"
  if (-not $SkipSkill -and (Test-Path -LiteralPath $skillTarget)) {
    Remove-Item -LiteralPath $skillTarget -Recurse -Force
    Write-Ok "removed skill $skillTarget"
  }
  Write-Step "Done. Restart the DSH host (or let HMR recompose) to unload the tools."
  return
}

Write-Step "Installing package into the profile"
New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null
if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
$includeDirs = @('lib', 'helper', 'skills', 'docs')
foreach ($dir in $includeDirs) {
  $from = Join-Path $Source $dir
  if (Test-Path -LiteralPath $from) {
    Copy-Item -LiteralPath $from -Destination $targetDir -Recurse -Force
  }
}
foreach ($file in @('package.json', 'cordis.patch.yml', 'README.md')) {
  $from = Join-Path $Source $file
  if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $targetDir -Force }
}
Write-Ok "copied to $targetDir"

if (-not $hasBundle) {
  $bundles = @($bundles) + $pluginName
  $manifest.dsh.profile.bundles = @($bundles)
  Copy-Item -LiteralPath $profileJson -Destination ("$profileJson.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
  Write-TextFile $profileJson ($manifest | ConvertTo-Json -Depth 20)
  Write-Ok "added '$pluginName' to dsh.profile.bundles (backup written)"
} else {
  Write-Ok "'$pluginName' already present in dsh.profile.bundles"
}

# --- skill --------------------------------------------------------------------
if (-not $SkipSkill) {
  if (Test-Path -LiteralPath $skillSource) {
    if (Test-Path -LiteralPath $skillTarget) { Remove-Item -LiteralPath $skillTarget -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $skillTarget) -Force | Out-Null
    Copy-Item -LiteralPath $skillSource -Destination $skillTarget -Recurse -Force
    Write-Ok "installed skill to $skillTarget"
  } else {
    Write-Warn "no skills\computer-use directory in the source; skipped skill install"
  }
}

# --- verify -------------------------------------------------------------------
if ($Verify) {
  Write-Step "Verifying the composition (--dump-config-schema imports every plugin module)"
  if ($DshExe -eq '') {
    $candidates = @(
      (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
      'D:\Applications\DeepseekHarness\DeepSeek Harness.exe',
      (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe')
    )
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { $DshExe = $candidate; break } }
  }
  if ($DshExe -eq '' -or -not (Test-Path -LiteralPath $DshExe)) {
    Write-Warn "could not find DeepSeek Harness.exe; run with -DshExe <path> to verify"
  } else {
    $bin = Join-Path (Split-Path -Parent $DshExe) 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
    # app.asar is a single file for Test-Path while the Electron-as-node binary
    # can load the launcher from it; just run it and let a failure surface.
    if ($true) {
      $previous = $env:ELECTRON_RUN_AS_NODE
      try {
        $env:ELECTRON_RUN_AS_NODE = '1'
        $output = & $DshExe $bin --profile $Profile --dump-config-schema 2>&1 | Out-String
        $exit = $LASTEXITCODE
      } finally {
        if ($previous -eq $null) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $previous }
      }
      if ($exit -ne 0) {
        Write-Warn "composition dump failed (exit $exit):"
        Write-Host $output -ForegroundColor Red
        throw "verification failed"
      }
      if ($output -match 'computer-use') {
        Write-Ok "composition includes the computer-use row"
      } else {
        Write-Warn "composition dump does not mention computer-use; check the profile bundles list"
      }
      Write-Ok "dump-config-schema exit 0"
    }
  }
}

Write-Step "Installed $pluginName@$pluginVersion into profile '$Profile'."
Write-Host @"
Next steps:
  * The running Web host picks the bundle up through HMR (live-reload profile).
    A host started without live reload needs a restart.
  * New sessions get the tools: computer_list_windows, computer_observe,
    computer_action, computer_sequence, computer_launch_app.
  * While computer use is active a click-through overlay shows the status and
    the user can press ESC to stop (USER_ESCAPE).
  * Configure the row in the profile's cordis.patch.yml if you need non-default
    options (see the plugin README).
"@ -ForegroundColor Gray
