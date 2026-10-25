import { Vec2, Rect2, clamp, segmentIntersectsSegment } from './vec2.js';
import { Curve2D } from './curve2d.js';

// A one-way track segment between two network nodes, represented as a smooth curve.
export class TrackSegment {
  // Distance from a segment endpoint within which an intersection with
  // another track is a junction artefact — two tracks meeting at a turnout —
  // rather than a flat crossing.
  static CROSSING_NODE_CLEARANCE = 12.0;
  // Intersections closer together than this are the same crossing, reported
  // twice because it lands on a shared vertex of the baked polyline.
  static CROSSING_DEDUP_EPSILON = 2.0;

  // Initialize a track segment between two network nodes, with optional waypoints.
  constructor(start, end, waypoints = []) {
    // The node this segment originates from.
    this.nodeStart = start;
    // The node this segment leads to.
    this.nodeEnd = end;
    // The Bézier curve describing the track path.
    this.curve = new Curve2D();
    // Flat crossings (diamonds) this segment's physical track makes with
    // others, registered on all four directed segments of the two tracks.
    this.crossings = [];
    // The platform occupying this segment, if any.
    this.platform = null;
    // The opposite-direction twin of this segment (same physical track).
    this.reverse = null;
    // The train currently holding a movement reservation on this segment.
    this.reservedBy = null;
    // Whether a train traversing this segment finds a path signal at its exit
    // (nodeEnd). The signal is a safe waiting point: a train halts there
    // until it can reserve the track through to the next one. A two-way
    // signal sets this flag on both twins; a one-way signal on only one.
    this.exitSignal = false;
    // For a one-way signal (this segment flagged, its twin not), how the
    // unserved direction is treated: strict by default — barred from routing
    // outright — or loose, merely penalized. Kept false wherever meaningless
    // so the flag pair stays canonical.
    this.looseOneWay = false;
    this._bounds = null;
    if (waypoints !== null) this._buildCurve(waypoints);
  }

  // Copy another segment's signal state onto this one. The two flags always
  // travel together — splits, station placement, and snapshot cloning all
  // move a signal from one segment object to another.
  copySignalFrom(src) {
    this.exitSignal = src.exitSignal;
    this.looseOneWay = src.looseOneWay;
  }

  // Whether this segment is occupied by a station platform.
  isPlatformSegment() {
    return this.platform !== null;
  }

  // Build a segment from an existing curve rather than from waypoints. Used
  // by GameSnapshot, which clones curves directly.
  static fromCurve(start, end, src) {
    const seg = new TrackSegment(start, end, null);
    seg.curve = src.duplicate();
    return seg;
  }

  // Build the curve for a track segment.
  _buildCurve(waypoints) {
    const points = [this.nodeStart.position, ...waypoints, this.nodeEnd.position];
    for (let i = 0; i < points.length; i++) {
      let handleIn = new Vec2();
      let handleOut = new Vec2();
      if (i === 0) {
        const tangent = points[1].sub(points[0]).normalized();
        const dist = points[0].distanceTo(points[1]);
        handleOut = tangent.mul(dist * 0.3);
      } else if (i === points.length - 1) {
        const tangent = points[i].sub(points[i - 1]).normalized();
        const dist = points[i].distanceTo(points[i - 1]);
        handleIn = tangent.mul(-dist * 0.3);
      } else {
        const tangent = points[i + 1].sub(points[i - 1]).normalized();
        const distPrev = points[i].distanceTo(points[i - 1]);
        const distNext = points[i].distanceTo(points[i + 1]);
        handleIn = tangent.mul(-distPrev * 0.3);
        handleOut = tangent.mul(distNext * 0.3);
      }
      this.curve.addPoint(points[i], handleIn, handleOut);
    }
  }

  // Get the length of a track segment.
  length() {
    return this.curve.getBakedLength();
  }

  // Get the position within the curve of point t, where t is between 0 and 1.
  positionAt(t) {
    const total = this.curve.getBakedLength();
    if (total <= 0) return this.nodeStart.position;
    return this.curve.sampleBaked(t * total);
  }

  // Get the angle within the curve of point t, where t is between 0 and 1.
  angleAt(t) {
    const total = this.curve.getBakedLength();
    if (total <= 0) return 0;
    const offset = t * total;
    const epsilon = 1.0;
    const p1 = this.curve.sampleBaked(Math.max(offset - epsilon, 0));
    const p2 = this.curve.sampleBaked(Math.min(offset + epsilon, total));
    return p2.sub(p1).angle();
  }

