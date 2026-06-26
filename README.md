# Music OBS Widget (MOBSW)

<a id="en"></a>
**English** · [Русский](#ru)

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
- *(Equalizer only, optional)* a virtual audio loopback such as **[VB-Audio Cable](https://vb-audio.com/Cable/)**. The player and jam-buddy overlays work without it.

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
MOBSW.exe        the app you run (built from source\ — see below)
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

> `MOBSW.exe` is a build output and is **not** committed to the repo (it's in `.gitignore`). Build it locally with the step below, or attach it to a GitHub **Release** for people who just want to download and run.

## About the build

`MOBSW.exe` is produced by `source\build-exe.ps1`, which uses [ps2exe](https://github.com/MScholtes/PS2EXE) (installed automatically on first run) to compile `source\widget-tray.ps1`. The exe gets the `spotobs_on.ico` icon and runs windowless.

On launch the app checks its dependencies: if Node.js or Python is missing it points you to the installers; if only the Node/Python *packages* are missing it offers to run `npm install` / `pip install -r requirements.txt` for you. A virtual audio cable is treated as optional (only the equalizer overlay needs it) and never blocks startup.

> Node.js and Python are **not** bundled into the exe — they must be installed on the machine. The exe is a launcher for the project, not a fully self-contained build, so keep it in the project root next to `server.js`, the theme folders and `assets/`.

## License

MIT — see [LICENSE](LICENSE). *(Add your name to the copyright line.)*

---

<a id="ru"></a>
# Music OBS Widget (MOBSW)

[English](#en) · **Русский**

Оверлеи «сейчас играет» для OBS, которые берут данные из того, что воспроизводится на ПК. Система читает информацию о треке напрямую из медиасессии Windows (SMTC), поэтому работает со Spotify, браузерами и большинством десктопных плееров — без API-ключей и без входа в аккаунт.

В комплекте три типа оверлеев, у каждого есть выбираемые темы, и всё управляется из небольшого приложения в системном трее.

| Оверлей | Адрес | Что показывает |
|---------|-------|----------------|
| **Player** | `http://localhost:8765/widget` | Обложку, название/исполнителя, прогресс |
| **Equalizer** | `http://localhost:8765/eq` | Полоски, реагирующие на звук (нужно устройство петлевого захвата) |
| **Jam Buddy** | `http://localhost:8765/buddy` | Анимированного персонажа, который двигается в такт |

**Темы в комплекте:** player — `infinite` · equalizer — `glowed` · jam buddy — `jamcat`.

> ⚠️ Только Windows. Скрипты захвата используют медиа-API Windows (WinRT/SMTC) и петлевой захват WASAPI.

---

## Как это работает

```
  Медиасессия Windows ─────► smtc_reader.py ─┐
  Петлевой звук ───────────► eq_capture.py ─┼─► server.js (WebSocket :8765) ──► браузер-источники OBS
  Определение бита ────────► bpm_capture.py ┘
```

- **`server.js`** — небольшой Node-сервер с WebSocket и раздачей статики. Принимает данные от Python-скриптов захвата и передаёт их в оверлеи в браузере. Также раздаёт HTML тем и определяет, какую тему использовать, из `widget_config.json`.
- **`smtc_reader.py`** — читает текущий трек (название, исполнитель, обложка, позиция) из медиасессии Windows.
- **`eq_capture.py`** — захватывает системный звук через петлевое устройство и формирует кадры эквалайзера.
- **`bpm_capture.py`** — оценивает BPM, чтобы Jam Buddy двигался в такт.
- **`source/widget-tray.ps1`** — центр управления: иконка в трее с переключателями для каждого компонента, выбором тем/устройства/источника и тумблером автозапуска. Это исходник, из которого собирается **`MOBSW.exe`** — файл, который ты запускаешь.

---

## Требования

- **Windows 10/11**
- **[Node.js](https://nodejs.org/)** (подойдёт LTS)
- **[Python 3.9+](https://www.python.org/)** (при установке отметь «Add Python to PATH»)
- **OBS Studio**
- *(Только для эквалайзера, опционально)* виртуальный петлевой звук, например **[VB-Audio Cable](https://vb-audio.com/Cable/)**. Оверлеи player и jam-buddy работают и без него.

---

## Установка

1. **Клонируй / скачай** репозиторий в папку.
2. **Установи зависимости Node** (из папки проекта):
   ```powershell
   npm install
   ```
3. **Установи зависимости Python:**
   ```powershell
   pip install -r requirements.txt
   ```
4. **Собери приложение** (один раз — создаёт `MOBSW.exe` в корне проекта):
   ```powershell
   powershell -ExecutionPolicy Bypass -File source\build-exe.ps1
   ```
5. **Запусти** двойным кликом по `MOBSW.exe`. Он стартует сервер и скрипты захвата и показывает иконку в трее. При первом запуске проверяет зависимости и предлагает доустановить недостающие пакеты.

6. **Добавь оверлеи в OBS** — добавь источник **«Браузер»** для каждого нужного оверлея:
   - Player: `http://localhost:8765/widget`
   - Equalizer: `http://localhost:8765/eq`
   - Jam Buddy: `http://localhost:8765/buddy`

   Задай ширину/высоту под тему и при желании включи *«Отключать источник, когда не виден»*.

---

## Настройка

Настройки лежат в двух JSON-файлах в корне проекта и обычно меняются через меню в трее, а не вручную:

- **`widget_config.json`** — какую тему использует каждый оверлей, источник музыки и поведение jam-buddy.
- **`eq_config.json`** — устройство, с которого эквалайзер захватывает звук. Значение по умолчанию (`CABLE Input (VB-Audio Virtual Cable)`) рассчитано на VB-Cable; выбери своё устройство из списка в трее.

**Выбор источника** в трее показывает активные медиасессии (вызывает `smtc_reader.py --list`), так что можно нацелить оверлеи на конкретное приложение.

---

## Автозапуск

В меню трея есть тумблер **«Autostart with system»**. Он создаёт ярлык в папке «Автозагрузка», который указывает прямо на `MOBSW.exe` и при входе в систему запускает его тихо (без консольного окна).

---

## Структура проекта

```
MOBSW.exe              приложение, которое ты запускаешь (собирается из source\ — см. ниже)
server.js              сервер WebSocket + статика
smtc_reader.py         данные о треке из медиасессии Windows
eq_capture.py          петлевой звук → кадры эквалайзера
bpm_capture.py         определение бита / BPM
widget_config.json     настройки тем / источника / buddy
eq_config.json         устройство захвата для эквалайзера
assets/                иконки трея и картинки кнопок
player_themes/         темы оверлея player
eq_themes/             темы оверлея equalizer
jam_buddy_themes/      темы оверлея jam-buddy
source/                исходник PowerShell + скрипт сборки
  widget-tray.ps1      исходный код приложения в трее
  build-exe.ps1        собирает widget-tray.ps1 → MOBSW.exe
```

> `MOBSW.exe` — это результат сборки, он **не** коммитится в репозиторий (он в `.gitignore`). Собери его локально шагом выше или приложи к **релизу** на GitHub для тех, кто просто хочет скачать и запустить.

## О сборке

`MOBSW.exe` создаётся скриптом `source\build-exe.ps1`, который использует [ps2exe](https://github.com/MScholtes/PS2EXE) (ставится автоматически при первом запуске) для компиляции `source\widget-tray.ps1`. Exe получает иконку `spotobs_on.ico` и работает без консольного окна.

При запуске приложение проверяет зависимости: если не хватает Node.js или Python — направит к установщикам; если не хватает только *пакетов* Node/Python — предложит выполнить `npm install` / `pip install -r requirements.txt` за тебя. Виртуальный аудиокабель считается опциональным (нужен только эквалайзеру) и никогда не блокирует запуск.

> Node.js и Python **не** встроены в exe — они должны быть установлены в системе. Exe — это лаунчер проекта, а не полностью самодостаточная сборка, поэтому держи его в корне проекта рядом с `server.js`, папками тем и `assets/`.

## Лицензия

MIT — см. [LICENSE](LICENSE). *(Впиши своё имя в строку copyright.)*
