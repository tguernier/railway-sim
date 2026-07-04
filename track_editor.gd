## Handles track drawing state and track manipulation operations on a TrackNetwork.
class_name TrackEditor
extends RefCounted

## The track network this editor operates on.
var network: TrackNetwork
## Whether the player is currently drawing a track.
var drawing := false
## The network node where the current track being drawn starts.
var start_node: NetworkNode = null
## Intermediate waypoints for the track currently being drawn.
var waypoints: Array[Vector2] = []

## Hit-test distance for clicking on a track segment or junction.
const HIT_RADIUS := 15.0
## Minimum allowed radius of curvature for a track segment (in pixels).
const MIN_CURVE_RADIUS := 80.0
## Maximum allowed divergence angle (radians) between a new track and the nearest
## existing track at a shared node (turnout angle). 15 degrees.
const MAX_TURNOUT_ANGLE := deg_to_rad(15.0)
## Half the length of a station platform along the track (in pixels).
const PLATFORM_HALF_LENGTH := 60.0
## Full length of a station platform along the track (in pixels).
const PLATFORM_LENGTH := PLATFORM_HALF_LENGTH * 2.0
## Minimum segment length that can host a platform.
const MIN_STATION_SEGMENT_LENGTH := PLATFORM_LENGTH + 20.0

## Set to true when the last finish attempt was rejected for being too tight.
var last_finish_rejected := false
## Rejection reason: "curve" or "turnout" (set when last_finish_rejected is true).
var rejection_reason := ""
## Human-readable reason the last station/split/delete operation failed.
var last_error := ""

func _init(net: TrackNetwork) -> void:
	network = net

## Start drawing a new track from a node.
func start_drawing(node: NetworkNode) -> void:
	drawing = true
	start_node = node
	waypoints = []

## Add a curve waypoint to the track being drawn.
func add_waypoint(pos: Vector2) -> void:
	waypoints.append(pos)

## Remove the last waypoint from the track being drawn.
func undo_waypoint() -> void:
	if waypoints.size() > 0:
		waypoints.pop_back()

## Finish drawing: create a bidirectional track to the target node and reset.
## Returns false if the curve or turnout angle is invalid (segment not created).
func finish_at(node: NetworkNode) -> bool:
	var reason := _validate_track(start_node, node, waypoints)
	if reason != "":
		last_finish_rejected = true
		rejection_reason = reason
		return false
	last_finish_rejected = false
	rejection_reason = ""
	create_bidirectional_track(start_node, node, waypoints)
	cancel()
	return true

## Finish drawing to a node, then immediately start a new drawing from that node.
## Returns false if the curve or turnout angle is invalid (segment not created).
func finish_and_continue(node: NetworkNode) -> bool:
	var reason := _validate_track(start_node, node, waypoints)
	if reason != "":
		last_finish_rejected = true
		rejection_reason = reason
		return false
	last_finish_rejected = false
	rejection_reason = ""
	create_bidirectional_track(start_node, node, waypoints)
	start_node = node
	waypoints = []
	return true

## Validate a candidate track for curve radius and turnout angle.
## Returns "" if valid, or a reason string ("curve" or "turnout") if invalid.
func _validate_track(from: NetworkNode, to: NetworkNode, wps: Array[Vector2]) -> String:
	var candidate := TrackSegment.new(from, to, wps)
	if candidate.min_radius_of_curvature() < MIN_CURVE_RADIUS:
		return "curve"
	if not _validate_turnout_angle(from, candidate, true) or not _validate_turnout_angle(to, candidate, false):
		return "turnout"
	return ""

## Check that a new segment's departure angle at a node doesn't diverge too much
## from any existing track. `is_start` indicates whether the node is the segment's start.
## Returns true if valid (no existing tracks, or divergence within limit).
func _validate_turnout_angle(node: NetworkNode, seg: TrackSegment, is_start: bool) -> bool:
	var existing := network.departure_angles_at(node)
	if existing.size() == 0:
		return true
	var new_angle: float
	if is_start:
		new_angle = seg.angle_at(0.0)
	else:
		# For the end node, the "departure" direction from that node along this segment
		# is the reverse of the segment's arrival direction.
		new_angle = seg.angle_at(1.0) + PI
	return min_divergence(existing, new_angle) <= MAX_TURNOUT_ANGLE

## Smallest undirected divergence (radians) between new_angle and any of the
## existing departure angles. Both travel directions are considered, since
## every track has a bidirectional partner.
static func min_divergence(existing: Array[float], new_angle: float) -> float:
	var lowest := INF
	for a in existing:
		var diff := absf(angle_difference(a, new_angle))
		var diff_rev := absf(angle_difference(a, new_angle + PI))
		lowest = minf(lowest, minf(diff, diff_rev))
	return lowest

