#!/bin/bash
# Local macOS Universal build (arm64 + x86_64) for the native Swift app.
# Usage: ./build_local_mac.sh 109
# Produces: dist/RimeoAgent_mac.zip

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_VERSION_BASE="${APP_VERSION_BASE:-1.0}"

# Build number. Pass one explicitly (e.g. "./build_local_mac.sh 230") to pin it.
# With no argument we derive the NEXT mac build number from local git tags, so the
# in-app version reads as a real number (e.g. "build 226") instead of "local".
if [[ -n "${1:-}" ]]; then
    BUILD_NUMBER="$1"
else
    _latest_build="$(git -C "$ROOT_DIR" tag -l 'mac-v1.0-build*' 2>/dev/null \
        | sed -E 's/.*build//' | grep -E '^[0-9]+$' | sort -n | tail -n 1 || true)"
    if [[ -n "${_latest_build:-}" ]]; then
        BUILD_NUMBER="$((_latest_build + 1))"
    else
        BUILD_NUMBER="$(date +%Y%m%d%H%M)"
    fi
fi
TAG_NAME="v1.0-build${BUILD_NUMBER}"
MAC_DIR="$ROOT_DIR/macos_arm64"
DIST_DIR="$ROOT_DIR/dist"

# REVIEW=1 builds a parallel "Rimeo Agent (Review)" that coexists with the main
# agent: different bundle id, Application Support dir, port (8042) and icon.
REVIEW="${REVIEW:-0}"
if [[ "$REVIEW" == "1" ]]; then
    APP_NAME="RimeoAgentReview"
    BUNDLE_ID="app.rimeo.agent.review"
    DISPLAY_NAME="Rimeo Agent (Review)"
    ICON_ICNS="$ROOT_DIR/RimeoAgentReview.icns"
    SWIFT_DEFINES="-Xswiftc -DREVIEW"
    ZIP_NAME="RimeoAgentReview_mac.zip"
    echo "==> REVIEW build (bundle=$BUNDLE_ID, port 8042, RimeoAgentReview support dir)"
else
    APP_NAME="RimeoAgent"
    BUNDLE_ID="app.rimeo.agent"
    DISPLAY_NAME="Rimeo Agent"
    ICON_ICNS="$ROOT_DIR/rimeo1024-bigsur.icns"
    SWIFT_DEFINES=""
    ZIP_NAME="RimeoAgent_mac.zip"
fi
APP_DIR="$DIST_DIR/$APP_NAME.app"

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
        printf 'WARNING: no "Developer ID Application" cert in keychain — falling back to a\n' >&2
        printf '         Development cert (%s).\n' "$identity" >&2
        printf '         OK for local testing, but NOT the production identity\n' >&2
        printf '         (Developer ID Application, team MM3Q8TJL85). Import the Developer ID\n' >&2
        printf '         cert into your keychain to sign local builds like production.\n' >&2
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
swift build -c release --arch arm64 --arch x86_64 $SWIFT_DEFINES

UNIVERSAL="$MAC_DIR/.build/apple/Products/Release/RimeoAgent"
HELPER="$MAC_DIR/.build/apple/Products/Release/RekordboxDBHelper"
# ФАЗА 6 — frozen-бинарь ЗАПИСИ в master.db (pyrekordbox внутри, ~52 МБ, PyInstaller).
# Собирается отдельно: RimeoAgent/rbdb_sync_helper/build_helper.sh
# Не путать с $HELPER выше — тот только ЧИТАЕТ базу.
SYNC_HELPER="$ROOT_DIR/rbdb_sync_helper/dist/rbdb-sync-helper"
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
# ФАЗА 6 — хелпер ЗАПИСИ. Отсутствует → агент честно отдаёт capability
# playlist_sync=false, и кнопка Sync в iOS просто не показывается (см.
# APIRouter.agentCapabilities + RekordboxWriter.bundledSyncHelperPath).
# Сборка агента при этом НЕ падает: Sync — опциональная фича, а не ядро.
if [ -f "$SYNC_HELPER" ]; then
    cp "$SYNC_HELPER" "$APP_DIR/Contents/MacOS/rbdb-sync-helper"
    chmod +x "$APP_DIR/Contents/MacOS/rbdb-sync-helper"
    echo "    sync helper: $(du -h "$SYNC_HELPER" | cut -f1 | tr -d ' ') → Contents/MacOS/rbdb-sync-helper"
else
    echo "    WARNING: rbdb-sync-helper не найден ($SYNC_HELPER)"
    echo "             Sync в Rekordbox будет НЕДОСТУПЕН (кнопка скрыта)."
    echo "             Собрать: RimeoAgent/rbdb_sync_helper/build_helper.sh"
fi
cp -R "$SQLCIPHER_FRAMEWORK" "$APP_DIR/Contents/Frameworks/SQLCipher.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/rbdb-helper"
cp "$MAC_DIR/build/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION_BASE" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUNDLE_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/RimeoAgent.icns"
cp "$ROOT_DIR/build_info.py" "$APP_DIR/Contents/Resources/build_info.py"
cp "$ROOT_DIR/similarity_config.json" "$APP_DIR/Contents/Resources/similarity_config.json"
# Real Rimeo logo (sidebar wordmark loads this from the bundle — never a drawn "R").
cp "$ROOT_DIR/rimeo1024.png" "$APP_DIR/Contents/Resources/rimeo1024.png"
# Built-in royalty-free review library (15 tracks + audio). The agent switches to
# it at runtime when signed in as the demo/review account (demo@rimeo.app) — see
# AppConfig.activateReviewMode(). Lets App Review see a working library straight
# from the agent downloaded off rimeo.app, with no real Rekordbox install.
cp -R "$ROOT_DIR/review_library" "$APP_DIR/Contents/Resources/review_library"
# LaunchAgent автозапуска (SMAppService.agent(plistName:)). Кладём ДО подписи — Contents/
# Library опечатывается вместе с бандлом. В REVIEW-сборке плист НЕ кладём: у неё другой
# bundle id, а Label у LaunchAgent'а один на всех — два зарегистрированных job'а с одинаковым
# Label подрались бы в launchd. Регистрация там просто откатится на старый login item.
if [[ "$REVIEW" != "1" ]]; then
    mkdir -p "$APP_DIR/Contents/Library/LaunchAgents"
    cp "$MAC_DIR/build/app.rimeo.agent.autostart.plist" \
       "$APP_DIR/Contents/Library/LaunchAgents/app.rimeo.agent.autostart.plist"
fi

echo "==> Runtime components are not bundled"
echo "    tunnel-runtime, ffmpeg, and ffprobe are installed by Component Gate from rimeo.app"

echo "==> Signing .app bundle..."
echo "    identity: $CODESIGN_IDENTITY"
xattr -cr "$APP_DIR"
codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -dv --verbose=4 "$APP_DIR" 2>&1 | sed -n '/^Identifier=/p;/^Signature=/p;/^TeamIdentifier=/p;/^Info.plist=/p;/^Sealed Resources=/p;/^Internal requirements=/p'

echo "==> Packaging..."
rm -f "$DIST_DIR/$ZIP_NAME"
cd "$DIST_DIR"
zip -r "$ZIP_NAME" "$APP_NAME.app" --quiet

echo ""
echo "✓ Done: $DIST_DIR/$ZIP_NAME"
echo "  Test: open $APP_DIR"
