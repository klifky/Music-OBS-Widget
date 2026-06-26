# Music OBS Widget (MOBSW)

**English** · [Русский](README.ru.md)

Now-playing music overlays for OBS, driven by whatever is playing on your PC. The system reads track info straight from the Windows media session (SMTC), so it works with Spotify, browsers, and most desktop players — no API keys, no login.

It ships three overlay types, each with selectable themes, all managed from a small system-tray app.

| Overlay | Route | What it shows |
|---------|-------|---------------|
| **Player** | `http://localhost:8765/widget` | Album art, title/artist, progress |
| **Equalizer** | `http://localhost:8765/eq` | Audio-reactive bars (needs a loopback capture device) |
| **Jam Buddy** | `http://localhost:8765/buddy` | An animated character that reacts to the beat |

**Themes included:** player — `infinite` · equalizer — `glowed` · jam buddy — `jamcat`.

> ⚠️ Windows only. The capture scripts rely on Windows media APIs (WinRT/SMTC) and WASAPI loopback.

---

## How it works

```
  Windows media session ──► smtc_reader.py ─┐
  Loopback audio ──────────► eq_capture.py ─┼─► server.js (WebSocket :8765) ──► OBS browser sources
  Beat detection ──────────► bpm_capture.py ┘
```

- **`server.js`** — a small Node WebSocket + static server. It receives data from the Python capture scripts and pushes it to the browser overlays. It also serves the theme HTML and resolves which theme to use from `widget_config.json`.
- **`smtc_reader.py`** — reads the current track (title, artist, album art, position) from the Windows media session.
- **`eq_capture.py`** — captures system audio via a loopback device and produces equalizer frames.
- **`bpm_capture.py`** — estimates BPM so the Jam Buddy can move in time.
- **`source/widget-tray.ps1`** — the control center: a tray icon with toggles for each component, theme/device/source pickers, and an autostart switch. This is the source that gets compiled into **`MOBSW.exe`**, the file you actually run.

---

## Requirements

- **Windows 10/11**
- **[Node.js](https://nodejs.org/)** (LTS is fine)
- **[Python 3.9+](https://www.python.org/)** (tick "Add Python to PATH" during install)
- **OBS Studio**
- *(For equalizer and jam buddy only, optional)* a virtual audio loopback such as **[VB-Audio Cable](https://vb-audio.com/Cable/)**. The player works without it.

---

## Setup

1. **Clone / download** this repo into a folder.
2. **Install Node dependencies** (from the project folder):
   ```powershell
   npm install
   ```
3. **Install Python dependencies:**
   ```powershell
   pip install -r requirements.txt
   ```
4. **Build the app** (one time — produces `MOBSW.exe` in the project root):
   ```powershell
   powershell -ExecutionPolicy Bypass -File source\build-exe.ps1
   ```
5. **Run** by double-clicking `MOBSW.exe`. It starts the server and capture scripts and shows a tray icon. On first launch it checks dependencies and offers to install any missing packages for you.

6. **Add overlays in OBS** — add a **Browser** source for each overlay you want:
   - Player: `http://localhost:8765/widget`
   - Equalizer: `http://localhost:8765/eq`
   - Jam Buddy: `http://localhost:8765/buddy`

   Set a width/height that fits the theme, and enable *"Shutdown source when not visible"* if you like.

---

## Configuration

Settings live in two JSON files in the project root and are normally edited through the tray menu, not by hand:

- **`widget_config.json`** — which theme each overlay uses, the music source, and jam-buddy behavior.
- **`eq_config.json`** — the audio device the equalizer captures from. The default (`CABLE Input (VB-Audio Virtual Cable)`) assumes VB-Cable; pick your own device from the tray's device list.

The tray's **source picker** lists active media sessions (it calls `smtc_reader.py --list`) so you can point the overlays at a specific app.

---

## Autostart

The tray menu has an **"Autostart with system"** toggle. It creates a shortcut in your Startup folder pointing straight at `MOBSW.exe`, which launches silently (no console window) at login.

---

## Project layout

```
MOBSW.exe              the app you run (built from source\ — see below)
server.js              WebSocket + static server
smtc_reader.py         track info from Windows media session
eq_capture.py          loopback audio → equalizer frames
bpm_capture.py         beat / BPM estimation
widget_config.json     theme / source / buddy settings
eq_config.json         equalizer capture device
assets/                tray icons and button images
player_themes/         player overlay themes
eq_themes/             equalizer overlay themes
jam_buddy_themes/      jam-buddy overlay themes
source/                PowerShell source + build script
  widget-tray.ps1      tray app source code
  build-exe.ps1        compiles widget-tray.ps1 → MOBSW.exe
```

## About the build

`MOBSW.exe` is produced by `source\build-exe.ps1`, which uses [ps2exe](https://github.com/MScholtes/PS2EXE) (installed automatically on first run) to compile `source\widget-tray.ps1`. The exe gets the `spotobs_on.ico` icon and runs windowless.

On launch the app checks its dependencies: if Node.js or Python is missing it points you to the installers; if only the Node/Python *packages* are missing it offers to run `npm install` / `pip install -r requirements.txt` for you. A virtual audio cable is treated as optional (only the equalizer overlay needs it) and never blocks startup.

## License

MIT — see [LICENSE](LICENSE).
