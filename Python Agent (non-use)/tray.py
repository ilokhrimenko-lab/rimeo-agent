import sys
import pystray
from PIL import Image
from pathlib import Path
from typing import Callable


def _icon_path() -> Path:
    """Return path to rimeo1024.png — works in dev and PyInstaller bundles."""
    import sys as _sys
    # PyInstaller extracts data files to sys._MEIPASS
    if getattr(_sys, "frozen", False) and hasattr(_sys, "_MEIPASS"):
        return Path(_sys._MEIPASS) / "rimeo1024.png"
    return Path(__file__).parent / "rimeo1024.png"


def _make_icon(size: int = 64) -> Image.Image:
    """Load Rimeo icon from PNG and resize to tray dimensions."""
    try:
        img = Image.open(_icon_path()).convert("RGBA")
        img = img.resize((size, size), Image.LANCZOS)
        return img
    except Exception:
        # Fallback: plain blue square
        img = Image.new("RGBA", (size, size), (59, 130, 246, 255))
        return img


def create_tray(on_open: Callable, on_quit: Callable) -> pystray.Icon:
    menu = pystray.Menu(
        pystray.MenuItem("Open Rimeo Agent", on_open, default=True),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", on_quit),
    )
    return pystray.Icon("Rimeo", _make_icon(), "Rimeo Agent", menu)
