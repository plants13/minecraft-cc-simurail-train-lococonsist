// ws_probe2.js — 验证限速编辑链路: setDefaultLimit / setEdgeLimit → 广播 → 文件
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');

const PORT = parseInt(process.argv[2] || '8090', 10);
const KEY = Buffer.from(String(Math.random())).toString('base64');
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const sock = net.connect(PORT, '127.0.0.1');
let buf = Buffer.alloc(0);

function wsFrame(payload) { const l = payload.length; let h = l < 126 ? Buffer.from([0x81, l]) : Buffer.alloc(4); if (l >= 126) { h[0] = 0x81; h[1] = 126; h.writeUInt16BE(l, 2); } return Buffer.concat([h, payload]); }
function tryFrame(b) { if (b.length < 2) return null; let len = b[1] & 0x7f, h = 2; if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); h = 4; } else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); h = 10; } const t = h + len; if (b.length < t) return null; return { opcode: b[0] & 0x0f, payload: b.slice(h, t), consumed: t }; }

let gotLine = false, done = false, handshaken = false;
function maybeFinish() { if (gotLine && !done) { done = true; const f = JSON.parse(fs.readFileSync('tcc/limits.json', 'utf8')); console.log('limits.json persisted:', JSON.stringify(f)); sock.end(); process.exit(0); } }

sock.write('GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + KEY + '\r\nSec-WebSocket-Version: 13\r\n\r\n');
sock.on('data', d => {
  buf = Buffer.concat([buf, d]);
  if (buf.includes('101 ') && !handshaken) {
    handshaken = true;
    buf = buf.slice(buf.indexOf('\r\n\r\n') + 4);
    console.log('handshake ok, sending get...');
    sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'get' }), 'utf8')));
  }
  for (;;) {
    const f = tryFrame(buf); if (!f) break;
    buf = buf.slice(f.consumed);
    if (f.opcode !== 0x1) continue;
    const m = JSON.parse(f.payload.toString('utf8'));
    console.log('recv:', m.type);
    if (m.type === 'line' && !gotLine) {
      gotLine = true;
      console.log('sending edits...');
      sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'setDefaultLimit', limit: 100 }), 'utf8')));
      const e = m.line.edges[0];
      sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'setEdgeLimit', from: e.from, to: e.to, limit: 45 }), 'utf8')));
    }
    if (m.type === 'limits') {
      console.log('limits broadcast:', JSON.stringify({ defaultLimit: m.defaultLimit, count: Object.keys(m.edges).length, first: Object.entries(m.edges)[0] }));
      setTimeout(maybeFinish, 300);
    }
  }
});
sock.on('error', e => { console.log('ERR', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
