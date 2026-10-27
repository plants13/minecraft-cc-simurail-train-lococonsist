// ws_probe3.js — 验证备注链路: get 带 notes / setNote → 广播 → notes.json
const net = require('net');
const fs = require('fs');
const KEY = Buffer.from(String(Math.random())).toString('base64');
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const sock = net.connect(8090, '127.0.0.1');
let buf = Buffer.alloc(0), handshaken = false, done = false;

sock.write('GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + KEY + '\r\nSec-WebSocket-Version: 13\r\n\r\n');

function wsFrame(payload) { const l = payload.length; let h = l < 126 ? Buffer.from([0x81, l]) : Buffer.alloc(4); if (l >= 126) { h[0] = 0x81; h[1] = 126; h.writeUInt16BE(l, 2); } return Buffer.concat([h, payload]); }
function tryFrame(b) { if (b.length < 2) return null; let len = b[1] & 0x7f, h = 2; if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); h = 4; } else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); h = 10; } const t = h + len; if (b.length < t) return null; return { opcode: b[0] & 0x0f, payload: b.slice(h, t), consumed: t }; }

sock.on('data', d => {
  buf = Buffer.concat([buf, d]);
  if (buf.includes('101 ') && !handshaken) { handshaken = true; console.log('handshake ok'); buf = buf.slice(buf.indexOf('\r\n\r\n') + 4); sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'get' }), 'utf8'))); }
  for (;;) {
    const f = tryFrame(buf); if (!f) break;
    buf = buf.slice(f.consumed);
    if (f.opcode !== 0x1) continue;
    const m = JSON.parse(f.payload.toString('utf8'));
    console.log('recv:', m.type);
    if (m.type === 'line') {
      console.log('  line.notes present:', !!m.notes, '| stations with note:', Object.keys(m.notes.stations).length);
      const st = m.line.stations[0];
      console.log('  setting note on station', st.id, '...');
      sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'setNote', kind: 'station', id: st.id, note: '测试备注' }), 'utf8')));
    }
    if (m.type === 'notes' && !done) {
      done = true;
      console.log('  notes broadcast:', JSON.stringify(m).slice(0, 120));
      setTimeout(() => {
        const f2 = JSON.parse(fs.readFileSync('tcc/notes.json', 'utf8'));
        console.log('notes.json:', JSON.stringify(f2).slice(0, 120));
        sock.end(); process.exit(0);
      }, 300);
    }
  }
});
sock.on('error', e => { console.log('ERR', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
