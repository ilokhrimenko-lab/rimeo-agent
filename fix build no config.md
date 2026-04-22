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
