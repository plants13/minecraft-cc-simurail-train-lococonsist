// ws_probe4.js — 多图验证: getGraphs → get(具体 graph) → 该图限速
const net = require('net');
const KEY = Buffer.from(String(Math.random())).toString('base64');
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const sock = net.connect(8090, '127.0.0.1');
let buf = Buffer.alloc(0), handshaken = false;

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
    if (m.type === 'graphs') {
      console.log('  graphs:', m.graphs.length, '| first:', JSON.stringify(m.graphs[0]), '| 主环线:', JSON.stringify(m.graphs.find(g => g.name === '主环线')));
      const other = m.graphs.find(g => g.name !== '主环线');
      if (other) { console.log('  requesting graph', other.id.slice(0, 12) + '...'); sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'get', graph: other.id }), 'utf8'))); }
      else sock.end();
    }
    if (m.type === 'line') {
      console.log('  line name:', m.line.line, '| graph:', m.graph, '| nodes:', m.line.nodes.length, '| limit[0]:', m.line.edges[0].limit);
      sock.end();
    }
  }
});
sock.on('error', e => { console.log('ERR', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 10000);
