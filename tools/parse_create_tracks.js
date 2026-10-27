// parse_create_tracks.js
// External parser for Create's railway save data (create_tracks.dat).
//
// create_tracks.dat = gzipped binary NBT. Schema (from Create source, 1.21.1):
//   root:
//     "RailGraphs"      : list<TrackGraph>
//     "SignalBlocks"    : list<SignalEdgeGroup>
//     "Trains"          : list<Train>          (not extracted)
//     "DimensionPalette": list<{Id: string}>   (dimension name table)
//   TrackGraph:
//     "Id" : uuid, "Color" : int
//     "Nodes": list<{Location, Normal, Connections}>
//       Location = {Pos: int[3] (DOUBLED coords, real = /2), D: dim index, YO: y pixels}
//       Connections = list<{To: node index, EdgeData}>
//         EdgeData: if curve (S-curve/arc): Positions/Starts/Axes/Normals/Primary/Girder/Smoothing/Material
//                   Signals/Points: signal & station references
//     "Points": { "create:signal"|"create:station"|"create:observer": list<...> }
//       TrackEdgePoint = {Id: uuid, Position: double (0..1 along edge), Edge: list<2 TrackNodeLocation>}
//       Station adds "Name"
//
// Usage: node parse_create_tracks.js <file.dat> [out.json]

const fs = require('fs');
const zlib = require('zlib');
let debugDumped = false;

// ---------- NBT (big-endian binary) ----------
const T = { END:0, BYTE:1, SHORT:2, INT:3, LONG:4, FLOAT:5, DOUBLE:6, BYTE_ARR:7, STRING:8, LIST:9, COMPOUND:10, INT_ARR:11, LONG_ARR:12 };

class Reader {
  constructor(b) { this.b = b; this.p = 0; }
  u8()  { return this.b[this.p++]; }
  i8()  { const v = this.b[this.p++]; return v > 127 ? v - 256 : v; }
  u16() { const v = (this.b[this.p] << 8) | this.b[this.p + 1]; this.p += 2; return v; }
  i16() { const v = this.u16(); return v > 32767 ? v - 65536 : v; }
  i32() { const v = this.b.readInt32BE(this.p); this.p += 4; return v; }
  i64() { const hi = this.b.readInt32BE(this.p); const lo = this.b.readUInt32BE(this.p + 4); this.p += 8; return (BigInt(hi) << 32n) | BigInt(lo); }
  f32() { const v = this.b.readFloatBE(this.p); this.p += 4; return v; }
  f64() { const v = this.b.readDoubleBE(this.p); this.p += 8; return v; }
  str(len) { const s = this.b.toString('utf8', this.p, this.p + len); this.p += len; return s; }
  string() { return this.str(this.u16()); }
}

function readTag(r, type) {
  switch (type) {
    case T.BYTE: return r.i8();
    case T.SHORT: return r.i16();
    case T.INT: return r.i32();
    case T.LONG: return r.i64().toString();
    case T.FLOAT: return r.f32();
    case T.DOUBLE: return r.f64();
    case T.STRING: return r.string();
    case T.BYTE_ARR: { const n = r.i32(), a = []; for (let i = 0; i < n; i++) a.push(r.i8()); return a; }
    case T.INT_ARR: { const n = r.i32(), a = []; for (let i = 0; i < n; i++) a.push(r.i32()); return a; }
    case T.LONG_ARR: { const n = r.i32(), a = []; for (let i = 0; i < n; i++) a.push(r.i64().toString()); return a; }
    case T.LIST: { const et = r.u8(), n = r.i32(), a = []; for (let i = 0; i < n; i++) a.push(readTag(r, et)); return a; }
    case T.COMPOUND: { const o = {}; for (;;) { const t = r.u8(); if (t === T.END) break; o[r.string()] = readTag(r, t); } return o; }
    default: throw new Error('unknown NBT type ' + type);
  }
}

function readNBT(buf) {
  const r = new Reader(buf);
  const type = r.u8();
  r.string(); // root name
  return readTag(r, type);
}

// MC UUIDs are int[4]: [mostHi, mostLo, leastHi, leastLo]
function fmtUUID(v) {
  if (!Array.isArray(v) || v.length !== 4) return String(v);
  const most = (BigInt(v[0] << 0) << 32n); // careful with sign
  const m = BigInt(v[0]) << 32n | (BigInt(v[1]) & 0xFFFFFFFFn);
  const l = BigInt(v[2]) << 32n | (BigInt(v[3]) & 0xFFFFFFFFn);
  const hex = (n) => n.toString(16).padStart(16, '0');
  return hex(m) + '-' + hex(l).slice(0, 4) + '-' + hex(l).slice(4, 8) + '-' + hex(l).slice(8, 12) + '-' + hex(l).slice(12);
}

