import { Vec2 } from './vec2.js';

// A chain of cubic Bézier spans given as points with in/out handles, baked
// into a polyline with points roughly BAKE_INTERVAL apart. Everything the game reads (length, sampling, closest
// offset) works off the baked polyline.
export const BAKE_INTERVAL = 5.0;
// Samples per span used to measure arc length before even resampling.
const MEASURE_STEPS = 64;

export class Curve2D {
  constructor() {
    // Each: { pos, in, out } — handles relative to pos.
    this.points = [];
    this._baked = null;
    this._dist = null;
  }

  addPoint(pos, handleIn = new Vec2(), handleOut = new Vec2()) {
    this.points.push({ pos, in: handleIn, out: handleOut });
    this._baked = null;
  }

  duplicate() {
    const c = new Curve2D();
    c.points = this.points.map((p) => ({ pos: p.pos, in: p.in, out: p.out }));
    return c;
  }

  _bake() {
    const baked = [];
    const dist = [];
    if (this.points.length === 0) {
      this._baked = baked;
      this._dist = dist;
      return;
    }
    baked.push(this.points[0].pos);
    dist.push(0);
    let total = 0;
    for (let i = 0; i < this.points.length - 1; i++) {
      const p0 = this.points[i].pos;
      const p1 = p0.add(this.points[i].out);
      const p3 = this.points[i + 1].pos;
      const p2 = p3.add(this.points[i + 1].in);
      // Arc-length table for this span.
      const ts = [0];
      const lens = [0];
      let prev = p0;
      let acc = 0;
      for (let k = 1; k <= MEASURE_STEPS; k++) {
        const t = k / MEASURE_STEPS;
        const p = bezier(p0, p1, p2, p3, t);
        acc += p.distanceTo(prev);
        ts.push(t);
        lens.push(acc);
        prev = p;
      }
      if (acc <= 0) continue;
      const n = Math.max(1, Math.ceil(acc / BAKE_INTERVAL));
      let j = 1;
      let last = baked[baked.length - 1];
      for (let k = 1; k <= n; k++) {
        const target = acc * k / n;
        while (j < lens.length - 1 && lens[j] < target) j++;
        const seg = lens[j] - lens[j - 1];
        const f = seg > 0 ? (target - lens[j - 1]) / seg : 0;
        const t = ts[j - 1] + (ts[j] - ts[j - 1]) * f;
        const p = k === n ? p3 : bezier(p0, p1, p2, p3, t);
        total += p.distanceTo(last);
        baked.push(p);
        dist.push(total);
        last = p;
      }
    }
    this._baked = baked;
    this._dist = dist;
  }

  getBakedPoints() {
    if (this._baked === null) this._bake();
    return this._baked;
  }

  getBakedLength() {
    if (this._baked === null) this._bake();
    return this._dist.length ? this._dist[this._dist.length - 1] : 0;
  }

  // Point at a distance along the baked polyline (linear interpolation).
  sampleBaked(offset) {
    const pts = this.getBakedPoints();
    if (pts.length === 0) return new Vec2();
    if (pts.length === 1) return pts[0];
    const d = this._dist;
    const total = d[d.length - 1];
    if (offset <= 0) return pts[0];
    if (offset >= total) return pts[pts.length - 1];
    // Binary search for the span containing offset.
    let lo = 0, hi = d.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (d[mid] <= offset) lo = mid; else hi = mid;
    }
    const span = d[hi] - d[lo];
    const f = span > 0 ? (offset - d[lo]) / span : 0;
    return pts[lo].lerp(pts[hi], f);
  }

  // Offset (distance along the curve) of the baked point closest to p.
  getClosestOffset(p) {
    return this._closest(p).offset;
  }

  getClosestPoint(p) {
    return this._closest(p).point;
  }

  _closest(p) {
    const pts = this.getBakedPoints();
    if (pts.length === 0) return { point: new Vec2(), offset: 0 };
    if (pts.length === 1) return { point: pts[0], offset: 0 };
    let best = Infinity, bestPoint = pts[0], bestOffset = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i], b = pts[i + 1];
      const ab = b.sub(a);
      const len2 = ab.dot(ab);
      let t = len2 > 0 ? p.sub(a).dot(ab) / len2 : 0;
      t = Math.max(0, Math.min(1, t));
      const q = a.add(ab.mul(t));
      const dd = q.distanceTo(p);
      if (dd < best) {
        best = dd;
        bestPoint = q;
        bestOffset = this._dist[i] + (this._dist[i + 1] - this._dist[i]) * t;
      }
    }
    return { point: bestPoint, offset: bestOffset };
  }
}

function bezier(p0, p1, p2, p3, t) {
  const u = 1 - t;
  const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
  return new Vec2(
    a * p0.x + b * p1.x + c * p2.x + d * p3.x,
    a * p0.y + b * p1.y + c * p2.y + d * p3.y,
  );
}
