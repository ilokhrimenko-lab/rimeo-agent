import asyncio
import os
import json
import re
import shutil
import socket
import subprocess
import threading
import urllib.request
import urllib.error
import urllib.parse as _uparse
import base64 as _b64
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, HTTPException, Response, BackgroundTasks
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

_CLOUD_HEADERS = {
    "Content-Type": "application/json",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Accept": "application/json",
}

from .config import settings, logger
from .parser import parse_library

app = FastAPI(title=settings.APP_NAME, version=settings.VERSION)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def _auto_start_tunnel():
    """Auto-start Cloudflare tunnel on agent startup if cloudflared is available."""
    if _find_cloudflared():
        t = threading.Thread(target=_run_tunnel_thread, daemon=True)
        t.start()
        logger.info("Auto-starting Cloudflare tunnel...")


@app.on_event("startup")
async def _start_cloud_relay():
    data = _load_data()
    if data.get("cloud_url") and data.get("cloud_token"):
        asyncio.create_task(_cloud_relay_worker())


# ─── Cloudflare Tunnel state ─────────────────────────────────────────────────
_tunnel_proc: Optional[subprocess.Popen] = None
_tunnel_url:  str = ""
_tunnel_lock  = threading.Lock()
_convert_locks: dict[str, threading.Lock] = {}
_convert_locks_guard = threading.Lock()


def _find_cloudflared() -> Optional[str]:
    found = shutil.which("cloudflared")
    if found:
        return found
    for loc in ["/usr/local/bin/cloudflared", "/opt/homebrew/bin/cloudflared",
                "/usr/bin/cloudflared", os.path.expanduser("~/.local/bin/cloudflared")]:
        if os.path.isfile(loc):
            return loc
    return None


