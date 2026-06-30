#!/usr/bin/env python3
"""Generate a rekordbox.xml (DJ_PLAYLISTS) from the royalty-free demo mp3s.

Pixabay filenames look like:  <uploader>-<title words>-<numericID>.mp3
We derive Artist (uploader), Title (middle words), Genre/BPM/Key heuristically,
and read real duration/bitrate via ffprobe.
"""
import os, re, json, subprocess, urllib.parse, html
from xml.sax.saxutils import quoteattr

AUDIO_DIR = os.path.dirname(os.path.abspath(__file__)) + "/audio"
OUT_XML   = os.path.dirname(os.path.abspath(__file__)) + "/rimeo_review.xml"

# genre keyword -> (Genre label, base BPM)
GENRE_RULES = [
    ("technology",      ("Corporate", 118)),
    ("presentation",    ("Corporate", 118)),
    ("brazilian phonk", ("Brazilian Phonk", 130)),
    ("phonk",           ("Phonk", 145)),
    ("deep house",      ("Deep House", 122)),
    ("techno house",    ("Techno House", 126)),
    ("techno",          ("Techno", 130)),
    ("tropical",        ("Tropical House", 108)),
    ("background beat", ("Lo-Fi Beats", 88)),
    ("house",           ("House", 124)),
]
CAMELOT = ["8A","9A","5A","11B","4A","7B","2A","10A","6A","12B","1A","3B","8B","9B","5B",
           "7A","12A","4B","10B","6B"]
# marketing filler to strip from titles
STOP = {"background","music","for","video","stories","story","short","second",
        "sec","vol","the","a","of","feat"}

def ffprobe(path):
    try:
        out = subprocess.run(
            ["ffprobe","-v","quiet","-print_format","json","-show_format","-show_streams",path],
            capture_output=True, text=True, timeout=30).stdout
        d = json.loads(out)
        dur = float(d.get("format",{}).get("duration",0) or 0)
        br  = int(d.get("format",{}).get("bit_rate",0) or 0)
        if br == 0:
            for s in d.get("streams",[]):
                if s.get("codec_type")=="audio":
                    br = int(s.get("bit_rate",0) or 0); break
        return dur, br
    except Exception:
        return 0.0, 0

def parse_name(fn):
    base = re.sub(r"\.mp3$", "", fn, flags=re.I)
    parts = base.split("-")
    # trailing numeric id
    if parts and parts[-1].isdigit():
        parts = parts[:-1]
    uploader = parts[0] if parts else "Unknown"
    title_words = parts[1:] if len(parts) > 1 else parts
    artist = uploader.replace("_"," ").strip().title() or "Unknown Artist"
    # title: drop filler tokens but keep meaning; keep order
    kept = [w for w in title_words if w.lower() not in STOP and not w.isdigit()]
    if not kept:
        kept = title_words
    title = " ".join(kept).strip().title() or base.title()
    return artist, title

def detect_genre_bpm(fn, idx):
    low = fn.lower().replace("-", " ")
    for kw,(g,bpm) in GENRE_RULES:
        if kw in low:
            return g, bpm + (idx % 5) - 2   # small spread ±2
    return "Electronic", 120 + (idx % 6)

def file_url(path):
    # rekordbox-style: file://localhost/<url-encoded absolute path>
    return "file://localhost" + urllib.parse.quote(path)

files = sorted(f for f in os.listdir(AUDIO_DIR)
               if f.lower().endswith(".mp3") and not f.startswith("._"))
print(f"tracks: {len(files)}")

tracks = []
for i, fn in enumerate(files, start=1):
    full = os.path.join(AUDIO_DIR, fn)
    dur, br = ffprobe(full)
    artist, title = parse_name(fn)
    genre, bpm = detect_genre_bpm(fn, i)
    key = CAMELOT[(i-1) % len(CAMELOT)]
    # spread DateAdded across 2024 so sorting (newest first) looks natural
    month = (i % 12) + 1
    day   = (i % 27) + 1
    date  = f"2024-{month:02d}-{day:02d}"
    tracks.append(dict(tid=i, artist=artist, title=title, genre=genre,
                       bpm=bpm, key=key, dur=int(round(dur)), br=br//1000,
                       loc=file_url(full), date=date, fn=fn))
    print(f"  [{i:02d}] {artist} — {title} | {genre} {bpm}BPM {key} | {int(round(dur))}s {br//1000}kbps")

# Build XML
def esc(s): return html.escape(str(s), quote=True)

col = []
for t in tracks:
    col.append(
        f'    <TRACK TrackID="{t["tid"]}" Name="{esc(t["title"])}" '
        f'Artist="{esc(t["artist"])}" Genre="{esc(t["genre"])}" '
        f'Kind="MP3 File" TotalTime="{t["dur"]}" AverageBpm="{t["bpm"]}" '
        f'Tonality="{t["key"]}" BitRate="{t["br"]}" Year="2024" '
        f'DateAdded="{t["date"]}" PlayCount="0" '
        f'Location="{esc(t["loc"])}"/>'
    )

# playlists by genre
from collections import defaultdict
by_genre = defaultdict(list)
for t in tracks:
    by_genre[t["genre"]].append(t["tid"])

def playlist_node(name, tids):
    rows = "".join(f'        <TRACK Key="{tid}"/>\n' for tid in tids)
    return (f'      <NODE Name="{esc(name)}" Type="1" KeyType="0" '
            f'Entries="{len(tids)}">\n{rows}      </NODE>\n')

all_pl = playlist_node("All Tracks", [t["tid"] for t in tracks])
genre_pls = "".join(playlist_node(g, tids) for g, tids in sorted(by_genre.items()))

xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<DJ_PLAYLISTS Version="1.0.0">
  <PRODUCT Name="rekordbox" Version="6.0.0" Company="AlphaTheta"/>
  <COLLECTION Entries="{len(tracks)}">
{chr(10).join(col)}
  </COLLECTION>
  <PLAYLISTS>
    <NODE Type="0" Name="ROOT" Count="{1+len(by_genre)}">
{all_pl}{genre_pls}    </NODE>
  </PLAYLISTS>
</DJ_PLAYLISTS>
'''

with open(OUT_XML, "w", encoding="utf-8") as f:
    f.write(xml)
print(f"\nwrote {OUT_XML} ({len(tracks)} tracks, {len(by_genre)} genre playlists)")
