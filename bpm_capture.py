# bpm_capture.py — BPM detection via WASAPI loopback
# Reads device from eq_config.json, settings from widget_config.json

import json
import sys
import time
import threading
import asyncio
import websockets
import numpy as np
import pyaudiowpatch as pyaudio

import os
from datetime import datetime

_HERE       = os.path.dirname(os.path.abspath(__file__))
WS_URL      = 'ws://localhost:8765/?client=bpm'
EQ_CONFIG   = os.path.join(_HERE, 'eq_config.json')
WDG_CONFIG  = os.path.join(_HERE, 'widget_config.json')
LOG_FILE    = os.path.join(_HERE, 'buddy.log')
COLLECT_SEC = 6
BASE_BPM    = 120.0

def log(msg, flush=True):
    line = f"[{datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=flush)
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass

# ── Config ────────────────────────────────────────────────────────────────────
def read_device_name():
    try:
        with open(EQ_CONFIG, 'r', encoding='utf-8-sig') as f:
            return json.load(f).get('device_name', '')
    except Exception:
        return ''

def read_buddy_config():
    defaults = {
        'lock_overrange': True, 'lock_bpm': 140, 'update_enabled': True, 'update_rate': 30,
        'method': 'flux', 'window_sec': 6, 'min_bpm': 70.0, 'max_bpm': 180.0,
    }
    try:
        with open(WDG_CONFIG, 'r', encoding='utf-8-sig') as f:
            cfg = json.load(f)
        result = {
            'lock_overrange':  bool(cfg.get('buddy_lock_overrange', True)),
            'lock_bpm':        int(cfg.get('buddy_lock_bpm', 140)),
            'update_enabled':  bool(cfg.get('buddy_update_enabled', True)),
            'update_rate':     max(1, int(cfg.get('buddy_update_rate', 30))),
            'method':          'flux' if bool(cfg.get('buddy_method_flux', True)) else 'energy',
            'window_sec':      max(3, min(20, int(cfg.get('buddy_window_sec', 6)))),
            'min_bpm':         float(cfg.get('buddy_min_bpm', 70)),
            'max_bpm':         float(cfg.get('buddy_max_bpm', 180)),
        }
        log(f'[config] method={result["method"]} window={result["window_sec"]}s range={result["min_bpm"]:.0f}-{result["max_bpm"]:.0f} '
            f'lock_overrange={result["lock_overrange"]} lock_bpm={result["lock_bpm"]} '
            f'update_enabled={result["update_enabled"]} update_rate={result["update_rate"]}s')
        return result
    except Exception as e:
        log(f'[config] read error: {e}, using defaults')
        return dict(defaults)

def find_device(pa, name):
    try:
        wasapi = pa.get_host_api_info_by_type(pyaudio.paWASAPI)
    except Exception:
        return None
    for i in range(wasapi['deviceCount']):
        dev = pa.get_device_info_by_host_api_device_index(wasapi['index'], i)
        if dev.get('isLoopbackDevice') and dev['name'] == name and dev['maxInputChannels'] > 0:
            return dev
    for i in range(wasapi['deviceCount']):
        dev = pa.get_device_info_by_host_api_device_index(wasapi['index'], i)
        if dev.get('isLoopbackDevice') and dev['maxInputChannels'] > 0:
            return dev
    return None

# ── BPM detection ─────────────────────────────────────────────────────────────
def _energy_onset(x, sr):
    """Broadband RMS-energy onset envelope at ~100 Hz. Fast, less precise."""
    hop = max(1, int(round(sr / 100.0)))
    nframes = (len(x) - hop) // hop
    if nframes < 16:
        return None, None
    env = np.empty(nframes, dtype=np.float64)
    for i in range(nframes):
        fr = x[i * hop:i * hop + hop]
        env[i] = np.sqrt(np.mean(fr * fr) + 1e-12)
    onset = np.diff(env)
    onset[onset < 0] = 0.0
    return onset, sr / hop