## Compute the smallest signed angle between two angles (range -PI to PI).
static func angle_difference(a: float, b: float) -> float:
	var d := fmod(b - a + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI

## Finish drawing onto a point on an existing track: split the track there and
## connect. The connection is validated BEFORE the split, so a rejected finish
## leaves the network untouched. With continue_after, drawing resumes from the
## new junction (shift+click chain). Returns true on success.
func finish_on_track(hit: Array, continue_after := false) -> bool:
	var seg: TrackSegment = hit[0]
	var t: float = hit[1]
	if seg.is_platform_segment():
		last_error = "Cannot create junctions inside a station"
		return false
	last_error = ""
	var split_pos := seg.position_at(t)
	var candidate := TrackSegment.new(start_node, NetworkNode.junction(split_pos), waypoints)
	var reason := ""
	if candidate.min_radius_of_curvature() < MIN_CURVE_RADIUS:
		reason = "curve"
	elif not _validate_turnout_angle(start_node, candidate, true):
		reason = "turnout"
	else:
		# After the split, the junction's departure angles are the track's
		# tangent at the split point (both directions).
		var track_angles: Array[float] = [seg.angle_at(t)]
		if min_divergence(track_angles, candidate.angle_at(1.0) + PI) > MAX_TURNOUT_ANGLE:
			reason = "turnout"
	if reason != "":
		last_finish_rejected = true
		rejection_reason = reason
		return false
	last_finish_rejected = false
	rejection_reason = ""
	var junction := split_track_at_hit(hit)
	create_bidirectional_track(start_node, junction, waypoints)
	if continue_after:
		start_node = junction
		waypoints = []
	else:
		cancel()
	return true

## Build a preview segment for the current drawing state (used for preview coloring).
func build_preview_segment(mouse: Vector2) -> TrackSegment:
	var end_node := NetworkNode.junction(mouse)
	return TrackSegment.new(start_node, end_node, waypoints)

## Cancel the current drawing. Cleans up the start node if it was a freshly
## placed junction that never got a track.
func cancel() -> void:
	if start_node != null:
		network.cleanup_orphan(start_node)
	drawing = false
	start_node = null
	waypoints = []

# --- Track operations ---

## Create a bidirectional track between two network nodes. The two segments
## are linked as each other's reverse twin.
func create_bidirectional_track(from: NetworkNode, to: NetworkNode, wps: Array[Vector2]) -> void:
	var fwd := TrackSegment.new(from, to, wps)
	var reversed_wp: Array[Vector2] = []
	for i in range(wps.size() - 1, -1, -1):
		reversed_wp.append(wps[i])
	var rev := TrackSegment.new(to, from, reversed_wp)
	fwd.reverse = rev
	rev.reverse = fwd
	network.add_segment(fwd)
	network.add_segment(rev)

## Split an existing track at a hit point, creating a junction. Returns the new
## junction node, or null if the segment is a station platform.
func split_track_at_hit(hit: Array) -> NetworkNode:
	var seg: TrackSegment = hit[0]
	var t: float = hit[1]
	if seg.is_platform_segment():
		last_error = "Cannot create junctions inside a station"
		return null
	last_error = ""
	var split_pos := seg.position_at(t)
	var junction := NetworkNode.junction(split_pos)
	network.add_node(junction)

	var reverse := seg.reverse

	var wp_first := _sample_curve_waypoints(seg, 0.0, t)
	var wp_second := _sample_curve_waypoints(seg, t, 1.0)

	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)

	create_bidirectional_track(seg.node_start, junction, wp_first)
	create_bidirectional_track(junction, seg.node_end, wp_second)

	return junction

## Try to delete the track at a screen position. Platform segments are
## protected — the station must be removed first. Returns true if a track
## pair was deleted.
func try_delete_track_at(pos: Vector2) -> bool:
	var hit := find_track_at(pos)
	if hit.size() == 0:
		return false
	var seg: TrackSegment = hit[0]
	if seg.is_platform_segment():
		last_error = "Remove the station before deleting its platform track"
		return false
	last_error = ""
	var reverse := seg.reverse
	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)
	network.cleanup_orphan(seg.node_start)
	network.cleanup_orphan(seg.node_end)
	return true

## Remove a town from the map. Towns are not graph nodes, so this only needs
## to tear down the town's station (if any) and drop it from the lists.
func remove_town(town: Town, towns: Array[Town], train_orders: Array[Town]) -> void:
	remove_station(town)
	towns.erase(town)
	train_orders.erase(town)

## Remove a town's station: delete its platform segments and clean up the
## entry/exit junctions if nothing else connects to them.
func remove_station(town: Town) -> void:
	if town.station == null:
		return
	for platform in town.station.platforms:
		var fwd: TrackSegment = platform.segment
		network.remove_segment(fwd)
		if platform.reverse_segment != null:
			network.remove_segment(platform.reverse_segment)
		network.cleanup_orphan(fwd.node_start)
		network.cleanup_orphan(fwd.node_end)
	town.station = null

