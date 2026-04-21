#!/bin/bash
# Build RimeoAgent for macOS
# Run from the Rimeo/ directory:
#   bash RimeoAgent/build/build_mac.sh
set -euo pipefail

APP_NAME="RimeoAgent"
BUNDLE_ID="app.rimeo.agent"
FLET="/Users/ilia/Library/Python/3.9/bin/flet"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOOKS_DIR="$SCRIPT_DIR/hooks"
ICON_PNG="$ROOT_DIR/Rimeo/Assets.xcassets/AppIcon.appiconset/rimeo1024.png"
ICON_ICNS="$SCRIPT_DIR/RimeoAgent.icns"

cd "$ROOT_DIR"
echo "=== Building $APP_NAME for macOS ==="
echo "Root: $ROOT_DIR"
echo ""

# ── Convert PNG → .icns ───────────────────────────────────────────────────────
echo "→ Creating icon..."
ICONSET=$(mktemp -d)/RimeoAgent.iconset
mkdir -p "$ICONSET"
sips -z 16   16   "$ICON_PNG" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32   32   "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32   32   "$ICON_PNG" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64   64   "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128  128  "$ICON_PNG" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256  256  "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256  256  "$ICON_PNG" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512  512  "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512  512  "$ICON_PNG" --out "$ICONSET/icon_512x512.png"     >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png"  >/dev/null
iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
echo "→ Icon: $ICON_ICNS"

# ── Deps ──────────────────────────────────────────────────────────────────────
echo "→ Installing CPU-only torch (smaller bundle)..."
pip3 install torch --index-url https://download.pytorch.org/whl/cpu --quiet

# Clean previous PyInstaller cache to free disk space
echo "→ Clearing PyInstaller cache..."
rm -rf "$HOME/Library/Application Support/pyinstaller/bincache"* 2>/dev/null || true
rm -rf build/ 2>/dev/null || true

# ── flet pack ────────────────────────────────────────────────────────────────
echo "→ Running flet pack..."
"$FLET" pack RimeoAgent/run.py \
  -y \
  --name "$APP_NAME" \
  --product-name "Rimeo Agent" \
  --bundle-id "$BUNDLE_ID" \
  --icon "$ICON_ICNS" \
  --add-data "RimeoAgent/rimeo1024.png:." \
  --hidden-import "uvicorn.logging" \
  --hidden-import "uvicorn.loops" \
  --hidden-import "uvicorn.loops.auto" \
  --hidden-import "uvicorn.protocols" \
  --hidden-import "uvicorn.protocols.http" \
  --hidden-import "uvicorn.protocols.http.auto" \
  --hidden-import "uvicorn.protocols.websockets" \
  --hidden-import "uvicorn.protocols.websockets.auto" \
  --hidden-import "uvicorn.lifespan" \
  --hidden-import "uvicorn.lifespan.on" \
  --hidden-import "fastapi" \
  --hidden-import "pydantic_settings" \
  --pyinstaller-build-args "--additional-hooks-dir=$HOOKS_DIR"

echo ""
echo "→ App bundle: dist/$APP_NAME.app"

# ── .pkg installer ────────────────────────────────────────────────────────────
# postinstall script снимает карантин Gatekeeper после установки в /Applications
if command -v pkgbuild &>/dev/null; then
  echo "→ Creating .pkg installer..."
  pkgbuild \
    --install-location "/Applications" \
    --component "dist/$APP_NAME.app" \
    --scripts "$SCRIPT_DIR/pkg_scripts" \
    "dist/${APP_NAME}.pkg"
  echo "→ Installer: dist/${APP_NAME}.pkg"
else
  echo "⚠  pkgbuild not found — skipping .pkg"
fi

# ── .zip for GitHub Releases / auto-updater ───────────────────────────────────
echo "→ Creating .zip archive..."
cd dist
if [ -d "${APP_NAME}.app" ] && [ "$(stat -f '%m' "${APP_NAME}.app")" -gt "$(( $(date +%s) - 600 ))" ]; then
  zip -r "${APP_NAME}_mac.zip" "${APP_NAME}.app" --quiet
elif [ -f "${APP_NAME}" ]; then
  zip "${APP_NAME}_mac.zip" "${APP_NAME}" --quiet
else
  echo "⚠  Nothing to zip — check flet pack output above"
  exit 1
fi
cd ..

echo ""
echo "✓ Done!"
[ -d "dist/${APP_NAME}.app" ] && echo "   dist/${APP_NAME}.app"
[ -f "dist/${APP_NAME}" ]     && echo "   dist/${APP_NAME}  (standalone binary)"
[ -f "dist/${APP_NAME}.pkg" ] && echo "   dist/${APP_NAME}.pkg"
echo "   dist/${APP_NAME}_mac.zip  ← загрузить на GitHub Releases"
