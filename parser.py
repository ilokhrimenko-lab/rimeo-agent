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