def _flux_onset(x, sr):
    """Spectral-flux onset envelope: sum of positive magnitude change across
    frequency bins per STFT frame. Much cleaner onsets than broadband energy,
    so the tempo peak in the autocorrelation is sharper and more reliable."""
    n_fft = 1024
    hop   = 512
    if len(x) < n_fft + hop:
        return None, None
    win = np.hanning(n_fft)
    nframes = 1 + (len(x) - n_fft) // hop
    if nframes < 16:
        return None, None
    flux = np.zeros(nframes, dtype=np.float64)
    prev = None
    for i in range(nframes):
        seg = x[i * hop:i * hop + n_fft] * win
        mag = np.abs(np.fft.rfft(seg))
        if prev is not None:
            d = mag - prev
            d[d < 0] = 0.0
            flux[i] = d.sum()
        prev = mag
    return flux, sr / hop


def detect_bpm(samples, sr, method='flux', min_bpm=70.0, max_bpm=180.0):
    """Estimate tempo via onset-strength autocorrelation with a tempo prior.

    - method 'flux'   -> spectral-flux onset (accurate, a bit heavier)
      method 'energy' -> RMS-energy onset (fast, coarser)
    - a log-Gaussian prior around 120 BPM gently suppresses octave errors
    - parabolic interpolation around the peak gives sub-bin (sub-BPM) precision
    Returns BPM (float) or None if inconclusive.
    """
    x = np.asarray(samples, dtype=np.float64)
    if x.size < sr:
        return None

    onset, fps = (_flux_onset(x, sr) if method == 'flux' else _energy_onset(x, sr))
    if onset is None or not np.any(onset):           # fall back to energy
        onset, fps = _energy_onset(x, sr)
    if onset is None or not np.any(onset):
        return None

    o  = onset - onset.mean()
    ac = np.correlate(o, o, mode='full')[len(o) - 1:]

    # Search a generous tempo span so octave folding has candidates on both sides
    lo_bpm = max(40.0,  min_bpm / 2.0)
    hi_bpm = min(300.0, max_bpm * 2.0)
    lag_min = max(1, int(np.floor(fps * 60.0 / hi_bpm)))
    lag_max = min(len(ac) - 1, int(np.ceil(fps * 60.0 / lo_bpm)))
    if lag_min >= lag_max:
        return None

    lags = np.arange(lag_min, lag_max + 1)
    seg  = ac[lag_min:lag_max + 1].astype(np.float64)
    if seg.max() <= 0:
        return None
    seg = seg / seg.max()

    # Tempo prior (resonance curve) centred on 120 BPM, wide in log space
    bpms  = 60.0 * fps / lags
    prior = np.exp(-0.5 * (np.log2(bpms / 120.0) / 0.9) ** 2)
    score = seg * prior

    k = int(np.argmax(score))
    # Parabolic interpolation around the winning lag for sub-bin precision
    if 0 < k < len(score) - 1:
        y0, y1, y2 = score[k - 1], score[k], score[k + 1]
        denom = (y0 - 2 * y1 + y2)
        delta = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
    else:
        delta = 0.0
    lag = lags[k] + max(-0.5, min(0.5, delta))
    bpm = 60.0 * fps / lag

    # Fold into the requested musical range
    while bpm < min_bpm - 1e-6: bpm *= 2
    while bpm > max_bpm + 1e-6: bpm /= 2
    return round(bpm, 1)

