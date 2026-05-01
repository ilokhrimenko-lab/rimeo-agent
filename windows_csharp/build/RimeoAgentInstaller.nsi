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
  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}\*.*"

  WriteRegStr HKCU "Software\RimeoAgent" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\Rimeo Agent"
  CreateShortcut "$SMPROGRAMS\Rimeo Agent\Rimeo Agent.lnk" "$INSTDIR\RimeoAgent.exe" "" "$INSTDIR\Assets\rimeo.ico"
  CreateShortcut "$SMPROGRAMS\Rimeo Agent\Uninstall Rimeo Agent.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\Rimeo Agent.lnk" "$INSTDIR\RimeoAgent.exe" "" "$INSTDIR\Assets\rimeo.ico"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\Rimeo Agent.lnk"
  Delete "$SMPROGRAMS\Rimeo Agent\Rimeo Agent.lnk"
  Delete "$SMPROGRAMS\Rimeo Agent\Uninstall Rimeo Agent.lnk"
  RMDir "$SMPROGRAMS\Rimeo Agent"

  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\RimeoAgent"
SectionEnd
