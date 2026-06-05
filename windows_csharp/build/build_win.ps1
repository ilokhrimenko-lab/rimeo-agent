param(
    [string]$BuildNumber = "dev",
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Rid = "win-x64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root    = Split-Path $PSScriptRoot -Parent
$Project = Join-Path $Root "RimeoAgent\RimeoAgent.csproj"
$Dist    = Join-Path $Root "dist"
# x64 keeps the historical artifact names; arm64 gets an explicit suffix.
if ($Rid -eq "win-arm64") {
    $ZipName       = "RimeoAgent_win-arm64.zip"
    $InstallerName = "RimeoAgentSetup_win-arm64.exe"
} else {
    $ZipName       = "RimeoAgent_win.zip"
    $InstallerName = "RimeoAgentSetup_win.exe"
}

Write-Host "=== Rimeo Agent Windows Build ===" -ForegroundColor Cyan
Write-Host "Build number: $BuildNumber"
Write-Host "Runtime:      $Rid"
Write-Host "Project: $Project"

# Update build_info.py
$BuildInfoPath = Join-Path (Split-Path $Root -Parent) "build_info.py"
if (Test-Path $BuildInfoPath) {
    $content = Get-Content $BuildInfoPath -Raw
    $content = $content -replace 'BUILD_NUMBER\s*=\s*"[^"]*"', "BUILD_NUMBER = `"$BuildNumber`""
    Set-Content $BuildInfoPath $content
    Write-Host "Updated build_info.py: BUILD_NUMBER=$BuildNumber"
} else {
    Write-Host "WARNING: build_info.py not found at $BuildInfoPath" -ForegroundColor Yellow
}

# Clean dist
if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Path $Dist | Out-Null

# dotnet publish
Write-Host "Running dotnet publish..." -ForegroundColor Cyan
dotnet publish $Project `
    -c Release `
    -r $Rid `
    --self-contained `
    -p:PublishSingleFile=false `
    -o (Join-Path $Dist "RimeoAgent")

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: dotnet publish failed" -ForegroundColor Red
    exit 1
}

# WinUI 3 unpackaged: publish -o often drops the app's merged resources.pri, without
# which ms-appx:///Views/*.xaml fail to load (FileNotFoundException -> UI crash). Copy it.
$priTarget = Join-Path $Dist "RimeoAgent\resources.pri"
if (-not (Test-Path $priTarget)) {
    $priSrc = Get-ChildItem -Path (Join-Path $Root "RimeoAgent\bin"), (Join-Path $Root "RimeoAgent\obj") `
        -Recurse -Filter resources.pri -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($priSrc) {
        Copy-Item $priSrc.FullName $priTarget -Force
        Write-Host "Copied resources.pri from $($priSrc.FullName)"
    }
}
if (-not (Test-Path $priTarget)) {
    Write-Host "ERROR: resources.pri not found — XAML pages will fail to load" -ForegroundColor Red
    exit 1
}

# Copy build_info.py into output
if (Test-Path $BuildInfoPath) {
    Copy-Item $BuildInfoPath (Join-Path $Dist "RimeoAgent\build_info.py")
}

# Emit a diagnostic launcher that enables .NET native mini-dumps (ClickUp 4003).
# Use this to run the agent on a test VM when chasing the early native crash.
$RunDiag = @'
@echo off
setlocal
set DOTNET_DbgEnableMiniDump=1
set DOTNET_DbgMiniDumpType=4
set DOTNET_CreateDumpDiagnostics=1
set DOTNET_EnableCrashReport=1
echo Launching RimeoAgent with native crash dumps enabled...
echo Dumps (if any) land next to this exe or in %%LOCALAPPDATA%%\Rimeo\dumps
"%~dp0RimeoAgent.exe"
endlocal
'@
Set-Content -Path (Join-Path $Dist "RimeoAgent\run_diag.cmd") -Value $RunDiag -Encoding ASCII
Write-Host "Wrote run_diag.cmd (native crash-dump launcher)"

# Optional: bundle cloudflared.exe
$CloudflaredSrc = Join-Path $PSScriptRoot "cloudflared.exe"
if (Test-Path $CloudflaredSrc) {
    Copy-Item $CloudflaredSrc (Join-Path $Dist "RimeoAgent\cloudflared.exe")
    Write-Host "Bundled cloudflared.exe"
} else {
    Write-Host "WARNING: cloudflared.exe not found in build/ — tunnel won't work out-of-the-box" -ForegroundColor Yellow
    Write-Host "  Download from https://github.com/cloudflare/cloudflared/releases/latest"
}

# Zip
$ZipPath = Join-Path $Dist $ZipName
Compress-Archive -Path (Join-Path $Dist "RimeoAgent\*") -DestinationPath $ZipPath -Force

# Installer
$InstallerScript = Join-Path $PSScriptRoot "RimeoAgentInstaller.nsi"
$InstallerPath = Join-Path $Dist $InstallerName
$MakeNsis = Get-Command makensis -ErrorAction SilentlyContinue
if ($MakeNsis) {
    Write-Host "Building installer..." -ForegroundColor Cyan
    & $MakeNsis.Source `
        "/DSOURCE_DIR=$(Join-Path $Dist "RimeoAgent")" `
        "/DOUT_FILE=$InstallerPath" `
        $InstallerScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: makensis failed" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "WARNING: makensis not found; skipping installer build" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
Write-Host "Executable: $Dist\RimeoAgent\RimeoAgent.exe"
Write-Host "Archive:    $ZipPath"
Write-Host "Installer:  $InstallerPath"