# ── Audio collector ───────────────────────────────────────────────────────────
class BpmDetector:
    def __init__(self):
        self._lock        = threading.Lock()
        self._track_id    = None
        self._playing     = False
        self._last_bpm    = None      # last accepted BPM
        self._collecting  = False     # a collect thread is currently running
        self._on_result   = None
        self._on_loading  = None
        self._update_timer = None     # threading.Timer for periodic update

    def set_callbacks(self, on_loading, on_result):
        self._on_loading = on_loading
        self._on_result  = on_result

    def new_track(self, track_id):
        with self._lock:
            if track_id == self._track_id:
                return
            self._track_id = track_id
            self._last_bpm = None
        self._cancel_timer()
        if self._on_loading:
            self._on_loading()
        self._spawn_collect(track_id)

    def set_playing(self, playing):
        with self._lock:
            changed = self._playing != playing
            self._playing  = playing
            last       = self._last_bpm
            collecting = self._collecting
            tid        = self._track_id
        if not playing:
            self._cancel_timer()
        elif changed:
            # Resumed playback of the SAME track.
            if last is not None:
                # We already know the tempo — push it back to the widget right
                # away so it leaves the loading state and keeps the last params,
                # then resume periodic updates.
                if self._on_result:
                    self._on_result(last)
                self._schedule_update()
            elif not collecting and tid:
                # Never got a result yet (e.g. paused during the first analysis)
                # — start a fresh detection now instead of waiting for the timer.
                if self._on_loading:
                    self._on_loading()
                self._spawn_collect(tid)
            else:
                self._schedule_update()

    def stopped(self):
        with self._lock:
            self._track_id = None
            self._playing  = False
            self._last_bpm = None
        self._cancel_timer()

    def _cancel_timer(self):
        if self._update_timer:
            self._update_timer.cancel()
            self._update_timer = None

    def _schedule_update(self):
        self._cancel_timer()
        # Read config fresh — user may have changed settings in tray
        cfg = read_buddy_config()
        if not cfg['update_enabled']:
            return
        with self._lock:
            if not self._playing or not self._track_id:
                return
            tid = self._track_id
        self._update_timer = threading.Timer(cfg['update_rate'], self._periodic_update, args=(tid,))
        self._update_timer.daemon = True
        self._update_timer.start()

    def _periodic_update(self, tid):
        # Re-check config at fire time — user may have disabled updates after timer was set
        cfg = read_buddy_config()
        if not cfg['update_enabled']:
            return
        with self._lock:
            if self._track_id != tid or not self._playing:
                return
        # NOTE: no on_loading() here on purpose. A periodic refresh runs silently
        # in the background while the widget keeps playing its current "active"
        # animation; when the new BPM arrives via on_result the animation simply
        # retunes to it. Only the first analysis of a track shows the loading state.
        self._spawn_collect(tid, periodic=True)

    def _spawn_collect(self, track_id, periodic=False):
        with self._lock:
            self._collecting = True
        t = threading.Thread(target=self._collect, args=(track_id, periodic), daemon=True)
        t.start()

    def _collect(self, track_id, periodic=False):
        device_name = read_device_name()
        pa = pyaudio.PyAudio()
        try:
            dev = find_device(pa, device_name)
            if dev is None:
                log('[bpm] No loopback device found', flush=True)
                return

            rate    = int(dev['defaultSampleRate'])
            ch      = dev['maxInputChannels']
            bufsize = 2048

            stream = pa.open(
                format=pyaudio.paFloat32,
                channels=ch,
                rate=rate,
                input=True,
                input_device_index=dev['index'],
                frames_per_buffer=bufsize
            )

            cfg          = read_buddy_config()
            collect_sec  = cfg['window_sec']
            target_frames = int(rate / bufsize * collect_sec)

            # Read one analysis window from the open stream. Returns mono audio,
            # or None if playback was paused / the track changed mid-capture.
            def read_window():
                frames = []
                for _ in range(target_frames):
                    with self._lock:
                        if self._track_id != track_id or not self._playing:
                            return None
                    data = stream.read(bufsize, exception_on_overflow=False)
                    frames.append(np.frombuffer(data, dtype=np.float32))
                return np.concatenate(frames).reshape(-1, ch).mean(axis=1)

            def measure():
                audio = read_window()
                if audio is None:
                    return False, None   # aborted
                return True, detect_bpm(audio, rate, method=cfg['method'],
                                        min_bpm=cfg['min_bpm'], max_bpm=cfg['max_bpm'])

            log(f'[bpm] Collecting {collect_sec}s via {cfg["method"]} (track={track_id[:8]}...)')
            ok, bpm = measure()
            if not ok:
                stream.close(); return

            # Lock BPM overrange: a first result above the limit is double-checked
            # with ONE more measurement. If it's still above the limit, the tempo
            # is treated as locked-out — the widget stays in the loading animation
            # instead of playing the active animation at a too-high BPM.
            # (Independent of Dynamic update: re-checks just happen on its schedule.)
            if cfg['lock_overrange'] and bpm is not None and bpm > cfg['lock_bpm']:
                log(f'[bpm] {bpm} > lock {cfg["lock_bpm"]} - rechecking once')
                ok2, bpm2 = measure()
                if not ok2:
                    stream.close(); return
                if bpm2 is not None and bpm2 <= cfg['lock_bpm']:
                    bpm = bpm2
                    log(f'[bpm] recheck {bpm2} within limit - accepted')
                else:
                    stream.close()
                    log(f'[bpm] recheck {bpm2} still over {cfg["lock_bpm"]} - locked (loading)')
                    with self._lock:
                        if self._track_id != track_id:
                            return
                        self._last_bpm = None    # don't re-emit a high value on resume
                    if self._on_loading:
                        self._on_loading()       # hold the loading animation
                    self._schedule_update()
                    return

            stream.close()

            if bpm is None:
                log('[bpm] Inconclusive, keeping previous value')
                with self._lock:
                    last = self._last_bpm
                if last is not None and self._on_result:
                    self._on_result(last)   # don't strand the widget on loading
                self._schedule_update()
                return

            with self._lock:
                if self._track_id != track_id:
                    return
                self._last_bpm = bpm

            log(f'[bpm] Result: {bpm} BPM', flush=True)
            if self._on_result:
                self._on_result(bpm)

            # Schedule next periodic update after result
            self._schedule_update()

        except Exception as e:
            log(f'[bpm] Detection error: {e}', flush=True)
        finally:
            with self._lock:
                self._collecting = False
            pa.terminate()

