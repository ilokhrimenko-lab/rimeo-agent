import os
import xml.etree.ElementTree as ET
from datetime import datetime
import logging
import urllib.parse
from typing import Dict, List, Any
from .config import settings, logger

# In-memory cache: avoids re-parsing XML on every /api/data request
_xml_cache: Dict[str, Any] = {}
_xml_cache_mtime: float = 0.0

_db_cache: Dict[str, Any] = {}
_db_cache_mtime: float = 0.0

def normalize_path(loc: str) -> str:
    path = urllib.parse.unquote(loc)
    if path.startswith("file://localhost/"):
        return path.replace("file://localhost", "")
    elif path.startswith("file:///"):
        return path.replace("file://", "")
    return path

def parse_rekordbox_xml() -> Dict[str, Any]:
    """Modernized parser for Rimeo Agent. Result is cached until XML file changes."""
    global _xml_cache, _xml_cache_mtime

    if not os.path.exists(settings.XML_PATH):
        logger.warning(f"XML not found at {settings.XML_PATH}")
        return {"tracks": [], "playlists": [], "xml_date": 0}

    try:
        mtime = os.path.getmtime(settings.XML_PATH)
    except OSError:
        mtime = 0.0

    if _xml_cache and mtime == _xml_cache_mtime:
        return _xml_cache

    logger.info("Parsing rekordbox XML (cache miss)...")

    try:
        tree = ET.parse(settings.XML_PATH)
        root = tree.getroot()
        
        tracks_db = []
        all_detected_playlists = {}

        collection = root.find("COLLECTION")
        if collection is not None:
            for tr in collection.findall("TRACK"):
                tid = tr.attrib.get("TrackID")
                if not tid: continue
                
                raw_date = tr.attrib.get("DateAdded", "")
                ts = 0
                try: ts = datetime.fromisoformat(raw_date).timestamp()
                except: pass

                artist = tr.attrib.get("Artist", "Unknown Artist")
                title = tr.attrib.get("Name", "Unknown Title")
                
                date_str = raw_date[:10] if raw_date else "0000-00-00"
                tracks_db.append({
                    "id": tid,
                    "artist": artist,
                    "title": title,
                    "genre": tr.attrib.get("Genre", ""),
                    "label": tr.attrib.get("Label", ""),
                    "rel_date": tr.attrib.get("Year", ""),
                    "key": tr.attrib.get("Tonality", "—"),
                    "bpm": float(tr.attrib.get("AverageBpm", "0")) if tr.attrib.get("AverageBpm") else 0.0,
                    "bitrate": int(tr.attrib.get("BitRate", "0")) if tr.attrib.get("BitRate") and tr.attrib.get("BitRate").isdigit() else 0,
                    "play_count": int(tr.attrib.get("PlayCount", "0")) if tr.attrib.get("PlayCount") and tr.attrib.get("PlayCount").isdigit() else 0,
                    "location": normalize_path(tr.attrib.get("Location", "")),
                    "timestamp": ts,
                    "date_str": date_str,
                    "playlists": [],
                    "playlist_indices": {}
                })

        def walk_playlists(node, path):
            for n in node.findall("NODE"):
                node_type = n.attrib.get("Type")
                name = n.attrib.get("Name", "")
                if node_type == "0":
                    walk_playlists(n, path + [name])
                elif node_type == "1":
                    p_path = " / ".join([p for p in path if p.upper() != "ROOT"] + [name])
                    if p_path not in all_detected_playlists:
                        all_detected_playlists[p_path] = 0
                    
                    for pl_order, t in enumerate(n.findall("TRACK"), 1):
                        track_id = t.attrib.get("Key") or t.attrib.get("TrackID")
                        # Optimizing lookup with a simple search for now (can use dict later)
                        for track in tracks_db:
                            if track["id"] == track_id:
                                track["playlist_indices"][p_path] = pl_order
                                if p_path not in track["playlists"]:
                                    track["playlists"].append(p_path)
                                if track["timestamp"] > all_detected_playlists[p_path]:
                                    all_detected_playlists[p_path] = track["timestamp"]

        if root.find("PLAYLISTS") is not None:
            walk_playlists(root.find("PLAYLISTS"), [])
            
        playlists_list = [{"path": p, "date": all_detected_playlists[p]} for p in all_detected_playlists]
        
        # Sort by newest added
        tracks_db.sort(key=lambda x: x.get("timestamp", 0), reverse=True)
        
        xml_date_ts = os.path.getmtime(settings.XML_PATH)

        result = {
            "tracks": tracks_db,
            "playlists": playlists_list,
            "xml_date": xml_date_ts
        }
        _xml_cache = result
        _xml_cache_mtime = mtime
        logger.info(f"XML parsed and cached: {len(tracks_db)} tracks")
        return result
    except Exception as e:
        logger.error(f"Error parsing Rekordbox XML: {e}")
        return {"tracks": [], "playlists": [], "xml_date": 0}


