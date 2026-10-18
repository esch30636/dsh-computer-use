#requires -Version 5.1
<#
.SYNOPSIS
  Prepare (or refresh) a DSH headless profile that composes dsh-computer-use,
  then run a real one-shot agent task against it for end-to-end verification.

.DESCRIPTION
  The shipped headless profile disables the managed credential store and the
  DeepSeek account platform, so a restored-auth patch is written into the test
  profile. The profile is created from the shipped headless template when it
  does not exist yet.

.PARAMETER Name
  Test profile name (default: cu-test).

.PARAMETER Task
  Optional task to run once the profile is prepared.

.PARAMETER DshExe
  Path to "DeepSeek Harness.exe"; auto-detected when omitted.

.PARAMETER SkipInstall
  Only ensure the profile exists and run the optional task; do not reinstall
  the plugin or rewrite the restored-auth patch.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-test-profile.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-test-profile.ps1 -Task "Use the computer_ tools to open Notepad, type hello, and take a screenshot."
#>
[CmdletBinding()]
param(
  [string]$Name = 'cu-test',
  [string]$Task = '',
  [string]$DshExe = '',
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Find-DshExe {
  if ($DshExe -ne '') { return $DshExe }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    'D:\Applications\DeepseekHarness\DeepSeek Harness.exe',
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
  throw "could not find DeepSeek Harness.exe; pass -DshExe <path>"
}

function Invoke-DshBin {
  param([string[]]$Arguments)
  $previous = $env:ELECTRON_RUN_AS_NODE
  try {
    $env:ELECTRON_RUN_AS_NODE = '1'
    $output = & $script:DshExe $script:DshBin @Arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
  } finally {
    if ($previous -eq $null) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $previous }
  }
  return @{ Output = $output; Exit = $exit }
}

$script:DshExe = Find-DshExe
$script:DshBin = Join-Path (Split-Path -Parent $script:DshExe) 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
# The launcher path lives inside app.asar, which Test-Path cannot see; invoking
# it through the Electron-as-node binary is the supported way and fails loudly.
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Name
$pluginRoot = Split-Path -Parent $PSScriptRoot

Write-Step "DSH executable: $script:DshExe"
Write-Step "Test profile:   $profileDir"

if (-not (Test-Path -LiteralPath (Join-Path $profileDir 'package.json'))) {
  Write-Step "Creating profile '$Name' from the shipped headless template"
  $result = Invoke-DshBin -Arguments @('--profile', $Name, '--from-default-profile', 'headless', '--help')
  if ($result.Exit -ne 0) { throw "profile creation failed: $($result.Output)" }
  Write-Ok "created $profileDir"
}

if (-not $SkipInstall) {
  Write-Step "Installing dsh-computer-use into the test profile"
  & (Join-Path $PSScriptRoot 'install.ps1') -Profile $Name -Source $pluginRoot -SkipSkill

  Write-Step "Writing restored-auth + model patch into the test profile"
  $patchPath = Join-Path $profileDir 'cordis.patch.yml'
  $patch = ''
  if (Test-Path -LiteralPath $patchPath) { $patch = Get-Content -LiteralPath $patchPath -Raw }
  $restored = @'
# --- dsh-computer-use test profile: restore the managed sign-in the shipped
# --- headless bundle disables, so the agent can run one real task.
- id: credentials
  disabled: false
- id: authorization
  disabled: false
- id: deepseek-account
  disabled: false
- id: agent-default-model
  config:
    provider: deepseek-account
    model: deepseek-flash
- id: computer-use
  config:
    confirmRiskyActions: true
'@
  if ($patch -match 'dsh-computer-use test profile') {
    Write-Ok "patch already present"
  } else {
    # Replace the empty flow-mapping document with the patch rows.
    $lines = New-Object System.Collections.Generic.List[string]
    $patched = $false
    foreach ($line in ($patch -split "`r?`n")) {
      if (-not $patched -and $line.Trim() -eq '[]') {
        $lines.Add($restored)
        $patched = $true
      } elseif (-not $patched -and $line.Trim() -eq '') {
        $lines.Add($line)
      } elseif (-not $patched) {
        $lines.Add(('#' + $line))
      } else {
        $lines.Add($line)
      }
    }
    if (-not $patched) {
      $lines.Add($restored)
    }
    Set-Content -LiteralPath $patchPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Ok "patch written to $patchPath"
  }
}

if ($Task -ne '') {
  Write-Step "Running one-shot agent task in profile '$Name'"
  Write-Host "    task: $Task" -ForegroundColor Gray
  $result = Invoke-DshBin -Arguments @('--profile', $Name, '--json', $Task)
  $jsonPath = Join-Path $env:TEMP ("cu-e2e-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
  Set-Content -LiteralPath $jsonPath -Value $result.Output -Encoding UTF8
  Write-Ok "exit=$($result.Exit); event stream saved to $jsonPath"
  $toolCalls = @()
  foreach ($line in ($result.Output -split "`r?`n")) {
    if ($line.Trim() -eq '') { continue }
    try { $event = $line | ConvertFrom-Json } catch { continue }
    if ($event.type -eq 'tool_call') { $toolCalls += $event }
  }
  Write-Host ("    tool calls: " + (($toolCalls | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor Gray
  if ($result.Exit -ne 0) {
    Write-Warn "agent run failed; last output:"
    Write-Host (($result.Output -split "`r?`n" | Select-Object -Last 30) -join "`n") -ForegroundColor Red
  }
  Write-Ok "done"
} else {
  Write-Step "Profile ready. Run a task with:"
  Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-test-profile.ps1 -Task '...' -SkipInstall" -ForegroundColor Gray
}
