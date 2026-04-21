@echo off
:: ─────────────────────────────────────────────────────────────────────────────
:: Build RimeoAgent for Windows
::
:: Output:
::   dist\RimeoAgent.exe        — run directly
::   dist\RimeoAgent_win.zip    — GitHub Releases asset (used by auto-updater)
::
:: Requirements:
::   pip install flet>=0.21.0 pillow
::   PowerShell (for zip creation, built-in on Win10+)
::
:: Usage:
::   cd C:\path\to\Rimeo        (parent of RimeoAgent\)
::   RimeoAgent\build\build_win.bat
:: ─────────────────────────────────────────────────────────────────────────────
setlocal enabledelayedexpansion

set APP_NAME=RimeoAgent
set ROOT_DIR=%~dp0..\..
set ICON_PNG=%ROOT_DIR%\rimeo1024.png
set ICON_ICO=%ROOT_DIR%\RimeoAgent\build\RimeoAgent.ico

cd /d "%ROOT_DIR%"
echo === Building %APP_NAME% for Windows ===
echo Root: %ROOT_DIR%
echo.

:: ── Deps ──────────────────────────────────────────────────────────────────
echo ^> Installing/updating flet and pillow...
pip install "flet>=0.21.0" pillow --quiet

:: CPU-only torch for smaller bundle (~200 MB vs ~2 GB GPU torch).
:: Remove these two lines if you need GPU support.
echo ^> Installing CPU-only torch for smaller bundle...
pip install torch --index-url https://download.pytorch.org/whl/cpu --quiet

:: ── Convert PNG → .ico ────────────────────────────────────────────────────
echo ^> Creating icon...
python -c "from PIL import Image; img=Image.open(r'%ICON_PNG%').convert('RGBA'); img.save(r'%ICON_ICO%', format='ICO', sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"
if errorlevel 1 (
  echo ERROR: icon conversion failed.
  exit /b 1
)
echo ^> Icon: %ICON_ICO%

:: ── flet pack ──────────────────────────────────────────────────────────────
echo ^> Running flet pack...
flet pack RimeoAgent\run.py ^
  --name %APP_NAME% ^
  --product-name "Rimeo Agent" ^
  --icon "%ICON_ICO%" ^
  --add-data "RimeoAgent\rimeo1024.png;." ^
  --add-data "RimeoAgent\rimo_data.json;RimeoAgent" ^
  --hidden-import "uvicorn.logging" ^
  --hidden-import "uvicorn.loops" ^
  --hidden-import "uvicorn.loops.auto" ^
  --hidden-import "uvicorn.protocols" ^
  --hidden-import "uvicorn.protocols.http" ^
  --hidden-import "uvicorn.protocols.http.auto" ^
  --hidden-import "uvicorn.protocols.websockets" ^
  --hidden-import "uvicorn.protocols.websockets.auto" ^
  --hidden-import "uvicorn.lifespan" ^
  --hidden-import "uvicorn.lifespan.on" ^
  --hidden-import "fastapi" ^
  --hidden-import "pydantic_settings" ^
  --collect-all "librosa" ^
  --collect-all "transformers" ^
  --collect-all "huggingface_hub" ^
  --collect-all "tokenizers" ^
  --noconfirm

if errorlevel 1 (
  echo ERROR: flet pack failed.
  exit /b 1
)

echo.
echo ^> Exe: dist\%APP_NAME%.exe

:: ── .zip for GitHub Releases / auto-updater ───────────────────────────────
echo ^> Creating .zip archive...
powershell -NoProfile -Command ^
  "Compress-Archive -Path 'dist\%APP_NAME%.exe' -DestinationPath 'dist\%APP_NAME%_win.zip' -Force"

echo.
echo == Build complete! ===
echo    dist\%APP_NAME%.exe          -- run directly
echo    dist\%APP_NAME%_win.zip      -- upload to GitHub Releases
echo.
echo Upload dist\%APP_NAME%_win.zip to the GitHub release as 'RimeoAgent_win.zip'
