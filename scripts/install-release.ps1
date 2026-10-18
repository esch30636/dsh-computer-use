#requires -Version 5.1
<#
.SYNOPSIS
  Install or update dsh-computer-use into a local DSH profile straight from the
  GitHub release (no git or pnpm required).

.DESCRIPTION
  Downloads the release tarball, extracts it, and runs scripts/install.ps1,
  which copies the package into <DSH_HOME>/profiles/<Profile>/node_modules,
  appends "dsh-computer-use" to dsh.profile.bundles (with a package.json
  backup), and installs the computer-use skill into %USERPROFILE%\.agents\skills.

  This is the installation path for the reserved "desktop" profile, where the
  `dsh plugin` CLI refuses to manage plugins (the Desktop app owns that profile).

.PARAMETER Profile
  DSH profile name to install into. Default: desktop.

.PARAMETER Repo
  GitHub repository. Default: esch30636/dsh-computer-use.

.PARAMETER Version
  Release tag to install (e.g. v1.1.0), or "latest". Default: latest.

.PARAMETER SkipSkill
  Do not install/update the global computer-use skill.

.PARAMETER Verify
  After installing, run the offline composition dump for the profile.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-release.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-release.ps1 -Profile web -Version v1.1.0 -Verify
#>
param(
  [string]$Profile = 'desktop',
  [string]$Repo = 'esch30636/dsh-computer-use',
  [string]$Version = 'latest',
  [switch]$SkipSkill,
  [switch]$Verify
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ReleaseAssetUrl([string]$Tag) {
  $assetVersion = $Tag
  if ($assetVersion.StartsWith('v')) { $assetVersion = $assetVersion.Substring(1) }
  if ($Tag -eq 'latest') {
    return @(
      "https://github.com/$Repo/releases/latest/download/dsh-computer-use.tgz",
      "https://github.com/$Repo/releases/latest/download/dsh-computer-use-$assetVersion.tgz"
    )
  }
  # Release assets are uploaded under both the stable and the versioned name.
  return @(
    "https://github.com/$Repo/releases/download/$Tag/dsh-computer-use-$assetVersion.tgz",
    "https://github.com/$Repo/releases/download/$Tag/dsh-computer-use.tgz"
  )
}

$temp = Join-Path $env:TEMP ('dsh-cu-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$tarball = Join-Path $temp 'dsh-computer-use.tgz'
try {
  Write-Host "==> dsh-computer-use release installer"
  Write-Host "    profile: $Profile"
  Write-Host "    release: $Repo@$Version"

  $downloaded = $false
  foreach ($url in (Get-ReleaseAssetUrl $Version)) {
    Write-Host "    downloading $url"
    try {
      Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -TimeoutSec 120
      $downloaded = $true
      break
    } catch {
      Write-Host "    failed: $($_.Exception.Message)"
    }
  }
  if (-not $downloaded) {
    throw "could not download the release tarball. Check the network/proxy, or download it manually from https://github.com/$Repo/releases and run scripts\install.ps1 -Source <extracted-package-folder>."
  }

  $size = (Get-Item -LiteralPath $tarball).Length
  Write-Host "    downloaded $size bytes"

  Write-Host "==> extracting"
  & tar -xzf $tarball -C $temp
  if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed' }
  $packageDir = Join-Path $temp 'package'
  if (-not (Test-Path -LiteralPath $packageDir)) { throw "release tarball has no package/ directory" }

  $installScript = Join-Path $PSScriptRoot 'install.ps1'
  if (-not (Test-Path -LiteralPath $installScript)) { throw "scripts\install.ps1 is missing next to this script" }

  $installArgs = @('-Profile', $Profile, '-Source', $packageDir)
  if ($SkipSkill) { $installArgs += '-SkipSkill' }
  if ($Verify) { $installArgs += '-Verify' }

  Write-Host "==> running install.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs
  if ($LASTEXITCODE -ne 0) { throw "install.ps1 failed with exit code $LASTEXITCODE" }

  Write-Host ''
  Write-Host '==> done. Restart DeepSeek Harness (or let HMR recompose) to load the plugin.'
  Write-Host '    The computer_* tools appear in a new session; the "电脑操作 computer use"'
  Write-Host '    composer entry appears after the client bundles rebuild/reload.'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
