# Паритет агентов: macOS ↔ Windows

Один файл, чтобы разница между платформами не копилась молча. Она уже копилась: порядок
плейлистов (`Seq`), нормальные логи и запись в Rekordbox появились на macOS и не появились на
Windows — просто потому, что это негде было записать.

## Правило

**Фича, сделанная на одной платформе, обязана появиться строкой в этой таблице тем же коммитом.**
Не «потом заведу задачу» — строкой здесь. Задачу можно завести позже, а вот забывается всё сразу.

Статусы: ✅ есть · ❌ нет · ⚠️ есть, но иначе/частично

## Как это проверяется

Не «код написан», а измерено. В `docs/parity-harness.md` описан стенд, который компилирует
ЧИСТУЮ ЛОГИКУ Windows-агента под `net8.0` (без WinUI) и гоняет её на macOS против эталонного
движка macOS-агента — на одной и той же живой библиотеке (2197 треков, 667 плейлистов).

Замер на build 255:

| Что сверялось | Результат |
|---|---|
| Рекомендации: состав, порядок, все 7 полей `score` | 10 сценариев (пагинация, `limit`, `use_key`, плейлисты на 136/24/5 треков, одиночный сид) — **совпадение побайтовое**, Δ`total` = 0.000000 |
| Граф совместности: 9 метрик (сессии, пары, покрытие, холодные) | идентичны (6930 пар истории, 92327 пар плейлистов) |
| Парсер: 2197 треков × 13 полей | 0 расхождений |
| Парсер: 667 плейлистов × 9 полей + ПОРЯДОК | 0 расхождений |
| `KeyNormalizer` / `GenreCanon` / `TrackIdentity` / `TrackAvailability` | 8788 значений, 0 расхождений; 36 групп дублей совпадают один-в-один |
| HTTP-контракт (`/api/data`, рекомендации, CRUD, барьеры, авторизация) | прогнан через реальный сокет |
| **Sync: запись в Rekordbox** | прогнан **на копии живой `master.db`** настоящим `RekordboxWriter`: создание плейлиста (`seq=1`, USN сдвинулся, verify прошёл, оверлей → `synced`), идемпотентный повтор (`nothing:true`, база не тронута), **откат** после падения хелпера (база и манифест вернулись байт-в-байт, оверлей остался `pending`) |

⚠️ Дымовой тест на живой Windows с Rekordbox **всё равно нужен**: WinUI-слой
(`Views/*.xaml.cs`, трей, автозапуск), реестр, `signtool`, NSIS и **сам frozen-хелпер,
собранный PyInstaller'ом под Windows** (здесь он проверялся как питон-скрипт — логика
оркестратора та же, но упаковка PyInstaller'а проверяема только в CI).

## Обновление агента

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Самообновление: скачать релиз → проверить → заменить → перезапуститься | ✅ | ✅ | — |
| Detached-подпись архива (ECDSA-P256), fail-closed | ✅ | ✅ | — |
| Проверка подписи распакованного бинаря | ✅ `codesign --verify --deep --strict` + TeamID `MM3Q8TJL85` | ⚠️ `AuthenticodeGate` реализован, но **спит** | Windows-.exe в CI **не подписывается вообще** (в `build-windows` нет `signtool`). Гейт само-якорный: включается сам, когда установленный файл окажется подписан. Безусловный fail-closed сегодня убил бы автоапдейт у всех. Чтобы включить — добавить `signtool` в CI (и/или вписать DN в `AuthenticodeGate.ExpectedSubjectPin`) |
| `POST /api/agent/update` + `GET /api/agent/update/status` | ✅ | ✅ | — |
| Ручки закрыты авторизацией (control-protected) | ✅ | ✅ | — |
| Стадии обновления честные (downloading/verifying/installing/restarting) | ✅ | ✅ | — |
| `done` после перезапуска (расписка на диске) | ✅ `update_handoff.json` | ✅ `update_result.json` | — |
| Кнопка «Update» в UI идёт через тот же стейт стадий | ✅ (общий `applyZip`) | ✅ через `AgentUpdateService` | — |
| Ежечасная тихая подготовка обновления (staged) | ✅ | ✅ | — |
| Держать процесс, пока телефон не заберёт стадию `restarting` | ✅ `awaitRestartingDelivered` | ⚠️ нет (аудит 2026-09-03) | Windows сразу `Environment.Exit` после установки — телефон может пропустить стадию `restarting`. Плюс синтетический прогресс verifying=0.90/installing=0.95 (macOS — честный fraction) и TTL статуса 15 мин vs 10 мин |

