#!/bin/bash
# Подпись onedir-сборки rbdb-sync-helper ИЗНУТРИ НАРУЖУ.
#
#   sign_helper_dir.sh <папка хелпера> <identity> <entitlements.plist> [доп. флаги codesign…]
#
#   CI:        sign_helper_dir.sh "$APP/Contents/Resources/rbdb-sync-helper" "$ID" "$ENT" --timestamp --options runtime
#   локально:  sign_helper_dir.sh "$APP/Contents/Resources/rbdb-sync-helper" "$ID" "$ENT"
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ ШАГ. Хелпер лежит в Contents/Resources, а `codesign --deep` ищет вложенный
# код только в «кодовых» папках бандла (MacOS, Frameworks, …) — в Resources он .so не увидит.
# Подпись .app запечатает их лишь как ресурсы (хеш файла), а нотаризация требует, чтобы КАЖДЫЙ
# Mach-O в бандле был подписан Developer ID + hardened runtime + timestamp. Поэтому каждый
# .so/.dylib подписываем сами, до подписи самого .app.
#
# ПОЧЕМУ Resources, а не MacOS/Frameworks: в onedir рядом с .so лежат .py, .dist-info,
# base_library.zip. В «кодовых» папках codesign требует, чтобы каждый файл был кодом, и
# не-Mach-O там ломает `codesign --verify --deep --strict` — а его агент прогоняет на
# каждом автообновлении (UpdateSignatureVerifier). Сломать его = тихо убить автоапдейт.
set -euo pipefail

DIR="${1:?папка хелпера}"
ID="${2:?identity}"
ENT="${3:?entitlements}"
shift 3

[ -x "$DIR/rbdb-sync-helper" ] || { echo "sign_helper_dir: нет $DIR/rbdb-sync-helper" >&2; exit 1; }
[ -d "$DIR/_internal" ]        || { echo "sign_helper_dir: нет $DIR/_internal" >&2; exit 1; }

signed=0
# 1. Все Mach-O внутри _internal. Симлинки пропускаем — подписывается файл, на который они ведут.
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
        codesign --force "$@" --sign "$ID" "$f"
        signed=$((signed + 1))
    fi
done < <(find "$DIR/_internal" -type f -print0)

# 2. .framework-бандлы (появляются, если PyInstaller собран фреймворковым питоном) — ПОСЛЕ
#    их содержимого, вложенные раньше внешних (обратная сортировка путей).
while IFS= read -r -d '' fw; do
    codesign --force "$@" --sign "$ID" "$fw"
    signed=$((signed + 1))
done < <(find "$DIR/_internal" -type d -name "*.framework" -print0 | sort -rz)

# 3. Сам исполняемый файл — последним и с entitlements (см. sync-helper.entitlements).
codesign --force "$@" --entitlements "$ENT" --sign "$ID" "$DIR/rbdb-sync-helper"
signed=$((signed + 1))

echo "sign_helper_dir: подписано $signed объектов в $DIR"
