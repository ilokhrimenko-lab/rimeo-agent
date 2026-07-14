## Build 114 — Expose stream transport and tunnel diagnostics

**Дата:** `2026-04-29`  
**Тег:** `v1.0-build114`

### macOS

**Статус:** rebuilt

**Что изменилось**

- `/api/status`, `/api/account` и `/api/tunnel/status` теперь явно отдают stream transport metadata:
  - `agent_url`
  - `tunnel_url`
  - `tunnel_active`
  - `cloudflared_found`
  - `stream_transport` (`tunnel` или `relay_only`)
- Cloud relay теперь логирует, рекламирует ли он tunnel URL в `/api/relay/poll`.
- Tunnel auto-start теперь логирует, найден ли `cloudflared`; если его нет, в лог пишется предупреждение, что web audio может не стартовать, если webapp не использует relay для audio.
- При появлении/исчезновении tunnel URL агент пишет `Cloud relay tunnel state changed`.

**Известные проблемы**

- Предоставленные логи показывают, что `/stream` вообще не запрашивается: файл, TCC, AIFF→WAV и waveform/artwork рабочие. Если после build 114 `/stream` всё ещё отсутствует, root cause находится в webapp/cloud audio URL decision layer.
- Без `cloudflared` webapp может иметь только relay transport. Если frontend audio element не умеет играть через relay-proxy URL, нужен cloud/webapp fix или доставка `cloudflared` вместе с агентом.

**Проверено вручную**

- `swift test` проходит: 4 теста, 0 failures.
- `./build_local_mac.sh 114` успешно создаёт `dist/RimeoAgent.app` и `dist/RimeoAgent_mac.zip`.
- `codesign --verify --deep --strict` проходит.
- `codesign -dv --verbose=4` показывает `Identifier=app.rimeo.agent` и `TeamIdentifier=49TC4WLDC5`.

### Windows

**Статус:** not rebuilt

**Что изменилось**

- no changes

**Известные проблемы**

- Windows native track в этом билде не пересобирался.

**Проверено вручную**

- not rebuilt

## Build 113 — Prefer stable macOS codesigning identity when available

**Дата:** `2026-04-29`  
**Тег:** `v1.0-build113`

### macOS

**Статус:** rebuilt

**Что изменилось**

- `build_local_mac.sh` больше не падает сразу в ad-hoc подпись по умолчанию.
- Локальная сборка теперь автоматически выбирает лучший доступный signing identity:
  - `Developer ID Application`, если установлен;
  - затем `Apple Development`;
  - затем локальный `rimeo`;
  - затем ad-hoc `-` как последний fallback.
- Для текущей машины выбран `Apple Development: il.okhrimenko+apple@gmail.com (5656PFPTMC)`, фактический `codesign` TeamIdentifier: `49TC4WLDC5` вместо `TeamIdentifier=not set`.

**Известные проблемы**

- Без paid Apple Developer Account нельзя сделать Developer ID notarization, поэтому первый запуск на чужом Mac всё ещё может требовать Right Click → Open или Open Anyway в Privacy & Security.
- `Apple Development` подпись лучше ad-hoc для стабильности identity, но это не полноценный публичный distribution certificate.
- TCC prompts для `Downloads` / `Documents` / `Desktop` всё равно могут появляться отдельно от Full Disk Access.

**Проверено вручную**

- `./build_local_mac.sh 113` успешно создаёт `dist/RimeoAgent.app` и `dist/RimeoAgent_mac.zip`.
- `codesign --verify --deep --strict` проходит.
- `codesign -dv --verbose=4` показывает `Identifier=app.rimeo.agent` и `TeamIdentifier=49TC4WLDC5`.

### Windows

**Статус:** not rebuilt

**Что изменилось**

- no changes

**Известные проблемы**

- Windows native track в этом билде не пересобирался.

**Проверено вручную**

- not rebuilt

## Build 112 — Web audio stream diagnostics for transferred macOS app

