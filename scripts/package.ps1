#requires -Version 5.1
<#
.SYNOPSIS
  Build the release artifacts for dsh-computer-use.

.DESCRIPTION
  Runs `npm pack` to produce the canonical plugin tarball (the same format
  `dsh plugin add <tarball-url>` installs), extracts it and re-zips the package
  contents for manual/offline installation, then writes SHA256SUMS.txt.

  Output (dist/):
    dsh-computer-use-<version>.tgz   npm/pnpm-installable package tarball
    dsh-computer-use-<version>.zip   unzip-and-run installer archive
    dsh-computer-use.tgz             copy of the tarball under the stable
                                     "latest/download" asset name
    SHA256SUMS.txt

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package.ps1
#>
param(
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($OutDir -eq '') { $OutDir = Join-Path $root 'dist' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
$name = [string]$manifest.name
$version = [string]$manifest.version
$tgzName = "$name-$version.tgz"
$zipName = "$name-$version.zip"

Push-Location $root
$previousErrorAction = $ErrorActionPreference
try {
  Write-Host "==> npm pack ($name@$version)"
  # npm writes its notices to stderr; don't let them trip ErrorActionPreference.
  $ErrorActionPreference = 'Continue'
  $packOutput = & npm pack --pack-destination $OutDir 2>&1 | Out-String
  $packExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorAction
  if ($packExit -ne 0) { throw "npm pack failed (exit $packExit): $packOutput" }
  Write-Host (($packOutput -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join "`n")

  $tgzPath = Join-Path $OutDir $tgzName
  if (-not (Test-Path -LiteralPath $tgzPath)) {
    $candidate = Get-ChildItem -LiteralPath $OutDir -Filter '*.tgz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate -eq $null) { throw "npm pack produced no tarball in $OutDir" }
    $tgzPath = $candidate.FullName
    $tgzName = $candidate.Name
  }
  Write-Host "    $tgzPath"

  # Zip: extract the packed tarball so the archive contains exactly the shipped
  # package contents (no node_modules, no dev files).
  $stage = Join-Path $env:TEMP ('dsh-cu-pack-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  try {
    & tar -xzf $tgzPath -C $stage
    if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed' }
    $packageDir = Join-Path $stage 'package'
    if (-not (Test-Path -LiteralPath $packageDir)) { throw "extracted tarball has no package/ directory" }
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "    $zipPath"
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Stable asset name so `/releases/latest/download/dsh-computer-use.tgz` works.
  $stablePath = Join-Path $OutDir "$name.tgz"
  Copy-Item -LiteralPath $tgzPath -Destination $stablePath -Force
  Write-Host "    $stablePath"

  # Checksums
  $sums = foreach ($file in @($tgzPath, (Join-Path $OutDir $zipName), $stablePath)) {
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $file -Leaf)"
  }
  Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS.txt') -Value $sums -Encoding ascii
  Write-Host "==> checksums written"
  $sums | ForEach-Object { Write-Host "    $_" }
  Write-Host "==> done: $OutDir"
} finally {
  Pop-Location
}
