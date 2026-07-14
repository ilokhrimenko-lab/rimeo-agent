# RimeoAgent — Native Frontend Migration Plan

> **Цель:** заменить Python/Flet UI на нативные реализации.
> macOS → SwiftUI (уже существует, нужна сборка)
> Windows → C# + WinUI 3
>
> Бэкенд (HTTP сервер, анализ треков, cloud relay) — каждая платформа реализует свой,
> Python-код остаётся как справочная реализация, но не запускается.

---

## Инструкция для AI CLI (Claude / Codex / Gemini)

> Прочитай этот блок перед любой работой над проектом.

### Контекст проекта

**RimeoAgent** — локальный агент для DJ-библиотеки Rekordbox. Работает на компьютере пользователя,
общается с облачным сервером `rimeo.app` через long-poll relay (HTTP).

```
rimeo.app (Flask, порт 5000)
    ↑ long-poll relay
RimeoAgent (локально, порт 8000)
    ├── HTTP API (треки, анализ, стриминг аудио, аккаунт)
    ├── Rekordbox XML parser → библиотека треков
    ├── Audio analysis engine → features (energy, timbre, groove, BPM, key)
    ├── Similarity engine → похожие треки
    ├── Cloudflare tunnel (опционально, для прямого доступа)
    └── UI (статус бар + окно с 7 вкладками)
```

**Вкладки UI:** Library · Analysis · Pairing · Account · Logs · (Onboarding при первом запуске)

### Ключевые файлы

| Путь | Описание |
|------|----------|
| `api_server.py` | Python-эталон: все HTTP endpoint'ы (23 шт.) |
| `analyzer.py` | Python-эталон: извлечение аудио-фич (librosa) |
| `similarity.py` | Python-эталон: скоринг похожести треков |
| `config.py` | Python-эталон: настройки, пути, agent ID |
| `macos_arm64/Sources/RimeoAgentMac/` | Swift-реализация (feature-complete) |
| `windows_csharp/` | C#-реализация (создаётся) |
| `change build log.md` | История сборок и решённых проблем |
| `NATIVE_AGENT_PLAN.md` | **Этот файл** — план и статус работ |

### Release discipline

- Каждый новый артефакт для проверки, QA или релиза получает новый **числовой** `BUILD_NUMBER`.
- Строковые build labels вроде `reload-fix`, `test-build`, `local-fix` запрещены для артефактов, которые передаются на проверку или пользователю.
- `BUILD_NUMBER` — единый release identifier и источник правды для:
  - `build_info.py`
  - UI version label / `DISPLAY_VERSION`
  - git tag / release title
  - changelog entry
- Ожидаемый формат тега: `v1.0-buildNNN`, без буквенных или текстовых суффиксов.
- Если для одного обновления собираются и macOS, и Windows, обе платформы используют один и тот же `BUILD_NUMBER`; различия описываются в platform-specific changelog.
- Если фактически rebuilt только одна платформа, build number всё равно считается общим для обновления, а для второй платформы changelog обязан явно содержать `no changes` или `not rebuilt`.

### Changelog policy

- Для каждого `BUILD_NUMBER` обязательно создаётся changelog entry с двумя подпунктами:
  - `macOS`
  - `Windows`
- Минимальный состав записи:
  - дата
  - build number / tag
  - статус платформы
  - что изменилось
  - известные проблемы
  - что проверено вручную
- Основной подробный журнал остаётся в `change build log.md`.
- `NATIVE_AGENT_PLAN.md` является policy-документом: ни один билд не считается готовым к передаче на проверку без соответствующей записи в `change build log.md`.
- Если изменения затронули только одну платформу, в changelog второй платформы явно указывать `no changes` или `not rebuilt`, чтобы не было двусмысленности.

### HTTP API (все endpoint'ы)

```
GET  /stream               — аудио стриминг (Range requests, AIFF→WAV)
GET  /waveform             — пики волны {duration, peaks[]}
GET  /artwork              — обложка трека (JPEG)
GET  /reveal               — открыть файл в Finder/Explorer
GET  /api/data             — вся библиотека (треки, плейлисты, заметки)
GET  /api/pairing_info     — код паринга (до привязки)
GET  /api/check_pairing    — проверить код
POST /api/save_note        — сохранить заметку к треку
POST /api/save_exclusions  — обновить список исключений
POST /api/send_tg          — отправить сообщение в Telegram
GET  /api/analysis         — фичи одного трека {id}
GET  /api/analysis/status  — прогресс анализа {done, total, current}
POST /api/analysis/start   — запустить анализ всей библиотеки
POST /api/analysis/recheck — переанализировать изменённые треки
GET  /api/analysis/track_list — список проанализированных ID
GET  /api/similar          — похожие треки {id, limit, use_key}
GET  /api/account          — статус аккаунта (agent_id, linked, tunnel_url)
GET  /api/status           — health check (200 OK)
POST /api/link_account     — привязать к облаку
POST /api/unlink_account   — отвязать
GET  /api/tunnel/status    — текущий tunnel URL
POST /api/tunnel/start     — запустить cloudflared
POST /api/tunnel/stop      — остановить tunnel
POST /api/report_bug       — отправить баг-репорт
```

