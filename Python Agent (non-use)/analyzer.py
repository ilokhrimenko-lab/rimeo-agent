"""
analyzer.py — Audio feature extraction for Rimeo Agent.

Pipeline per track:
  1. Load waveform peaks from cache → find best 60-second segment
     (highest avg energy in 35-65% window, avoiding breakdowns)
  2. Extract that segment to a temp WAV via ffmpeg
  3. Run librosa to compute: Energy, Timbre (MFCC), Groove, Happiness
  4. Return feature dict + segment timestamps (for UI inspection)
"""
import os
import json
import subprocess
import tempfile
import time
from typing import Optional, Dict, Any, Tuple, List

import numpy as np

if __package__:
    from .config import settings, logger
else:
    from config import settings, logger

SEGMENT_DURATION = 60.0   # seconds to analyse per track
MFCC_COEFFS      = 13
CLAP_MODEL_ID    = "laion/clap-htsat-fused"
CLAP_SR          = 48000   # CLAP expects 48 kHz
CLAP_MAX_SEC     = 30      # truncate to 30 s to keep inference fast


# ─── CLAP singleton ───────────────────────────────────────────────────────────

_clap_model     = None
_clap_processor = None


def _get_clap():
    """Lazy-load CLAP model (downloaded once to ~/.cache/huggingface)."""
    global _clap_model, _clap_processor
    if _clap_model is None:
        try:
            from transformers import ClapModel, ClapProcessor
            logger.info("Loading CLAP model %s …", CLAP_MODEL_ID)
            _clap_processor = ClapProcessor.from_pretrained(CLAP_MODEL_ID)
            _clap_model     = ClapModel.from_pretrained(CLAP_MODEL_ID)
            _clap_model.eval()
            logger.info("CLAP model ready")
        except Exception as e:
            logger.warning("CLAP unavailable: %s", e)
    return _clap_model, _clap_processor


def _clap_embedding(y: np.ndarray, orig_sr: int) -> Optional[list]:
    """
    Return a normalised 512-dim CLAP embedding as a plain list of floats.
    Returns None if CLAP is not installed or inference fails.
    """
    model, processor = _get_clap()
    if model is None or processor is None:
        return None
    try:
        import torch
        import librosa as _librosa

        # Resample to 48 kHz if needed, then truncate to CLAP_MAX_SEC
        if orig_sr != CLAP_SR:
            y = _librosa.resample(y, orig_sr=orig_sr, target_sr=CLAP_SR)
        y = y[: CLAP_SR * CLAP_MAX_SEC]

        inputs = processor(audio=y, sampling_rate=CLAP_SR, return_tensors="pt")
        with torch.no_grad():
            emb = model.get_audio_features(**inputs)          # (1, 512)
        emb = emb / emb.norm(dim=-1, keepdim=True)            # unit normalise
        return [round(float(v), 6) for v in emb[0].tolist()]
    except Exception as e:
        logger.warning("CLAP embedding failed: %s", e)
        return None


# ─── Segment selection ────────────────────────────────────────────────────────

def find_analysis_segment(peaks: List[float], duration: float) -> Tuple[float, float]:
    """
    Return (start_sec, end_sec) of the best 60-second window to analyse.

    Strategy:
    - Search only the central 35 %–65 % of the track (skip intros/outros)
    - Pick the window with the highest mean energy (avoid breakdowns)
    """
    seg = SEGMENT_DURATION
    if not peaks or duration <= 0:
        start = duration * 0.40
        return (round(start, 1), round(min(start + seg, duration), 1))

    n = len(peaks)
    search_lo = int(n * 0.35)
    search_hi = int(n * 0.65)

    # Window length in peak samples
    win = max(1, int(n * seg / duration))
    win = min(win, search_hi - search_lo)

    arr = np.array(peaks, dtype=np.float32)

    best_idx   = search_lo
    best_score = -1.0

    for i in range(search_lo, search_hi - win + 1):
        score = float(arr[i : i + win].mean())
        if score > best_score:
            best_score = score
            best_idx   = i

    start = duration * best_idx / n
    end   = min(start + seg, duration)
    return (round(start, 1), round(end, 1))


# ─── Audio extraction ─────────────────────────────────────────────────────────