def _run_tunnel_thread():
    global _tunnel_proc, _tunnel_url
    cmd = _find_cloudflared()
    if not cmd:
        logger.error("cloudflared not found — install with: brew install cloudflared")
        return
    try:
        _tunnel_proc = subprocess.Popen(
            [cmd, "tunnel", "--url", f"http://localhost:{settings.PORT}", "--no-autoupdate"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        url_re = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")
        for line in _tunnel_proc.stdout:
            logger.info("cloudflared: %s", line.rstrip())
            m = url_re.search(line)
            if m and not _tunnel_url:
                _tunnel_url = m.group(0)
                logger.info("Tunnel active: %s", _tunnel_url)
                data = _load_data(); data["tunnel_url"] = _tunnel_url; _save_data(data)
    except Exception as e:
        logger.error("Tunnel thread error: %s", e)
    finally:
        _tunnel_url = ""
        data = _load_data(); data["tunnel_url"] = ""; _save_data(data)
        _tunnel_proc = None


# ─── Persistent data helpers ──────────────────────────────────────────────────

def _load_data() -> dict:
    if settings.DATA_FILE.exists():
        try:
            return json.loads(settings.DATA_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "notes": {},
        "global_exclusions": [],
        "pairing_code": "",
        "cloud_url": "",
        "cloud_user_id": None,
    }


def _save_data(data: dict) -> None:
    data.setdefault("cloud_url", "")
    data.setdefault("cloud_user_id", None)
    settings.DATA_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _load_analysis() -> dict:
    """Load analysis_data.json → {track_id: features}."""
    path = settings.BASE_DIR / "analysis_data.json"
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def _save_analysis(store: dict) -> None:
    path = settings.BASE_DIR / "analysis_data.json"
    path.write_text(json.dumps(store, indent=2), encoding="utf-8")


# ─── Audio streaming ──────────────────────────────────────────────────────────

def _get_convert_lock(track_id: str) -> threading.Lock:
    with _convert_locks_guard:
        lock = _convert_locks.get(track_id)
        if lock is None:
            lock = threading.Lock()
            _convert_locks[track_id] = lock
        return lock


def _ensure_aiff_converted(path: str, track_id: str) -> str:
    cached = settings.CACHE_DIR / f"conv_{track_id}.wav"
    if cached.exists():
        return str(cached)

    with _get_convert_lock(track_id):
        if cached.exists():
            return str(cached)

        logger.info("Converting AIFF → WAV: %s", track_id)
        r = subprocess.run(
            ["ffmpeg", "-i", path, "-f", "wav", str(cached), "-y"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        if r.returncode != 0 or not cached.exists():
            logger.error(
                "ffmpeg failed for id=%s rc=%d: %s",
                track_id, r.returncode,
                r.stderr.decode("utf-8", errors="replace")[-500:],
            )
            raise HTTPException(503, "Audio conversion failed — retry in a moment")

    return str(cached)

def _stream_range(path: str, start: int, end: int, chunk: int = 256 * 1024):
    with open(path, "rb") as f:
        f.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            data = f.read(min(chunk, remaining))
            if not data:
                break
            yield data
            remaining -= len(data)


@app.get("/stream")
async def stream_audio(request: Request, path: str, id: str, preload: bool = False):
    if not os.path.exists(path):
        raise HTTPException(404, "File not found")

    ext = os.path.splitext(path)[1].lower()
    final = path

    if ext in (".aif", ".aiff"):
        if preload:
            def _preload_convert() -> None:
                try:
                    _ensure_aiff_converted(path, id)
                except HTTPException:
                    pass
                except Exception as e:
                    logger.error("AIFF preload failed for id=%s: %s", id, e)

            threading.Thread(target=_preload_convert, daemon=True).start()
            return JSONResponse({"status": "preloading"})

        final = _ensure_aiff_converted(path, id)
    elif preload:
        return JSONResponse({"status": "preloading"})

    size   = os.path.getsize(final)
    rng    = request.headers.get("Range", "")
    start, end = 0, size - 1

    if rng:
        try:
            r_start, r_end = rng.replace("bytes=", "").split("-")
            start = int(r_start) if r_start else 0
            end   = int(r_end)   if r_end   else size - 1
        except ValueError:
            pass

    if start > end or start >= size:
        return Response(status_code=416)

    _MIME = {
        ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4",
        ".aac": "audio/aac",  ".ogg": "audio/ogg", ".flac": "audio/flac",
    }
    mime = _MIME.get(os.path.splitext(final)[1].lower(), "audio/mpeg")
    # Always 206 + Content-Range so browsers know byte-range is supported from
    # the very first request — this enables immediate playback start and seek.
    return StreamingResponse(
        _stream_range(final, start, end),
        status_code=206,
        headers={
            "Content-Range":  f"bytes {start}-{end}/{size}",
            "Accept-Ranges":  "bytes",
            "Content-Length": str(end - start + 1),
        },
        media_type=mime,
    )


# ─── Library ──────────────────────────────────────────────────────────────────

@app.get("/api/data")
async def get_library_data():
    app_data = _load_data()
    loop     = asyncio.get_event_loop()
    data     = await loop.run_in_executor(None, parse_library)
    return {
        "tracks":           data["tracks"],
        "playlists":        data["playlists"],
        "notes":            app_data.get("notes", {}),
        "global_exclusions": app_data.get("global_exclusions", []),
        "library_date":     data.get("xml_date", 0),
    }


# ─── Pairing ──────────────────────────────────────────────────────────────────

@app.get("/api/pairing_info")
async def get_pairing_info():
    import random, string, urllib.parse
    code = "".join(random.choices(string.ascii_uppercase + string.digits, k=5))

    app_data = _load_data()
    app_data["pairing_code"] = code
    _save_data(app_data)

    from .config import get_local_ip
    local_url = f"http://{get_local_ip()}:{settings.PORT}"
    # Use tunnel URL if active — allows pairing from outside the local network
    url = _tunnel_url or app_data.get("tunnel_url", "") or local_url
    qr_data = json.dumps({"url": url, "code": code, "agent_id": settings.AGENT_ID})
    qr_url  = f"https://api.qrserver.com/v1/create-qr-code/?size=300x300&data={urllib.parse.quote(qr_data)}"

    return {"code": code, "qr_url": qr_url, "local_url": url, "agent_id": settings.AGENT_ID}


@app.get("/api/check_pairing")
async def check_pairing(code: str):
    app_data = _load_data()
    if app_data.get("pairing_code") == code:
        return {"status": "ok"}
    raise HTTPException(403, "Invalid pairing code")


# ─── Notes & exclusions ───────────────────────────────────────────────────────

@app.post("/api/save_note")
async def save_note(request: Request):
    body = await request.json()
    tid  = body.get("id")
    note = (body.get("note") or "").strip()

    app_data = _load_data()
    if note:
        app_data.setdefault("notes", {})[tid] = note
    else:
        app_data.get("notes", {}).pop(tid, None)
    _save_data(app_data)
    return {"status": "ok"}


@app.post("/api/save_exclusions")
async def save_exclusions(request: Request):
    body = await request.json()
    if not isinstance(body, list):
        raise HTTPException(400, "Expected a list of playlist paths")
    app_data = _load_data()
    app_data["global_exclusions"] = body
    _save_data(app_data)
    return {"status": "ok"}


# ─── Waveform & artwork ───────────────────────────────────────────────────────

@app.get("/waveform")
async def get_waveform(path: str, id: str):
    cache = settings.CACHE_DIR / f"wave_{id}.json"
    if cache.exists():
        return JSONResponse(json.loads(cache.read_text()))

    if not os.path.exists(path):
        raise HTTPException(404)

    try:
        # Get duration via ffprobe
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=10,
        )
        duration = float(r.stdout.strip()) if r.stdout.strip() else 0.0

        cmd = ["ffmpeg", "-v", "error", "-i", path,
               "-ac", "1", "-filter:a", "aresample=100", "-f", "s8", "-"]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        raw, _ = proc.communicate()

        if not raw:
            return {"duration": duration, "peaks": []}

        samples = [abs(b if b < 128 else b - 256) / 128.0 for b in raw]
        step    = max(1, len(samples) // 8000)
        peaks   = []
        for i in range(0, len(samples), step):
            chunk = samples[i : i + step]
            peaks.append(round(min(1.0, sum(chunk) / len(chunk) * 2.5), 3))

        result = {"duration": duration, "peaks": peaks}
        cache.write_text(json.dumps(result))
        return result
    except Exception as e:
        logger.error("Waveform generation failed: %s", e)
        return {"duration": 0, "peaks": []}


@app.get("/artwork")
async def get_artwork(path: str, id: str):
    cache = settings.CACHE_DIR / f"art_{id}.jpg"
    if cache.exists():
        return FileResponse(cache)
    if not os.path.exists(path):
        raise HTTPException(404)
    try:
        subprocess.run(
            ["ffmpeg", "-i", path, "-an", "-vcodec", "mjpeg",
             "-vframes", "1", "-s", "512x512", str(cache), "-y"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if cache.exists():
            return FileResponse(cache)
    except Exception:
        pass
    raise HTTPException(404)


# ─── Telegram ─────────────────────────────────────────────────────────────────

@app.post("/api/send_tg")
async def send_tg(request: Request):
    body   = await request.json()
    token  = settings.TG_TOKEN
    chat   = settings.TG_CHAT_ID
    if not token or not chat:
        raise HTTPException(503, "Telegram not configured")

    text = f"🎵 {body.get('artist', '')} — {body.get('title', '')}"
    import urllib.request, urllib.parse
    url  = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
    urllib.request.urlopen(url, data=data, timeout=10)
    return {"status": "ok"}


# ─── Analysis ─────────────────────────────────────────────────────────────────

# In-memory progress state (shared with background task)
_analysis_state = {
    "running": False,
    "total":   0,
    "done":    0,
    "current": "",
    "errors":  0,
}
_analysis_lock = threading.Lock()


@app.get("/api/analysis")
async def get_analysis(id: str):
    """Return stored features for one track."""
    store = _load_analysis()
    feat  = store.get(id)
    if feat is None:
        raise HTTPException(404, "Track not analysed yet")
    return feat


@app.get("/api/analysis/status")
async def get_analysis_status():
    """Current progress of the background analysis job."""
    with _analysis_lock:
        return dict(_analysis_state)


@app.post("/api/analysis/start")
async def start_analysis(background_tasks: BackgroundTasks):
    """Trigger full-library analysis in the background."""
    with _analysis_lock:
        if _analysis_state["running"]:
            return {"status": "already_running"}
        _analysis_state.update(running=True, done=0, errors=0, current="")

    background_tasks.add_task(_run_analysis_job)
    return {"status": "started"}


@app.post("/api/analysis/recheck")
async def recheck_analysis(background_tasks: BackgroundTasks):
    """Re-analyze tracks that are missing any of the 4 required metrics."""
    with _analysis_lock:
        if _analysis_state["running"]:
            return {"status": "already_running"}
        _analysis_state.update(running=True, done=0, errors=0, current="")

    background_tasks.add_task(_run_analysis_job)  # reuses same job — now skips only complete tracks
    store = _load_analysis()
    _REQUIRED = {"energy", "timbre", "groove", "happiness"}
    incomplete = [tid for tid, feat in store.items() if not _REQUIRED.issubset(feat.keys())]
    return {"status": "started", "incomplete_tracks": len(incomplete)}


def _run_analysis_job():
    from .analyzer import analyze_track, _load_analysis, _save_analysis

    data   = parse_library()
    tracks = data.get("tracks", [])

    # Deduplicate by track ID (same file can appear in multiple playlists)
    seen = {}
    for t in tracks:
        seen[t["id"]] = t
    unique_tracks = list(seen.values())

    store = _load_analysis()

    with _analysis_lock:
        _analysis_state["total"] = len(unique_tracks)

    for i, track in enumerate(unique_tracks):
        label = f"{track.get('artist', '')} — {track.get('title', '')}"
        with _analysis_lock:
            _analysis_state["current"] = label
            _analysis_state["done"]    = i

        # Skip only if all 4 metrics present
        _REQUIRED = {"energy", "timbre", "groove", "happiness"}
        if track["id"] in store and _REQUIRED.issubset(store[track["id"]].keys()):
            with _analysis_lock:
                _analysis_state["done"] = i + 1
            continue

        try:
            result = analyze_track(track)
            if result:
                store[track["id"]] = result
                if (i + 1) % 10 == 0:
                    _save_analysis(store)   # checkpoint every 10 tracks
        except Exception as e:
            logger.error("Analysis failed for %s: %s", label, e)
            with _analysis_lock:
                _analysis_state["errors"] += 1

    _save_analysis(store)

    with _analysis_lock:
        _analysis_state.update(running=False, done=len(unique_tracks), current="")

    logger.info("Analysis complete: %d tracks", len(unique_tracks))


# ─── Similar tracks ───────────────────────────────────────────────────────────

@app.get("/api/similar")
async def get_similar(id: str, limit: int = 10, use_key: int = 1):
    """
    Return top-N similar tracks for the given track ID.
    Runs heavy computation in a thread so the async event loop is not blocked.
    """
    store = _load_analysis()
    if id not in store:
        raise HTTPException(404, "Track not analysed — run /api/analysis/start first")

    _use_key = bool(use_key)

    def _compute():
        from .similarity import find_similar
        data       = parse_library()
        all_tracks = data.get("tracks", [])
        results    = find_similar(id, all_tracks, store,
                                  top_n=min(limit, 50), use_key=_use_key)
        src_feat   = store.get(id, {})
        # Return shape that matches the JS consumer
        return {
            "results":         results,
            "source_features": src_feat,
            "analyzed_count":  len(store),
        }

    loop = asyncio.get_event_loop()
    payload = await loop.run_in_executor(None, _compute)
    return payload


@app.get("/api/analysis/track_list")
async def get_analysed_ids():
    """Return list of track IDs that have been analysed."""
    store = _load_analysis()
    return {"ids": list(store.keys()), "count": len(store)}


# ─── Cloud account linking ────────────────────────────────────────────────────

def _get_agent_local_url() -> str:
    """Return http://<local_ip>:<port> for this agent."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception:
        ip = "127.0.0.1"
    return f"http://{ip}:{settings.PORT}"


@app.get("/api/status")
async def get_status():
    """Return agent info: id, version, xml status, cloud link state."""
    app_data  = _load_data()
    xml_path  = settings.XML_PATH
    db_path   = settings.DB_PATH
    cloud_url = app_data.get("cloud_url", "")
    db_exists = bool(db_path) and os.path.exists(db_path)
    return {
        "agent_id":   settings.AGENT_ID,
        "version":    settings.VERSION,
        "xml_path":   xml_path,
        "xml_exists": os.path.exists(xml_path) if xml_path else False,
        "db_path":    db_path,
        "db_exists":  db_exists,
        "library_source": "db" if db_exists else "xml",
        "cloud_url":  cloud_url,
        "is_linked":  bool(cloud_url),
    }


@app.post("/api/link_account")
async def link_account(request: Request):
    """
    Link this agent to a Rimeo cloud account.

    Body: { "token": "<compound_token>" }

    The compound token (base64 JSON) contains both the cloud URL and
    the one-time secret. The agent decodes it, then POSTs to
    <cloud_url>/api/agents/link with its identity.
    """
    import base64 as _b64
    body  = await request.json()
    token = (body.get("token") or "").strip()

    if not token:
        raise HTTPException(400, "token is required")

    # Try to decode compound token {url, t}
    cloud_url  = ""
    raw_token  = token
    try:
        decoded   = json.loads(_b64.urlsafe_b64decode(token + "==").decode("utf-8"))
        cloud_url = decoded.get("url", "").rstrip("/")
        raw_token = decoded.get("t", token)
    except Exception:
        pass

    # Fallback: caller may pass cloud_url explicitly, or use default
    if not cloud_url:
        cloud_url = (body.get("cloud_url") or "").rstrip("/")
    if not cloud_url:
        cloud_url = settings.RIMEO_APP_URL.rstrip("/")

    local_url  = _get_agent_local_url()
    data       = _load_data()
    tunnel_url = _tunnel_url or data.get("tunnel_url", "")
    payload    = json.dumps({
        "token":      raw_token,
        "agent_id":   settings.AGENT_ID,
        "agent_url":  local_url,
        "tunnel_url": tunnel_url,
        "agent_name": settings.APP_NAME,
    }).encode("utf-8")

    link_endpoint = f"{cloud_url}/api/agents/link"
    req = urllib.request.Request(
        link_endpoint,
        data=payload,
        headers=_CLOUD_HEADERS,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        raise HTTPException(e.code, f"Cloud rejected link: {body_text}")
    except Exception as e:
        raise HTTPException(502, f"Could not reach cloud: {e}")

    # Persist cloud URL + token on success
    app_data = _load_data()
    app_data["cloud_url"]     = cloud_url
    app_data["cloud_user_id"] = result.get("email")
    if result.get("cloud_token"):
        app_data["cloud_token"] = result["cloud_token"]
    _save_data(app_data)

    # (Re)start the cloud relay worker
    global _relay_task
    if _relay_task is None or _relay_task.done():
        _relay_task = asyncio.create_task(_cloud_relay_worker())

    return {"status": "linked", "cloud_url": cloud_url, "result": result}


@app.post("/api/unlink_account")
async def unlink_account():
    """Remove the cloud account link from this agent and notify the cloud server."""
    app_data  = _load_data()
    cloud_url = app_data.get("cloud_url", "")

    # Notify the cloud to delete the agent binding
    if cloud_url:
        try:
            payload = json.dumps({"agent_id": settings.AGENT_ID}).encode()
            req = urllib.request.Request(
                f"{cloud_url}/api/agents/unlink_by_agent",
                data=payload,
                headers=_CLOUD_HEADERS,
                method="POST",
            )
            urllib.request.urlopen(req, timeout=5)
        except Exception as e:
            logger.warning("Could not notify cloud on unlink: %s", e)

    app_data["cloud_url"] = ""
    app_data["cloud_user_id"] = None
    _save_data(app_data)
    return {"status": "unlinked"}


@app.get("/api/tunnel/status")
async def tunnel_status_endpoint():
    data = _load_data()
    active = bool(_tunnel_proc and _tunnel_proc.poll() is None)
    url = _tunnel_url or (data.get("tunnel_url", "") if active else "")
    return {"active": active, "url": url, "cloudflared_found": bool(_find_cloudflared())}


@app.post("/api/tunnel/start")
async def tunnel_start():
    global _tunnel_proc, _tunnel_url
    with _tunnel_lock:
        if _tunnel_proc and _tunnel_proc.poll() is None:
            return {"status": "already_running", "url": _tunnel_url}
        _tunnel_url = ""
        t = threading.Thread(target=_run_tunnel_thread, daemon=True)
        t.start()
    # Wait up to 20 s for the URL to appear
    for _ in range(40):
        await asyncio.sleep(0.5)
        if _tunnel_url:
            return {"status": "started", "url": _tunnel_url}
    return {"status": "starting", "url": ""}


@app.post("/api/tunnel/stop")
async def tunnel_stop():
    global _tunnel_proc, _tunnel_url
    with _tunnel_lock:
        if _tunnel_proc:
            _tunnel_proc.terminate()
            _tunnel_proc = None
        _tunnel_url = ""
    data = _load_data(); data["tunnel_url"] = ""; _save_data(data)
    return {"status": "stopped"}


# ─── Cloud WebSocket relay ────────────────────────────────────────────────────

_relay_task: Optional[asyncio.Task] = None


async def _handle_relay_cmd(cloud_url: str, data: dict):
    """Process one relay command and POST the result back to the cloud."""
    try:
        import httpx
    except ImportError:
        logger.error("httpx not installed — cloud relay unavailable")
        return

    req_id   = data.get("req_id", "")
    method   = data.get("method", "GET")
    path     = data.get("path", "/")
    headers  = {k: v for k, v in (data.get("headers") or {}).items() if k and v}
    body_b64 = data.get("body")
    body     = _b64.b64decode(body_b64) if body_b64 else None

    headers.pop("host", None)
    headers.pop("Host", None)
    url = f"http://127.0.0.1:{settings.PORT}{path}"

    result: dict = {}
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.request(
                method, url, headers=headers, content=body, timeout=30.0
            )
            result = {
                "req_id": req_id,
                "status": resp.status_code,
                "headers": dict(resp.headers),
                "body_b64": _b64.b64encode(resp.content).decode(),
            }
    except Exception as e:
        logger.error("Relay error req=%s path=%s: %s", req_id, path, e)
        result = {
            "req_id": req_id, "status": 502, "headers": {},
            "body_b64": _b64.b64encode(str(e).encode()).decode(),
        }

    try:
        async with httpx.AsyncClient(headers=_CLOUD_HEADERS) as client:
            await client.post(
                f"{cloud_url}/api/relay/result",
                json=result,
                timeout=10.0,
            )
    except Exception as e:
        logger.error("Relay result POST failed req=%s: %s", req_id, e)


async def _cloud_relay_worker():
    global _relay_task
    _relay_task = asyncio.current_task()

    try:
        import httpx
    except ImportError:
        logger.error("httpx not installed — cloud relay unavailable")
        return

    backoff = 1
    while True:
        data        = _load_data()
        cloud_url   = data.get("cloud_url", "")
        cloud_token = data.get("cloud_token", "")

        if not cloud_url or not cloud_token:
            await asyncio.sleep(30)
            continue

        tunnel  = _tunnel_url or ""
        poll_url = (f"{cloud_url}/api/relay/poll/{settings.AGENT_ID}"
                    f"?token={cloud_token}"
                    + (f"&tunnel={_uparse.quote(tunnel, safe='/:')}" if tunnel else ""))

        try:
            logger.info("Cloud relay connecting: %s", cloud_url)
            async with httpx.AsyncClient(timeout=30.0, headers=_CLOUD_HEADERS) as client:
                resp = await client.get(poll_url)

            if resp.status_code == 403:
                logger.warning("Cloud relay: unauthorized (bad token), retry in 60s")
                await asyncio.sleep(60)
                backoff = 1
                continue

            if resp.status_code != 200:
                logger.warning("Cloud relay poll: HTTP %s, retry in %ds",
                               resp.status_code, backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30)
                continue

            backoff = 1
            msg = resp.json()
            if msg.get("type") == "ping":
                continue  # immediately poll again

            logger.debug("Cloud relay cmd: req_id=%s method=%s path=%s",
                         msg.get("req_id"), msg.get("method"), msg.get("path"))
            asyncio.create_task(_handle_relay_cmd(cloud_url, msg))

        except Exception as e:
            logger.warning("Cloud relay error: %s, retry in %ds", e, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


@app.get("/reveal")
async def reveal_in_finder(path: str):
    """Open the file's parent folder in Finder (macOS) or Explorer (Windows)."""
    if not os.path.exists(path):
        raise HTTPException(404, "File not found")
    if os.name == "nt":
        subprocess.Popen(["explorer", "/select,", path])
    else:
        subprocess.Popen(["open", "-R", path])
    return {"status": "ok"}


@app.get("/api/account")
async def get_account():
    """Return stored cloud account info from rimo_data.json."""
    app_data = _load_data()
    return {
        "cloud_url":     app_data.get("cloud_url", ""),
        "cloud_user_id": app_data.get("cloud_user_id"),
        "is_linked":     bool(app_data.get("cloud_url", "")),
        "agent_id":      settings.AGENT_ID,
        "agent_url":     _get_agent_local_url(),
    }


@app.post("/api/report_bug")
async def report_bug(request: Request):
    """Forward a bug report (with log excerpt) to the linked cloud app."""
    body = await request.json()
    description = (body.get("description") or "").strip()
    if not description:
        raise HTTPException(400, "description required")

    # Attach last 80 lines of agent log
    log_excerpt = ""
    try:
        log_path = settings.LOG_FILE
        if log_path.exists():
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            log_excerpt = "\n".join(lines[-80:])
    except Exception:
        pass

    app_data = _load_data()
    cloud_url = (app_data.get("cloud_url") or "").rstrip("/")
    if not cloud_url:
        raise HTTPException(503, "Agent is not linked to a cloud account")

    payload = json.dumps({
        "agent_id":    settings.AGENT_ID,
        "user_email":  app_data.get("cloud_user_id") or "",
        "description": description,
        "log_excerpt": log_excerpt,
    }).encode()
    req = urllib.request.Request(
        f"{cloud_url}/api/report_bug",
        data=payload,
        headers=_CLOUD_HEADERS,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception as e:
        raise HTTPException(502, f"Could not reach cloud: {e}")

    return {"status": "ok"}