### Cloud Relay (long-poll)

```
Агент → GET  rimeo.app/api/relay/poll/{agentID}?token=X   (держит 25 сек)
Сервер → {"type": "ping"} или {"req_id", "method", "path", "body_b64"}
Агент → выполняет команду локально (localhost:8000)
Агент → POST rimeo.app/api/relay/result  {req_id, status, body_b64}
```

### Данные агента (rimo_data.json)

```json
{
  "xml_path": "/path/to/rekordbox.xml",
  "agent_id": "uuid",
  "cloud_token": "token",
  "tunnel_url": "https://xxx.trycloudflare.com",
  "notes": {"track_id": "текст"},
  "exclusions": ["track_id"],
  "pairing_code": "XXXX"
}
```

### Алгоритм скоринга похожести

| Компонент | Вес | Детали |
|-----------|-----|--------|
| Vibe (аудио-фичи) | 45% | energy, timbre MFCC, groove, brightness, happiness |
| Key (Camelot wheel) | 25% | perfect match=1.0, +/-1=0.5, rest=0 |
| Tempo (BPM) | 20% | разница >8 BPM → трек исключается полностью |
| Metadata | 10% | genre, label, artist |

### Статус чек-листов

- ✅ Сделано
- 🔄 В работе
- 🔲 Предстоит сделать

---

## macOS — SwiftUI (macos_arm64/)

> Swift-реализация **feature-complete**. Нужно только настроить сборку и выпустить.

### Архитектура (уже реализована)

```
macos_arm64/Sources/RimeoAgentMac/
├── AppDelegate.swift         — NSApp, dock click, status bar menu
├── main.swift                — entry point, activationPolicy
├── Config/
│   ├── AppConfig.swift       — пути, agent_id, порт 8000
│   └── AgentLogger.swift     — логирование
├── Models/
│   ├── TrackModel.swift      — Track, Playlist, LibraryData
│   └── DataStore.swift       — rimo_data.json (заметки, exclusions, токены)
├── Services/
│   ├── AppState.swift        — @Published глобальный стейт
│   ├── RekordboxParser.swift — парсинг XML → треки/плейлисты
│   ├── AudioService.swift    — waveform (ffmpeg), artwork, AIFF→WAV
│   ├── AnalysisEngine.swift  — аудио-фичи (AVFoundation + Accelerate)
│   ├── SimilarityEngine.swift— скоринг похожести
│   ├── CloudRelay.swift      — long-poll loop
│   ├── TunnelManager.swift   — cloudflared subprocess
│   └── UpdateChecker.swift   — авто-обновление
├── HTTPServer/
│   ├── HTTPServer.swift      — нативный HTTP (без зависимостей)
│   └── APIRouter.swift       — все 23 endpoint'а
└── Views/
    ├── ContentView.swift
    ├── OnboardingView.swift
    ├── LibraryTabView.swift
    ├── AnalysisTabView.swift
    ├── PairingTabView.swift
    ├── AccountTabView.swift
    └── LogsTabView.swift
```

### Чек-лист macOS

> Swift-приложение уже собиралось и запускалось в debug-режиме; часть реальной функциональности проверена.
> Непроверенные пункты ниже остаются в статусе 🔲.

#### Шаг 1 — Первый запуск (отладка)
- ✅ `swift build` компилируется без ошибок
- ✅ Запустить debug-бинарник: `macos_arm64/.build/arm64-apple-macosx/debug/RimeoAgentMac`
- ✅ Приложение открывается, окно отображается
- ✅ Нет краша при старте (проверить логи: `~/Library/Application Support/RimeoAgent/agent.log`)
- ✅ HTTP сервер слушает порт 8000 (`curl http://localhost:8000/api/status` → 200)
- ✅ Onboarding показывается при первом запуске (нет rimo_data.json)

#### Шаг 2 — Базовая функциональность
- ✅ Rekordbox XML парсинг — треки отображаются во вкладке Library
- ✅ Waveform peaks — `/waveform?path=...` возвращает данные
- ✅ Artwork — `/artwork?path=...` возвращает JPEG
- ✅ Стриминг аудио — `/stream?path=...` работает (Range requests)
- ✅ Персистентные данные — заметки и exclusions сохраняются после перезапуска

