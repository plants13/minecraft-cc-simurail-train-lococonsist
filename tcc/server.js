// tcc/server.js
// 列车控制中心（上位机）：线路预览 + 限速编辑（多图支持）。
// 零依赖：http 静态服务 + 手写 RFC6455 WebSocket（列控主机以后也用同一 WS 通道拉取线路）。
//
// Usage: node server.js [port] [create_tracks.dat]
//   default port 8090, dat ../create_tracks.dat
//
// WebSocket 协议（JSON 文本帧，所有命令带 graph 图号）：
//   C->S  {type:"getGraphs"}                             图列表（下拉框）
//   C->S  {type:"get", graph?}                           请求线路（缺省=最大图/主环线）
//   C->S  {type:"setDefaultLimit", graph, limit}
//   C->S  {type:"setEdgeLimit", graph, from, to, limit}  limit=null 恢复默认
//   C->S  {type:"setNote", graph, kind:"signal"|"station", id, note}  note 空则清除
//   C->S  {type:"setGraphName", graph, name}              修改图显示名 (name 空则恢复默认)
//   S->C  {type:"graphs", graphs:[{id,name,nodes,signals,stations}]}
//   S->C  {type:"line", graph, line, notes}
//   S->C  {type:"limits", graph, defaultLimit, edges}
//   S->C  {type:"notes", graph, signals, stations}

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parseTracks } = require('../tools/parse_create_tracks');
const { buildLineData } = require('./linegen');

const ROOT = __dirname;
const PORT = parseInt(process.argv[2] || process.env.PORT || '8090', 10);
const DAT_FILE = process.argv[3] || path.join(ROOT, '..', 'create_tracks.dat');
const LIMITS_FILE = path.join(ROOT, 'limits.json');
const NOTES_FILE = path.join(ROOT, 'notes.json');
const NAMES_FILE = path.join(ROOT, 'names.json');

// ---------- 数据 ----------
const data = parseTracks(DAT_FILE);
const biggest = data.graphs.reduce((a, b) => (b.nodes.length > a.nodes.length ? b : a));
const graphNames = {};
data.graphs.forEach((g, i) => { graphNames[g.id] = g.id === biggest.id ? '主环线' : '线路-' + (i + 1); });

// 每图独立状态
const state = { limits: {}, notes: {} };
try {
  const raw = JSON.parse(fs.readFileSync(LIMITS_FILE, 'utf8'));
  if (raw.defaultLimit !== undefined) state.limits[biggest.id] = raw;   // 旧扁平格式迁移到默认图
  else state.limits = raw;
} catch (e) { /* first run */ }
try { state.notes = JSON.parse(fs.readFileSync(NOTES_FILE, 'utf8')); } catch (e) {}
if (typeof state.notes !== 'object' || state.notes === null) state.notes = {};
try { state.names = JSON.parse(fs.readFileSync(NAMES_FILE, 'utf8')); } catch (e) {}
if (typeof state.names !== 'object' || state.names === null) state.names = {};

function graphName(gid) { return state.names[gid] || graphNames[gid] || gid; }
function persistNames() { fs.writeFileSync(NAMES_FILE, JSON.stringify(state.names, null, 2)); }

function graphsPayload() {
  return data.graphs.map(g => ({
    id: g.id, name: graphName(g.id), nodes: g.nodes.length,
    signals: (g.points['create:signal'] || []).length,
    stations: (g.points['create:station'] || []).length,
  }));
}
function broadcastGraphs() { broadcast({ type: 'graphs', graphs: graphsPayload() }); }

const cache = {};
function getLine(gid) {
  if (!cache[gid]) {
    const g = data.graphs.find(x => x.id === gid);
    if (!g) return null;
    cache[gid] = buildLineData(g, graphName(gid));
  }
  return cache[gid];
}
function ensureState(gid) {
  if (!state.limits[gid]) state.limits[gid] = { defaultLimit: 120, edges: {} };
  if (!state.notes[gid]) state.notes[gid] = { signals: {}, stations: {} };
}
const edgeKey = (a, b) => (a < b ? a + '|' + b : b + '|' + a);
function applyLimits(line, gid) {
  const s = state.limits[gid];
  for (const e of line.edges) e.limit = s.edges[edgeKey(e.from, e.to)] ?? s.defaultLimit;
}
function persistLimits() { fs.writeFileSync(LIMITS_FILE, JSON.stringify(state.limits, null, 2)); }
function persistNotes() { fs.writeFileSync(NOTES_FILE, JSON.stringify(state.notes, null, 2)); }

// ---------- WebSocket (RFC 6455, zero-dep) ----------
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const clients = new Set();

