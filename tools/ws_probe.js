// ws_probe.js — 零依赖 WebSocket 客户端，验证 TCC 服务器全链路
// 用法: node ws_probe.js [port]
const net = require('net');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2] || '8090', 10);
const KEY = Buffer.from(String(Math.random())).toString('base64');
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const sock = net.connect(PORT, '127.0.0.1');
let buf = Buffer.alloc(0);

function wsFrame(payload) {
  const len = payload.length;
  let head;
  if (len < 126) head = Buffer.from([0x81, len]);
  else if (len < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([head, payload]);
}
function tryFrame(b) {
  if (b.length < 2) return null;
  const opcode = b[0] & 0x0f;
  let len = b[1] & 0x7f, header = 2;
  if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); header = 4; }
  else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); header = 10; }
  const total = header + len;
  if (b.length < total) return null;
  return { opcode, payload: b.slice(header, total), consumed: total };
}

sock.write(
  'GET / HTTP/1.1\r\nHost: localhost:' + PORT + '\r\n' +
  'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
  'Sec-WebSocket-Key: ' + KEY + '\r\nSec-WebSocket-Version: 13\r\n\r\n'
);

sock.on('data', d => {
  buf = Buffer.concat([buf, d]);
  // handshake 阶段
  if (buf.includes('101 Switching Protocols')) {
    const expect = crypto.createHash('sha1').update(KEY + GUID).digest('base64');
    const acceptOk = buf.toString('utf8').includes('Sec-WebSocket-Accept: ' + expect);
    console.log('handshake 101:', buf.slice(0, buf.indexOf('\r\n\r\n')).toString().split('\r\n')[0], '| accept OK:', acceptOk);
    if (!acceptOk) process.exit(1);
    buf = buf.slice(buf.indexOf('\r\n\r\n') + 4);
    // 发 get
    sock.write(wsFrame(Buffer.from(JSON.stringify({ type: 'get' }), 'utf8')));
  }
  // 帧阶段
  for (;;) {
    const f = tryFrame(buf);
    if (!f) break;
    buf = buf.slice(f.consumed);
    if (f.opcode === 0x1) {
      const msg = JSON.parse(f.payload.toString('utf8'));
      if (msg.type === 'line') {
        const l = msg.line;
        console.log('got line:', l.line, '| graph:', l.graph);
        console.log('  nodes:', l.nodes.length, 'edges:', l.edges.length,
          'signals:', l.signals.length, 'stations:', l.stations.length);
        console.log('  sample edge:', JSON.stringify(l.edges[0]));
        console.log('  edge limit example:', l.edges[100].limit);
        sock.end();
        process.exit(0);
      }
    } else if (f.opcode === 0x8) { process.exit(0); }
  }
});
sock.on('error', e => { console.log('ERR', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 10000);