#### Шаг 3 — Аудио анализ
- ✅ Запустить анализ через вкладку Analysis (или `POST /api/analysis/start`)
- ✅ Прогресс обновляется (`GET /api/analysis/status`)
- ✅ Фичи сохраняются (`GET /api/analysis?id=...` возвращает energy, timbre, groove и т.д.)
- ✅ Similarity работает (`GET /api/similar?id=...` возвращает список треков)

  Проверка build 109: на текущей библиотеке реально доступны 15 аудиофайлов, 1995 путей недоступны (`/Volumes/KODAK/...` и старые папки). Analysis теперь считает только доступные файлы, показывает `unavailable=1995` отдельно от ошибок, сохраняет `analysis_data.json` после каждого успешного трека, `/api/similar` возвращает результаты.
  Статус анализа также показывает `not_analyzed` и `all_analyzed`: когда все доступные файлы уже посчитаны, UI говорит “All available tracks analyzed”; если нет — показывает число оставшихся непроанализированных треков.

#### Шаг 4 — Cloud и паринг
- ✅ Паринг с rimeo.app — код генерируется, привязка проходит
- ✅ Cloud relay работает (агент поллит, rimeo.app видит агент онлайн)
  Живая проверка пройдена: из облака пришли relay-команды `/api/status`, `/waveform`, `/artwork`, и агент успешно вернул `POST /api/relay/result`.
- ✅ Стриминг через облако (библиотека rimeo.app загружает треки через relay/tunnel)
  Проверено через активный Cloudflare tunnel: `/api/status` → 200, `/stream` с `Range` → 206, `/artwork` → 200.

#### Шаг 5 — Dock и статус бар
- ✅ Статус-бар иконка отображается корректно
- ✅ Меню статус-бара работает (Open / Quit)
- ✅ Закрыть окно → агент остаётся в фоне (не quit)
- ✅ Клик по dock-иконке → окно переоткрывается
- ✅ Окно не открывается слишком маленьким: увеличены стартовый размер и минимальные размеры окна

#### Шаг 6 — Сборка .app bundle
- ✅ Создать `macos_arm64/build/Info.plist` (CFBundleDisplayName = "Rimeo Agent", LSMinimumSystemVersion 12.0)
- ✅ `swift build -c release --arch arm64` — компилируется
- ✅ Создать .app bundle вручную из release-бинарника + Info.plist + иконка
- ✅ Обновить `build_local_mac.sh` — заменить `flet pack` на `swift build` + .app
- ✅ Обновить `.github/workflows/build.yml` — macOS job на Swift
- ✅ Dock-иконка показывает "Rimeo Agent" (не "flet"), не прыгает

  Локальная проверка build 109: `./build_local_mac.sh 109` успешно создал `dist/RimeoAgent.app` и `dist/RimeoAgent_mac_arm64.zip`; `plutil -lint` прошёл для обоих `Info.plist`, zip содержит бинарник, иконку и `build_info.py`.

#### Не критично (оставить на потом)
- ✅ Авто-обновление (UpdateChecker) — протестировать
- ✅ Cloudflare tunnel (TunnelManager) — протестировать
- ✅ CLAP embeddings (512-dim ML — опционально)
- ✅ Парсинг Pioneer master.db (fallback если нет XML)
  Актуальное состояние: встроенный native helper через SQLCipher уже используется как preferred path внутри `.app`, Python helper остаётся fallback для совместимости/отладки.
  Известная проблема build-пути уже устранена: large-library reload раньше зависал из-за stdout deadlock между приложением и helper-ом; теперь helper пишет результат во временный output file contract.

### Gap-анализ: Python агент → Swift parity

> Актуализировано после первой реальной проверки Swift-сборки.
> Это список расхождений между Python-референсом и `macos_arm64/`.

#### Высокий приоритет
- ✅ `RekordboxParser.swift` — добавить fallback на Pioneer `master.db` как в Python `parse_library()`
  Реализовано и проверено в сценарии без `.env` / без XML: `/api/data` возвращает библиотеку из `master.db`, `isOnboarding=false`.
- ✅ `APIRouter.swift` `/api/status` — вернуть Python-поля `db_path`, `db_exists`, `library_source`
- ✅ `APIRouter.swift` / `AppConfig.swift` — синхронизировать версию/формат версии с Python (`DISPLAY_VERSION`)
- 🔄 `CloudRelay.swift` — синхронизировать cloud headers / backoff / обработку ошибок с Python
  Исправлен критичный баг очереди (poll loop больше не блокирует обработку relay-команд), добавлены Python-подобные логи/headers/retry; end-to-end проверка через реальный cloud flow уже пройдена.

