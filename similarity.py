"""
similarity.py — Match Score engine for Rimeo Agent.

Formula (total 0–100):
  Vibe      45 %  — Acoustic style/energy/mood
                      Timbre     0.50  (MFCC[1:] cosine — tonal colour, MFCC[0] skipped)
                      Energy     0.25  (RMS loudness / intensity)
                      Happiness  0.15  (major/minor mood — coarse proxy)
                      Groove     0.10  (beat regularity)
  Key       25 %  — Camelot wheel harmonic compatibility
  Tempo     20 %  — BPM delta with hard-filter at >8 BPM
  Metadata  10 %  — Same label + shared playlists (Jaccard)
"""
import re
import math
from typing import Dict, Any, List, Optional


def tempo_score(bpm_a: float, bpm_b: float) -> Optional[float]:
    """
    Returns None  → hard-filtered (delta > 8 BPM, skip this pair entirely).
    0.25 – 1.0   → score based on delta.

    delta 0–2   → 1.0
    delta 2–8   → linear decay  1.0 → 0.25
    delta > 8   → None (excluded)
    """
    if bpm_a <= 0 or bpm_b <= 0:
        return 0.5   # BPM unknown — neutral score

    delta = abs(bpm_a - bpm_b)

    if delta > 8.0:
        return None

    if delta <= 2.0:
        return 1.0

    # Linear 1.0 → 0.25 over range [2, 8]
    return round(1.0 - (delta - 2.0) / 6.0 * 0.75, 4)


def camelot_score(key_a: str, key_b: str) -> float:
    """
    Harmonic compatibility score based on the Camelot wheel.

    Rekordbox Tonality field: "1A"–"12A" (minor), "1B"–"12B" (major).

    Scoring:
      Same key                              → 1.0
      Same number, different letter         → 0.85  (relative major/minor)
      ±1 number, same letter                → 0.85  (adjacent, energy shift)
      ±2 number, same letter                → 0.50  (2-step modulation)
      ±1 number, different letter           → 0.35  (stretch, possible clash)
      Everything else                       → 0.0   (harmonic clash)
      Unknown / unrecognised key            → 0.5   (neutral)
    """
    def _parse(k: str):
        k = (k or "").strip()
        if not k or k == "—":
            return None, None
        m = re.match(r'^(\d{1,2})([AB])$', k, re.I)
        if not m:
            return None, None
        return int(m.group(1)), m.group(2).upper()

    num_a, let_a = _parse(key_a)
    num_b, let_b = _parse(key_b)

    if num_a is None or num_b is None:
        return 0.5  # unknown key — neutral

    # Circular distance on 1–12 wheel
    diff = abs(num_a - num_b)
    num_diff = min(diff, 12 - diff)

    same_num = (num_a == num_b)
    same_let = (let_a == let_b)

    if same_num and same_let:
        return 1.0

    if same_num and not same_let:      # relative major/minor
        return 0.85

    if num_diff == 1 and same_let:     # adjacent on wheel
        return 0.85

    if num_diff == 2 and same_let:     # 2-step modulation
        return 0.50

    if num_diff == 1 and not same_let: # stretch
        return 0.35

    return 0.0   # harmonic clash


def vibe_score(feat_a: Dict, feat_b: Dict) -> float:
    """
    Acoustic similarity focused on tonal colour, energy and mood.

    Sub-weights (sum to 1.0):
      Timbre     0.50  — MFCC[1:] cosine (skip coeff-0 which is energy-biased)
      Energy     0.25  — RMS loudness/intensity match
      Happiness  0.15  — major/minor valence (coarse mood proxy)
      Groove     0.10  — beat regularity match
    """
    score = 0.0
    weight = 0.0

    # ── Timbre (MFCC cosine — skip coeff 0 which dominates raw cosine) ────────
    if "timbre" in feat_a and "timbre" in feat_b:
        # MFCC[0] ≈ log-energy, magnitude >> MFCC[1:]; skipping it makes
        # cosine reflect spectral shape rather than loudness level.
        a = feat_a["timbre"][1:]
        b = feat_b["timbre"][1:]
        if a and b and len(a) == len(b):
            dot = sum(x * y for x, y in zip(a, b))
            na  = math.sqrt(sum(x * x for x in a))
            nb_ = math.sqrt(sum(x * x for x in b))
            if na > 0 and nb_ > 0:
                cos = dot / (na * nb_)           # –1 … 1
                score  += ((cos + 1.0) / 2.0) * 0.50
                weight += 0.50

    # ── Energy (intensity / loudness) ────────────────────────────────────────
    if "energy" in feat_a and "energy" in feat_b:
        diff   = abs(feat_a["energy"] - feat_b["energy"])
        score  += (1.0 - min(1.0, diff * 3.5)) * 0.25
        weight += 0.25

    # ── Happiness (mood: dark ↔ bright) ──────────────────────────────────────
    if "happiness" in feat_a and "happiness" in feat_b:
        diff   = abs(feat_a["happiness"] - feat_b["happiness"])
        score  += (1.0 - min(1.0, diff * 2.5)) * 0.15
        weight += 0.15

    # ── Groove (beat regularity) ──────────────────────────────────────────────
    if "groove" in feat_a and "groove" in feat_b:
        diff   = abs(feat_a["groove"] - feat_b["groove"])
        score  += (1.0 - min(1.0, diff * 3.0)) * 0.10
        weight += 0.10

    return round(score / weight, 4) if weight > 0 else 0.0