## Запуск и фон

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Автозапуск при входе в систему | ✅ `SMAppService.agent` + LaunchAgent в бандле | ✅ Run-ключ реестра | — |
| Включается автоматически один раз (потом решает пользователь) | ✅ | ✅ | — |
| Тихий старт в фоне без окна | ✅ `RIMEO_BACKGROUND=1` → `.accessory` | ✅ `--background`, окно не активируется | Windows: **дымовой тест на живой машине** — окно не всплыло, трей есть, `/api/status` отвечает |
| Повторный клик по ярлыку показывает окно | ✅ | ✅ именованное событие `Local\RimeoAgent.Windows.ShowWindow` | — |
| Иконка в трее / menu bar | ✅ | ✅ | — |

## Rekordbox

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Чтение библиотеки (SQLCipher) | ✅ | ✅ | — |
| Порядок плейлистов как в Rekordbox (`Seq`) | ✅ | ✅ | — |
| Длительность трека (`djmdContent.Length`) | ✅ | ✅ | — |
| Обложка из БД (`ImagePath`, вне аудиофайла) | ✅ | ✅ | — |
| Узел для КАЖДОГО `djmdPlaylist` (папки, пустые, smart) | ✅ | ✅ | — |
| Smart-плейлисты: состав ВЫЧИСЛЯЕТСЯ из правил `SmartList` | ✅ | ✅ | — |
| Устойчивый разбор дат Rekordbox (`"… .123 +00:00"`) | ✅ | ✅ | — |
| Фолбэк master.db → XML при провале разбора БД | ✅ | ✅ | — |
| **Запись плейлистов в Rekordbox (Sync)** | ⚠️ только Apple Silicon | ✅ (x64; на ARM64 — только Win11) | Прогнано end-to-end на копии живой базы: создание, идемпотентный повтор, откат |
| Прогресс синка по стадиям (`checking → backup → writing → verifying`) | ✅ | ✅ | Стадии реальные, не таймер: счётчик треков приходит из stdout хелпера |
| Бэкап перед записью: `master.db` + `-wal` + `-shm` | ✅ | ✅ | Только `.db` при непустом `-wal` = неконсистентный снимок = битый откат |
| **Бэкап `masterPlaylists6.xml`** | ✅ **починено здесь** | ✅ | 🚨 Дыра была на ОБЕИХ платформах. `pyrekordbox.commit()` пишет этот манифест, а бэкапили только три файла базы — то есть откат возвращал базу, но **не манифест**, и XML оставался со ссылками на плейлисты, которых уже нет. Замерено: один `create_playlist` меняет XML с 47 837 до 47 946 байт |
| Барьер «Rekordbox закрыт» | ✅ `NSWorkspace` | ✅ `Process.GetProcessesByName`, **fail-closed** | ⚠️ Windows при сбое перечисления процессов раньше возвращал «не запущен» (fail-open). master.db в WAL-режиме, а там читатель НЕ держит write-lock → `BEGIN IMMEDIATE` хелпера возьмётся при ПРОСТАИВАЮЩЕМ Rekordbox. Значит «Rekordbox открыт и молчит» ловит ТОЛЬКО этот барьер, и fail-open дал бы запись под живым Rekordbox. Теперь при сбое перечисления → 409 |
| Разбор кода ошибки хелпера из stderr | ✅ **починено здесь** | ✅ | 🚨 macOS парсил stderr ЦЕЛИКОМ как JSON. `pyrekordbox` пишет туда WARNING (проверено: «No masterPlaylists6.xml found») → JSON не парсился → код оставался `write_failed`, а он НЕ в `preWriteErrorCodes` ⇒ `restore()` отрабатывал даже когда причиной был `rekordbox_running` — то есть **под живым Rekordbox**. Обе платформы теперь берут последнюю `{`-строку stderr |
| Верификация перечитыванием базы + проверка сдвига USN | ✅ | ✅ | USN не сдвинулся ⇒ Rekordbox правку отвергнет ⇒ для нас это провал, а не успех |
| `capabilities.playlist_sync` отражает РЕАЛЬНУЮ способность | ✅ Mach-O: есть ли слайс под текущую арку | ✅ PE: `IMAGE_FILE_HEADER.Machine` + сборка ОС | Хелпер собирается PyInstaller'ом только под x64. На **Win11 ARM64** он идёт под эмуляцией → `true`; на **Win10 ARM64** эмуляции x64 нет → честный `false`, кнопка не появляется |
| `RIMEO_SYNC_HELPER` — override пути к хелперу | ✅ | ✅ | Саппорт может подсунуть пересобранный хелпер одному пользователю, не выкатывая релиз. Проверка арки при этом НЕ пропускается |
| Оверлеи плейлистов (CRUD из iOS: create/add/remove/reorder/rename/delete) | ✅ | ✅ | — |
| `capabilities` в `/api/data` | ✅ | ✅ | — |
| `content_hash` плейлиста (SHA-256 по `track_ids`) | ✅ | ✅ | сверен с эталоном: совпадает, оверлей на iOS самоочистится |
| Похожие треки (`POST /api/similar`) | ✅ | ✅ тот же движок | Windows-движок на аудио-фичах (MFCC/clap) **выброшен целиком** |
| Рекомендации для плейлиста (`POST /api/playlist/recommendations`) | ✅ | ✅ | — |
| Нормализация тональности (Camelot ↔ классика) | ✅ `KeyNormalizer` | ✅ | на живой библиотеке 983 трека из 2197 (**45%**) хранят ключ классикой — без этого фильтр был выключен на них |
| Канонизация жанра (`Afro House` / `Afro-House` / `AfroHouse` / `Хаус`) | ✅ `GenreCanon` | ✅ | — |
| Граф совместности (история сетов + ручные плейлисты) | ✅ `CoPlayGraph` | ✅ | smart-плейлисты исключены: иначе **63% рёбер графа** пришли бы из правил (`KEY / 9A - 9B`, `HOUSE GENRE`) — модель училась бы на том фильтре, который заменяет |
| Ранжирование: BPM как гейт (±3 BPM, half/double), а не тай-брейк | ✅ | ✅ | на живой библиотеке **94% треков** в окне 118–130 BPM — сортировка по ΔBPM была чистым шумом |
| Пагинация рекомендаций (`offset` → Refresh даёт «ещё») | ✅ | ✅ | — |
| Квота на «открытия» (≥3 непроигранных в каждой десятке) | ✅ `interleaveCold` | ✅ | проверено: ровно 3/10 на каждой из 5 страниц |
| Дедуп по «артист + название» | ✅ `TrackIdentity` | ✅ | — |
| Не рекомендовать треки с недоступными файлами | ✅ `TrackAvailability` | ✅ | — |
| Конфиг из облака (`GET /api/similarity_config`, синк 600 с) | ✅ | ✅ | `similarity_config.json` теперь едет в Windows-сборку (добавлен в `.csproj`). ⚠️ `StartCloudSync()` был написан, но **никто его не звал** — мёртвый код, агент вечно сидел на встроенных дефолтах. Вызов добавлен в `App.xaml.cs` |

