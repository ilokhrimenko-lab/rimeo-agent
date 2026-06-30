# Rimeo Agent

Нативные desktop-агенты Rimeo: читают DJ-библиотеку (Rekordbox), стримят треки в iOS/web-приложение через локальную сеть или Cloudflare Tunnel.

Репозиторий содержит **двух агентов** — по одному на каждую ОС:

| ОС | Папка | Стек |
|----|-------|------|
| **macOS** (Apple Silicon + Intel, universal) | [`macos_arm64/`](macos_arm64/) | Swift + SwiftPM, SQLCipher |
| **Windows** (x64 + arm64) | [`windows_csharp/`](windows_csharp/) | C# / .NET 8, WinUI 3 |

## Сборка и релиз

Сборка идёт в GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)) и **запускается только пушем тега**:

| Тег | Что собирается |
|-----|----------------|
| `v1.0-buildNNN` | macOS + Windows |
| `mac-v1.0-buildNNN` | только macOS |
| `win-v1.0-buildNNN` | только Windows |

Артефакты (`.zip` для mac, `.exe`-инсталлятор + `.zip` для win) автоматически прикрепляются к GitHub Release.

Локальная сборка macOS-агента: `./release_mac.sh` (или `./build_local_mac.sh`).

## Структура корня

- `macos_arm64/`, `windows_csharp/` — исходники двух агентов
- `build_info.py` — версия и номер билда (перезаписывается CI из тега)
- `similarity_config.json` — конфиг анализа схожести треков
- `rimeo1024*.png` / `*.icns` — иконки приложения (используются CI)
- `release_mac.sh`, `release_win.sh`, `build_local_mac.sh` — скрипты сборки
