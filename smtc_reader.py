#!/usr/bin/env python3
# smtc_reader.py — reads now-playing track info via the Windows Media Session
# API (SMTC) and sends it to the widget server via WebSocket.
# The source app is selectable in the tray; "" = auto (current system session).
# pip install winrt-Windows.Media.Control winrt-Windows.Storage.Streams
#             winrt-Windows.Foundation winrt-Windows.Foundation.Collections
#             websocket-client

import asyncio
import base64
import json
import os
import sys
import threading
import time
import websocket

from winrt.windows.media.control import (
    GlobalSystemMediaTransportControlsSessionManager as GSMTCS,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
)
from winrt.windows.storage.streams import DataReader, Buffer, InputStreamOptions

WS_URL     = "ws://localhost:8765/?client=smtc"
POLL_MS    = 1000
_HERE      = os.path.dirname(os.path.abspath(__file__))
WDG_CONFIG = os.path.join(_HERE, "widget_config.json")

import re

def _clean_aumid(aumid):
    """Reduce an AUMID to a stable, human-readable app token.
    Handles all the messy shapes seen in the wild:
      'Spotify F0DC299D809B9700'            -> 'Spotify'   (space-separated hex tail)
      'Spotify.exe'                         -> 'Spotify'
      'C:\\path\\App.exe'                    -> 'App'
      'Package_8wekyb3d8bbwe!App'           -> 'Package'
      'SpotifyF0DC299D809B9700' (glued hex) -> 'Spotify'
    """
    base = str(aumid).replace("/", "\\").split("\\")[-1]
    base = re.split(r"[\s!]", base, 1)[0]          # \s catches normal + non-breaking spaces
    if base.lower().endswith(".exe"):
        base = base[:-4]
    base = re.sub(r"[ _\-]*[0-9a-fA-F]{8,}$", "", base)   # drop a glued volatile hex tail
    return base.strip()

def app_key(aumid):
    """Stable lowercase identity for matching (volatile AUMID tails removed)."""
    return _clean_aumid(aumid).lower()

def app_name(aumid):
    """Friendly display name (same cleaning, original case)."""
    return _clean_aumid(aumid) or str(aumid)

def read_source_app():
    """Configured source app match string. '' = auto / current session.
    Stored as free text (an app name or part of it); matched as a lowercase
    substring against each session's AUMID, so it survives volatile AUMID tails.
    """
    try:
        with open(WDG_CONFIG, "r", encoding="utf-8-sig") as f:
            return (json.load(f).get("source_app_id", "") or "").strip().lower()
    except Exception:
        return ""

def pick_session(mgr):
    """Choose which SMTC session to read.
    - If a source app is configured, match it (substring of the AUMID / app key)
      against the per-app sessions from get_sessions(); fall back to the current
      session only if it matches. We do NOT mix get_current_session() into the
      enumeration, because that proxy can flip apps mid-read and corrupt data.
    - Otherwise use the current session, then any playing session, then any.
    """
    try:
        sessions = list(mgr.get_sessions())
    except Exception:
        sessions = []

    src = read_source_app()
    if src:
        for s in sessions:
            try:
                aumid = (s.source_app_user_model_id or "").lower()
            except Exception:
                aumid = ""
            if aumid and (src in aumid or src in app_key(aumid)):
                return s
        # fallback: maybe it's only exposed as the current session right now
        try:
            cur = mgr.get_current_session()
            if cur:
                a = (cur.source_app_user_model_id or "").lower()
                if a and (src in a or src in app_key(a)):
                    return cur
        except Exception:
            pass
        return None  # chosen app isn't available right now
    # Auto mode
    try:
        cur = mgr.get_current_session()
        if cur:
            return cur
    except Exception:
        pass
    for s in sessions:
        try:
            if s.get_playback_info().playback_status == PlaybackStatus.PLAYING:
                return s
        except Exception:
            pass
    return sessions[0] if sessions else None

# ── WebSocket ─────────────────────────────────────────────────────────────────
ws_app    = None
connected = False
ws_lock   = threading.Lock()

def send_state(payload):
    with ws_lock:
        if not connected or not ws_app: return
        try:
            ws_app.send(json.dumps(payload))
        except: pass

def on_open(ws):
    global connected; connected = True
    print("[smtc] Connected to server")

def on_close(ws, *a):
    global connected; connected = False
    print("[smtc] Disconnected, reconnecting...")

def on_error(ws, e):
    global connected; connected = False

def ws_thread():
    global ws_app
    while True:
        try:
            ws_app = websocket.WebSocketApp(WS_URL,
                on_open=on_open, on_close=on_close, on_error=on_error)
            ws_app.run_forever()
        except Exception as e:
            print(f"[smtc] WS error: {e}")
        time.sleep(3)

# ── Thumbnail reader ──────────────────────────────────────────────────────────
async def read_thumbnail(thumb_ref):
    try:
        stream = await thumb_ref.open_read_async()
        size   = stream.size
        if size == 0: return None
        buf    = Buffer(size)
        await stream.read_async(buf, size, InputStreamOptions.READ_AHEAD)
        reader = DataReader.from_buffer(buf)
        data   = bytearray(size)
        for i in range(size):
            data[i] = reader.read_byte()
        mime = "image/png" if data[:4] == b'\x89PNG' else "image/jpeg"
        b64  = base64.b64encode(bytes(data)).decode()
        return f"data:{mime};base64,{b64}"
    except Exception as e:
        print(f"[smtc] Thumbnail error: {e}")
        return None

# ── Track ID (hash from title+artist to detect track changes) ─────────────────
def make_track_id(title, artist, album):
    import hashlib
    return hashlib.md5(f"{title}|{artist}|{album}".encode()).hexdigest()[:16]