## Облако и локальная сеть

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| **LAN-PSK уезжает в облако при входе по email** (`/api/agents/link`, `/api/agent/login|signup`) | ✅ | ✅ | Windows не слал `lan_secret` **вообще**. Следствие: телефон никогда не получал ключ и стримил через Cloudflare, стоя в одной комнате с ПК (на маке замеряли: 98 мс / 37 МБ/с по локалке против 1–7 с через туннель) |
| **LAN-PSK уезжает в облако по heartbeat релея** (`?lan_secret=`) | ✅ | ✅ | Главный канал: **уже связанный агент повторно `/api/agent/login` не зовёт**, поэтому линковка секрет не донесёт |
| `build` + `caps` в heartbeat релея | ✅ | ✅ | — |
| Метка собственного релея (`X-Rimeo-Relay-Key`) | ✅ | ✅ | — |
| **mDNS/Bonjour-реклама `_rimeo._tcp`** (TXT `agent_id` + `v`) | ✅ `BonjourAdvertiser.swift`, старт в `AppDelegate.startServices()` | ❌ **нет вообще** (0 упоминаний mDNS/Bonjour/DNSSD в `windows_csharp/`) | Следствие: у Windows-сессий телефон не может найти агента по имени и живёт ИСКЛЮЧИТЕЛЬНО на подсказке `lan_ip`/`lan_port` из облака. Именно эта незадокументированная разница дала iOS-баг 2026-07-24: строгий матч по `agent_id` промахивался всегда, iOS падал в фолбэк «единственный найденный» и уводил стрим на ЧУЖОЙ мак (401). iOS-сторона починена (строгий матч + HTTP-проверка личности), но Windows по-прежнему не переживает смену адреса, пока облако не обновит `agent_url` |
| `GET /api/status` публичен и отдаёт `agent_id` | ✅ `SecurityGates.swift:77-80` | ✅ `SecurityGates.cs:71-79` | Контракт, на который опирается iOS-проверка личности агента перед переключением на LAN. **Не убирать из publicPaths и не переименовывать поле `agent_id`** — иначе у всех телефонов LAN тихо отвалится в облако |