**Дата:** `2026-04-29`  
**Тег:** `v1.0-build112`

### macOS

**Статус:** rebuilt

**Что изменилось**

- Добавлены расширенные логи для расследования web playback на другой машине:
  - входящий relay-запрос: method/path/Range/header count/body size;
  - локальный `/stream`: raw path, resolved path, track id, preload, Range, TCC exists/readable, финальный WAV path, byte range и response length;
  - AIFF→WAV conversion: cache hit, source exists/readable, `ffmpeg` path, stderr при ошибке, размер готового WAV.
- Обновлены query parsing tests: `%20` проверяет пробелы в path, а буквальный `+` сохраняется как часть имени файла.

**Известные проблемы**

- Если webapp вообще не отправляет `/stream`, проблема остаётся на стороне cloud/web source URL, tunnel/relay routing или browser playback branch; новый билд должен показать это отсутствием строк `Stream request`.
- Long-poll relay по-прежнему буферизует локальный ответ в `body_b64`; для больших audio ranges это может быть ограничением relay-архитектуры.
- В Swift-сборке остаются прежние compile warnings, не блокирующие сборку.

**Проверено вручную**

- `swift test` проходит: 4 теста, 0 failures.
- `swift build -c release --arch arm64 --arch x86_64` проходит.

### Windows

**Статус:** not rebuilt

**Что изменилось**

- no changes

**Известные проблемы**

- Windows native track в этом билде не пересобирался.

**Проверено вручную**

- not rebuilt

## Build 111 — Settings tab (startup, Dock, 24/7 keep-alive) + Logs preserved

**Дата:** `2026-04-29`  
**Тег:** `v1.0-build111`

### macOS

**Статус:** rebuilt

**Что изменилось**

- Вкладка `Logs` переименована в `Settings`, иконка в sidebar заменена на `gearshape`.
- В `Settings` добавлены рабочие системные пункты:
  - `Open RimeoAgent at system startup` — интеграция через `SMAppService.mainApp`.
  - `Always show RimeoAgent icon in Dock` — реальное переключение `NSApplication.ActivationPolicy` (`regular` / `accessory`) и применение на старте приложения.
  - `Allow RimeoAgent to keep disk access alive for 24/7 work` — управление background keep-awake через `caffeinate -dimsu`.
- Блоки bug report и log output из старой вкладки `Logs` сохранены и оставлены ниже в той же вкладке `Settings`.

**Известные проблемы**

- `Launch at login` зависит от системных ограничений/macOS policy и может требовать дополнительного подтверждения пользователя на некоторых конфигурациях.
- 24/7 режим через `caffeinate` влияет на энергопотребление.
- В сборке остаются warning-и компилятора, не блокирующие работу.

**Проверено вручную**

- `swift build` проходит успешно.
- `./build_local_mac.sh 111` успешно создаёт:
  - `dist/RimeoAgent.app`
  - `dist/RimeoAgent_mac.zip`
- Подпись проходит (`codesign --verify --deep --strict`), `codesign -dv` показывает `Identifier=app.rimeo.agent`.

### Windows

**Статус:** not rebuilt

**Что изменилось**

- no changes

**Известные проблемы**

- Windows native track в этом билде не пересобирался.

**Проверено вручную**

- not rebuilt

## Build 110 — TCC / Full Disk Access diagnostics + native macOS build refresh

**Дата:** `2026-04-29`  
**Тег:** `v1.0-build110`

### macOS

**Статус:** rebuilt

**Что изменилось**

- Full Disk Access banner теперь пересчитывается при возврате приложения в фокус и при повторном показе основного UI, поэтому после выдачи FDA плашка должна сниматься без перезапуска.
- Добавлена TCC-диагностика для расследования prompt'ов на `Downloads` / `Documents` / `Desktop`: приложение логирует state FDA, bundle identity, signing summary и фактический путь/операцию, вызвавшие доступ.
- Локальная native-сборка обновлена: `build_local_mac.sh` теперь собирает universal Swift `.app`, очищает `xattr`, подписывает bundle с `--identifier app.rimeo.agent` и пакует `dist/RimeoAgent_mac.zip`.