function wsAccept(key) { return crypto.createHash('sha1').update(key + WS_GUID).digest('base64'); }
function tryFrame(buf) {
  if (buf.length < 2) return null;
  const b0 = buf[0], b1 = buf[1];
  const opcode = b0 & 0x0f, fin = (b0 & 0x80) !== 0, masked = (b1 & 0x80) !== 0;
  let len = b1 & 0x7f, header = 2;
  if (len === 126) { if (buf.length < 4) return null; len = buf.readUInt16BE(2); header = 4; }
  else if (len === 127) { if (buf.length < 10) return null; len = Number(buf.readBigUInt64BE(2)); header = 10; }
  const total = header + (masked ? 4 : 0) + len;
  if (buf.length < total) return null;
  let off = header, payload;
  if (masked) {
    const mask = buf.slice(off, off + 4); off += 4;
    payload = Buffer.alloc(len);
    for (let i = 0; i < len; i++) payload[i] = buf[off + i] ^ mask[i & 3];
  } else payload = buf.slice(off, off + len);
  return { fin, opcode, payload, consumed: total };
}
function wsFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) header = Buffer.from([0x81, len]);
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([header, payload]);
}
function send(client, buf) { try { client.socket.write(buf); } catch (e) {} }
function broadcast(obj) { const buf = wsFrame(JSON.stringify(obj)); for (const c of clients) send(c, buf); }

function handle(client, f) {
  if (f.opcode === 0x8) { send(client, wsFrame('')); client.socket.end(); return; }
  if (f.opcode === 0x9) { send(client, wsFrame('')); return; }
  if (f.opcode !== 0x1) return;
  let msg;
  try { msg = JSON.parse(f.payload.toString('utf8')); } catch (e) { return; }

  if (msg.type === 'getGraphs') {
    send(client, wsFrame(JSON.stringify({ type: 'graphs', graphs: graphsPayload() })));
  } else if (msg.type === 'get') {
    const gid = String(msg.graph || biggest.id);
    const line = getLine(gid);
    if (!line) return;
    ensureState(gid);
    applyLimits(line, gid);
    send(client, wsFrame(JSON.stringify({ type: 'line', graph: gid, line, notes: state.notes[gid] })));
  } else if (msg.type === 'setDefaultLimit') {
    const gid = String(msg.graph || biggest.id);
    ensureState(gid);
    state.limits[gid].defaultLimit = Math.max(0, Math.min(400, Math.round(Number(msg.limit) || 0)));
    const line = getLine(gid); if (line) applyLimits(line, gid);
    persistLimits();
    broadcast({ type: 'limits', graph: gid, defaultLimit: state.limits[gid].defaultLimit, edges: state.limits[gid].edges });
  } else if (msg.type === 'setEdgeLimit') {
    const gid = String(msg.graph || biggest.id);
    ensureState(gid);
    const key = edgeKey(String(msg.from), String(msg.to));
    if (msg.limit == null) delete state.limits[gid].edges[key];
    else state.limits[gid].edges[key] = Math.max(0, Math.min(400, Math.round(Number(msg.limit) || 0)));
    const line = getLine(gid); if (line) applyLimits(line, gid);
    persistLimits();
    broadcast({ type: 'limits', graph: gid, defaultLimit: state.limits[gid].defaultLimit, edges: state.limits[gid].edges });
  } else if (msg.type === 'setNote') {
    const gid = String(msg.graph || biggest.id);
    ensureState(gid);
    const kind = msg.kind === 'station' ? 'stations' : 'signals';
    const id = String(msg.id || '');
    if (msg.note == null || String(msg.note).trim() === '') delete state.notes[gid][kind][id];
    else state.notes[gid][kind][id] = String(msg.note);
    persistNotes();
    broadcast({ type: 'notes', graph: gid, signals: state.notes[gid].signals, stations: state.notes[gid].stations });
  } else if (msg.type === 'setGraphName') {
    const gid = String(msg.graph || '');
    const nm = msg.name == null ? '' : String(msg.name).trim();
    if (nm === '') delete state.names[gid];
    else state.names[gid] = nm;
    const cached = cache[gid];
    if (cached) cached.line = graphName(gid);
    persistNames();
    broadcastGraphs();
  }
}

// ---------- HTTP ----------
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const url = decodeURIComponent((req.url || '/').split('?')[0]);
  const file = path.join(ROOT, url === '/' ? 'index.html' : path.normalize(url));
  if (file !== ROOT && !file.startsWith(ROOT + path.sep)) { res.writeHead(403); res.end('forbidden'); return; }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('404'); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
});
server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.destroy(); return; }
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + wsAccept(key) + '\r\n\r\n');
  const client = { socket, buffer: Buffer.alloc(0) };
  clients.add(client);
  const drop = () => clients.delete(client);
  socket.on('data', d => {
    client.buffer = Buffer.concat([client.buffer, d]);
    for (;;) { const f = tryFrame(client.buffer); if (!f) break; client.buffer = client.buffer.slice(f.consumed); handle(client, f); }
  });
  socket.on('close', drop);
  socket.on('error', drop);
});

server.listen(PORT, () => {
  console.log('TCC server: http://localhost:' + PORT);
  console.log('dat:', DAT_FILE, '| graphs:', data.graphs.length, '| biggest(主环线):', biggest.id);
});