# ── SMTC polling loop ─────────────────────────────────────────────────────────
last_track_id  = None
last_thumb_id  = None
last_thumb_b64 = None
last_position  = 0.0   # for drift filtering
last_poll_time = 0.0   # real time of last poll

async def poll_once():
    global last_track_id, last_thumb_id, last_thumb_b64, last_position, last_poll_time

    try:
        mgr = await GSMTCS.request_async()
    except Exception as e:
        print(f"[smtc] Session error: {e}")
        return

    # Choose source session (configured app, or auto current session)
    session = pick_session(mgr)
    if not session:
        return

    try:
        info     = await session.try_get_media_properties_async()
        timeline = session.get_timeline_properties()
        pb       = session.get_playback_info()
    except Exception as e:
        print(f"[smtc] Properties error: {e}")
        return

    title  = info.title  or ""
    artist = info.artist or ""
    album  = info.album_title or ""

    if not title: return

    duration_s = timeline.end_time.total_seconds()
    raw_pos    = timeline.position.total_seconds()
    playing    = (pb.playback_status == PlaybackStatus.PLAYING)

    # Filter SMTC position jitter — if playing, extrapolate from last known position
    now = time.monotonic()
    elapsed = now - last_poll_time if last_poll_time > 0 else 0
    expected = last_position + elapsed if playing else last_position
    # Accept SMTC value if it differs from expected by more than 1.5s (real seek)
    # otherwise use it directly (SMTC is authoritative)
    position_s = raw_pos
    last_position = raw_pos
    last_poll_time = now

    progress   = (position_s / duration_s) if duration_s > 0 else 0

    track_id = make_track_id(title, artist, album)

    # Get thumbnail — only re-read when track changes
    art_url = None
    if track_id != last_thumb_id:
        if info.thumbnail:
            b64 = await read_thumbnail(info.thumbnail)
            if b64:
                last_thumb_b64 = b64
                last_thumb_id  = track_id
        else:
            last_thumb_b64 = None
            last_thumb_id  = track_id

    art_url = last_thumb_b64

    is_new_track = (track_id != last_track_id)
    # Also send full payload on first connection (last_thumb_id was just set)
    is_full = is_new_track or (last_thumb_id == track_id and last_track_id is None)

    if is_full:
        # Full payload with art — on track change or first connection
        payload = {
            "trackId":  track_id,
            "name":     title,
            "artist":   artist,
            "album":    album,
            "artUrl":   art_url or "",
            "playlist": "",
            "duration": int(duration_s * 1000),
            "position": int(position_s * 1000),
            "playing":  playing,
            "progress": round(progress, 6),
            "analysis": None,
        }
        last_track_id = track_id
        if is_new_track:
            print(f"[smtc] Now playing: {title} — {artist}")
    else:
        # Lightweight update — no art, no name, just playback state
        payload = {
            "trackId":  track_id,
            "name":     title,
            "artist":   artist,
            "album":    album,
            "artUrl":   None,        # skip — widget keeps current art
            "playlist": "",
            "duration": int(duration_s * 1000),
            "position": int(position_s * 1000),
            "playing":  playing,
            "progress": round(progress, 6),
            "analysis": None,
        }

    send_state(payload)

async def poll_loop():
    while True:
        await poll_once()
        await asyncio.sleep(POLL_MS / 1000)

# ── Session listing (for the tray source picker) ──────────────────────────────
async def list_sessions_data():
    try:
        mgr = await GSMTCS.request_async()
    except Exception:
        return []
    await asyncio.sleep(0.3)               # let the manager finish discovery
    try:
        sessions = list(mgr.get_sessions())
    except Exception:
        sessions = []
    out  = []
    seen = set()
    # Read each per-app session ONCE, from the same object. No get_current_session
    # mixing — that proxy flips apps mid-read and corrupts name/track pairing.
    for s in sessions:
        try:
            aumid = s.source_app_user_model_id or ""
        except Exception:
            aumid = ""
        key = app_key(aumid)
        if not key or key in seen:
            continue
        seen.add(key)
        title = artist = ""
        playing = False
        try:
            info = await s.try_get_media_properties_async()
            title  = info.title or ""
            artist = info.artist or ""
        except Exception:
            pass
        try:
            playing = (s.get_playback_info().playback_status == PlaybackStatus.PLAYING)
        except Exception:
            pass
        out.append({"id": key, "name": app_name(aumid),
                    "title": title, "artist": artist, "playing": playing})
    return out

# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if "--list" in sys.argv:
        # Optional output file path (written as UTF-8) — more reliable than stdout
        # redirection from PowerShell. Without a path, print a readable diagnostic.
        out_path = None
        for a in sys.argv[1:]:
            if a != "--list":
                out_path = a
                break
        data = asyncio.run(list_sessions_data())
        if out_path:
            try:
                with open(out_path, "w", encoding="utf-8") as f:
                    f.write(json.dumps(data, ensure_ascii=False))
            except Exception:
                print(json.dumps(data, ensure_ascii=False))
        else:
            print(f"Found {len(data)} media session(s):\n")
            for d in data:
                mark = "[playing]" if d["playing"] else "[paused] "
                print(f"  {mark} key='{d['id']}'  name='{d['name']}'")
                print(f"            track: {d['artist']} - {d['title']}")
            print("\n(raw JSON below)\n" + json.dumps(data, ensure_ascii=False))
        sys.exit(0)
    src = read_source_app()
    print(f"[smtc] Starting SMTC reader (source: {src or 'auto / current session'})")
    print("[smtc] Connecting to ws://localhost:8765")
    threading.Thread(target=ws_thread, daemon=True).start()
    time.sleep(1)
    try:
        asyncio.run(poll_loop())
    except KeyboardInterrupt:
        print("\n[smtc] Stopped")