**Известные проблемы**

- Системный prompt вида `RimeoAgent.app would like to access files in your Downloads folder` всё ещё может быть нормальным поведением macOS даже при наличии FDA, потому что это отдельная privacy surface `Files & Folders`.
- Локальная сборка сейчас подписывается ad-hoc по умолчанию; для полностью стабильной TCC identity между машинами и тестовыми циклами нужен постоянный signing identity / Developer ID.
- В Swift-сборке остаются compile warnings, они не блокируют выпуск этого билда.

**Проверено вручную**

- `swift build` в `macos_arm64` проходит успешно.
- `./build_local_mac.sh 110` успешно создаёт `dist/RimeoAgent.app` и `dist/RimeoAgent_mac.zip`.
- `codesign --verify --deep --strict` проходит на готовом `.app`.
- `codesign -dv --verbose=4` показывает `Identifier=app.rimeo.agent`.

### Windows

**Статус:** not rebuilt

**Что изменилось**

- no changes

**Известные проблемы**

- Windows native track в этом билде не пересобирался.

**Проверено вручную**

- not rebuilt

# Fix: No module named 'config'

## Проблема

При запуске `/Applications/RimeoAgent.app/Contents/MacOS/RimeoAgent` вылетала ошибка:

```
ModuleNotFoundError: No module named 'config'
[PYI-...:ERROR] Failed to execute script 'run' due to unhandled exception: No module named 'config'
```

---

## Корень проблемы

В `run.py` при `__package__` == `''` (всегда falsy в frozen bundle) код идёт по ветке:
```python
from config import settings, logger
```

Чтобы этот импорт сработал в frozen bundle, PyInstaller должен:
1. Найти `config.py` **во время анализа** (phase: analysis)
2. Включить его в `_MEIPASS` (куда PyInstaller распаковывает модули)

`sys._MEIPASS` уже добавлен в `sys.path` PyInstaller'ом автоматически. Значит если `config.py` попал в бандл — импорт работает. Если нет — ошибка.

---

## Build 105 — НЕ ПОМОГЛО

**Коммит:** `011a9ba` — "Fix missing local module imports in frozen bundle"  
**Тег:** `v1.0-build105`

### Что сделали

В `.github/workflows/build.yml` добавили в `flet pack`:

- `--hidden-import config` (и остальные локальные модули)
- `--pyinstaller-build-args="--paths=. --additional-hooks-dir=build/hooks"`

### Почему не помогло

`flet pack` **меняет рабочую директорию внутри** перед тем как вызывает PyInstaller. В итоге:

- `--paths=.` указывает на temp-каталог flet, а не на папку проекта → `config.py` не найден при анализе
- `--hidden-import "config"` без найденного исходника — no-op (PyInstaller предупреждает но модуль не включает)
- `--additional-hooks-dir=build/hooks` — каталог хуков был пустым (все `.py`-хуки удалены, только `.DS_Store`)

---

## Build 106 — текущая попытка

**Коммит:** `3078244` — "Use absolute path for PyInstaller --paths to fix config module bundling"  
**Тег:** `v1.0-build106`

### Что сделали

В `.github/workflows/build.yml`:

- macOS: `--paths=.` → `--paths=$(pwd)`
- Windows: `--paths=.` → `--paths=$($PWD.Path)`
- Убрали `--additional-hooks-dir=build/hooks`

### Почему должно помочь

Shell раскрывает `$(pwd)` **до** запуска `flet pack` — в момент раскрытия CWD ещё правильный (корень проекта). PyInstaller получает абсолютный путь, находит `config.py`, включает его в бандл.

### Статус

**macOS arm64 — УСПЕШНО ✓**  
Windows — неизвестно (не проверялось)

> Побочный эффект: вес приложения вырос с ~25 МБ до ~250 МБ, потому что теперь
> PyInstaller реально находит `analyzer.py` / `similarity.py` и тянет за ними `torch` (~200 МБ).
> Решение — отдельная задача.

