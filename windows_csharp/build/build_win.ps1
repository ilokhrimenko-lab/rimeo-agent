param(
    [string]$BuildNumber = "dev"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root    = Split-Path $PSScriptRoot -Parent
$Project = Join-Path $Root "RimeoAgent\RimeoAgent.csproj"
$Dist    = Join-Path $Root "dist"
$ZipName = "RimeoAgent_win.zip"

Write-Host "=== Rimeo Agent Windows Build ===" -ForegroundColor Cyan
Write-Host "Build number: $BuildNumber"
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
    -r win-x64 `
    --self-contained `
    -p:PublishSingleFile=false `
    -o (Join-Path $Dist "RimeoAgent")

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: dotnet publish failed" -ForegroundColor Red
    exit 1
}

# Copy build_info.py into output
if (Test-Path $BuildInfoPath) {
    Copy-Item $BuildInfoPath (Join-Path $Dist "RimeoAgent\build_info.py")
}

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
Write-Host ""
Write-Host "=== Build complete ===" -ForegroundColor Green
Write-Host "Executable: $Dist\RimeoAgent\RimeoAgent.exe"
Write-Host "Archive:    $ZipPath"
