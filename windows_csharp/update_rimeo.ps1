# Rimeo Agent — download & install the latest release from GitHub.
# No admin needed (installs to %LOCALAPPDATA%\RimeoAgent).
# Run: powershell -ExecutionPolicy Bypass -File update_rimeo.ps1
#   -Portable  : install the .zip build instead of the NSIS installer
#   -Rid x64|arm64 : force an architecture (default: auto-detect this machine)

param(
    [switch]$Portable,
    [ValidateSet('auto', 'x64', 'arm64')]
    [string]$Rid = 'auto'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'ilokhrimenko-lab/rimeo-agent'

# --- Resolve architecture (robust: independent of the PowerShell host bitness) ---
if ($Rid -eq 'auto') {
    $os  = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $Rid = if ($os -eq 'Arm64') { 'arm64' } else { 'x64' }
}
Write-Host "Architecture: $Rid"

# --- Pick the matching release asset ---
if ($Portable) {
    $asset = if ($Rid -eq 'arm64') { 'RimeoAgent_win-arm64.zip' } else { 'RimeoAgent_win.zip' }
} else {
    $asset = if ($Rid -eq 'arm64') { 'RimeoAgentSetup_win-arm64.exe' } else { 'RimeoAgentSetup_win.exe' }
}

# --- Find the download URL in the latest release ---
$rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'RimeoUpdater' }
$url = ($rel.assets | Where-Object { $_.name -eq $asset }).browser_download_url
if (-not $url) { throw "Release $($rel.tag_name) has no asset named '$asset'" }
Write-Host "Release: $($rel.tag_name)  ->  $asset"

# --- Download ---
$out = Join-Path $env:TEMP $asset
Write-Host "Downloading..."
Invoke-WebRequest $url -OutFile $out -UseBasicParsing

# --- Stop a running instance so files can be replaced ---
Get-Process RimeoAgent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$installDir = Join-Path $env:LOCALAPPDATA 'RimeoAgent'

if ($Portable) {
    # Extract the zip over the install dir
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Write-Host "Extracting to $installDir ..."
    Expand-Archive -Path $out -DestinationPath $installDir -Force
} else {
    # NSIS silent install
    Write-Host "Installing (silent)..."
    Start-Process $out -ArgumentList '/S' -Wait
}

# --- Launch ---
$exe = Join-Path $installDir 'RimeoAgent.exe'
if (Test-Path $exe) {
    Write-Host "Installed -> $installDir"
    Start-Process $exe
} else {
    Write-Warning "RimeoAgent.exe not found at $exe — check the install output above."
}