#### Средний приоритет
- ✅ `AnalysisEngine.swift` — сверить численное поведение с `analyzer.py` на одинаковых треках
  Методология: segment selection и output shape совпадают. Числа несовместимы между движками (40 vs 128 mel-фильтров, spectral-flux groove vs librosa beat tracker, raw-FFT chroma vs HPSS+CQT) — это норма для native порта без librosa. Смешивать Python- и Swift-analyzed треки в одном store нельзя; при переходе нужен полный re-analyze.
- ✅ `SimilarityEngine.swift` — добавить CLAP-ветку скоринга как опциональный режим parity с Python
  Добавлено: поле `clap: [Double]?` в `TrackFeatures`, метод `clapScore()` (dot-product единично-нормированных векторов → 0–1), переключение формулы весов (CLAP 0.80/0.12/0.08 vs MFCC 0.45/0.25/0.20/0.10). Swift не генерирует CLAP-эмбеддинги, но использует их если они есть в analysis_data.json от Python-агента.
- ✅ `APIRouter.swift` `/api/data` — унифицировать поле даты библиотеки (`library_date` vs `xml_date`) под текущий Python-контракт
- ✅ `AudioService.swift` / media endpoints — исправить зависания `ffmpeg` и быстрый `preload=true` для waveform/artwork
  Причина: stdout/stderr pipe читались после `waitUntilExit()`, из-за чего шумный `ffmpeg` мог зависнуть; relay получал timeout, а фронт показывал offline/actions unavailable. Теперь pipe читаются параллельно, есть timeout, preload отвечает сразу и считает кэш в фоне.
- ✅ `AnalysisEngine.swift` / `AnalysisTabView.swift` — довести Analysis до рабочего состояния
  Исправлен старт из UI (раньше UI сам ставил `running=true`, и endpoint отвечал `already_running`), добавлен `/api/analysis/stop`, короткие timeout'ы для анализа, синхронное сохранение после каждого успешного трека и честный статус `analyzed_count/unavailable/errors`.
- ✅ `APIRouter.swift` `/api/account` и `/api/report_bug` — проверить полное совпадение request/response shape с Python
- 🔄 UI parity-pass со `ui_app.py`:
  Уже приведены к Python-макету `main layout`, `Library`, `Onboarding`, `Analysis`, `Pairing`, `Account` и `Logs`; дальше нужна финальная визуальная полировка и проверка отдельных деталей поведения.

#### Investigative workstream — TCC / Downloads / Full Disk Access
- 🔄 Разобраться, почему при наличии Full Disk Access приложение всё равно может показывать системный prompt вида `RimeoAgent.app would like to access files in your Downloads folder`.
- Основная рабочая гипотеза №1:
  текущий баннер `Full Disk Access` и реальный prompt `Files & Folders` для `Downloads/Desktop/Documents` относятся к разным permission surfaces; текущая эвристика `hasFullDiskAccess()` через чтение `TCC.db` не гарантирует отсутствие prompt'ов на `Downloads`.
- Рабочая гипотеза №2:
  локальные unsigned / ad-hoc builds могут не иметь стабильной TCC identity; после пересборки macOS может заново спрашивать доступ даже при том же bundle id.
- Следующий исполнитель должен:
  - заменить трактовку “FDA-only” на явную модель TCC diagnostics;
  - логировать отдельно:
    - `full disk access state`
    - `Downloads/Desktop/Documents prompt state`
    - bundle identifier
    - signing state
    - фактический путь, вызвавший prompt
  - перестать обещать пользователю, что только FDA решает доступ “ко всем локациям”;
  - спланировать переход на стабильную подпись тестовых билдов и/или на user-granted file access через `NSOpenPanel` / bookmarks там, где это критично.
- Expected outcome:
  понять, это продуктовый баг permission-модели, проблема подписи локальных билдов, или нормальное поведение TCC для `Downloads`.
- Smoke-test matrix для расследования:
  - свежий локальный build
  - `Downloads`
  - `Documents`
  - внешний диск
  - signed vs unsigned / ad-hoc
  - повторный запуск после rebuild
  - наличие / отсутствие system prompt
- Статус расследования на текущую итерацию:
  подтверждены обе гипотезы. В коде был FDA-only UX, хотя системный prompt на `Downloads` относится к отдельной macOS privacy surface `Files & Folders`, а локально собранный `.app` был bundle-less с точки зрения подписи (`codesign` показывал `Info.plist=not bound`, `TeamIdentifier=not set`, effective identifier = `RimeoAgent`), что делает TCC identity нестабильной между rebuild'ами.
