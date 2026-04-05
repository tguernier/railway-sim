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
func finish_at(node: NetworkNode) -> void:
	create_bidirectional_track(start_node, node, waypoints)
	cancel()

## Finish drawing to a node, then immediately start a new drawing from that node.
func finish_and_continue(node: NetworkNode) -> void:
	create_bidirectional_track(start_node, node, waypoints)
	start_node = node
	waypoints = []

## Cancel the current drawing.
func cancel() -> void:
	drawing = false
	start_node = null
	waypoints = []

# --- Track operations ---

## Create a bidirectional track between two network nodes.
func create_bidirectional_track(from: NetworkNode, to: NetworkNode, wps: Array[Vector2]) -> void:
	network.add_segment(TrackSegment.new(from, to, wps))
	var reversed_wp: Array[Vector2] = []
	for i in range(wps.size() - 1, -1, -1):
		reversed_wp.append(wps[i])
	network.add_segment(TrackSegment.new(to, from, reversed_wp))

## Split an existing track at a hit point, creating a junction. Returns the new junction node.
func split_track_at_hit(hit: Array) -> NetworkNode:
	var seg: TrackSegment = hit[0]
	var t: float = hit[1]
	var split_pos := seg.position_at(t)
	var junction := NetworkNode.junction(split_pos)
	network.add_node(junction)

	var reverse := find_reverse_segment(seg)

	var wp_first := _sample_curve_waypoints(seg, 0.0, t)
	var wp_second := _sample_curve_waypoints(seg, t, 1.0)

	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)

	create_bidirectional_track(seg.node_start, junction, wp_first)
	create_bidirectional_track(junction, seg.node_end, wp_second)

	return junction

## Try to delete the track at a screen position.
func try_delete_track_at(pos: Vector2) -> void:
	var hit := find_track_at(pos)
	if hit.size() == 0:
		return
	var seg: TrackSegment = hit[0]
	var reverse := find_reverse_segment(seg)
	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)
	network.cleanup_orphan(seg.node_start)
	network.cleanup_orphan(seg.node_end)

## Remove a town and all its connected tracks from the network.
func remove_town(town: Town, towns: Array[Town], train_orders: Array[Town]) -> void:
	var connected: Array = []
	for seg in network.segments:
		if seg.node_start == town.node or seg.node_end == town.node:
			connected.append(seg)
	for seg in connected:
		network.remove_segment(seg)
	for seg in connected:
		if seg.node_start != town.node:
			network.cleanup_orphan(seg.node_start)
		if seg.node_end != town.node:
			network.cleanup_orphan(seg.node_end)
	network.nodes.erase(town.node)
	network._outgoing.erase(town.node)
	towns.erase(town)
	train_orders.erase(town)

# --- Hit testing ---

## Returns the junction node at a screen position, if there is one.
func find_junction_at(pos: Vector2) -> NetworkNode:
	for node in network.nodes:
		if node.is_junction() and pos.distance_to(node.position) < HIT_RADIUS:
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

## Find the reverse of a segment (same endpoints, opposite direction).
func find_reverse_segment(seg: TrackSegment) -> TrackSegment:
	for s in network.segments:
		if s.node_start == seg.node_end and s.node_end == seg.node_start:
			return s
	return null

# --- Internal helpers ---

## Sample interior waypoints from a segment's curve between t_start and t_end.
func _sample_curve_waypoints(seg: TrackSegment, t_start: float, t_end: float) -> Array[Vector2]:
	var wps: Array[Vector2] = []
	var num_samples := 6
	for i in range(1, num_samples):
		var t := t_start + (t_end - t_start) * float(i) / float(num_samples)
		wps.append(seg.position_at(t))
	return wps
