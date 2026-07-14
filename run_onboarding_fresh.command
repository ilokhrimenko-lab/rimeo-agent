#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Запуск RimeoAgent в «первом запуске» (онбординг с нуля) — БЕЗОПАСНО.
#
# Почему так: агент жёстко хранит состояние в
#   ~/Library/Application Support/RimeoAgent/   (rimo_data.json и т.д.)
# и показывает онбординг, только если этой папки/источника нет.
# Подмена HOME не работает — FileManager берёт настоящий home из системы.
# Поэтому скрипт ВРЕМЕННО отодвигает реальный конфиг, запускает чистый
# онбординг, а когда ты ЗАКРОЕШЬ приложение — автоматически возвращает
# реальные данные на место (даже при Ctrl+C). Твой агент не пострадает.
#
# Запуск: двойной клик в Finder, либо  ./run_onboarding_fresh.command
# Своё приложение:  RIMEO_APP="/path/to/RimeoAgent.app" ./run_onboarding_fresh.command
# ─────────────────────────────────────────────────────────────
set -u

APP="${RIMEO_APP:-/Applications/RimeoAgent.app}"
SUPPORT="$HOME/Library/Application Support"
LIVE="$SUPPORT/RimeoAgent"
BAK="$SUPPORT/RimeoAgent.real-backup.$$"

if [ ! -d "$APP" ]; then
    echo "✗ Не найдено приложение: $APP"
    exit 1
fi

# Если обычный агент (порт 8000) запущен — он держит реальный конфиг в памяти
# и при выходе перезапишет его. Глушим только ОБЫЧНЫЙ агент, Review не трогаем.
RUNNING_PIDS="$(lsof -nP -iTCP:8000 -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$RUNNING_PIDS" ]; then
    echo "Останавливаю запущенный обычный агент (порт 8000): $RUNNING_PIDS"
    # shellcheck disable=SC2086
    kill $RUNNING_PIDS 2>/dev/null || true
    sleep 1
fi

restore() {
    echo ""
    echo "Восстанавливаю реальный конфиг агента…"
    rm -rf "$LIVE"
    if [ -d "$BAK" ]; then
        mv "$BAK" "$LIVE"
        echo "✓ Реальные данные возвращены на место."
    fi
}
trap restore EXIT INT TERM

# Отодвигаем реальный конфиг → агент стартует как впервые.
if [ -d "$LIVE" ]; then
    mv "$LIVE" "$BAK"
    echo "Реальный конфиг временно отложен в: $BAK"
fi

echo ""
echo "➡️  Запускаю чистый онбординг. Реальные данные вернутся, когда закроешь окно."
echo ""

# -n: новый экземпляр; -W: ждать, пока приложение не закроется → потом trap.
open -n -W "$APP"