function vec3(v) {
  // old Create: {"V": [x,y,z]} ; newer: {X,Y,Z} ; also bare [x,y,z]
  if (v && Array.isArray(v.V) && v.V.length === 3) return { x: v.V[0], y: v.V[1], z: v.V[2] };
  if (Array.isArray(v) && v.length === 3) return { x: v[0], y: v[1], z: v[2] };
  if (v && typeof v.X === 'number') return { x: v.X, y: v.Y, z: v.Z };
  return { x: 0, y: 0, z: 0 };
}

// TrackNodeLocation: Pos is int[3] at doubled resolution; real = /2, y += YO/16
function nodeLoc(loc) {
  const pos = loc.Pos || [loc.X, loc.Y, loc.Z];
  const yo = loc.YO || 0;
  return { x: pos[0] / 2, y: pos[1] / 2 + yo / 16, z: pos[2] / 2 };
}

function parseTracks(file) {
  const raw = zlib.gunzipSync(fs.readFileSync(file));
  let root = readNBT(raw);
  // world-level SavedData wrapper: {DataVersion, data: <payload>}
  if (root.data && typeof root.data === 'object' && !root.RailGraph && !root.RailGraphs)
    root = root.data;

  const palette = (root.DimensionPalette || []).map(c => c.Id);
  // key may be "RailGraph" (older Create) or "RailGraphs" (current)
  const graphList = root.RailGraphs || root.RailGraph || [];

  const graphs = (graphList || []).map(g => {
    const nodes = (g.Nodes || []).map((n, i) => {
      const conns = (n.Connections || []).map(c => {
        const ed = c.EdgeData || {};
        const curve = ed.Positions ? {
          starts: (ed.Starts || []).map(vec3),
          axes:   (ed.Axes || []).map(vec3),
          primary: !!ed.Primary,
          girder:  !!ed.Girder,
        } : null;
        if (curve && process.env.DEBUG && !debugDumped) {
          debugDumped = true;
          console.log('RAW curve EdgeData:', JSON.stringify(ed));
        }
        return { to: c.To, curve, material: ed.Material || null };
      });
      const loc = nodeLoc(n.Location || {});
      return {
        index: i,
        x: loc.x, y: loc.y, z: loc.z,
        dimension: palette[n.Location && n.Location.D] || '?',
        normal: (n.Normal || []),
        connections: conns,
      };
    });

    const points = {};
    for (const [type, list] of Object.entries(g.Points || {})) {
      points[type] = list.map(p => {
        const o = {
          id: fmtUUID(p.Id),
          position: p.Position,
          edge: (p.Edge || []).map(nodeLoc),
        };
        if (p.Name !== undefined) o.name = p.Name;
        return o;
      });
    }

    return { id: fmtUUID(g.Id), color: g.Color, nodes, points };
  });

  return { dimensionPalette: palette, graphs };
}

// ---------- main ----------
if (require.main === module) {
  const file = process.argv[2] || 'create_tracks.dat';
  const outFile = process.argv[3];
  const data = parseTracks(file);

  if (outFile) fs.writeFileSync(outFile, JSON.stringify(data, null, 2));

  // summary
  console.log('dimensions:', data.dimensionPalette.join(', '));
  for (const g of data.graphs) {
    const sig = (g.points['create:signal'] || []).length;
    const sta = (g.points['create:station'] || []).length;
    let edges = 0, curves = 0;
    for (const n of g.nodes) for (const c of n.connections) { edges++; if (c.curve) curves++; }
    console.log(`graph ${g.id}: nodes=${g.nodes.length} edges=${edges} curves(S/arc)=${curves} signals=${sig} stations=${sta}`);
    if (g.nodes.length && outFile) {
      console.log('  sample node 0:', JSON.stringify(g.nodes[0]));
      const curve = g.nodes.flatMap(n => n.connections).find(c => c.curve);
      if (curve) console.log('  sample curve:', JSON.stringify(curve.curve));
    }
  }
  console.log('output:', outFile || '(none)');
}

module.exports = { parseTracks, nodeLoc, vec3 };