- Выполнено в коде:
  - добавлен `TCCDiagnostics.swift` с логированием:
    - `full_disk_access`
    - bundle id / bundle path / executable
    - signing summary из `codesign -dv`
    - category path (`downloads`, `documents`, `desktop`, `external_volume`, `other`)
  - добавлены path-level TCC logs в `stream`, `waveform`, `artwork`, `reveal`, `analysis`, AIFF conversion и segment extraction;
  - локальная сборка `build_local_mac.sh` теперь явно выполняет `codesign --force --deep --sign ...` для готового `.app`, чтобы TCC видел подпись bundle, а не только ad-hoc signature на Mach-O бинарнике.
- Текущий вывод:
  prompt вида `RimeoAgent.app would like to access files in your Downloads folder` может быть нормальным даже при наличии FDA, а частота повторных prompt'ов дополнительно усиливается нестабильной identity у локальных unsigned / ad-hoc билдов.

#### Investigative workstream — macOS Intel audio not found in web version
- 🔄 Разобраться, почему у агента macOS Intel в web-версии не идёт передача звука, хотя Finder action работает, а сам трек в web пишет, что не найден по пути.
- Подтверждённые факты из текущего кода:
  - playback в web идёт через `/stream?path=...`;
  - `/stream` сначала делает `FileManager.default.fileExists(atPath:)`, потом для `aiff/aif` вызывает `ffmpeg`;
  - `reveal` и `stream` используют один и тот же `path`, но failure modes разные;
  - query parsing уже имеет отдельный тест на пробелы и `+`.
- Prioritized hypotheses:
  - Intel-сборка отстаёт по fixes query/path decoding и использует старый билд;
  - путь трека корректно доходит до `/reveal`, но ломается в `/stream` на encoding / normalization / escaping;
  - `ffmpeg` на Intel отсутствует или находится не там, и фронт интерпретирует downstream failure как “track not found”;
  - есть TCC / readability issue для самого аудиофайла, даже если путь в библиотеке существует.
- Следующий исполнитель должен:
  - добавить расширенные логи в `/stream`, `AudioService.ensureWAV`, `waveform`, `artwork`;
  - логировать:
    - raw path
    - decoded path
    - `fileExists`
    - `isReadableFile`
    - resolved location
    - `ffmpeg` / `ffprobe` binary path
    - stderr
    - HTTP status
  - сравнить один и тот же track path на Intel между `/reveal`, `/stream`, `/waveform`, `/artwork`;
  - проверить path handling для:
    - пробелов
    - `+`
    - `%20`
    - unicode
    - апострофов
    - внешних дисков
    - `Downloads`
  - отдельно прогнать Intel smoke-test на:
    - AIFF
    - WAV
    - MP3
- Expected outcome:
  следующая итерация должна либо дать точную root cause, либо сузить её до одного слоя:
  - query parsing
  - file access / TCC
  - `ffmpeg` discovery
  - path normalization из Rekordbox
- Статус текущей итерации build 112:
  - по предоставленному логу `/waveform`, `/artwork`, `/api/data` и `/api/status` проходят через relay, но явного `/stream` в логе нет;
  - добавлена диагностика relay → local `/stream` → AIFF conversion, чтобы следующий лог показал, отсутствует ли сам запрос `/stream` или он падает на `Range`, path/TCC, `ffmpeg` либо размере relay-ответа;
  - обновлены query parsing tests: `%20` используется для пробелов, буквальный `+` в path сохраняется.
- Статус текущей итерации build 114:
  - повторный лог подтвердил: файлы доступны (`exists=true`, `readable=true`), `ffmpeg` найден, AIFF успешно конвертируется в WAV, но `/stream` всё ещё не приходит;
  - агент теперь отдаёт `tunnel_url`, `tunnel_active`, `cloudflared_found`, `stream_transport` в `/api/status`, `/api/account`, `/api/tunnel/status`;
  - relay логирует, рекламируется ли tunnel URL в cloud poll; отсутствие tunnel теперь явно помечается как возможная причина “waveform/artwork есть, audio source не создаётся”.
- Root cause установлен (build 115): анализ 13,600 строк лога с другой машины показал ноль упоминаний cloudflared — бинарник был устаревшей локальной сборкой без `autoStartIfAvailable()`. Cloudflare tunnel никогда не запускался, `app.py` возвращал 503 на любой `/stream`-запрос.
- Исправлено в build 115:
  - cloudflared бандлится внутрь .app (`Contents/MacOS/cloudflared`) — установка не нужна;
  - `findCloudflared()` ищет bundled-бинарник первым;
  - `TunnelManager.runTunnel()` обёрнут в retry loop — авто-рестарт через 5 сек после краша;
  - health check каждые 10 минут;
  - `CloudRelay.pushTunnelUpdate()` — немедленное уведомление облака при появлении tunnel URL (без ожидания следующего 25-секундного poll-цикла);
  - стартовый лог `cloudflared_found=true/false, path=...` в первых строках лога;
  - `POST /api/relay/result` timeout 10 → 30 сек;
  - `app.py` 503 с понятным hint-сообщением.

