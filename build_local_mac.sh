#!/bin/bash
# Local macOS arm64 build — mirrors GitHub Actions workflow exactly.
# Usage: ./build_local_mac.sh 108
# Produces: dist/RimeoAgent_mac_arm64.zip

set -e

BUILD_NUMBER="${1:-local}"
TAG_NAME="v1.0-build${BUILD_NUMBER}"

echo "==> Build $BUILD_NUMBER ($TAG_NAME)"

# 1. Write build_info.py (same as CI "Prepare build metadata" step)
printf 'VERSION = "1.0"\nBUILD_NUMBER = "%s"\nRELEASE_TAG = "%s"\n' \
    "$BUILD_NUMBER" "$TAG_NAME" > build_info.py
echo "    build_info.py updated"

# 2. Install deps (same versions as CI)
echo "==> Installing dependencies..."
python3 -m pip install --upgrade pip --quiet
python3 -m pip install -r requirements.txt --quiet
python3 -m pip install "flet==0.28.3" "flet-cli==0.28.3" pyinstaller pillow --quiet
python3 -m pip install torch --index-url https://download.pytorch.org/whl/cpu --quiet
echo "    done"

# 3. Create .icns icon (same sips commands as CI)
echo "==> Creating icon..."
ICONSET=$(mktemp -d)/RimeoAgent.iconset
mkdir -p "$ICONSET"
sips -z 16   16   rimeo1024.png --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32   32   rimeo1024.png --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32   32   rimeo1024.png --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64   64   rimeo1024.png --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128  128  rimeo1024.png --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256  256  rimeo1024.png --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256  256  rimeo1024.png --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512  512  rimeo1024.png --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512  512  rimeo1024.png --out "$ICONSET/icon_512x512.png"     >/dev/null
sips -z 1024 1024 rimeo1024.png --out "$ICONSET/icon_512x512@2x.png"  >/dev/null
ICON_ICNS="$(pwd)/RimeoAgent.icns"
iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
echo "    $ICON_ICNS"

# 4. flet pack (same flags as CI)
echo "==> Building app..."
flet pack run.py \
    -y \
    --name RimeoAgent \
    --product-name "Rimeo Agent" \
    --bundle-id app.rimeo.agent \
    --icon "$ICON_ICNS" \
    --add-data "rimeo1024.png:." \
    --hidden-import "config" \
    --hidden-import "api_server" \
    --hidden-import "ui_app" \
    --hidden-import "tray" \
    --hidden-import "analyzer" \
    --hidden-import "similarity" \
    --hidden-import "updater" \
    --hidden-import "parser" \
    --hidden-import "build_info" \
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
    --pyinstaller-build-args="--paths=$(pwd)"

# 5. Build .pkg installer
echo "==> Creating .pkg installer..."
PKG_SCRIPTS=$(mktemp -d)
cat > "$PKG_SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
xattr -dr com.apple.quarantine /Applications/RimeoAgent.app 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

pkgbuild \
    --install-location "/Applications" \
    --component "dist/RimeoAgent.app" \
    --scripts "$PKG_SCRIPTS" \
    "dist/RimeoAgent_mac_arm64.pkg"

# 6. Also zip the .app (same as CI artifact)
echo "==> Packaging .zip..."
cd dist
if [ -d "RimeoAgent.app" ]; then
    zip -r RimeoAgent_mac_arm64.zip RimeoAgent.app --quiet
else
    zip RimeoAgent_mac_arm64.zip RimeoAgent --quiet
fi
cd ..

echo ""
echo "✓ Done:"
echo "  dist/RimeoAgent_mac_arm64.pkg  (installer — для пользователей)"
echo "  dist/RimeoAgent_mac_arm64.zip  (то же что GitHub Actions artifact)"
echo "  Test: open dist/RimeoAgent.app"
