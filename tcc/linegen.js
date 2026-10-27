// tcc/linegen.js — 从 create_tracks 解析出的 graph 构建线路数据（与 tools/generate_line.js 同逻辑）
// buildLineData(graph, lineName) -> { line, graph, nodes[], edges[], signals[], stations[] }

const norm = v => { const l = Math.hypot(v.x, v.y, v.z); return l ? { x: v.x / l, y: v.y / l, z: v.z / l } : { x: 0, y: 0, z: 0 }; };
const add = (a, b) => ({ x: a.x + b.x, y: a.y + b.y, z: a.z + b.z });
const scale = (a, k) => ({ x: a.x * k, y: a.y * k, z: a.z * k });
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
const dot = (a, b) => a.x * b.x + a.y * b.y + a.z * b.z;

function bezier(p0, c0, c1, p1, t) {
  const u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
  return { x: a * p0.x + b * c0.x + c * c1.x + d * p1.x, y: a * p0.y + b * c0.y + c * c1.y + d * p1.y, z: a * p0.z + b * c0.z + c * c1.z + d * p1.z };
}

function handleLength(end1, end2, axis1, axis2) {
  const d = dist(end1, end2);
  const c = Math.max(-1, Math.min(1, dot(axis1, axis2)));
  const angle = Math.acos(c);
  if (angle < 1e-4) return d / 3;
  const n = 2 * Math.PI / angle;
  const factor = (4 / 3) * Math.tan(Math.PI / (2 * n));
  return Math.max((d / (2 * Math.sin(angle / 2))) * factor, 1);
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
  for (let i = 1; i <= 16; i++) { const p = bezier(h.end1, h.c0, h.c1, h.end2, i / 16); len += dist(prev, p); prev = p; }
  return len;
}
function curvePoint(curve, t) {
  const h = curveHandle(curve);
  return bezier(h.end1, h.c0, h.c1, h.end2, Math.max(0, Math.min(1, t)));
}
function classifyCurve(curve) {
  const a1 = norm(curve.axes[0]), a2 = norm(curve.axes[1]);
  return Math.abs(dot(a1, a2)) > 0.5 ? 's' : 'arc';
}

function buildLineData(graph, lineName) {
  const posKey = p => `${p.x},${p.y},${p.z}`;
  const nodeIdByPos = new Map();
  for (const n of graph.nodes) nodeIdByPos.set(posKey(n), 'n' + n.index);

  // 边去重 + 分类 + 长度
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

  // 信号/站台：Position 是沿边距离（块），按 getLocationOn 方向换算 t
  const edgeByKey = new Map(edges.map(e => {
    const ek = e.from < e.to ? e.from + '|' + e.to : e.to + '|' + e.from;
    return [ek, e];
  }));
  function extractPoints(type, isStation) {
    return (graph.points[type] || []).map(p => {
      const [pa, pb] = p.edge;
      const ia = nodeIdByPos.get(posKey(pa));
      const ib = nodeIdByPos.get(posKey(pb));
      if (ia === undefined || ib === undefined) return null;
      const k = ia < ib ? ia + '|' + ib : ib + '|' + ia;
      const edge = edgeByKey.get(k);
      if (!edge) return null;
      const na = graph.nodes.find(n => 'n' + n.index === ia);
      const nb = graph.nodes.find(n => 'n' + n.index === ib);
      const dFrom = posKey(pb) === posKey(na) ? edge.length - p.position : p.position;
      const t = Math.max(0, Math.min(1, dFrom / edge.length));
      let pos;
      if (edge.curve) pos = curvePoint(edge.curve, t);
      else pos = { x: na.x + (nb.x - na.x) * t, y: na.y + (nb.y - na.y) * t, z: na.z + (nb.z - na.z) * t };
      const o = { id: p.id, from: ia, to: ib, d: Math.round(p.position * 100) / 100, t: Math.round(t * 1000) / 1000, pos: { x: Math.round(pos.x * 100) / 100, y: Math.round(pos.y * 100) / 100, z: Math.round(pos.z * 100) / 100 } };
      if (isStation) o.name = p.name;
      return o;
    }).filter(Boolean);
  }

  return {
    line: lineName,
    graph: graph.id,
    nodes: graph.nodes.map(n => ({ id: 'n' + n.index, x: n.x, y: n.y, z: n.z, dimension: n.dimension })),
    edges,
    signals: extractPoints('create:signal', false),
    stations: extractPoints('create:station', true),
  };
}

module.exports = { buildLineData };
