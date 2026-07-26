## A one-way track segment between two network nodes, represented as a smooth curve.
class_name TrackSegment
extends RefCounted

## Distance from a segment endpoint within which an intersection with another
## track is a junction artefact — two tracks meeting at a turnout — rather
## than a flat crossing.
const CROSSING_NODE_CLEARANCE := 12.0
## Intersections closer together than this are the same crossing, reported
## twice because it lands on a shared vertex of the baked polyline.
const CROSSING_DEDUP_EPSILON := 2.0

## The node this segment originates from.
var node_start: NetworkNode
## The node this segment leads to.
var node_end: NetworkNode
## The Bézier curve describing the track path.
var curve: Curve2D

## Flat crossings (diamonds) this segment's physical track makes with others.
## Held strongly — a TrackCrossing points back at its tracks weakly, so the
## pair does not form a cycle. Registered on all four directed segments of the
## two tracks, so an exclusion lookup from any direction is one array walk.
var crossings: Array[TrackCrossing] = []

var _bounds: Rect2
var _bounds_valid := false

## The platform occupying this segment, if any. Stored as a weak reference to
## avoid cycles (the platform holds a strong reference to its segments).
var _platform_ref: WeakRef = null
var platform: Platform:
	get: return _platform_ref.get_ref() as Platform if _platform_ref != null else null
	set(p): _platform_ref = weakref(p) if p != null else null

## The opposite-direction twin of this segment (same physical track). Stored as
## a weak reference to avoid cycles between the pair. Null for one-way track.
var _reverse_ref: WeakRef = null
var reverse: TrackSegment:
	get: return _reverse_ref.get_ref() as TrackSegment if _reverse_ref != null else null
	set(s): _reverse_ref = weakref(s) if s != null else null

## The train currently holding a movement reservation on this segment. Stored
## as a weak reference to avoid cycles (trains hold their reserved segments
## strongly). Null when the segment is free.
var _reserved_by_ref: WeakRef = null
var reserved_by: Train:
	get: return _reserved_by_ref.get_ref() as Train if _reserved_by_ref != null else null
	set(t): _reserved_by_ref = weakref(t) if t != null else null

## Whether a train traversing this segment finds a path signal at its exit
## (node_end). The signal is a safe waiting point: a train halts there until
## it can reserve the track through to the next one. A two-way signal sets
## this flag on both twins; a one-way signal on only one.
var exit_signal := false

## Whether this segment is occupied by a station platform.
func is_platform_segment() -> bool:
	return platform != null

## Initialize a track segment between two network nodes, with optional waypoints.
func _init(start: NetworkNode, end: NetworkNode, waypoints: Array[Vector2] = []) -> void:
	node_start = start
	node_end = end
	curve = Curve2D.new()
	_build_curve(waypoints)

## Build a segment from an existing curve rather than from waypoints. Used by
## GameSnapshot, which clones curves directly — a segment does not retain its
## waypoint list, so the curve is the source of truth.
static func from_curve(start: NetworkNode, end: NetworkNode, src: Curve2D) -> TrackSegment:
	var seg := TrackSegment.new(start, end)
	seg.curve = src.duplicate()
	seg._bounds_valid = false
	return seg

## Build the curve for a track segment.
func _build_curve(waypoints: Array[Vector2]) -> void:
	var points: Array[Vector2] = []
	points.append(node_start.position)
	for wp in waypoints:
		points.append(wp)
	points.append(node_end.position)

	for i in range(points.size()):
		var handle_in := Vector2.ZERO
		var handle_out := Vector2.ZERO

		if i == 0:
			var tangent := (points[1] - points[0]).normalized()
			var dist := points[0].distance_to(points[1])
			handle_out = tangent * dist * 0.3
		elif i == points.size() - 1:
			var tangent := (points[i] - points[i - 1]).normalized()
			var dist := points[i].distance_to(points[i - 1])
			handle_in = -tangent * dist * 0.3
		else:
			var tangent := (points[i + 1] - points[i - 1]).normalized()
			var dist_prev := points[i].distance_to(points[i - 1])
			var dist_next := points[i].distance_to(points[i + 1])
			handle_in = -tangent * dist_prev * 0.3
			handle_out = tangent * dist_next * 0.3

		curve.add_point(points[i], handle_in, handle_out)

## Get the length of a track segment.
func length() -> float:
	return curve.get_baked_length()

## Get the position within the curve of point t, where t is between 0 and 1.
func position_at(t: float) -> Vector2:
	if curve.get_baked_length() <= 0.0:
		return node_start.position
	return curve.sample_baked(t * curve.get_baked_length())