- Статус итерации build 115–116: тунель по-прежнему не работает.
  - Build 115: бандлинг cloudflared в build script использует silent skip — если GitHub API недоступен, скрипт продолжается без бинарника. Итог: `cloudflared_found=false` в логах на другой машине, тунель никогда не стартует.
  - Build 116: добавлена загрузка cloudflared at runtime (в `~/Library/Application Support/RimeoAgent/cloudflared`) если не найден в бандле. Это ненадёжное решение: требует интернета при первом запуске, задержка перед стартом тунеля, не работает "из коробки".
  - **Открытая проблема:** нет надёжного способа гарантировать наличие cloudflared в бандле без CI-уровня проверки артефакта. Нужно либо:
    - сделать шаг bundling в CI обязательным (exit 1 если не скачался), либо
    - перейти на альтернативу, не требующую внешнего бинарника (например, встроенный reverse proxy через rimeo.app relay для `/stream`).
  - **Архитектурная проблема:** relay не подходит для стриминга аудио — он рассчитан на маленькие JSON-ответы; большие бинарные данные через него не проходят. Cloudflare tunnel — единственный рабочий путь для `/stream` из другой сети.

#### Низкий приоритет / позже
- ✅ `UpdateChecker.swift` — заменить заглушечный GitHub repo (`your-org/rimeo`) на реальный release-источник
  Установлено: `ilokhrimenko-lab/rimeo-agent`, asset name — `RimeoAgent_mac.zip` (актуальное имя; **менять нельзя**, оно захардкожено в `UpdateChecker.swift`)
- 🔲 Проверить полное совпадение логов и UX cloud/tunnel сценариев с Python агентом
- ✅ UX-требование окна: нативное приложение должно открываться с комфортным стартовым размером и увеличенным minimum size; тот же подход обязателен для Windows-версии

---

## Windows — C# + WinUI 3

> Реализация создаётся с нуля. Ориентир — Python-код в корне RimeoAgent/ и Swift в macos_arm64/.

### Целевая структура проекта

```
windows_csharp/
├── RimeoAgent.sln
├── RimeoAgent/
│   ├── RimeoAgent.csproj     (WinUI 3, .NET 8, self-contained)
│   ├── App.xaml + App.xaml.cs
│   ├── MainWindow.xaml + .cs
│   ├── Config/
│   │   └── AppConfig.cs      — пути, agent_id, порт
│   ├── Models/
│   │   ├── TrackModel.cs
│   │   └── DataStore.cs      — rimo_data.json
│   ├── Services/
│   │   ├── RekordboxParser.cs
│   │   ├── AudioService.cs   — waveform (ffprobe), artwork
│   │   ├── AnalysisEngine.cs — аудио-фичи (NAudio + MathNet)
│   │   ├── SimilarityEngine.cs
│   │   ├── CloudRelay.cs     — long-poll
│   │   ├── TunnelManager.cs  — cloudflared subprocess
│   │   └── UpdateChecker.cs
│   ├── HttpServer/
│   │   ├── HttpServer.cs     — HttpListener или ASP.NET Core minimal API
│   │   └── ApiRouter.cs      — все 23 endpoint'а
│   └── Views/
│       ├── LibraryPage.xaml
│       ├── AnalysisPage.xaml
│       ├── PairingPage.xaml
│       ├── AccountPage.xaml
│       └── LogsPage.xaml
└── build/
    └── build_win.ps1
```

### Рекомендуемые NuGet-пакеты

| Пакет | Назначение |
|-------|-----------|
| `NAudio` | Аудио декодинг, waveform |
| `MathNet.Numerics` | FFT, MFCC расчёты |
| `System.Text.Json` | JSON (встроенный) |
| `Microsoft.WindowsAppSDK` | WinUI 3 |
| `H.NotifyIcon.WinUI` | System tray |

### Чек-лист Windows

#### Проект и инфраструктура
- 🔲 Создать `windows_csharp/RimeoAgent.sln` с WinUI 3 проектом (.NET 8)
- 🔲 Настроить `<SelfContained>true</SelfContained>` + `win-x64` в .csproj
- 🔲 Добавить NuGet: NAudio, MathNet.Numerics, H.NotifyIcon.WinUI
- 🔲 Настроить иконку приложения (rimeo.ico)
- 🔲 Добавить `.github/workflows/build.yml` job для Windows (dotnet publish)