⚠️ **Sync на Intel-маках недоступен.** Агент universal (`x86_64 arm64`), а `rbdb-sync-helper` —
PyInstaller-onefile, собирается на arm64-раннере и выходит **arm64-only**. На Intel он не запустится.
С build 254 агент это ЗНАЕТ: `bundledSyncHelperPath()` читает Mach-O заголовок и проверяет, есть ли
слайс под текущую архитектуру. На Intel capability `playlist_sync` = false → кнопка Sync в приложении
не появляется. До этого она светилась активной, а нажатие падало с «Bad CPU type in executable».
Чтобы синк заработал и на Intel, хелпер надо собирать вторым джобом на `macos-13` и склеивать `lipo`.

## UI и экраны

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| **Экран входа появляется реактивно при потере аккаунта** | ✅ `ContentView`: `if !appState.cloudLinked { LinkDeviceView() }` | ✅ (build 261) `MainWindow.OnCloudLinkChanged` | До 261 гейт на Windows показывался ТОЛЬКО при старте процесса: после Sign out (и после выселения облаком, `reason=evicted`) оболочка оставалась с карточкой «Not signed in», из которой некуда идти — залипшее состояние до перезапуска агента. Заодно ожил префилл email + «Your session ended…» в `LinkDevicePage` — раньше эта ветка была видна только после ручного рестарта |
| Кнопка «Sign in» на карточке «Not signed in» | ❌ (не нужна: экран входа подменяет весь UI) | ✅ страховка, зовёт `ReturnToLinkGate()` | — |
| Email аккаунта под «Signed in to Rimeo» | ✅ `appState.cloudEmail` (in-process) | ✅ (build 261) `AppState.CloudEmail` / `DataStore.CloudUserId` | Windows читал email через `GET /api/account` **без `lan_token`**, а поле `cloud_user_id` отдаётся только авторизованному вызывающему (фикс M1) — приходил `null`, и подпись всегда сваливалась на fallback `https://rimeo.app`. Тот же капкан ждёт любой другой UI-вызов к своему же API без токена |
| Иконка статуса аккаунта | ✅ SF Symbols | ✅ векторные пути (`UI.Icon`) | Были `FontIcon` с глифами Segoe MDL2, но обе строки глифов в исходнике оказались ПУСТЫМИ: иконка не рисовалась, а `Spacing` строки оставался — заголовок уезжал вправо относительно кнопки. Векторные пути не зависят от системного шрифта |
| **Кнопки не белеют под курсором** | ✅ (`.buttonStyle(.plain)`) | ✅ (build 261) `UI.PinStates` | Шаблон WinUI в PointerOver/Pressed подменяет фон `ContentPresenter` на системный почти-белый: у Primary белый текст оказывался на белом. Обход существовал ТОЧЕЧНО в `LinkDevicePage` — теперь он в фабриках `UI.cs`, то есть на всех экранах |
| **Акцент = `UI.Acc`, а не личный акцент Windows** | ✅ кастомные стили | ✅ (build 261) `Resources`-оверрайды | Тумблеры источников, чекбокс автозапуска, `ProgressRing`, выделенный пункт навигации красились личным акцентом пользователя (розовым/оранжевым). Переопределены на контролах (`ToggleSwitchFillOn*`, `CheckBoxCheckBackground*`, `NavigationViewItem*Selected`), а не в `App.xaml`: токены зависят от `UI.IsDark`, а тема переключается в рантайме. Добавлен недостающий токен `SwitchOff` |
| Поля ввода без системного хрома | ✅ | ✅ (build 261) `UI.StripFieldChrome` / `UI.StyleField` | Приём переехал из `LinkDevicePage` в `UI.cs`: поле баг-репорта и лимит кэша больше не моргают системным белым и не рисуют акцентное подчёркивание |
| «Глазок» пароля на экране входа | ✅ | ✅ (build 261) `PasswordRevealMode.Peek` | Было `Hidden` — при опечатке пользователь Windows видел только «Sign-in failed» |
| Состояние «обновление скачано, встанет при следующем запуске» | ✅ `.scheduled` (ручной выбор «On Next Launch») | ✅ (build 261) авто-стейджинг + строка статуса | Механика РАЗНАЯ: на Windows `CheckAndStageSilently` качает билд сам, раз в час, и ставит на следующем старте — кнопки «On Next Launch» там быть не может. UI теперь честно показывает `UpdateChecker.StagedVersion` вместо «Check for updates» |
| Ошибка чтения `master.db` видна в UI | ✅ `masterDBError` + карточка | ✅ (build 261) `RekordboxParser.MasterDbError` + карточка | Windows проглатывал исключение в лог, поэтому не мог отличить «база не читается» от «библиотека пустая» и на любой ноль писал «could not be read». Теперь три исхода, как на macOS |
| Реакция drop-зоны на перетаскивание | ✅ фон/рамка → акцент | ✅ (build 261) | `OnDragOver` только разрешал операцию: файл висел над окном без единого визуального отклика |
| **«Open audio file…» / выбор Rekordbox XML открывает диалог** | ✅ `NSOpenPanel` | ✅ (build 266) `Win32FileDialog` (comdlg32 `GetOpenFileNameW`) | WinRT `FileOpenPicker.PickSingleFileAsync()` в unpackaged+self-contained WinUI 3 на Win11 26xxx кидал `COMException 0x80004005`: кнопка «срабатывала», окно выбора не появлялось — «нет реакции» (подтверждено логом агента `nikolasleeman`, build 265, 2026-09-04). Затрагивало и Check spek, и пикер XML в Library. Нативный shell-диалог не трогает WinRT-брокер → работает на всех сборках Windows |
| Перетаскивание файла в Check spek реально принимается | ✅ `.onDrop([.fileURL])` | ✅ (build 266) хэндлеры на ScrollViewer + Page, try/catch + deferral | Раньше `AllowDrop`/хэндлеры висели только на «голой» `Page` (весь `Content` — `ScrollViewer`) → окно не регистрировалось как OLE-drop-target, drop не давал реакции. Теперь `AllowDrop` и на корневом `ScrollViewer` (hit-testable, `Background=Bg`); при провале `GetStorageItemsAsync` — `ShowFailed`, а не тишина |
| Регистр подписей кнопок | Title Case (HIG) | sentence case (Fluent) | **Осознанное расхождение.** Внутри Windows-UI разнобой убран («Clear cache», «Send report», «Check for updates»), но платформенные нормы разные — не выравнивать «под macOS» |
| **Open with → Rimeo Agent** (файловая ассоциация + отдельное окно «Check quality») | ✅ `AppDelegate.application(_:open:)` → `QualityWindowManager` → окно `CheckQualityRootView` (auth-гейт) + `CFBundleDocumentTypes` в `Info.plist` | ❌ **нет вообще** (аудит 2026-09-03) | Три причины, каждой хватает: приложение unpackaged (`WindowsPackageType=None` → нет MSIX `<uap:FileTypeAssociation>`); в реестр ProgId/OpenWith не пишется (есть только автозапуск+тема); `OnLaunched` (`App.xaml.cs:56`) читает из командной строки ТОЛЬКО `--background`, путь к файлу игнорит, а второй инстанс (`SignalRunningInstance`) путь не пробрасывает. «Check spek» на Windows есть, но только как вкладка — отдельного окна и точек входа (Finder Open-With / drag-on-icon / меню File) нет. Реализация: регистрация ProgId в реестре при старте + приём пути в `OnLaunched`/проброс в живой инстанс → навигация в Check spek |
| **Онбординг-экран + выбор master.db** | ✅ `OnboardingView` (welcome / retry-autodetect / пикер master.db ИЛИ xml) | ⚠️ частично (аудит 2026-09-03) | `IsOnboarding` (`AppState.cs:35`) задаётся, но НИ ОДНИМ view не читается — отдельного экрана нет. Частично свёрнуто в `LibraryPage.xaml.cs` (карточка «master.db could not be read» + пикер), но `FinishOnboarding` (`AppState.cs:90`) принимает ТОЛЬКО XML: на Windows нельзя указать сам master.db, нет welcome и retry-auto-detect |
| **Экран-гейт скачивания компонентов (~62 МБ)** | ✅ `ComponentGateView` (Install / прогресс / Restart) | ⚠️ логика без UI (аудит 2026-09-03) | Логика есть (`ComponentManager.cs`), но на Windows компоненты качаются МОЛЧА в фоне с ретраями (`App.xaml.cs:224-245`) — без блокирующего экрана, кнопки Install, прогресса и Restart. UX-разница: маковый юзер видит гейт, Windows — нет |
| **Форс английской раскладки на фокусе поля пароля** | ✅ `KeyboardInputSource` | ❌ нет (аудит 2026-09-03) | На Windows нет `ActivateKeyboardLayout`/`LoadKeyboardLayout` при фокусе пароля. Кейс «ввёл пароль в русской раскладке → Sign-in failed» так же применим, но не закрыт |