def _extract_segment(track_path: str, start: float, duration: float) -> Optional[str]:
    """
    Export a mono 22 050 Hz WAV segment to a temp file.
    Returns the path, or None on failure.
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()

    cmd = [
        "ffmpeg", "-v", "error",
        "-ss", str(start), "-t", str(duration),
        "-i", track_path,
        "-ac", "1", "-ar", "22050",
        "-f", "wav", "-y", tmp.name,
    ]
    ret = subprocess.run(cmd, capture_output=True, timeout=60)
    if ret.returncode != 0 or not os.path.exists(tmp.name):
        logger.warning("ffmpeg segment extraction failed for %s", track_path)
        return None
    return tmp.name


def _get_duration(track_path: str) -> float:
    """Probe track duration via ffprobe."""
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error",
             "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1",
             track_path],
            capture_output=True, text=True, timeout=10,
        )
        return float(r.stdout.strip())
    except Exception:
        return 300.0  # safe fallback


# ─── Feature extraction ───────────────────────────────────────────────────────

def _compute_features(audio_path: str) -> Optional[Dict[str, Any]]:
    """
    Extract all acoustic features from a mono WAV segment.

    Returns:
        energy    float  0-1   loudness / intensity
        timbre    list   13 MFCC means (tonal colour)
        groove    float  0-1   beat regularity (1 = perfectly steady)
        happiness float  0-1   valence (0 = minor/dark, 1 = major/bright)
    """
    try:
        import librosa

        y, sr = librosa.load(audio_path, sr=22050, mono=True)
        if len(y) == 0:
            return None

        # ── Energy (raw RMS — no hard cap so quiet/loud tracks stay separated) ──
        rms_frames = librosa.feature.rms(y=y)[0]
        rms_mean   = float(np.mean(rms_frames))
        energy     = round(rms_mean, 6)   # raw, typically 0.005–0.15

        # ── Timbre (MFCC) ────────────────────────────────────────────────────
        mfcc   = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=MFCC_COEFFS)
        timbre = [round(float(v), 4) for v in mfcc.mean(axis=1)]

        # ── Brightness (spectral centroid, normalised to 0-1 over music range)
        # Centroid 500 Hz = dark/bass, 4000+ Hz = bright/hi-hat heavy.
        cent     = librosa.feature.spectral_centroid(y=y, sr=sr)[0]
        brightness = round(min(1.0, float(np.mean(cent)) / 4000.0), 4)

        # ── Density / noisiness (zero-crossing rate) ─────────────────────────
        # Low ZCR = bass/pad heavy; high ZCR = lots of hi-hats, noise, texture
        zcr_vals = librosa.feature.zero_crossing_rate(y)[0]
        zcr      = round(float(np.mean(zcr_vals)), 4)

        # ── Groove (beat-interval regularity) ───────────────────────────────
        _, beats = librosa.beat.beat_track(y=y, sr=sr)
        if len(beats) > 2:
            ibi    = np.diff(librosa.frames_to_time(beats, sr=sr))
            groove = float(1.0 - min(1.0, np.std(ibi) / (np.mean(ibi) + 1e-6)))
        else:
            groove = 0.5
        groove = round(groove, 4)

        # ── Happiness (valence via chroma mode detection) ────────────────────
        # Note: low variance in electronic music (~0.5 for most tracks).
        # Kept for completeness but weighted low in similarity.
        y_h, _ = librosa.effects.hpss(y)
        chroma  = librosa.feature.chroma_cqt(y=y_h, sr=sr).mean(axis=1)

        MAJOR = [0, 2, 4, 5, 7, 9, 11]
        MINOR = [0, 2, 3, 5, 7, 8, 10]
        best_major = best_minor = 0.0
        for root in range(12):
            maj  = sum(chroma[(root + d) % 12] for d in MAJOR)
            min_ = sum(chroma[(root + d) % 12] for d in MINOR)
            best_major = max(best_major, maj)
            best_minor = max(best_minor, min_)
        total     = best_major + best_minor + 1e-8
        happiness = round(float(best_major / total), 4)

        clap = _clap_embedding(y, sr)

        result: Dict[str, Any] = {
            "energy":     energy,      # raw RMS
            "brightness": brightness,  # spectral centroid 0-1
            "zcr":        zcr,         # zero-crossing rate
            "timbre":     timbre,      # 13 MFCC means
            "groove":     groove,
            "happiness":  happiness,
        }
        if clap is not None:
            result["clap"] = clap      # 512-dim unit-normalised embedding
        return result

    except Exception as e:
        logger.error("Feature extraction error: %s", e)
        return None


# ─── Public API ───────────────────────────────────────────────────────────────

def analyze_track(track: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """
    Full analysis pipeline for one track.

    Returns a result dict:
        track_id, segment_start, segment_end,
        energy, timbre, groove, happiness, analyzed_at
    or None on failure.
    """
    track_id   = track.get("id", "")
    track_path = track.get("location", "")

    if not track_id or not os.path.exists(track_path):
        return None

    # ── Load waveform peaks from cache ───────────────────────────────────────
    peaks    = []
    duration = 0.0
    cache_f  = settings.CACHE_DIR / f"wave_{track_id}.json"
    if cache_f.exists():
        try:
            wf       = json.loads(cache_f.read_text())
            peaks    = wf.get("peaks", [])
            duration = float(wf.get("duration", 0))
        except Exception:
            pass

    if duration <= 0:
        duration = _get_duration(track_path)

    seg_start, seg_end = find_analysis_segment(peaks, duration)
    seg_dur = seg_end - seg_start

    # ── Extract audio segment ────────────────────────────────────────────────
    audio_tmp = _extract_segment(track_path, seg_start, seg_dur)
    if not audio_tmp:
        return None

    try:
        features = _compute_features(audio_tmp)
    finally:
        try:
            os.unlink(audio_tmp)
        except OSError:
            pass

    if not features:
        return None

    return {
        "track_id":     track_id,
        "segment_start": seg_start,
        "segment_end":   seg_end,
        "analyzed_at":  int(time.time()),
        **features,
    }


def load_analysis_store() -> Dict[str, Dict]:
    """Load analysis_data.json → {track_id: features}."""
    path = settings.BASE_DIR / "analysis_data.json"
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_analysis_store(store: Dict[str, Dict]) -> None:
    """Persist analysis_data.json."""
    path = settings.BASE_DIR / "analysis_data.json"
    path.write_text(json.dumps(store, indent=2), encoding="utf-8")
