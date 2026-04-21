import threading
from config import settings, logger


def _run_api():
    import uvicorn
    from api_server import app
    logger.info("Starting FastAPI backend on port %d...", settings.PORT)
    uvicorn.run(app, host=settings.HOST, port=settings.PORT, log_level="error")


if __name__ == "__main__":
    # API in background thread
    api_thread = threading.Thread(target=_run_api, daemon=True)
    api_thread.start()

    # Flet MUST run on main thread (signal.signal constraint)
    # macOS status bar icon is created from inside Flet via NSStatusBar (pyobjc)
    # Windows tray icon is created from inside Flet via pystray background thread
    from ui_app import start_gui
    logger.info("Starting Flet UI on main thread...")
    start_gui()