#### HTTP сервер и API
- 🔲 `HttpServer.cs` — HttpListener на 127.0.0.1:8000
- 🔲 `ApiRouter.cs` — `/api/data`
- 🔲 `ApiRouter.cs` — `/stream` (Range requests, AIFF→WAV через ffmpeg)
- 🔲 `ApiRouter.cs` — `/waveform`
- 🔲 `ApiRouter.cs` — `/artwork`
- 🔲 `ApiRouter.cs` — `/reveal` (открыть файл в Explorer)
- 🔲 `ApiRouter.cs` — `/api/pairing_info`, `/api/check_pairing`
- 🔲 `ApiRouter.cs` — `/api/save_note`, `/api/save_exclusions`
- 🔲 `ApiRouter.cs` — `/api/analysis`, `/api/analysis/status`, `/api/analysis/start`, `/api/analysis/recheck`, `/api/analysis/track_list`
- 🔲 `ApiRouter.cs` — `/api/similar`
- 🔲 `ApiRouter.cs` — `/api/account`, `/api/status`, `/api/link_account`, `/api/unlink_account`
- 🔲 `ApiRouter.cs` — `/api/tunnel/status`, `/api/tunnel/start`, `/api/tunnel/stop`
- 🔲 `ApiRouter.cs` — `/api/report_bug`, `/api/send_tg`

