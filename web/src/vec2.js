// Immutable 2D vector — the subset of Godot's Vector2 the game logic uses.
// World coordinates are the original game's pixels: x right, y down.
export class Vec2 {
  constructor(x = 0, y = 0) {
    this.x = x;
    this.y = y;
  }

  static fromAngle(a) {
    return new Vec2(Math.cos(a), Math.sin(a));
  }

  add(o) { return new Vec2(this.x + o.x, this.y + o.y); }
  sub(o) { return new Vec2(this.x - o.x, this.y - o.y); }
  mul(s) { return new Vec2(this.x * s, this.y * s); }
  neg() { return new Vec2(-this.x, -this.y); }
  dot(o) { return this.x * o.x + this.y * o.y; }
  cross(o) { return this.x * o.y - this.y * o.x; }
  length() { return Math.hypot(this.x, this.y); }
  distanceTo(o) { return Math.hypot(this.x - o.x, this.y - o.y); }
  angle() { return Math.atan2(this.y, this.x); }
  equals(o) { return this.x === o.x && this.y === o.y; }
  isZero() { return this.x === 0 && this.y === 0; }

  normalized() {
    const l = this.length();
    return l === 0 ? new Vec2(0, 0) : new Vec2(this.x / l, this.y / l);
  }

  // Godot's Vector2.orthogonal(): rotated 90° counter-clockwise in math
  // terms, i.e. (y, -x).
  orthogonal() { return new Vec2(this.y, -this.x); }

  rotated(a) {
    const c = Math.cos(a), s = Math.sin(a);
    return new Vec2(this.x * c - this.y * s, this.x * s + this.y * c);
  }

  // Signed angle from this vector to o.
  angleTo(o) { return Math.atan2(this.cross(o), this.dot(o)); }

  lerp(o, t) { return new Vec2(this.x + (o.x - this.x) * t, this.y + (o.y - this.y) * t); }
}

export const TAU = Math.PI * 2;

export function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

export function degToRad(d) { return d * Math.PI / 180; }
export function radToDeg(r) { return r * 180 / Math.PI; }

// Godot's global angle_difference(from, to): the shortest signed angle from
// `from` to `to`, in [-PI, PI].
export function angleDifference(from, to) {
  const diff = (to - from) % TAU;
  return ((2 * diff) % TAU) - diff;
}

// Godot's Geometry2D.segment_intersects_segment: the intersection point of
// segments a-b and c-d, or null.
export function segmentIntersectsSegment(a, b, c, d) {
  const r = b.sub(a);
  const s = d.sub(c);
  const denom = r.cross(s);
  if (Math.abs(denom) < 1e-12) return null;
  const ca = c.sub(a);
  const t = ca.cross(s) / denom;
  const u = ca.cross(r) / denom;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return a.add(r.mul(t));
}

// Godot's Rect2 subset: axis-aligned bounds with grow/expand/intersects.
export class Rect2 {
  constructor(minX, minY, maxX, maxY) {
    this.minX = minX; this.minY = minY; this.maxX = maxX; this.maxY = maxY;
  }
  static fromPoint(p) { return new Rect2(p.x, p.y, p.x, p.y); }
  expand(p) {
    return new Rect2(Math.min(this.minX, p.x), Math.min(this.minY, p.y),
      Math.max(this.maxX, p.x), Math.max(this.maxY, p.y));
  }
  grow(by) { return new Rect2(this.minX - by, this.minY - by, this.maxX + by, this.maxY + by); }
  intersects(o) {
    return this.minX < o.maxX && o.minX < this.maxX && this.minY < o.maxY && o.minY < this.maxY;
  }
}

// Array helpers mirroring GDScript's Array.erase / has.
export function erase(arr, item) {
  const i = arr.indexOf(item);
  if (i >= 0) arr.splice(i, 1);
}