def clap_score(feat_a: Dict, feat_b: Dict) -> Optional[float]:
    """
    Cosine similarity between CLAP embeddings, mapped to 0–1.

    Embeddings are pre-normalised to unit length, so dot product == cosine.
    Returns None if either track lacks a CLAP embedding (e.g. not yet re-analysed).
    """
    a = feat_a.get("clap")
    b = feat_b.get("clap")
    if not a or not b or len(a) != len(b):
        return None
    dot = sum(x * y for x, y in zip(a, b))
    return round((dot + 1.0) / 2.0, 4)   # [-1, 1] → [0, 1]


def metadata_score(track_a: Dict, track_b: Dict) -> float:
    """
    Bonus for:
      - Same record label        (0.6 share)
      - Shared playlists Jaccard (0.4 share)
    """
    score = 0.0

    la = (track_a.get("label") or "").strip().lower()
    lb = (track_b.get("label") or "").strip().lower()
    if la and lb and la == lb:
        score += 0.6

    pa = set((track_a.get("playlist_indices") or {}).keys())
    pb = set((track_b.get("playlist_indices") or {}).keys())
    if pa and pb:
        union = len(pa | pb)
        if union > 0:
            score += (len(pa & pb) / union) * 0.4

    return round(min(1.0, score), 4)


def compute_match(
    track_a: Dict, track_b: Dict,
    feat_a:  Dict, feat_b:  Dict,
    use_key: bool = True,
) -> Optional[Dict[str, float]]:
    """
    Compute full match score between two tracks.

    Returns None if hard-filtered by BPM delta > 8.
    Otherwise returns:
        total     0–100
        vibe      0–100
        key       0–100
        tempo     0–100
        metadata  0–100

    use_key=False redistributes key weight to vibe/tempo.
    """
    ts = tempo_score(track_a.get("bpm", 0), track_b.get("bpm", 0))
    if ts is None:
        return None   # hard BPM filter

    cs = clap_score(feat_a, feat_b)
    vs = cs if cs is not None else vibe_score(feat_a, feat_b)
    ks = camelot_score(track_a.get("key", ""), track_b.get("key", ""))
    ms = metadata_score(track_a, track_b)

    if cs is not None:
        # CLAP mode
        if use_key:
            total = (vs * 0.80 + ks * 0.12 + ts * 0.08) * 100
        else:
            total = (vs * 0.90 + ts * 0.10) * 100
    else:
        # Fallback MFCC mode
        if use_key:
            total = (vs * 0.45 + ks * 0.25 + ts * 0.20 + ms * 0.10) * 100
        else:
            total = (vs * 0.60 + ts * 0.25 + ms * 0.15) * 100

    key_val = round(ks * 100, 1)
    return {
        "total":    round(total, 1),
        "vibe":     round(vs * 100, 1),
        "key":      key_val,
        "harmony":  key_val,   # alias for iOS client
        "tempo":    round(ts * 100, 1),
        "metadata": round(ms * 100, 1),
        "clap":     cs is not None,
    }


def find_similar(
    track_id:      str,
    all_tracks:    List[Dict],
    analysis_data: Dict[str, Dict],
    top_n:         int = 10,
    use_key:       bool = True,
) -> List[Dict]:
    """
    Return top_n similar tracks for track_id, sorted by match score desc.

    Each result: {"track": {...}, "score": {"total": X, "vibe": X, "key": X, ...}}
    Tracks without analysis data are silently skipped.
    """
    feat_a  = analysis_data.get(track_id)
    track_a = next((t for t in all_tracks if t["id"] == track_id), None)
    if feat_a is None or track_a is None:
        return []

    results = []
    for track_b in all_tracks:
        if track_b["id"] == track_id:
            continue
        feat_b = analysis_data.get(track_b["id"])
        if feat_b is None:
            continue
        score = compute_match(track_a, track_b, feat_a, feat_b, use_key=use_key)
        if score is not None:
            results.append({"track": track_b, "score": score})

    results.sort(key=lambda x: x["score"]["total"], reverse=True)
    return results[:top_n]