#### Данные и парсинг
- 🔲 `DataStore.cs` — чтение/запись rimo_data.json (`%APPDATA%\RimeoAgent\`)
- 🔲 `AppConfig.cs` — пути, agent_id (генерация UUID при первом запуске), порт
- 🔲 `RekordboxParser.cs` — парсинг Rekordbox XML (XmlDocument/XDocument)

#### Аудио
- 🔲 `AudioService.cs` — waveform peaks через ffprobe (Process)
- 🔲 `AudioService.cs` — artwork extraction (NAudio / TagLib#)
- 🔲 `AudioService.cs` — AIFF→WAV конвертация для стриминга (ffmpeg Process)

#### Анализ треков
- 🔲 `AnalysisEngine.cs` — `FindAnalysisSegment()` (сегмент 35–65% с макс. energy)
- 🔲 `AnalysisEngine.cs` — Energy (RMS)
- 🔲 `AnalysisEngine.cs` — Brightness (spectral centroid)
- 🔲 `AnalysisEngine.cs` — ZCR (zero-crossing rate)
- 🔲 `AnalysisEngine.cs` — Timbre (13 MFCC коэффициентов, MathNet FFT)
- 🔲 `AnalysisEngine.cs` — Groove (beat interval regularity)
- 🔲 `AnalysisEngine.cs` — Happiness (chroma major/minor ratio)
- 🔲 `AnalysisEngine.cs` — фоновая очередь анализа + progress tracking

#### Similarity Engine
- 🔲 `SimilarityEngine.cs` — Vibe score (cosine similarity по фичам, 45%)
- 🔲 `SimilarityEngine.cs` — Key/Camelot score (25%)
- 🔲 `SimilarityEngine.cs` — Tempo score с hard-exclude >8 BPM (20%)
- 🔲 `SimilarityEngine.cs` — Metadata score (genre, label, artist, 10%)
- 🔲 `SimilarityEngine.cs` — итоговый `GetSimilarTracks(trackId, limit, useKey)`

#### Cloud и сеть
- 🔲 `CloudRelay.cs` — long-poll loop (HttpClient, GET /api/relay/poll, POST /api/relay/result)
- 🔲 `CloudRelay.cs` — обработка команд: forward → local → result
- 🔲 `TunnelManager.cs` — запуск `cloudflared.exe` как Process, парсинг stdout для URL
- 🔲 `UpdateChecker.cs` — проверка GitHub Releases, скачивание, запуск нового installer

#### UI (WinUI 3)
- 🔲 `MainWindow.xaml` — sidebar + NavigationView (5 вкладок)
- 🔲 `MainWindow.xaml` — задать комфортный стартовый размер окна и увеличенный minimum size (не открывать приложение слишком маленьким)
- 🔲 System tray иконка (H.NotifyIcon) + меню "Open / Quit"
- 🔲 Запуск при старте Windows (реестр / Task Scheduler) — опционально
- 🔲 `LibraryPage.xaml` — список треков, плейлисты
- 🔲 `AnalysisPage.xaml` — кнопка старта, progress bar, таблица результатов
- 🔲 `PairingPage.xaml` — код паринга, ввод кода
- 🔲 `AccountPage.xaml` — статус аккаунта, link/unlink
- 🔲 `LogsPage.xaml` — tail лог-файла

#### Сборка и дистрибуция
- 🔲 `build_win.ps1` — `dotnet publish -c Release -r win-x64 --self-contained`
- 🔲 Обновить `.github/workflows/build.yml` — Windows job
- 🔲 Zip артефакт → `RimeoAgent_win.zip` (стабильное имя для download URL)
- 🔲 Протестировать на чистом Windows (без .NET, без Python)

#### Финальное тестирование Windows
- 🔲 Иконка в system tray корректна
- 🔲 Закрытие окна → агент остаётся в tray
- 🔲 Cloud relay end-to-end (агент ← → rimeo.app)
- 🔲 Стриминг треков через UI
- 🔲 Анализ на реальной библиотеке Rekordbox
- 🔲 Авто-обновление

---

## Авто-обновление агента

### Как это работает

Агент проверяет обновления раз в 24 часа, используя **GitHub Releases** репозитория `ilokhrimenko-lab/rimeo-agent`.

### Схема релиза

```
GitHub Actions (build.yml)
  → триггер: git tag v1.0-buildNNN   (без тега workflow НЕ стартует: коммит + тег)
  → собирает .app / .exe
  → создаёт GitHub Release с тегом
  → прикладывает артефакты:
       RimeoAgent.dmg             (macOS — для людей: перетащить в Applications)
       RimeoAgent_mac.zip         (macOS — ТОЛЬКО автообновление)
       RimeoAgentSetup_win.exe    (Windows — NSIS, x64 + arm64)
       RimeoAgent_win.zip         (Windows — автообновление)
```

**🚨 mac-ассета два, оба обязательны.** `RimeoAgent_mac.zip` — канал автообновления, имя захардкожено в
`UpdateChecker.swift`; убрать его из релиза = тихо сломать апдейт у всех установленных агентов.
`RimeoAgent.dmg` — то, что скачивает человек; собирается `packaging/dmg/make_dmg.sh` (dmgbuild, headless,
без Finder/AppleScript) и нотаризуется отдельно от `.app`.

### Проверка обновлений

```
GET https://api.github.com/repos/ilokhrimenko-lab/rimeo-agent/releases/latest
→ { "tag_name": "v1.0-build109", "assets": [...] }
```

Агент сравнивает `tag_name` с текущей версией (`AppConfig.version`). Если версия новее — показывает диалог.

### UX-флоу (один клик, без браузера)

```
[Диалог] "Update Available: v1.0-build109"
         [Update & Restart]  [Later]
              ↓
         Скачивает RimeoAgent_mac.zip  (НЕ dmg — апдейтер работает только с zip)
              ↓
         Распаковывает во временную папку
              ↓
         Пробует заменить .app без прав
         → не получилось → системный диалог Touch ID / пароль
              ↓
         Запускает новую версию → выходит
```

### Периодичность

- Штамп последней проверки: `~/Library/Application Support/RimeoAgent/last_update_check` (macOS)
- Интервал: 24 часа

### Реализация

| Платформа | Файл | Статус |
|-----------|------|--------|
| macOS | `UpdateChecker.swift` | ✅ реализовано |
| Windows | `UpdateChecker.cs` | 🔲 предстоит |

**macOS:** при нехватке прав использует `osascript` с `administrator privileges` — стандартный диалог Touch ID / пароль macOS. Не требует внешних фреймворков.

**Windows (план):** скачать `.zip`, распаковать, запустить `installer.bat` с `runas` — аналогичный UAC-диалог.

---

## Общий прогресс

| Платформа | Код | Сборка | Тесты |
|-----------|-----|--------|-------|
| macOS (Swift) | ✅ feature-complete, запускался | ✅ .app/.zip собираются | 🔄 частично |
| Windows (C#) | 🔲 | 🔲 | 🔲 |

---

## Промпт для AI CLI

При открытии этого проекта в Claude Code / Codex / Gemini CLI используй этот промпт:

```
Ты работаешь над проектом RimeoAgent — нативным локальным агентом для DJ.
Прочитай файл: RimeoAgent/NATIVE_AGENT_PLAN.md

Он содержит:
- Полное описание архитектуры и HTTP API
- Чек-листы с текущим статусом (✅ / 🔄 / 🔲) для macOS и Windows
- Примеры данных (rimo_data.json, relay protocol, similarity weights)

Перед началом работы:
1. Открой NATIVE_AGENT_PLAN.md и найди незавершённые задачи (🔲) для нужной платформы
2. Для macOS смотри эталон: macos_arm64/Sources/RimeoAgentMac/
3. Для Windows смотри эталон: api_server.py, analyzer.py, similarity.py
4. После выполнения задачи обнови статус в NATIVE_AGENT_PLAN.md (🔲 → ✅)

Не запускай Python-код как часть нативного приложения.
Все фичи должны быть реализованы нативно на Swift (macOS) или C# (Windows).
```