## Get the angle within the curve of point t, where t is between 0 and 1.
func angle_at(t: float) -> float:
	var total := curve.get_baked_length()
	if total <= 0.0:
		return 0.0
	var offset := t * total
	var epsilon := 1.0
	var p1 := curve.sample_baked(maxf(offset - epsilon, 0.0))
	var p2 := curve.sample_baked(minf(offset + epsilon, total))
	return (p2 - p1).angle()

## Get baked points along a track segment.
func get_baked_points() -> PackedVector2Array:
	return curve.get_baked_points()

## Axis-aligned bounds of the baked curve, cached — crossing detection tests
## every segment against every other, and most pairs are rejected here.
func bounds() -> Rect2:
	if not _bounds_valid:
		var points := curve.get_baked_points()
		if points.size() == 0:
			_bounds = Rect2(node_start.position, Vector2.ZERO)
		else:
			_bounds = Rect2(points[0], Vector2.ZERO)
			for i in range(1, points.size()):
				_bounds = _bounds.expand(points[i])
		_bounds_valid = true
	return _bounds

# --- Flat crossings ---

## Points where two segments' baked curves cross without connecting. Empty for
## reverse twins and when the bounds miss. Intersections within
## CROSSING_NODE_CLEARANCE of an endpoint of either segment are discarded: a
## track terminating on another meets it at a turnout, it does not cross it.
static func crossing_points(a: TrackSegment, b: TrackSegment) -> Array[Vector2]:
	var found: Array[Vector2] = []
	if a == b or a.reverse == b:
		return found
	if not a.bounds().grow(1.0).intersects(b.bounds().grow(1.0)):
		return found
	var pa := a.get_baked_points()
	var pb := b.get_baked_points()
	if pa.size() < 2 or pb.size() < 2:
		return found
	var ends: Array[Vector2] = [
		a.node_start.position, a.node_end.position,
		b.node_start.position, b.node_end.position,
	]
	for i in range(pa.size() - 1):
		for j in range(pb.size() - 1):
			var hit = Geometry2D.segment_intersects_segment(pa[i], pa[i + 1], pb[j], pb[j + 1])
			if hit == null:
				continue
			var point: Vector2 = hit
			if _near_any(point, ends, CROSSING_NODE_CLEARANCE):
				continue
			if _near_any(point, found, CROSSING_DEDUP_EPSILON):
				continue
			found.append(point)
	return found

## Undirected angle (0..PI/2) at which two segments cross at a point. Taken
## from each curve's tangent nearest the point, so it is symmetric in the
## argument order and independent of either track's direction of travel.
static func crossing_angle(a: TrackSegment, b: TrackSegment, point: Vector2) -> float:
	var da := _tangent_near(a, point)
	var db := _tangent_near(b, point)
	if da == Vector2.ZERO or db == Vector2.ZERO:
		return 0.0
	var diff := absf(da.angle_to(db))
	return minf(diff, PI - diff)

## Unit tangent of a segment's curve at the point on it closest to `point`.
static func _tangent_near(seg: TrackSegment, point: Vector2) -> Vector2:
	var total := seg.length()
	if total <= 0.0:
		return Vector2.ZERO
	var t := clampf(seg.curve.get_closest_offset(point) / total, 0.0, 1.0)
	return Vector2.from_angle(seg.angle_at(t))

## Whether a point lies within `dist` of any of a list of positions.
static func _near_any(point: Vector2, others: Array, dist: float) -> bool:
	for other in others:
		if point.distance_to(other) < dist:
			return true
	return false

## Minimum radius of curvature along the segment, sampled at evenly-spaced points.
## Uses the circumradius of three consecutive baked points to approximate curvature.
## Returns INF for a straight line.
func min_radius_of_curvature(samples: int = 20) -> float:
	var total := curve.get_baked_length()
	if total <= 0.0:
		return INF
	var min_r := INF
	for i in range(samples):
		var t := float(i) / float(samples - 1)
		var offset := t * total
		var step := maxf(total / float(samples), 2.0)
		var p0 := curve.sample_baked(maxf(offset - step, 0.0))
		var p1 := curve.sample_baked(offset)
		var p2 := curve.sample_baked(minf(offset + step, total))
		var r := _circumradius(p0, p1, p2)
		if r < min_r:
			min_r = r
	return min_r

## Compute the circumradius of a triangle defined by three points.
## Returns INF if the points are collinear.
static func _circumradius(p0: Vector2, p1: Vector2, p2: Vector2) -> float:
	var a := p1 - p0
	var b := p2 - p0
	var cross := absf(a.x * b.y - a.y * b.x)
	if cross < 1e-6:
		return INF
	var la := a.length()
	var lb := b.length()
	var lc := (p2 - p1).length()
	return (la * lb * lc) / (2.0 * cross)
