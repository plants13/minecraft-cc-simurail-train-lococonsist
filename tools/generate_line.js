// generate_line.js
// Build LKJ line data JSON from create_tracks.dat.
// The line directly records its source graph UUID (create_tracks graphs are
// already sparse: nodes = track connection points, edges = straight/S/arc).
//
// Usage:
//   node tools/generate_line.js <create_tracks.dat> <line-name> [graph-selector] [out.json]
//   graph-selector: graph UUID | "biggest" (default) | "biggest-signals"

const fs = require('fs');
const { parseTracks } = require('./parse_create_tracks');

// ---------- vec3 / bezier helpers ----------
const norm = v => { const l = Math.hypot(v.x, v.y, v.z); return l ? { x: v.x/l, y: v.y/l, z: v.z/l } : { x: 0, y: 0, z: 0 }; };
const add = (a, b) => ({ x: a.x + b.x, y: a.y + b.y, z: a.z + b.z });
const scale = (a, k) => ({ x: a.x*k, y: a.y*k, z: a.z*k });
const dist = (a, b) => Math.hypot(a.x-b.x, a.y-b.y, a.z-b.z);
const dot = (a, b) => a.x*b.x + a.y*b.y + a.z*b.z;

function bezier(p0, c0, c1, p1, t) {
  const u = 1 - t;
  const a = u*u*u, b = 3*u*u*t, c = 3*u*t*t, d = t*t*t;
  return {
    x: a*p0.x + b*c0.x + c*c1.x + d*p1.x,
    y: a*p0.y + b*c0.y + c*c1.y + d*p1.y,
    z: a*p0.z + b*c0.z + c*c1.z + d*p1.z,
  };
}

// Handle length: standard circular-arc approximation (Create uses a similar
// circle fit; close enough for mileage, the train brakes with margins).
function handleLength(end1, end2, axis1, axis2) {
  const d = dist(end1, end2);
  const c = Math.max(-1, Math.min(1, dot(axis1, axis2)));
  const angle = Math.acos(c);
  if (angle < 1e-4) return d / 3;
  const n = 2 * Math.PI / angle;
  const factor = (4 / 3) * Math.tan(Math.PI / (2 * n));
  const radius = d / (2 * Math.sin(angle / 2));
  return Math.max(radius * factor, 1);
}

function curveHandle(curve) {
  const end1 = curve.starts[0], end2 = curve.starts[1];
  const a1 = norm(curve.axes[0]), a2 = norm(curve.axes[1]);
  const h = handleLength(end1, end2, a1, a2);
  return { end1, end2, c0: add(end1, scale(a1, h)), c1: add(end2, scale(a2, h)) };
}

function curveLength(curve) {
  const h = curveHandle(curve);
  let len = 0, prev = h.end1;
  for (let i = 1; i <= 16; i++) {
    const p = bezier(h.end1, h.c0, h.c1, h.end2, i / 16);
    len += dist(prev, p);
    prev = p;
  }
  return len;
}

function curvePoint(curve, t) {
  const h = curveHandle(curve);
  return bezier(h.end1, h.c0, h.c1, h.end2, Math.max(0, Math.min(1, t)));
}

// S-curve: entry/exit tangents roughly parallel; otherwise an arc
function classifyCurve(curve) {
  const a1 = norm(curve.axes[0]), a2 = norm(curve.axes[1]);
  return Math.abs(dot(a1, a2)) > 0.5 ? 's' : 'arc';
}

// ---------- main ----------
const datFile = process.argv[2];
const lineName = process.argv[3] || 'line';
const selector = process.argv[4] || 'biggest';
const outFile = process.argv[5];

if (!datFile) {
  console.log('usage: node generate_line.js <dat> <line-name> [uuid|biggest|biggest-signals] [out.json]');
  process.exit(1);
}

const data = parseTracks(datFile);
let graph;
if (selector === 'biggest')
  graph = data.graphs.reduce((a, b) => (b.nodes.length > a.nodes.length ? b : a));
