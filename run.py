import sys
import os
import threading
import time
import types

PACKAGE_NAME = "RimeoAgent"
PACKAGE_DIR = os.path.abspath(os.path.dirname(__file__))
PARENT_DIR = os.path.dirname(PACKAGE_DIR)

# In development this repo is imported as the RimeoAgent package from its parent
# directory. Inside the frozen bundle, files are flattened into one directory, so
# we synthesize the package namespace before importing package modules.
if PARENT_DIR not in sys.path:
    sys.path.append(PARENT_DIR)

if PACKAGE_NAME not in sys.modules:
    pkg = types.ModuleType(PACKAGE_NAME)
    pkg.__path__ = [PACKAGE_DIR]
    pkg.__file__ = os.path.join(PACKAGE_DIR, "__init__.py")
    sys.modules[PACKAGE_NAME] = pkg

from RimeoAgent.config import settings, logger


def _run_api():
    import uvicorn
    from RimeoAgent.api_server import app
    logger.info("Starting FastAPI backend on port %d...", settings.PORT)
    uvicorn.run(app, host=settings.HOST, port=settings.PORT, log_level="error")


if __name__ == "__main__":
    # API in background thread
    api_thread = threading.Thread(target=_run_api, daemon=True)
    api_thread.start()

    # Flet MUST run on main thread (signal.signal constraint)
    # macOS status bar icon is created from inside Flet via NSStatusBar (pyobjc)
    # Windows tray icon is created from inside Flet via pystray background thread
    from RimeoAgent.ui_app import start_gui
    logger.info("Starting Flet UI on main thread...")
    start_gui()