# ── WebSocket client ──────────────────────────────────────────────────────────
detector = BpmDetector()

async def run():
    send_queue = asyncio.Queue()
    loop = asyncio.get_event_loop()

    def on_loading():
        loop.call_soon_threadsafe(send_queue.put_nowait,
            json.dumps({ 'type': 'bpm_loading' }))

    def on_result(bpm):
        rate = round(bpm / BASE_BPM, 4)
        loop.call_soon_threadsafe(send_queue.put_nowait,
            json.dumps({ 'type': 'bpm', 'bpm': bpm, 'base_bpm': BASE_BPM, 'rate': rate }))

    detector.set_callbacks(on_loading, on_result)

    while True:
        try:
            async with websockets.connect(WS_URL) as ws:
                log('[bpm] Connected to server', flush=True)

                async def sender():
                    while True:
                        msg = await send_queue.get()
                        try:
                            await ws.send(msg)
                        except Exception:
                            break

                asyncio.create_task(sender())

                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except Exception:
                        continue

                    if msg.get('type') == 'state':
                        d = msg.get('data', {})
                        tid     = d.get('trackId')
                        playing = bool(d.get('playing', False))

                        if playing and tid:
                            detector.new_track(tid)
                            detector.set_playing(True)
                        elif not playing:
                            detector.set_playing(False)

                    elif msg.get('type') == 'disconnected':
                        detector.stopped()

        except Exception as e:
            log(f'[bpm] Disconnected ({e}), retry in 3s', flush=True)
            await asyncio.sleep(3)

if __name__ == '__main__':
    asyncio.run(run())
