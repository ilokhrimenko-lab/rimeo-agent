#!/bin/bash
#
# Собирает RimeoAgent.dmg — окно с иконкой приложения, стрелкой и папкой Applications.
#
# Раскладку пишет dmgbuild, а НЕ Finder/AppleScript:
#   - Finder снапит иконки к своей сетке (заданные 45/263 он молча превращает в 95/313),
#     то есть попасть иконкой в рамку на фоне через него нельзя;
#   - на CI-раннере Finder недоступен и AppleScript-подход флапает.
# dmgbuild пишет .DS_Store напрямую, детерминированно и headless.
#
# Usage: make_dmg.sh <path-to-.app> <output.dmg>
#
set -euo pipefail

APP_PATH="${1:?usage: make_dmg.sh <app> <out.dmg>}"
OUT_DMG="${2:?usage: make_dmg.sh <app> <out.dmg>}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# Фон: 660×400 @1x + @2x в одном .tiff, иначе на Retina он мыльный.
tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" \
         -out "$HERE/background.tiff" >/dev/null

DMGBUILD="${DMGBUILD:-dmgbuild}"
command -v "$DMGBUILD" >/dev/null || { echo "!! dmgbuild не найден: pip install dmgbuild"; exit 1; }

rm -f "$OUT_DMG"
"$DMGBUILD" -s "$HERE/settings.py" -D app="$APP_PATH" -D here="$HERE" "Rimeo Agent" "$OUT_DMG"
echo ">> $OUT_DMG"
