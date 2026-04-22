# Fix: No module named 'config' — Build 105+

## Проблема

При запуске `/Applications/RimeoAgent.app/Contents/MacOS/RimeoAgent` вылетала ошибка:

```
ModuleNotFoundError: No module named 'config'
[PYI-...:ERROR] Failed to execute script 'run' due to unhandled exception: No module named 'config'
```

## Причина

`flet pack` запускает PyInstaller **из другой рабочей директории** (внутреннего temp-каталога), поэтому:

- `--paths=.` указывал на temp-каталог flet, а не на проект → `config.py` не находился при анализе
- `--hidden-import "config"` без найденного исходника работает как no-op (PyInstaller предупреждает но не включает модуль)
- `--additional-hooks-dir=build/hooks` указывал на каталог без хуков (только `.DS_Store`)

В `run.py` при `__package__` == `''` (falsy, что всегда так в frozen bundle) код идёт по ветке:
```python
from config import settings, logger  # config не найден в sys.path frozen bundle
```

## История попыток

### Build 105 — НЕ ПОМОГЛО

Файл: `.github/workflows/build.yml`

Добавлено для macOS и Windows:
- **`--paths=.`** в `--pyinstaller-build-args` — не помогло т.к. `.` — это temp-каталог flet, не проект
- **`--additional-hooks-dir=build/hooks`** — каталог пустой (хуки удалены)
- **`--hidden-import`** для всех локальных модулей — правильно, но без валидного `--paths` не работало

Коммит: `011a9ba` — "Fix missing local module imports in frozen bundle"

### Build 106 — текущая попытка

**Причина почему Build 105 не помог**: shell раскрывает `$(pwd)` ДО запуска flet pack. Значит `$(pwd)` = реальная директория проекта. Но `--paths=.` не раскрывается shell'ом — PyInstaller видит буквальную точку относительно своего CWD (temp-каталог flet).

**Что изменено**:
- macOS: `--pyinstaller-build-args="--paths=."` → `--pyinstaller-build-args="--paths=$(pwd)"`
- Windows: `--pyinstaller-build-args="--paths=."` → `"--pyinstaller-build-args=--paths=$($PWD.Path)"`
- Убран `--additional-hooks-dir=build/hooks` (каталог хуков пустой)

Файл: `.github/workflows/build.yml`

## Если build 106 тоже не поможет

Следующие варианты:
1. Отказаться от `flet pack`, использовать прямой `pyinstaller` с `.spec`-файлом (полный контроль над `pathex`)
2. Добавить в `run.py` явную манипуляцию `sys.path` перед импортами (`sys.path.insert(0, sys._MEIPASS)`)
3. Использовать `--collect-all config` вместо `--hidden-import config`
