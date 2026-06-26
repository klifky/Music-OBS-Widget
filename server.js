// server.js — Music OBS Widget WebSocket server
// Receives data from smtc_reader.py, eq_capture.py, bpm_capture.py

const http = require('http');
const path = require('path');
const fs   = require('fs');
const { WebSocketServer } = require('ws');

const PORT        = 8765;
const CONFIG_FILE = path.join(__dirname, 'widget_config.json');

// ── Theme resolution ──────────────────────────────────────────────────────────
function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch {
    return { widget_theme: 'infinite', eq_theme: 'glowed', buddy_theme: 'default' };
  }
}

const THEME_DIRS     = { widget: 'player_themes', eq: 'eq_themes', buddy: 'jam_buddy_themes' };
const THEME_DEFAULTS = { widget: 'infinite',      eq: 'glowed',    buddy: 'default'          };
const THEME_KEYS     = { widget: 'widget_theme',  eq: 'eq_theme',  buddy: 'buddy_theme'      };

function resolveTheme(type) {
  const config = readConfig();
  const theme  = config[THEME_KEYS[type]] || THEME_DEFAULTS[type];
  return path.join(__dirname, THEME_DIRS[type], theme, 'index.html');
}

// ── HTTP server ───────────────────────────────────────────────────────────────
const STATIC_PREFIXES = ['/player_themes/', '/eq_themes/', '/jam_buddy_themes/'];

const httpServer = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // Static assets inside theme folders
  if (STATIC_PREFIXES.some(p => url.startsWith(p))) {
    const file = path.join(__dirname, url);
    if (!file.startsWith(__dirname)) { res.writeHead(403); res.end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end('Not found'); return; }
      const ext  = path.extname(file).toLowerCase();
      const mime = {
        '.png':'image/png', '.jpg':'image/jpeg', '.jpeg':'image/jpeg',
        '.gif':'image/gif', '.svg':'image/svg+xml', '.webp':'image/webp',
        '.webm':'video/webm', '.mp4':'video/mp4',
        '.css':'text/css', '.js':'application/javascript',
        '.woff2':'font/woff2', '.woff':'font/woff',
      }[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': mime });
      res.end(data);
    });
    return;
  }

  // Theme HTML endpoints
  const routes = {
    '/': 'widget', '/widget': 'widget',
    '/equalizer': 'eq', '/eq': 'eq',
    '/buddy': 'buddy', '/jam-buddy': 'buddy',
  };
  const routeType = routes[url];
  if (routeType !== undefined) {
    const file = resolveTheme(routeType);
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(`Theme file not found: ${file}`); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    });
    return;
  }

  res.writeHead(404); res.end('Not found');
});

// ── WebSocket server ──────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server: httpServer });

const widgetClients = new Set();
let lastState = null;
let lastBpm   = null;  // cache last BPM so buddy gets it on connect
let lastEq    = null;  // cache last EQ frame so a freshly-loaded eq widget can init immediately

wss.on('connection', (ws, req) => {
  const params     = new URL(req.url, 'http://localhost').searchParams;
  const clientType = params.get('client');

  // ── EQ capture ─────────────────────────────────────────────────────────────
  if (clientType === 'eq') {
    console.log('[server] EQ capture connected');
    ws.on('message', (raw) => {
      try {
        const data = JSON.parse(raw.toString());
        if (data.type !== 'eq') return;
        lastEq = data;
        const msg = JSON.stringify(data);
        widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
      } catch (e) {}
    });
    ws.on('close', () => console.log('[server] EQ capture disconnected'));
    return;
  }

  // ── BPM capture ────────────────────────────────────────────────────────────
  if (clientType === 'bpm') {
    console.log('[server] BPM capture connected');
    // Forward state updates to BPM process so it knows when tracks change
    ws.on('message', (raw) => {
      try {
        const data = JSON.parse(raw.toString());
        // bpm_loading and bpm results — forward to all widget clients
        if (data.type === 'bpm' || data.type === 'bpm_loading') {
          if (data.type === 'bpm') lastBpm = data;
          const msg = JSON.stringify(data);
          widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
        }
      } catch (e) {}
    });
    // bpm_capture.py needs state messages to know track changes —
    // register it as a widget client temporarily just for receiving
    widgetClients.add(ws);
    ws.on('close', () => {
      widgetClients.delete(ws);
      console.log('[server] BPM capture disconnected');
    });
    if (lastState) ws.send(JSON.stringify({ type: 'state', data: lastState }));
    return;
  }

  // ── SMTC reader ────────────────────────────────────────────────────────────
  if (clientType === 'smtc') {
    console.log('[server] SMTC reader connected');
    ws.on('message', (raw) => {
      try {
        const data = JSON.parse(raw.toString());
        if (data.artUrl) lastState = data;
        console.log('[track]', data.name, '-', data.artist);
        const msg = JSON.stringify({ type: 'state', data });
        widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
      } catch (e) {
        console.warn('[server] Bad message from SMTC reader:', e.message);
      }
    });
    ws.on('close', () => {
      console.log('[server] SMTC reader disconnected');
      const msg = JSON.stringify({ type: 'disconnected' });
      widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
    });
    return;
  }

  // ── Widget / Buddy client ──────────────────────────────────────────────────
  console.log('[server] Widget connected');
  widgetClients.add(ws);
  if (lastState) ws.send(JSON.stringify({ type: 'state', data: lastState }));
  if (lastBpm)   ws.send(JSON.stringify(lastBpm));
  if (lastEq)    ws.send(JSON.stringify(lastEq));
  ws.on('close', () => {
    widgetClients.delete(ws);
    console.log('[server] Widget disconnected');
  });
});

// ── Start ─────────────────────────────────────────────────────────────────────
httpServer.listen(PORT, '127.0.0.1', () => {
  const cfg = readConfig();
  console.log('\n🎵 Music Widget Server');
  console.log(`   WebSocket  : ws://localhost:${PORT}`);
  console.log(`   Widget URL : http://localhost:${PORT}/widget  (theme: ${cfg.widget_theme || 'infinite'})`);
  console.log(`   EQ URL     : http://localhost:${PORT}/eq      (theme: ${cfg.eq_theme     || 'glowed'})`);
  console.log(`   Buddy URL  : http://localhost:${PORT}/buddy   (theme: ${cfg.buddy_theme  || 'default'})\n`);
});

process.on('SIGINT', () => {
  console.log('\n[server] Stopping...');
  wss.close(); httpServer.close(); process.exit(0);
});