## Диагностика

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Логи с ротацией (append, 5 МБ × 3 поколения) | ✅ | ✅ | — |
| Access-log HTTP (`[REQ]`, peer IP, транспорт) | ✅ | ✅ | имена корзин общие: `LAN` / `TUNNEL` / `RELAY` / `LOCAL` / `EXTERNAL` / `UI` — `grep transport=TUNNEL` работает по бандлам обеих платформ |
| Метка собственного релея (`X-Rimeo-Relay-Key`) | ✅ | ✅ | без неё облачный путь в логе неотличим от локального браузера |
| Строка `[BOOT]` о ПРЕДЫДУЩЕМ запуске (`exit=clean\|unclean`, uptime) | ✅ UserDefaults | ✅ `run_state.json` | — |
| Логи агента уезжают в диагностический бандл iOS (хвост ФАЙЛА, не памяти) | ✅ | ✅ | — |
| Набор полей строки `[REQ]` | ✅ + `ttfb_ms`, `bytes=sent/declared`, `abort=client` | ⚠️ есть `bytes=`/`abort=client` (`HttpServer.cs:367,404`), нет `ttfb_ms` | Обновлено 2026-09-03: `bytes`/`abort` уже портированы, разрыв сузился до одного поля `ttfb_ms` |
| `GET /api/admin/diag` | ✅ | ❌ роута нет | Низкий приоритет: дублирует `/api/status` + `/api/logs` |
| **`HEAD *` → 200** (пробы cloudflared/relay) | ❌ HEAD не обрабатывается → 404 (`APIRouter.swift:145`) | ✅ короткое замыкание HEAD → headers-only 200 (`ApiRouter.cs:103-110`) | **Обратный разрыв** (аудит 2026-09-03): здесь впереди Windows. macOS отвечает на HEAD-пробы 404 |
| `OPTIONS *` preflight | ⚠️ 200 empty (`HTTPServer.swift:170`) | ⚠️ 204 empty (`HttpServer.cs:111`) | Косметика: разный статус CORS-preflight |

