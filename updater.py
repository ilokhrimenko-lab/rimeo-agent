"""
Auto-update module for RimeoAgent.

Flow:
  1. check_update_async(callback) — background thread, non-blocking
  2. callback receives UpdateInfo(version, download_url, notes) or None
  3. download_and_apply(info, progress_cb) — downloads zip, replaces app, relaunches

Checks once per 24 h (timestamp in ~/.rimeo/last_update_check).
Skipped entirely when not frozen (dev mode).
"""
import sys
import json
import shutil
import tempfile
import threading
import zipfile
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable, Optional

from .config import settings, logger

# ── Change this before first release ─────────────────────────────────────────
GITHUB_REPO = "ilokhrimenko-lab/rimeo-agent"
# ─────────────────────────────────────────────────────────────────────────────

_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
_CHECK_EVERY_HOURS = 24
_STAMP_FILE = Path.home() / ".rimeo" / "last_update_check"


@dataclass
class UpdateInfo:
    version: str
    download_url: str
    notes: str


# ── Helpers ───────────────────────────────────────────────────────────────────

def _asset_name() -> str:
    if sys.platform == "darwin":
        return "RimeoAgent_mac.zip"
    if sys.platform == "win32":
        return "RimeoAgent_win.zip"
    return ""


def _due_for_check() -> bool:
    if not _STAMP_FILE.exists():
        return True
    try:
        last = datetime.fromisoformat(_STAMP_FILE.read_text().strip())
        return datetime.now() - last > timedelta(hours=_CHECK_EVERY_HOURS)
    except Exception:
        return True


def _stamp():
    try:
        _STAMP_FILE.parent.mkdir(parents=True, exist_ok=True)
        _STAMP_FILE.write_text(datetime.now().isoformat())
    except Exception:
        pass


# ── Public API ────────────────────────────────────────────────────────────────

def check_update() -> Optional[UpdateInfo]:
    """
    Synchronous update check.
    Returns UpdateInfo when a new version is available, None otherwise.
    Always returns None in dev mode (not frozen by PyInstaller).
    """
    if not getattr(sys, "frozen", False):
        return None
    if not _due_for_check():
        return None

    asset = _asset_name()
    if not asset:
        logger.debug("Auto-update: unsupported platform")
        return None

    try:
        req = urllib.request.Request(
            _API_URL,
            headers={"User-Agent": f"RimeoAgent/{settings.VERSION}"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
    except Exception as e:
        logger.warning("Update check failed: %s", e)
        _stamp()
        return None

    _stamp()
    tag = data.get("tag_name", "")
    if not tag or tag == settings.VERSION:
        logger.info("Up to date (%s)", settings.VERSION)
        return None

    for a in data.get("assets", []):
        if a.get("name") == asset:
            logger.info("Update available: %s → %s", settings.VERSION, tag)
            return UpdateInfo(
                version=tag,
                download_url=a["browser_download_url"],
                notes=(data.get("body") or "")[:400],
            )

    logger.warning("Release %s has no asset '%s'", tag, asset)
    return None


def check_update_async(callback: Callable[[Optional[UpdateInfo]], None]):
    """Run check_update() in a daemon thread, call callback(result) when done."""
    def _run():
        try:
            callback(check_update())
        except Exception as e:
            logger.warning("Async update error: %s", e)
            callback(None)
    threading.Thread(target=_run, daemon=True, name="update-check").start()


def download_and_apply(
    info: UpdateInfo,
    progress_cb: Optional[Callable[[float], None]] = None,
):
    """
    Download the update zip, extract it, replace the running app, relaunch.
    Calls progress_cb(0.0–1.0) during download.
    Exits the current process to apply the update.
    Raises RuntimeError on failure (caller must handle).
    """
    logger.info("Downloading update %s from %s", info.version, info.download_url)
    tmp = Path(tempfile.mkdtemp(prefix="rimeo_upd_"))

    zip_path = tmp / "update.zip"
    try:
        req = urllib.request.Request(
            info.download_url,
            headers={"User-Agent": f"RimeoAgent/{settings.VERSION}"},
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            with open(zip_path, "wb") as f:
                while chunk := resp.read(65536):
                    f.write(chunk)
                    done += len(chunk)
                    if progress_cb and total:
                        progress_cb(done / total)
    except Exception as e:
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError(f"Download failed: {e}") from e

    logger.info("Download complete, applying update…")

    if sys.platform == "darwin":
        _apply_mac(zip_path, tmp)
    elif sys.platform == "win32":
        _apply_win(zip_path, tmp)
    else:
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError("Auto-update not supported on this platform")


# ── Platform-specific apply ───────────────────────────────────────────────────

def _app_bundle() -> Path:
    """macOS: .app bundle path = sys.executable/../../../"""
    return Path(sys.executable).resolve().parent.parent.parent


def _apply_mac(zip_path: Path, tmp: Path):
    ext = tmp / "ext"
    ext.mkdir()
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(ext)

    new_app = next((p for p in ext.iterdir() if p.suffix == ".app"), None)
    if not new_app:
        raise RuntimeError("No .app found in update archive")

    current_app = _app_bundle()
    script = tmp / "update.sh"
    script.write_text(
        "#!/bin/bash\n"
        "sleep 2\n"
        f'rm -rf "{current_app}"\n'
        f'cp -R "{new_app}" "{current_app}"\n'
        f'open "{current_app}"\n'
        f'rm -rf "{tmp}"\n',
        encoding="utf-8",
    )
    script.chmod(0o755)

    import subprocess
    subprocess.Popen(["bash", str(script)], close_fds=True)
    logger.info("macOS update script launched — exiting")
    sys.exit(0)


def _apply_win(zip_path: Path, tmp: Path):
    ext = tmp / "ext"
    ext.mkdir()
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(ext)

    new_exe = next(ext.rglob("*.exe"), None)
    if not new_exe:
        raise RuntimeError("No .exe found in update archive")

    current_exe = Path(sys.executable).resolve()
    bat = tmp / "update.bat"
    bat.write_text(
        "@echo off\r\n"
        "timeout /t 2 /nobreak >nul\r\n"
        f'copy /y "{new_exe}" "{current_exe}"\r\n'
        f'start "" "{current_exe}"\r\n'
        f'rmdir /s /q "{tmp}"\r\n',
        encoding="utf-8",
    )

    import subprocess
    subprocess.Popen(["cmd", "/c", str(bat)], creationflags=0x00000010, close_fds=True)
    logger.info("Windows update script launched — exiting")
    sys.exit(0)