---

## Build 107 — Проблемы с dock icon и повторным открытием

**Коммит:** `69307b4` — "Fix macOS dock icon bounce and window reopen"  
**Тег:** `v1.0-build107`

### Проблемы

1. **Медленный запуск** — приложение долго загружается на arm64
2. **Иконка в доке прыгает (bounce)** — dock icon bouncing после того как окно уже открылось
3. **Непонятно как переоткрыть** — после закрытия окна нет очевидного способа вернуть его

### Что сделали

- Добавлен `NSApplicationDidBecomeActiveNotification` observer — клик по dock icon → открывает окно
- Вынесен `_show_or_restart_window()` как общая функция для меню и observer'а
- `setActivationPolicy_(.Regular)` перенесён до `ft.app()` (было внутри async setup)

### Результат после теста

Проблемы **не устранены**. Дополнительно обнаружено: в доке появляются **две иконки** — от Python-процесса и от Flet subprocess.

---

## Build 108 — Убрать двойную иконку, Python 3.11

**Тег:** `v1.0-build108`

### Проблемы (уточнённые)

1. **Две иконки в доке** — Python-процесс + Flet subprocess оба отображаются
2. **Bounce** — вызван тем, что Python-процесс устанавливал `NSApplicationActivationPolicyRegular` поверх Flet subprocess
3. **Python 3.9.6 локально** — расходится с GitHub Actions (3.11)

### Что сделали

**`ui_app.py`:**
- Убран `setActivationPolicy_(.Regular)` полностью — Python-процесс не показывается в dock, остаётся только Flet subprocess
- Добавлена `_show_menubar_hint()` — алерт при первом закрытии окна: "Иконка в строке меню..."

**`build_local_mac.sh`:**
- Скрипт теперь проверяет Python 3.11 при старте и завершается с ошибкой если версия другая
- Все вызовы заменены на `$PY` (python3.11), сборка через `$PY -m flet pack`

### Установка Python 3.11 локально

```bash
brew install python@3.11
```

---

## Build 109 — Анализ корня проблем + план: переход на нативную Swift-сборку

**Тег:** `v1.0-build109` (планируется)

### Диагностика: почему Build 107–108 не помогли

Все попытки исправить иконку и bounce в Python-коде были обречены, потому что архитектура Flet принципиально не позволяет это исправить снаружи:

```
RimeoAgent (PyInstaller, 259 МБ)
    └── ft.app() → порождает отдельный subprocess: Flutter/Dart runtime
                       ↑ ЭТОТ процесс владеет dock-иконкой и окном
```

**Что именно происходит:**
1. `setActivationPolicy_(.Regular)` в Python влиял на Python-процесс, а не на Flutter subprocess — поэтому появлялись две иконки
2. `appDidBecomeActive_` observer ловит события Python-приложения, а клик по dock идёт во Flutter subprocess
3. Flutter runtime при запуске вызывает `[[NSProcessInfo processInfo] setProcessName:@"flet"]` — это захардкожено в Flutter/Flet runtime и **не переопределяется через Info.plist**
4. Bounce происходит потому что Flutter subprocess инициализируется позже Python, и до момента полной инициализации dock считает окно "не готовым"

**Итог:** Все три проблемы (медленный запуск, bounce, иконка "flet") — это фундаментальные ограничения связки PyInstaller+Flet+Flutter. Пропатчить это на уровне Python-кода невозможно.

### Решение: нативная Swift-сборка

В `macos_arm64/` уже существует полностью готовая нативная реализация на SwiftUI:

| Параметр | Flet (Build 108) | Swift (Build 109) |
|---|---|---|
| Размер бинарника | 259 МБ | ~3 МБ |
| Время запуска | ~3-5 сек | мгновенный |
| Dock-иконка | "flet" | "Rimeo Agent" |
| Bounce | есть | нет (activationPolicy до event loop) |
| Клик по dock-иконке | не работает | `applicationShouldHandleReopen` |

