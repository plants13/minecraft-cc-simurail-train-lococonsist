// ws_probe5.js — 验证 setGraphName → 广播 → names.json
const net = require('net');
const fs = require('fs');
const KEY = Buffer.from(String(Math.random())).toString('base64');
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const sock = net.connect(8090, '127.0.0.1');
let buf = Buffer.alloc(0), handshaken = false, done = false;

function wsFrame(payload) { const l = payload.length; let h = l < 126 ? Buffer.from([0x81, l]) : Buffer.alloc(4); if (l >= 126) { h[0] = 0x81; h[1] = 126; h.writeUInt16BE(l, 2); } return Buffer.concat([h, payload]); }
function tryFrame(b) { if (b.length < 2) return null; let len = b[1] & 0x7f, h = 2; if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); h = 4; } else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); h = 10; } const t = h + len; if (b.length < t) return null; return { opcode: b[0] & 0x0f, payload: b.slice(h, t), consumed: t }; }

sock.write('GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + KEY + '\r\nSec-WebSocket-Version: 13\r\n\r\n');
sock.on('data', d => {
  buf = Buffer.concat([buf, d]);
  if (buf.includes('101 ') && !handshaken) { handshaken = true; buf = buf.slice(buf.indexOf('\r\n\r\n') + 4); sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'getGraphs' }), 'utf8'))); }
  for (;;) {
    const f = tryFrame(buf); if (!f) break;
    buf = buf.slice(f.consumed);
    if (f.opcode !== 0x1) continue;
    const m = JSON.parse(f.payload.toString('utf8'));
    console.log('recv:', m.type);
    if (m.type === 'graphs' && !done) {
      const g = m.graphs.find(x => x.name === '主环线');
      console.log('  graphs:', m.graphs.length, '| with data (signals/stations):', m.graphs.filter(x => x.signals > 0 || x.stations > 0).length, '| 主环线:', !!g);
      if (g) { console.log('  renaming 主环线 -> 测试环线 ...'); sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'setGraphName', graph: g.id, name: '测试环线' }), 'utf8'))); }
      else { sock.end(); process.exit(0); }
    }
    if (m.type === 'graphs' && done) {
      console.log('  after rename, 主环线 exists:', m.graphs.some(x => x.name === '主环线'), '| 测试环线 exists:', m.graphs.some(x => x.name === '测试环线'));
      const f2 = JSON.parse(fs.readFileSync('tcc/names.json', 'utf8'));
      console.log('  names.json:', JSON.stringify(f2).slice(0, 120));
      sock.end(); process.exit(0);
    }
  }
});
sock.on('error', e => { console.log('ERR', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
