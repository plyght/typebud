<#
.SYNOPSIS
  Build the typebud Windows installer (Inno Setup 6) from `zig build package` output.

.DESCRIPTION
  scripts/make-installer-windows.ps1 -PackageDir out/pkg/typebud -Version 0.3.0
    -> dist/typebud-setup-0.3.0-x86_64.exe

  -PackageDir  the Windows package directory (<prefix>\typebud, containing typebud.exe)
  -Version     semver without a leading "v" (0.3.0, 0.3.0-beta.1)
  -OutDir      output directory (default: <repo>\dist)
  -Iscc        path to ISCC.exe (default: PATH, then the usual Inno Setup 6 install dirs)

  Prints the installer path; under GitHub Actions also sets the step output `installer`.
  Needs Inno Setup 6 (`choco install innosetup -y --no-progress`).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$PackageDir,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutDir,
  [string]$Iscc
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$Version = $Version -replace '^v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
  throw "Version '$Version' is not semver (expected e.g. 0.3.0 or 0.3.0-beta.1)"
}
# Version resource needs a.b.c.d (numbers only).
$core = ($Version -replace '[-+].*$', '').Split('.')
$numeric = ($core + @('0')) -join '.'

$pkg = (Resolve-Path -LiteralPath $PackageDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $pkg 'typebud.exe'))) {
  throw "$pkg does not contain typebud.exe (pass the <prefix>\typebud directory from 'zig build package')"
}
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = (Resolve-Path -LiteralPath $OutDir).Path

if (-not $Iscc) {
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { $Iscc = $cmd.Source }
}
if (-not $Iscc) {
  foreach ($c in @(
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
    if ($c -and (Test-Path -LiteralPath $c)) { $Iscc = $c; break }
  }
}
if (-not $Iscc) { throw 'ISCC.exe (Inno Setup 6) not found; install it with: choco install innosetup -y' }

$iss = Join-Path $repo 'packaging\windows\typebud.iss'
Write-Host "Inno Setup: $Iscc"
Write-Host "Packaging $pkg as typebud $Version ($numeric)"
& $Iscc /Qp "/DAppVersion=$Version" "/DAppVersionNumeric=$numeric" "/DPackageDir=$pkg" "/DOutputDir=$out" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$setup = Join-Path $out "typebud-setup-$Version-x86_64.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "expected $setup was not produced" }
$size = (Get-Item -LiteralPath $setup).Length
Write-Host ("Wrote {0} ({1:N1} MiB)" -f $setup, ($size / 1MB))
if ($env:GITHUB_OUTPUT) { "installer=$setup" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
$setup