  // Get baked points along a track segment.
  getBakedPoints() {
    return this.curve.getBakedPoints();
  }

  // Axis-aligned bounds of the baked curve, cached — crossing detection tests
  // every segment against every other, and most pairs are rejected here.
  bounds() {
    if (this._bounds === null) {
      const points = this.curve.getBakedPoints();
      if (points.length === 0) {
        this._bounds = Rect2.fromPoint(this.nodeStart.position);
      } else {
        let b = Rect2.fromPoint(points[0]);
        for (let i = 1; i < points.length; i++) b = b.expand(points[i]);
        this._bounds = b;
      }
    }
    return this._bounds;
  }

  // --- Flat crossings ---

  // Points where two segments' baked curves cross without connecting. Empty
  // for reverse twins and when the bounds miss. Intersections within
  // CROSSING_NODE_CLEARANCE of an endpoint of either segment are discarded: a
  // track terminating on another meets it at a turnout, it does not cross it.
  static crossingPoints(a, b) {
    const found = [];
    if (a === b || a.reverse === b) return found;
    if (!a.bounds().grow(1.0).intersects(b.bounds().grow(1.0))) return found;
    const pa = a.getBakedPoints();
    const pb = b.getBakedPoints();
    if (pa.length < 2 || pb.length < 2) return found;
    const ends = [
      a.nodeStart.position, a.nodeEnd.position,
      b.nodeStart.position, b.nodeEnd.position,
    ];
    for (let i = 0; i < pa.length - 1; i++) {
      for (let j = 0; j < pb.length - 1; j++) {
        const point = segmentIntersectsSegment(pa[i], pa[i + 1], pb[j], pb[j + 1]);
        if (point === null) continue;
        if (nearAny(point, ends, TrackSegment.CROSSING_NODE_CLEARANCE)) continue;
        if (nearAny(point, found, TrackSegment.CROSSING_DEDUP_EPSILON)) continue;
        found.push(point);
      }
    }
    return found;
  }

  // Undirected angle (0..PI/2) at which two segments cross at a point. Taken
  // from each curve's tangent nearest the point, so it is symmetric in the
  // argument order and independent of either track's direction of travel.
  static crossingAngle(a, b, point) {
    const da = tangentNear(a, point);
    const db = tangentNear(b, point);
    if (da.isZero() || db.isZero()) return 0;
    const diff = Math.abs(da.angleTo(db));
    return Math.min(diff, Math.PI - diff);
  }

  // Minimum radius of curvature along the segment, sampled at evenly-spaced
  // points. Uses the circumradius of three consecutive samples to approximate
  // curvature. Returns Infinity for a straight line.
  minRadiusOfCurvature(samples = 20) {
    const total = this.curve.getBakedLength();
    if (total <= 0) return Infinity;
    let minR = Infinity;
    for (let i = 0; i < samples; i++) {
      const t = i / (samples - 1);
      const offset = t * total;
      const step = Math.max(total / samples, 2.0);
      const p0 = this.curve.sampleBaked(Math.max(offset - step, 0));
      const p1 = this.curve.sampleBaked(offset);
      const p2 = this.curve.sampleBaked(Math.min(offset + step, total));
      const r = circumradius(p0, p1, p2);
      if (r < minR) minR = r;
    }
    return minR;
  }
}

// Unit tangent of a segment's curve at the point on it closest to `point`.
function tangentNear(seg, point) {
  const total = seg.length();
  if (total <= 0) return new Vec2();
  const t = clamp(seg.curve.getClosestOffset(point) / total, 0, 1);
  return Vec2.fromAngle(seg.angleAt(t));
}

// Whether a point lies within `dist` of any of a list of positions.
function nearAny(point, others, dist) {
  for (const other of others) {
    if (point.distanceTo(other) < dist) return true;
  }
  return false;
}

// Compute the circumradius of a triangle defined by three points.
// Returns Infinity if the points are collinear.
export function circumradius(p0, p1, p2) {
  const a = p1.sub(p0);
  const b = p2.sub(p0);
  const cross = Math.abs(a.x * b.y - a.y * b.x);
  if (cross < 1e-6) return Infinity;
  const la = a.length();
  const lb = b.length();
  const lc = p2.sub(p1).length();
  return (la * lb * lc) / (2.0 * cross);
}
