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

# Приёмка образа. Не паранойя: dmgbuild копирует бандл через ditto и НЕ проверяет его код
# возврата — при нехватке места он молча теряет файлы, а образ собирается «успешно».
# Так уже уехал релиз, где в бандле не было тикета нотаризации и LaunchAgent'а автозапуска.
MNT="$(mktemp -d)"
hdiutil attach "$OUT_DMG" -nobrowse -readonly -quiet -mountpoint "$MNT"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$MNT"' EXIT

FAIL=0
APP_IN_DMG="$MNT/$(basename "$APP_PATH")"

# Подпись цела ⇒ ни один опечатанный файл не потерялся.
if ! codesign --verify --deep --strict "$APP_IN_DMG" 2>/dev/null; then
  echo "!! подпись бандла в образе не проходит проверку — файлы потерялись при копировании"
  FAIL=1
fi

# Эти два теряются первыми и молча, поэтому проверяем их поимённо.
if [ ! -e "$APP_IN_DMG/Contents/Library/LaunchAgents" ]; then
  echo "!! в образе нет Contents/Library/LaunchAgents — автозапуск не заработает"
  FAIL=1
fi
if [ -e "$APP_PATH/Contents/CodeResources" ] && [ ! -e "$APP_IN_DMG/Contents/CodeResources" ]; then
  echo "!! в образе нет тикета нотаризации (Contents/CodeResources)"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  rm -f "$OUT_DMG"
  exit 1
fi

echo ">> $OUT_DMG (бандл в образе проверен: подпись цела, LaunchAgent и тикет на месте)"
