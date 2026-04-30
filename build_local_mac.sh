#!/bin/bash
# Local macOS Universal build (arm64 + x86_64) for the native Swift app.
# Usage: ./build_local_mac.sh 109
# Produces: dist/RimeoAgent_mac.zip

set -euo pipefail

BUILD_NUMBER="${1:-local}"
TAG_NAME="v1.0-build${BUILD_NUMBER}"
APP_VERSION_BASE="${APP_VERSION_BASE:-1.0}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$ROOT_DIR/macos_arm64"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/RimeoAgent.app"
ICON_ICNS="$ROOT_DIR/rimeo1024-bigsur.icns"

pick_codesign_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    local identity
    identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
    if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return
    fi

    identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
    if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return
    fi

    identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(rimeo[^"]*\)".*/\1/p' | head -n 1)"
    if [[ -n "$identity" ]]; then
        printf '%s\n' "$identity"
        return
    fi

    printf '%s\n' "-"
}

CODESIGN_IDENTITY="$(pick_codesign_identity)"

if [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    BUILD_SUFFIX="$BUILD_NUMBER"
else
    BUILD_SUFFIX="$(date +%Y%m%d%H%M%S)"
fi
APP_BUNDLE_VERSION="${APP_VERSION_BASE}.${BUILD_SUFFIX}"

echo "==> Build $BUILD_NUMBER ($TAG_NAME)"

printf 'VERSION = "%s"\nBUILD_NUMBER = "%s"\nRELEASE_TAG = "%s"\n' \
    "$APP_VERSION_BASE" \
    "$BUILD_NUMBER" "$TAG_NAME" > "$ROOT_DIR/build_info.py"
echo "    build_info.py updated"
echo "    bundle version: $APP_BUNDLE_VERSION"
echo "    icon: $ICON_ICNS"

echo "==> Building Swift release (Universal: arm64 + x86_64)..."
cd "$MAC_DIR"
swift build -c release --arch arm64 --arch x86_64

UNIVERSAL="$MAC_DIR/.build/apple/Products/Release/RimeoAgent"
HELPER="$MAC_DIR/.build/apple/Products/Release/RekordboxDBHelper"
SQLCIPHER_FRAMEWORK="$MAC_DIR/.build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework"
if [ ! -f "$UNIVERSAL" ]; then
    echo "ERROR: universal binary not found at $UNIVERSAL"
    exit 1
fi
if [ ! -f "$HELPER" ]; then
    echo "ERROR: helper binary not found at $HELPER"
    exit 1
fi
if [ ! -d "$SQLCIPHER_FRAMEWORK" ]; then
    echo "ERROR: SQLCipher.framework not found at $SQLCIPHER_FRAMEWORK"
    exit 1
fi
echo "    archs: $(lipo -archs "$UNIVERSAL")"
echo "    helper archs: $(lipo -archs "$HELPER")"

echo "==> Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$UNIVERSAL" "$APP_DIR/Contents/MacOS/RimeoAgent"
chmod +x "$APP_DIR/Contents/MacOS/RimeoAgent"
cp "$HELPER" "$APP_DIR/Contents/MacOS/rbdb-helper"
chmod +x "$APP_DIR/Contents/MacOS/rbdb-helper"
cp -R "$SQLCIPHER_FRAMEWORK" "$APP_DIR/Contents/Frameworks/SQLCipher.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/rbdb-helper"
cp "$MAC_DIR/build/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION_BASE" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUNDLE_VERSION" "$APP_DIR/Contents/Info.plist"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/RimeoAgent.icns"
cp "$ROOT_DIR/build_info.py" "$APP_DIR/Contents/Resources/build_info.py"

echo "==> Runtime components are not bundled"
echo "    tunnel-runtime, ffmpeg, and ffprobe are installed by Component Gate from rimeo.app"

echo "==> Signing .app bundle..."
echo "    identity: $CODESIGN_IDENTITY"
xattr -cr "$APP_DIR"
codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier app.rimeo.agent "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -dv --verbose=4 "$APP_DIR" 2>&1 | sed -n '/^Identifier=/p;/^Signature=/p;/^TeamIdentifier=/p;/^Info.plist=/p;/^Sealed Resources=/p;/^Internal requirements=/p'

echo "==> Packaging..."
rm -f "$DIST_DIR/RimeoAgent_mac.zip"
cd "$DIST_DIR"
zip -r RimeoAgent_mac.zip RimeoAgent.app --quiet

echo ""
echo "✓ Done: $DIST_DIR/RimeoAgent_mac.zip"
echo "  Test: open $APP_DIR"