def parse_master_db() -> Dict[str, Any]:
    """Read library directly from Rekordbox master.db (SQLCipher). Cached by mtime."""
    global _db_cache, _db_cache_mtime

    db_path = settings.DB_PATH
    if not db_path or not os.path.exists(db_path):
        logger.warning(f"master.db not found at {db_path}")
        return {"tracks": [], "playlists": [], "xml_date": 0, "source": "db"}

    try:
        mtime = os.path.getmtime(db_path)
    except OSError:
        mtime = 0.0

    if _db_cache and mtime == _db_cache_mtime:
        return _db_cache

    logger.info("Parsing rekordbox master.db (cache miss)...")

    try:
        from pyrekordbox.db6 import Rekordbox6Database
        db = Rekordbox6Database(db_path)

        # Build playlist ID → object map (skip deleted)
        playlist_map = {
            p.ID: p for p in db.get_playlist()
            if not p.rb_local_deleted
        }

        def build_playlist_path(p) -> str:
            parts = []
            current = p
            while current is not None and current.ParentID != "root":
                parts.append(current.Name)
                current = playlist_map.get(current.ParentID)
            parts.append(p.Name if not parts else parts[-1])
            # parts built bottom-up, but we already collected correctly — reverse
            # Actually re-do: walk up collecting names
            parts = []
            current = p
            while current is not None:
                if current.ParentID == "root":
                    parts.append(current.Name)
                    break
                parts.append(current.Name)
                current = playlist_map.get(current.ParentID)
            parts.reverse()
            return " / ".join(parts)

        # Map track ID → {playlists, playlist_indices, latest_timestamp}
        track_playlists: Dict[str, Dict] = {}
        all_playlists: Dict[str, float] = {}

        for p in playlist_map.values():
            if not p.Songs:
                continue
            p_path = build_playlist_path(p)
            if p_path not in all_playlists:
                all_playlists[p_path] = 0.0

            for song in p.Songs:
                if song.rb_local_deleted:
                    continue
                tid = song.ContentID
                if tid not in track_playlists:
                    track_playlists[tid] = {"playlists": [], "playlist_indices": {}}
                track_playlists[tid]["playlist_indices"][p_path] = song.TrackNo
                if p_path not in track_playlists[tid]["playlists"]:
                    track_playlists[tid]["playlists"].append(p_path)

        tracks_db = []
        for t in db.get_content():
            if t.rb_local_deleted:
                continue

            ts = 0.0
            try:
                ts = t.created_at.timestamp()
            except Exception:
                pass

            date_str = t.DateCreated or "0000-00-00"
            bpm = round(t.BPM / 100.0, 2) if t.BPM else 0.0
            pl_info = track_playlists.get(t.ID, {"playlists": [], "playlist_indices": {}})

            # Update playlist latest timestamp
            for p_path in pl_info["playlists"]:
                if ts > all_playlists.get(p_path, 0.0):
                    all_playlists[p_path] = ts

            tracks_db.append({
                "id":               t.ID,
                "artist":           t.ArtistName or "Unknown Artist",
                "title":            t.Title or "Unknown Title",
                "genre":            t.GenreName or "",
                "label":            t.LabelName or "",
                "rel_date":         str(t.ReleaseYear) if t.ReleaseYear else "",
                "key":              t.KeyName or "—",
                "bpm":              bpm,
                "bitrate":          t.BitRate or 0,
                "play_count":       t.DJPlayCount or 0,
                "location":         t.FolderPath or "",
                "timestamp":        ts,
                "date_str":         date_str,
                "playlists":        pl_info["playlists"],
                "playlist_indices": pl_info["playlist_indices"],
            })

        tracks_db.sort(key=lambda x: x["timestamp"], reverse=True)
        playlists_list = [{"path": p, "date": all_playlists[p]} for p in all_playlists]

        result = {
            "tracks":   tracks_db,
            "playlists": playlists_list,
            "xml_date": mtime,
            "source":   "db",
        }
        _db_cache = result
        _db_cache_mtime = mtime
        logger.info(f"master.db parsed and cached: {len(tracks_db)} tracks, {len(playlists_list)} playlists")
        return result

    except Exception as e:
        logger.error(f"Error parsing master.db: {e}")
        return {"tracks": [], "playlists": [], "xml_date": 0, "source": "db"}


def parse_library() -> Dict[str, Any]:
    """Try master.db first; fall back to XML if DB unavailable."""
    db_path = settings.DB_PATH
    if db_path and os.path.exists(db_path):
        result = parse_master_db()
        if result["tracks"]:
            return result
    return parse_rekordbox_xml()
