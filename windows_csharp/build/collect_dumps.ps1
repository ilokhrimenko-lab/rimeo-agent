# Enables Windows Error Reporting LocalDumps for RimeoAgent.exe so that a native
# crash (WinUI / COM, which .NET handlers cannot catch) leaves a full crash dump.
# Run ONCE on the test machine, elevated (Run as administrator).
#
# Diagnoses ClickUp 4003 — agent window appears then dies natively within ~9-15s.
#
#   pwsh -ExecutionPolicy Bypass -File collect_dumps.ps1
#
# After a crash, inspect the .dmp in the DumpFolder below (open in WinDbg / VS).
# If NO dump appears even though the process died, the process was force-killed
# (e.g. Windows Defender) rather than crashing — that itself narrows the cause.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExeName    = "RimeoAgent.exe"
$DumpFolder = Join-Path $env:LOCALAPPDATA "Rimeo\dumps"
$RegBase    = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
$RegKey     = Join-Path $RegBase $ExeName

# Require elevation (HKLM write).
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: must run elevated (Run as administrator)." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $DumpFolder -Force | Out-Null
if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
if (-not (Test-Path $RegKey))  { New-Item -Path $RegKey  -Force | Out-Null }

# DumpType 2 = full dump; DumpCount keeps the last few crashes.
New-ItemProperty -Path $RegKey -Name "DumpFolder" -Value $DumpFolder -PropertyType ExpandString -Force | Out-Null
New-ItemProperty -Path $RegKey -Name "DumpType"   -Value 2          -PropertyType DWord        -Force | Out-Null
New-ItemProperty -Path $RegKey -Name "DumpCount"  -Value 10         -PropertyType DWord        -Force | Out-Null

Write-Host "WER LocalDumps enabled for $ExeName" -ForegroundColor Green
Write-Host "Dump folder: $DumpFolder"
Write-Host ""
Write-Host "Now reproduce the crash, then look for a .dmp in the folder above."
Write-Host "To disable later: Remove-Item -Path '$RegKey' -Recurse"
