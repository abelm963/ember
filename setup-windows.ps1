# Ember: one-time setup and run on Windows.
# Run from this folder in PowerShell:   powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
# It installs what is missing (Git, Flutter, Visual Studio C++ build tools), then starts Ember.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Write-Host "`n== Ember setup ==" -ForegroundColor DarkYellow

# 1. Git (Flutter needs it)
if (-not (Have git)) {
  Write-Host "Installing Git..."
  winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements --silent
  $env:Path += ";C:\Program Files\Git\cmd"
}

# 2. Visual Studio 2022 Build Tools with the C++ desktop workload (needed to build Windows apps)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVc = $false
if (Test-Path $vswhere) {
  $hasVc = [bool](& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
}
if (-not $hasVc) {
  Write-Host "Installing Visual Studio C++ build tools (a few GB, 10-30 minutes)..."
  winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements `
    --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
}

# 3. Flutter SDK (installed to C:\dev\flutter)
if (-not (Have flutter)) {
  $flutterDir = 'C:\dev\flutter'
  if (-not (Test-Path "$flutterDir\bin\flutter.bat")) {
    Write-Host "Installing Flutter to $flutterDir ..."
    New-Item -ItemType Directory -Force -Path 'C:\dev' | Out-Null
    git clone --depth 1 -b stable https://github.com/flutter/flutter.git $flutterDir
  }
  $env:Path = "$flutterDir\bin;" + $env:Path
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -notlike "*$flutterDir\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$flutterDir\bin;$userPath", 'User')
  }
}

flutter config --no-analytics | Out-Null
flutter config --enable-windows-desktop | Out-Null

Write-Host "`nChecking the toolchain..." -ForegroundColor DarkYellow
flutter doctor

Write-Host "`nFetching packages..." -ForegroundColor DarkYellow
flutter pub get

Write-Host "`nStarting Ember (first build takes a few minutes)..." -ForegroundColor DarkYellow
flutter run -d windows
