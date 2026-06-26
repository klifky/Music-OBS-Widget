#!/usr/bin/env python3
# eq_capture.py — WASAPI loopback FFT -> WebSocket
# pip install pyaudiowpatch numpy websocket-client

import pyaudiowpatch as pyaudio
import numpy as np
import websocket, json, threading, time, os, logging

LOG_FILE    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eq_capture.log")
CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eq_config.json")

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger("eq")

WS_URL     = "ws://localhost:8765/?client=eq"
CHUNK      = 2048
SMOOTH     = 0.75
# Per-band scale
SCALE = {
    'b60':   400.0,
    'b150':  120.0,
    'b400':  300.0,
    'k1':    600.0,
    'k2_4':  1200.0,
    'k15':   4000.0,
}

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eq_config.json")

# ── WebSocket ─────────────────────────────────────────────────────────────────
ws_app    = None
connected = False
ws_lock   = threading.Lock()

def send_bands(bands):
    with ws_lock:
        if not connected or not ws_app: return
        try:
            msg = {"type": "eq"}
            msg.update({k: round(v, 4) for k, v in bands.items()})
            ws_app.send(json.dumps(msg))
        except: pass

def on_open(ws):
    global connected; connected = True
    log.info("Connected to server")
def on_close(ws, *a):
    global connected; connected = False
    log.info("Disconnected, reconnecting...")
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
            log.error(f"WS error: {e}")
        time.sleep(3)

# ── FFT ───────────────────────────────────────────────────────────────────────
def get_bands(pcm, rate, channels):
    mono = pcm.reshape(-1, channels).mean(axis=1) if channels > 1 else pcm
    if len(mono) < 64: return 0.0, 0.0, 0.0
    window = np.hanning(len(mono))
    fft    = np.abs(np.fft.rfft(mono * window)) / (len(mono) / 2)
    freqs  = np.fft.rfftfreq(len(mono), d=1.0 / rate)
    def rms(lo, hi, scale):
        idx = np.where((freqs >= lo) & (freqs < hi))[0]
        if not len(idx): return 0.0
        return float(np.clip(np.sqrt(np.mean(fft[idx]**2)) * scale, 0, 1))
    return {
        'b60':  rms(40,    100,  SCALE['b60']),   # kick, bass
        'b150': rms(100,   300,  SCALE['b150']),  # bass body
        'b400': rms(300,   800,  SCALE['b400']),  # low mids
        'k1':   rms(800,   2500, SCALE['k1']),    # mids
        'k2_4': rms(2500,  6000, SCALE['k2_4']),  # presence
        'k15':  rms(6000,  20000,SCALE['k15']),   # air/treble
    }

# ── Find capture device ──────────────────────────────────────────────────────
def load_config():
    """Load saved device name from eq_config.json."""
    try:
        with open(CONFIG_FILE, encoding="utf-8-sig") as f:
            return json.load(f)
    except:
        return {}

def find_loopback(pa):
    """Find loopback device by name from config. Manual selection only."""
    config     = load_config()
    saved_name = config.get("device_name", "")

    if not saved_name:
        log.warning("No device selected. Choose a capture device in the tray.")
        return None

    loopbacks = []
    for i in range(pa.get_device_count()):
        d = pa.get_device_info_by_index(i)
        if d.get("isLoopbackDevice"):
            d["_index"] = i
            loopbacks.append(d)

    for d in loopbacks:
        if saved_name in d["name"]:
            log.info(f"Device: {d['name']}")
            return d

    log.warning(f"Device not found in system: {saved_name}")
    log.warning(f"Available: {[x['name'] for x in loopbacks]}")
    return None

# ── Audio loop ────────────────────────────────────────────────────────────────
def audio_loop():
    pa           = pyaudio.PyAudio()
    smooth       = {k: 0.0 for k in SCALE}
    stream       = None
    current      = None
    current_name = None
    log.info(f"Config: {CONFIG_FILE}")

    while True:
        config_name = load_config().get("device_name", "")
        if not config_name:
            log.warning("No device configured, waiting...")
            time.sleep(2); continue

        # Config changed — force device re-open
        if config_name != current_name:
            if stream:
                try: stream.stop_stream(); stream.close()
                except: pass
            stream = None; current = None; current_name = config_name

        loopback = find_loopback(pa)
        if not loopback:
            time.sleep(3); continue

        dev_index = loopback["_index"]
        if current != dev_index:
            if stream:
                try: stream.stop_stream(); stream.close()
                except: pass
            current  = dev_index
            rate     = int(loopback["defaultSampleRate"])
            channels = loopback["maxInputChannels"]
            log.info(f"Capturing: {loopback['name']} @ {rate} Hz, {channels} ch")
            try:
                stream = pa.open(
                    format=pyaudio.paFloat32,
                    channels=channels,
                    rate=rate,
                    input=True,
                    input_device_index=current,
                    frames_per_buffer=CHUNK,
                )
            except Exception as e:
                log.error(f"Failed to open stream: {e}")
                current = None; time.sleep(3); continue

        try:
            data  = stream.read(CHUNK, exception_on_overflow=False)
            audio = np.frombuffer(data, dtype=np.float32)
            bands = get_bands(audio, rate, channels)
            for k in bands:
                smooth[k] = SMOOTH * smooth.get(k, 0) + (1 - SMOOTH) * bands[k]
            send_bands(smooth)
        except Exception as e:
            log.error(f"Stream error: {e}")
            time.sleep(1); current = None

if __name__ == "__main__":
    log.info("Starting... (Ctrl+C to stop)")
    threading.Thread(target=ws_thread, daemon=True).start()
    time.sleep(1)
    try:
        audio_loop()
    except KeyboardInterrupt:
        log.info("Stopped")
