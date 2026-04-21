import os
import sys
import uuid
import socket
import logging
import warnings
warnings.filterwarnings("ignore", category=Warning, module="urllib3")
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field
from .build_info import VERSION as BUILD_VERSION, BUILD_NUMBER, RELEASE_TAG


def _display_version(version: str, build_number: str) -> str:
    build_number = (build_number or "").strip()
    if not build_number or build_number.lower() == "dev":
        return version
    return f"{version} (build {build_number})"


def _get_app_data_dir() -> Path:
    """Return the platform-appropriate user data directory."""
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "RimeoAgent"
    elif sys.platform == "win32":
        appdata = os.environ.get("APPDATA") or str(Path.home())
        return Path(appdata) / "RimeoAgent"
    else:
        return Path.home() / ".rimeo_agent"


_APP_DATA_DIR = _get_app_data_dir()
_APP_DATA_DIR.mkdir(parents=True, exist_ok=True)


def _detect_db_path() -> str:
    if sys.platform == "darwin":
        return str(Path.home() / "Library" / "Pioneer" / "rekordbox" / "master.db")
    elif sys.platform == "win32":
        appdata = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        # Rekordbox 7 stores data under "rekordbox", RB6 under "rekordbox6"
        for folder in ("rekordbox", "rekordbox6"):
            candidate = Path(appdata) / "Pioneer" / folder / "master.db"
            if candidate.exists():
                return str(candidate)
        return str(Path(appdata) / "Pioneer" / "rekordbox6" / "master.db")
    else:
        return str(Path.home() / ".local" / "share" / "Pioneer" / "rekordbox" / "master.db")


def _load_persistent_agent_id() -> str:
    """Read AGENT_ID from app data dir — create once if missing."""
    id_file = _APP_DATA_DIR / "agent_id"
    if id_file.exists():
        stored = id_file.read_text(encoding="utf-8").strip()
        if stored:
            return stored
    new_id = str(uuid.uuid4())
    id_file.write_text(new_id, encoding="utf-8")
    return new_id


class RimeoSettings(BaseSettings):
    # --- Project Info ---
    VERSION: str = BUILD_VERSION
    BUILD_NUMBER: str = BUILD_NUMBER
    RELEASE_TAG: str = RELEASE_TAG
    DISPLAY_VERSION: str = _display_version(BUILD_VERSION, BUILD_NUMBER)
    APP_NAME: str = "Rimeo Desktop Agent"

    # --- Server Config ---
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    # --- Paths ---
    # XML_PATH is empty by default — user sets it on first run via onboarding
    XML_PATH: str = ""
    # DB_PATH: auto-detected from default Pioneer location; can be overridden
    DB_PATH: str = Field(default_factory=_detect_db_path)

    # All user data lives in Application Support / AppData
    BASE_DIR:  Path = _APP_DATA_DIR
    CACHE_DIR: Path = _APP_DATA_DIR / "cache"
    DATA_FILE: Path = _APP_DATA_DIR / "rimo_data.json"
    LOG_FILE:  Path = _APP_DATA_DIR / "agent.log"

    # --- Security ---
    AGENT_ID:   str = Field(default_factory=_load_persistent_agent_id)
    MASTER_KEY: str = Field(default_factory=lambda: uuid.uuid4().hex)

    # --- Integrations ---
    TG_TOKEN:   str = ""
    TG_CHAT_ID: str = ""

    # --- Domain Mapping ---
    RIMEO_APP_URL: str = "https://rimeo.app"

    model_config = SettingsConfigDict(
        env_prefix="RIMEO_",
        env_file=str(_APP_DATA_DIR / ".env"),
    )


# Global Settings Instance
settings = RimeoSettings()

# Ensure directories exist
settings.CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Logging Setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(settings.LOG_FILE, encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("RimeoAgent")


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"