### Что нужно сделать

**1. `RimeoAgent/macos_arm64/build/Info.plist`** — создать новый файл:
```xml
<dict>
  <key>CFBundleDisplayName</key><string>Rimeo Agent</string>
  <key>CFBundleExecutable</key><string>RimeoAgent</string>
  <key>CFBundleIdentifier</key><string>app.rimeo.agent</string>
  <key>CFBundleIconFile</key><string>RimeoAgent</string>
  <key>CFBundleVersion</key><string>1.0.109</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
```

**2. `.github/workflows/build.yml`** — заменить секцию macOS на `swift build`:
```yaml
- name: Build macOS app (Swift)
  run: |
    cd RimeoAgent/macos_arm64
    swift build -c release --arch arm64
    APP="$RUNNER_TEMP/RimeoAgent.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp .build/arm64-apple-macosx/release/RimeoAgentMac "$APP/Contents/MacOS/RimeoAgent"
    cp build/Info.plist "$APP/Contents/Info.plist"
    # создать .icns из rimeo1024.png через sips + iconutil
    cd "$RUNNER_TEMP" && zip -r "$GITHUB_WORKSPACE/RimeoAgent_mac_arm64.zip" RimeoAgent.app
```

**3. `RimeoAgent/build_local_mac.sh`** — аналогично заменить `flet pack` на `swift build` + создание .app bundle.

**4. Перед сборкой проверить** что Swift-реализация поддерживает всё необходимое:
- [ ] FastAPI/uvicorn запускается (через `Process` или встроенный HTTP)
- [ ] NSStatusBar с меню работает
- [ ] Relay polling (URLSession)
- [ ] `applicationShouldHandleReopen` в AppDelegate

---

## Ссылки на скачивание (всегда актуальны)

GitHub Releases поддерживает постоянный URL на последний релиз — менять в онбординге не нужно:

```
https://github.com/ilokhrimenko-lab/rimeo-agent/releases/latest/download/RimeoAgent.dmg
https://github.com/ilokhrimenko-lab/rimeo-agent/releases/latest/download/RimeoAgent_mac.zip
https://github.com/ilokhrimenko-lab/rimeo-agent/releases/latest/download/RimeoAgentSetup_win.exe
```

**Важно:** имена файлов в `build.yml` должны оставаться стабильными. Если переименовать артефакт в workflow — ссылка сломается.

**🚨 mac-релиз = ДВА ассета, оба обязательны:**
- `RimeoAgent_mac.zip` — **канал автообновления**. Имя захардкожено в `UpdateChecker.swift` (`assetName`); убрать из релиза или переименовать = **тихо** сломать автоапдейт у всех установленных агентов.
- `RimeoAgent.dmg` — установщик для людей (перетащить в Applications). Собирается `packaging/dmg/make_dmg.sh` (dmgbuild, headless), нотаризуется **отдельно** от `.app`.

Выкатывать «просто zip» нельзя. Подробности → `memory/infrastructure.md`, раздел «macOS — SwiftUI».

(Историческое: старое имя `RimeoAgent_mac_arm64.zip` из ранних билдов больше не используется — mac-ассет называется `RimeoAgent_mac.zip` и собирается universal.)

---

## Если build 106 тоже не поможет

Следующие варианты по возрастанию радикальности:

1. **`sys.path` в `run.py`** — добавить в начало файла перед импортами:
   ```python
   import sys
   if getattr(sys, 'frozen', False) and hasattr(sys, '_MEIPASS'):
       sys.path.insert(0, sys._MEIPASS)
   ```
   Работает только если config.py всё-таки попал в бандл.

2. **`--collect-all config`** вместо `--hidden-import config` — явно собирает все файлы модуля.

3. **Отказаться от `flet pack`**, перейти на прямой `pyinstaller` с `.spec`-файлом — полный контроль над `pathex`, `hiddenimports`, `datas`.