## Безопасность

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Контейнмент `?path=` (6002): корень тома не становится allow-root | ✅ (`dir != "/"`) | ✅ (корень СИСТЕМНОГО диска) | Корни прочих томов (`D:\`, UNC) разрешены осознанно — аналог `/Volumes/X` на маке |
| Контейнмент: symlink/junction резолвится во ВСЕХ компонентах пути | ✅ `realpath()` | ✅ | Резолв только листа позволял сбежать junction'ом в СЕРЕДИНЕ пути |
| Мутации плейлистов закрыты авторизацией | ✅ | ✅ | `/api/playlist/recommendations` — публичный (как `/api/similar`) |

## Детерминизм выдачи

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Порядок сессий истории стабилен между запусками | ✅ **починено здесь** | ✅ | Swift рандомизирует обход `Dictionary` по процессу: два прогона одного хелпера на одной базе давали РАЗНЫЙ `playlists[]`. Отсортировали по id |
| Тайбрейк порядка плейлистов не зависит от юникода | ✅ **починено здесь** | ✅ | Тайбрейк был по `path`: Swift сравнивает строки канонически, C# — ординально по UTF-16, и на плейлисте с эмодзи (суррогатная пара) или диакритикой в NFD платформы разошлись бы. Тайбрейк переведён на `rekordbox_id` (ASCII) |
| Юникод: NFC-нормализация ключей сравнения | ✅ (канонически by design) | ✅ `TextNorm.Nfc` | В живых тегах одно имя лежит в РАЗНЫХ формах (трек 62017310: `artist` в NFD, `title` в NFC) |
| Юникод: `U+200B` (ZWSP) считается пробелом | ✅ (Foundation) | ✅ `TextNorm.Trim/IsWhitespace` | Исчерпывающий перебор BMP дал **ровно одно** расхождение множеств пробелов: `char.IsWhiteSpace` не считает ZWSP пробелом, а Foundation считает. Тег `"9A<ZWSP>"` давал `9A` на маке и `null` на Windows. ZWSP приезжает копипастом с Beatport/Bandcamp |

🚨 **Не включай `<InvariantGlobalization>true</InvariantGlobalization>` в `RimeoAgent.csproj`.**
В invariant-режиме .NET выкидывает ICU, и `String.Normalize()` становится **тихим no-op** — не
бросает, а возвращает строку как есть. Дедуп треков сломается молча, без единой ошибки в логе.
Подробности — в `Services/TextNorm.cs`.

## Отдача аудио (`/stream`)

| Возможность | macOS | Windows | Что делать |
|---|---|---|---|
| Hi-res (bitrate > 2000) → 16-бит WAV для всех клиентов | ✅ | ✅ | — |
| AIFF → WAV для веб-плеера (wavesurfer не декодирует AIFF) | ✅ | ✅ | — |
| AIFF отдаётся **как есть** клиенту `src=ios` | ✅ (с build 168, экономит 1–3 c на старте) | ❌ конвертирует всем | Выровнять **после** того, как разъедется iOS-билд с валидацией prefix-кеша: смена представления меняет байты под кешами уже выпущенных билдов |
| `raw=1` → байт-в-байт оригинал (скачивание/офлайн) | ✅ | ✅ | — |
| `fmt=original` / `fmt=wav` — явный запрос представления, приоритетнее эвристики по `src` | ✅ **добавлено здесь** | ✅ **добавлено здесь** | `fmt` влияет только на AIFF (на остальных форматах — no-op на обеих платформах) |
| Заголовок ответа `X-Rimeo-Variant: original\|wav\|wav16` | ✅ **добавлено здесь** | ✅ **добавлено здесь** | Клиентский байтовый кеш сверяет представление и выбрасывает запись при смене, вместо склейки чужих байт |
| Папка `cache/` пересоздаётся ПЕРЕД каждой записью (конверсия/waveform/artwork), не только на старте | ✅ **добавлено здесь** | ✅ **добавлено здесь** | bug_reports #89: `cache/` снесли в рантайме → ffmpeg-вывод `No such file or directory` → `/stream` 503 на всех треках с конверсией (AIFF, hi-res), а 16-бит WAV играл. `AppConfig.ensureCacheDir()` / `EnsureCacheDir()` идемпотентен |

🚨 **Один и тот же URL обязан отдавать одни и те же байты на всех маршрутах (LAN и туннель).**
Так и утёк баг-репорт #83: iOS по LAN не слал `src`, агент считал его веб-плеером и отдавал
AIFF, сконвертированный в WAV, а через туннель (прокси дописывает `src=ios`) — сырой AIFF.
Prefix-кеш iOS склеил WAV-голову с AIFF-хвостом, и это игралось как громкий белый шум.

## Дистрибутив

| | macOS | Windows |
|---|---|---|
| Для людей | `RimeoAgent.dmg` (перетащить в Applications) | `RimeoAgentSetup_win.exe` (NSIS) |
| Для автообновления | `RimeoAgent_mac.zip` + `.sig` | `RimeoAgent_win.zip` + `.sig` |

⚠️ Имя `RimeoAgent_mac.zip` захардкожено в `UpdateChecker`. Переименуешь — автообновление
у всех установленных агентов умрёт **молча**. Подробности: `memory/infrastructure.md`.

## Безопасность (аудит build 259, фиксы 2026-07-22)

Полная верификация находок → `memory/tasks/backlog.md` (секция «🔐 Аудит безопасности»).
Статус фиксов: macOS верифицирован `swift build` + 32 теста; Windows — зеркало, C#-паттерны
прогнаны в scratch-net8.0, полная сборка требует Windows/csfull-стенда.

| Фикс | macOS | Windows | Замечание |
|---|---|---|---|
| **C1** pairing_info не отдаёт LAN PSK по сети | ✅ гейт `req.trusted` (только in-process UI) | ✅ гейт `PeerIsLoopback` (только 127.0.0.1) | Разный механизм: macOS UI зовёт роутер in-process (trusted), WinUI ходит по loopback+PSK. macOS строже (loopback-браузер тоже режется); на Windows остаётся DNS-rebind-остаток → L8/Host-header |
| **Default-deny роутер** (`requiresAuth = !publicPaths`) | ✅ + 4 regression-теста | ✅ `PublicPaths` | Новый роут теперь protected по умолчанию (закрыл корень C1/M1/M4/M11 + NEW-diag) |
| **M4** analysis start/stop/recheck за auth | ✅ | ✅ | убраны из publicPaths (обе) |
| **M1** email/абс.пути только авторизованным | ✅ field-strip (status/account) | ✅ field-strip | `/api/admin/diag` теперь protected — но роут есть ТОЛЬКО на macOS |
| **M11** `location` вырезан для неавториз. (similar/recs) | ✅ | ✅ | метадата остаётся, абс.путь — нет |
| **M5** allow-list `cloud_url` (не слать PSK на чужой хост) | ✅ `CloudURLPolicy` | ✅ `CloudUrlPolicy` | аудит указал только Win — фикс на ОБЕИХ |
| **M10** artwork fallback через path-guard | ✅ обе ветки (abs + `..`) | — (нет fallback на Win) | |
| **NEW-3** валидация tunnel_id/hostname (YAML/traversal) | ✅ | ✅ | |
| **NEW-4** не эхоить `cloud_token` в ответе link/login | ✅ | ✅ (link + login) | |
| **L6** constant-time pairing-compare | ✅ | ✅ | |
| **L6** CSPRNG для pairing-кода | ✅ (уже `SystemRandomNumberGenerator`) | ✅ был `new Random()` → `RandomNumberGenerator` | реальный фикс — только Windows |
| **H2** rimo_data.json не world-readable | ✅ `chmod 0600` | ⏳ ACL/DPAPI — отложено | Слепая правка ACL рискует сломать чтение логина (=unpair всех). Нужен Windows-тест |
| **L7** `${{ github.ref_name }}` не в run-шелл | ✅ build.yml (общий CI) | ✅ | через `$TAG_NAME` |
| **H1** QR-секрет не уходит в api.qrserver.com | ✅ нейтрализован C1 (UI генерит QR локально) | ⏳ нужен локальный QR-энкодер | Windows-UI qrserver'ом рендерит pairing-QR; но pairing_info теперь loopback-only |
| **H3/H4/H5/M6/M7/M9** CI/installer/подпись | ⏳ | ⏳ | требуют build-машины / signtool / SHA-lookup / Windows-теста инсталлятора — не правил вслепую |
