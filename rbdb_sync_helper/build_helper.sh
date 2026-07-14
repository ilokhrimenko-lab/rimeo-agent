#!/bin/bash
# Сборка frozen-бинаря rbdb-sync-helper (PyInstaller one-file).
#
# ЗАЧЕМ FROZEN, А НЕ СИСТЕМНЫЙ PYTHON:
# у юзера на машине нет ни pyrekordbox, ни sqlcipher3 — и ставить их мы не можем.
# Inline-python-фолбэк (как у read-хелпера rbdb-helper) для ЗАПИСИ невозможен:
# нужны нативные колёса. Поэтому — самодостаточный бинарь со всем внутри.
#
# Выход: dist/rbdb-sync-helper  → копируется в бандл агента.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "══════════════════════════════════════════"
echo "  Сборка rbdb-sync-helper (frozen)"
echo "══════════════════════════════════════════"
echo

if [ ! -x .venv/bin/python ]; then
    echo "❌ Нет .venv. Создай:"
    echo "   uv venv --python 3.12 .venv"
    echo "   uv pip install --python .venv/bin/python pyrekordbox==0.4.3 sqlcipher3-wheels pyinstaller"
    exit 1
fi

rm -rf build dist

.venv/bin/pyinstaller \
    --onefile \
    --name rbdb-sync-helper \
    --clean \
    --noconfirm \
    --strip \
    --console \
    `# pyrekordbox тянет данные/схемы через importlib — PyInstaller их не видит сам` \
    --collect-all pyrekordbox \
    --collect-all sqlcipher3 \
    --hidden-import sqlalchemy \
    --hidden-import construct \
    `# то, что точно не нужно — режем, иначе бинарь пухнет на десятки МБ` \
    --exclude-module matplotlib \
    --exclude-module pandas \
    --exclude-module PIL \
    --exclude-module tkinter \
    --exclude-module pytest \
    rbdb_sync_helper.py

echo
if [ -x dist/rbdb-sync-helper ]; then
    SIZE=$(du -h dist/rbdb-sync-helper | cut -f1 | tr -d ' ')
    echo "✅ dist/rbdb-sync-helper  ($SIZE)"
    echo
    echo "Смоук-тест (должен ругнуться на аргументы):"
    ./dist/rbdb-sync-helper 2>&1 | head -1 | sed 's/^/   /'
else
    echo "❌ Бинарь не собрался"
    exit 1
fi