## Build a station on the track at a screen position, inside a town's radius.
## Splits the hit segment into approach tracks and a platform segment with
## entry/exit junctions. Returns the new Station, or null (with last_error set)
## if placement is invalid.
func place_station(pos: Vector2, towns: Array[Town]) -> Station:
	var hit := find_track_at(pos)
	if hit.size() == 0:
		last_error = "Click on a track to place a station"
		return null
	var seg: TrackSegment = hit[0]
	var t: float = hit[1]
	if seg.is_platform_segment():
		last_error = "There is already a platform here"
		return null

	var point := seg.position_at(t)
	var town: Town = null
	var best_dist := INF
	for candidate_town in towns:
		var d := point.distance_to(candidate_town.position)
		if d <= candidate_town.radius and d < best_dist:
			best_dist = d
			town = candidate_town
	if town == null:
		last_error = "Stations must be placed inside a town's circle"
		return null
	if town.station != null:
		last_error = "This town already has a station"
		return null

	var total := seg.length()
	if total < MIN_STATION_SEGMENT_LENGTH:
		last_error = "Track too short for a platform"
		return null

	# Centre the platform span on the click, shifted to fit within the segment.
	var start_off := clampf(t * total - PLATFORM_HALF_LENGTH, 0.0, total - PLATFORM_LENGTH)
	var end_off := start_off + PLATFORM_LENGTH
	# Snap to an existing endpoint when the span ends close to it, to avoid
	# creating tiny stub segments.
	var snap := maxf(total * 0.05, HIT_RADIUS)
	var snap_start := start_off <= snap
	var snap_end := end_off >= total - snap
	var t_start := 0.0 if snap_start else start_off / total
	var t_end := 1.0 if snap_end else end_off / total

	var entry := seg.node_start if snap_start else NetworkNode.junction(seg.position_at(t_start))
	var exit := seg.node_end if snap_end else NetworkNode.junction(seg.position_at(t_end))
	var platform_wps := _sample_curve_waypoints(seg, t_start, t_end)
	var platform_seg := TrackSegment.new(entry, exit, platform_wps)
	if platform_seg.min_radius_of_curvature() < MIN_CURVE_RADIUS:
		last_error = "Track too curved for a platform"
		return null

	# Replace the hit segment with approach tracks + the platform pair.
	var reverse := seg.reverse
	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)
	if not snap_start:
		create_bidirectional_track(seg.node_start, entry, _sample_curve_waypoints(seg, 0.0, t_start))
	if not snap_end:
		create_bidirectional_track(exit, seg.node_end, _sample_curve_waypoints(seg, t_end, 1.0))
	var reversed_wps: Array[Vector2] = []
	for i in range(platform_wps.size() - 1, -1, -1):
		reversed_wps.append(platform_wps[i])
	var platform_rev := TrackSegment.new(exit, entry, reversed_wps)
	platform_seg.reverse = platform_rev
	platform_rev.reverse = platform_seg
	network.add_segment(platform_seg)
	network.add_segment(platform_rev)

	# Draw the platform on the side of the track facing the town.
	var mid := platform_seg.position_at(0.5)
	var perp := Vector2.from_angle(platform_seg.angle_at(0.5)).orthogonal()
	var side := 1.0 if perp.dot(town.position - mid) >= 0.0 else -1.0

	var station := Station.new(town)
	var platform := Platform.new(platform_seg, platform_rev, side)
	platform.station = station
	station.platforms.append(platform)
	platform_seg.platform = platform
	platform_rev.platform = platform
	town.station = station
	last_error = ""
	return station

# --- Hit testing ---

## Returns the junction node at a screen position, if there is one.
func find_junction_at(pos: Vector2) -> NetworkNode:
	for node in network.nodes:
		if pos.distance_to(node.position) < HIT_RADIUS:
			return node
	return null

## Find the closest track segment to a screen position. Returns [segment, t] or [].
func find_track_at(pos: Vector2) -> Array:
	var best_seg: TrackSegment = null
	var best_dist := HIT_RADIUS
	var best_t := 0.0
	var seen: Dictionary = {}
	for seg in network.segments:
		var key_a := "%s-%s" % [seg.node_start.position, seg.node_end.position]
		var key_b := "%s-%s" % [seg.node_end.position, seg.node_start.position]
		if seen.has(key_a) or seen.has(key_b):
			continue
		seen[key_a] = true

		var points := seg.get_baked_points()
		var total_len := seg.length()
		if total_len <= 0.0:
			continue
		var accumulated := 0.0
		for i in range(points.size()):
			var d := pos.distance_to(points[i])
			if d < best_dist:
				best_dist = d
				best_seg = seg
				if i > 0:
					accumulated += points[i].distance_to(points[i - 1])
				best_t = accumulated / total_len
			elif i > 0:
				accumulated += points[i].distance_to(points[i - 1])
	if best_seg != null:
		return [best_seg, best_t]
	return []

# --- Internal helpers ---

## Sample interior waypoints from a segment's curve between t_start and t_end.
func _sample_curve_waypoints(seg: TrackSegment, t_start: float, t_end: float) -> Array[Vector2]:
	var wps: Array[Vector2] = []
	var num_samples := 6
	for i in range(1, num_samples):
		var t := t_start + (t_end - t_start) * float(i) / float(num_samples)
		wps.append(seg.position_at(t))
	return wps