else if (selector === 'biggest-signals')
  graph = data.graphs.reduce((a, b) =>
    ((b.points['create:signal'] || []).length > (a.points['create:signal'] || []).length ? b : a));
else
  graph = data.graphs.find(g => g.id === selector);
if (!graph) { console.log('graph not found:', selector); process.exit(1); }

const posKey = p => `${p.x},${p.y},${p.z}`;
const nodeIdByPos = new Map();
for (const n of graph.nodes) nodeIdByPos.set(posKey(n), 'n' + n.index);

// dedup edges (each node pair appears twice, once per direction)
const edges = [];
const seen = new Set();
for (const n of graph.nodes) {
  for (const c of n.connections) {
    const a = 'n' + n.index, b = 'n' + c.to;
    const key = a < b ? a + '|' + b : b + '|' + a;
    if (seen.has(key)) continue;
    seen.add(key);
    const na = graph.nodes[n.index], nb = graph.nodes[c.to];
    let length, kind = 'straight';
    if (c.curve) { length = curveLength(c.curve); kind = classifyCurve(c.curve); }
    else length = dist(na, nb);
    edges.push({ from: a, to: b, kind, material: c.material, length: Math.round(length * 100) / 100, curve: c.curve || undefined });
  }
}

// signals / stations: attach to the edge (from/to). The stored Position is a
// DISTANCE in blocks from one end of the edge (Create's getLocationOn: if the
// point's second edge location equals the edge's first node, the distance is
// measured from the far end -> length - position; otherwise -> position).
function extractPoints(type, isStation) {
  return (graph.points[type] || []).map(p => {
    const [pa, pb] = p.edge;
    const ia = nodeIdByPos.get(posKey(pa));
    const ib = nodeIdByPos.get(posKey(pb));
    if (ia === undefined || ib === undefined) return null;
    const edge = edges.find(e => (e.from === ia && e.to === ib) || (e.from === ib && e.to === ia));
    if (!edge) return null;
    const na = graph.nodes.find(n => 'n' + n.index === ia);
    const dFrom = posKey(pb) === posKey(na) ? edge.length - p.position : p.position;
    const t = Math.max(0, Math.min(1, dFrom / edge.length));
    let pos;
    if (edge.curve) pos = curvePoint(edge.curve, t);
    else pos = {
      x: na.x + (graph.nodes.find(n => 'n' + n.index === ib).x - na.x) * t,
      y: na.y + (graph.nodes.find(n => 'n' + n.index === ib).y - na.y) * t,
      z: na.z + (graph.nodes.find(n => 'n' + n.index === ib).z - na.z) * t,
    };
    const o = {
      id: p.id,
      from: ia, to: ib,
      d: Math.round(p.position * 100) / 100,       // stored distance (blocks)
      t: Math.round(t * 1000) / 1000,              // fraction along the edge
      pos: { x: Math.round(pos.x * 100) / 100, y: Math.round(pos.y * 100) / 100, z: Math.round(pos.z * 100) / 100 },
    };
    if (isStation) o.name = p.name;
    return o;
  }).filter(Boolean);
}

const line = {
  line: lineName,
  graph: graph.id,   // 直接记录 graph 号
  nodes: graph.nodes.map(n => ({ id: 'n' + n.index, x: n.x, y: n.y, z: n.z, dimension: n.dimension })),
  edges,
  signals: extractPoints('create:signal', false),
  stations: extractPoints('create:station', true),
};

if (outFile) fs.writeFileSync(outFile, JSON.stringify(line, null, 2));

console.log(`line "${lineName}" <- graph ${graph.id}`);
console.log(`  nodes=${line.nodes.length} edges=${line.edges.length} ` +
  `(s=${line.edges.filter(e => e.kind === 's').length}, arc=${line.edges.filter(e => e.kind === 'arc').length}) ` +
  `signals=${line.signals.length} stations=${line.stations.length}`);
console.log('  output:', outFile || '(stdout only)');
