Unicode true
ManifestSupportedOS all
RequestExecutionLevel user

!include "MUI2.nsh"

!ifndef SOURCE_DIR
  !error "SOURCE_DIR must point to the published RimeoAgent output"
!endif

!ifndef OUT_FILE
  !define OUT_FILE "RimeoAgentSetup_win.exe"
!endif

Name "Rimeo Agent"
OutFile "${OUT_FILE}"
InstallDir "$LOCALAPPDATA\RimeoAgent"
InstallDirRegKey HKCU "Software\RimeoAgent" "InstallDir"

!define MUI_ABORTWARNING
!define MUI_ICON "${SOURCE_DIR}\Assets\rimeo.ico"
!define MUI_UNICON "${SOURCE_DIR}\Assets\rimeo.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\RimeoAgent.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Rimeo Agent"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install"
  ; Stop a running agent (and its cloudflared child) before overwriting files.
  ; A live agent holds write-locks on RimeoAgent.exe / *.dll / cloudflared.exe,
  ; which made NSIS abort with "Error opening file for writing" on reinstall.
  ; /T kills the process tree; the Sleep lets Windows release the file handles.
  DetailPrint "Stopping any running Rimeo Agent…"
  nsExec::ExecToLog 'taskkill /F /T /IM RimeoAgent.exe'
  nsExec::ExecToLog 'taskkill /F /T /IM cloudflared.exe'
  Sleep 1500

  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}\*.*"

  WriteRegStr HKCU "Software\RimeoAgent" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\Rimeo Agent"
  CreateShortcut "$SMPROGRAMS\Rimeo Agent\Rimeo Agent.lnk" "$INSTDIR\RimeoAgent.exe" "" "$INSTDIR\Assets\rimeo.ico"
  CreateShortcut "$SMPROGRAMS\Rimeo Agent\Uninstall Rimeo Agent.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\Rimeo Agent.lnk" "$INSTDIR\RimeoAgent.exe" "" "$INSTDIR\Assets\rimeo.ico"

  ; M4 (LAN tier): let the non-elevated agent listen on ALL interfaces so phones
  ; on the same Wi-Fi reach it directly. urlacl grants http://+:8000/ to Everyone
  ; (WD SID — locale-independent), the firewall rule opens the TCP port inbound.
  ; delete-then-add so a reinstall doesn't error on an existing entry.
  DetailPrint "Reserving HTTP URL + firewall rule for LAN access…"
  nsExec::ExecToLog 'netsh http delete urlacl url=http://+:8000/'
  nsExec::ExecToLog 'netsh http add urlacl url=http://+:8000/ sddl=D:(A;;GX;;;WD)'
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Rimeo Agent (LAN)"'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="Rimeo Agent (LAN)" dir=in action=allow protocol=TCP localport=8000'
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\Rimeo Agent.lnk"
  Delete "$SMPROGRAMS\Rimeo Agent\Rimeo Agent.lnk"
  Delete "$SMPROGRAMS\Rimeo Agent\Uninstall Rimeo Agent.lnk"
  RMDir "$SMPROGRAMS\Rimeo Agent"

  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\RimeoAgent"

  ; Автозапуск агент включает себе сам при первом запуске (Run-ключ с --background) —
  ; после удаления запись обязана уйти, иначе Windows будет пытаться стартовать
  ; несуществующий exe при каждом входе.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "RimeoAgent"

  ; Remove the LAN urlacl + firewall rule added on install.
  nsExec::ExecToLog 'netsh http delete urlacl url=http://+:8000/'
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Rimeo Agent (LAN)"'
SectionEnd
