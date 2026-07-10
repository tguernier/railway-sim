## A one-way track segment between two network nodes, represented as a smooth curve.
class_name TrackSegment
extends RefCounted

## The node this segment originates from.
var node_start: NetworkNode
## The node this segment leads to.
var node_end: NetworkNode
## The Bézier curve describing the track path.
var curve: Curve2D

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

## The train currently holding this block, if any. Stored as a weak reference
## (segment → train is a back-reference; the train's route holds the segment).
var _occupying_ref: WeakRef = null
var occupying_train: Train:
	get: return _occupying_ref.get_ref() as Train if _occupying_ref != null else null
	set(t): _occupying_ref = weakref(t) if t != null else null

## Whether this segment is occupied by a station platform.
func is_platform_segment() -> bool:
	return platform != null

## Whether the signal (if any) at this segment's end bounds a reservation
## span for travel along it. A ONE_WAY signal met from behind also counts:
## routing never produces such a crossing, but treating it as a boundary
## keeps a stale route from sailing through against it.
func ends_reservation_span() -> bool:
	if not node_end.is_signal:
		return false
	var dir := Vector2.from_angle(angle_at(1.0))
	return node_end.signal_governs(dir) or node_end.blocks_travel(dir)

## Whether this physical block (this segment or its reverse twin) is held by a
## train other than the given one. Pass null to test for any occupant.
func is_occupied_by_other(train: Train) -> bool:
	if occupying_train != null and occupying_train != train:
		return true
	return reverse != null and reverse.occupying_train != null \
		and reverse.occupying_train != train

## Reserve this block for a train. Fails if another train holds this segment
## or its reverse twin. Re-reserving by the same train succeeds.
func reserve(train: Train) -> bool:
	if is_occupied_by_other(train):
		return false
	occupying_train = train
	return true

## Free this block.
func release() -> void:
	occupying_train = null

## Initialize a track segment between two network nodes, with optional waypoints.
func _init(start: NetworkNode, end: NetworkNode, waypoints: Array[Vector2] = []) -> void:
	node_start = start
	node_end = end
	curve = Curve2D.new()
	_build_curve(waypoints)

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
