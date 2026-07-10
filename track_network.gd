## Graph of track segments connecting network nodes. Supports pathfinding via Dijkstra.
class_name TrackNetwork
extends RefCounted

## Cost penalty added to segments reserved by another train during
## occupancy-aware routing. A penalty rather than an exclusion: a route must
## still be found when everything is temporarily busy, and the penalty steers
## a train onto free track (e.g. the empty branch of a passing loop).
const OCCUPIED_PENALTY := 100000.0
## Far heavier penalty for a busy segment inside the route's FIRST
## reservation span (before any signal governing the direction of travel).
## Such a route cannot even be started — the train would sit waiting at its
## current spot — so it must lose to any route that is merely busy beyond a
## signal, no matter how many later penalties that route accumulates.
const SPAN_BLOCKED_PENALTY := 1_000_000_000.0

## All track segments in the network.
var segments: Array[TrackSegment] = []
## The live trains, consulted by occupancy-aware routing for the head-on
## opposition penalty (set by main whenever the live world is created or
## swapped in, e.g. on reset or undo). Routing works without it — validation
## calls pass no train and take no penalties.
var trains: Array = []
## All junction nodes in the network.
var nodes: Array[NetworkNode] = []
## Adjacency list mapping each node to its outgoing segments.
var _outgoing: Dictionary = {}

## Add a network node.
func add_node(node: NetworkNode) -> void:
	if not nodes.has(node):
		nodes.append(node)

## Add a track segment to the network (also registers its endpoint nodes).
func add_segment(segment: TrackSegment) -> void:
	segments.append(segment)
	add_node(segment.node_start)
	add_node(segment.node_end)
	if not _outgoing.has(segment.node_start):
		_outgoing[segment.node_start] = []
	_outgoing[segment.node_start].append(segment)

## Remove a track segment from the network.
func remove_segment(segment: TrackSegment) -> void:
	segments.erase(segment)
	if _outgoing.has(segment.node_start):
		_outgoing[segment.node_start].erase(segment)

## Get outgoing track segments from a node.
func get_outgoing(node: NetworkNode) -> Array:
	if _outgoing.has(node):
		return _outgoing[node]
	return []

## Get incoming track segments to a node.
func get_incoming(node: NetworkNode) -> Array:
	var result: Array = []
	for seg in segments:
		if seg.node_end == node:
			result.append(seg)
	return result

## Remove a node if it has no connections. Returns true if removed.
func cleanup_orphan(node: NetworkNode) -> bool:
	if get_outgoing(node).size() == 0 and get_incoming(node).size() == 0:
		nodes.erase(node)
		_outgoing.erase(node)
		return true
	return false

## Get all departure angles (radians) of outgoing segments at a node.
func departure_angles_at(node: NetworkNode) -> Array[float]:
	var angles: Array[float] = []
	for seg in get_outgoing(node):
		angles.append(seg.angle_at(0.0))
	return angles

## Whether a train may enter a segment at its start node — false when a
## one-way signal there faces against the segment's direction of travel.
static func can_enter(seg: TrackSegment) -> bool:
	return not seg.node_start.blocks_travel(Vector2.from_angle(seg.angle_at(0.0)))

## Find the shortest route from a node to a station platform. The route always
## ends with a traversal of the platform segment (entering at whichever end
## gives the shorter path), so the train passes alongside the platform and
## finishes at its far end. An end whose platform traversal starts against a
## one-way signal is not considered. Pass for_train to penalize segments
## reserved by other trains (occupancy-aware dispatch).
func find_route_to_platform(from: NetworkNode, platform: Platform, for_train: Train = null) -> Array:
	var entry := platform.segment.node_start
	var exit := platform.segment.node_end
	if from == entry and can_enter(platform.segment):
		return [platform.segment]
	if from == exit and can_enter(platform.reverse_segment):
		return [platform.reverse_segment]
	var route_a := find_route(from, entry, for_train) if can_enter(platform.segment) else []
	var route_b := find_route(from, exit, for_train) if can_enter(platform.reverse_segment) else []
	var len_a := route_cost(route_a, for_train) if route_a.size() > 0 else INF
	var len_b := route_cost(route_b, for_train) if route_b.size() > 0 else INF
	if is_inf(len_a) and is_inf(len_b):
		return []
	if len_a <= len_b:
		route_a.append(platform.segment)
		return route_a
	route_b.append(platform.reverse_segment)
	return route_b

## Check that a loop of station platforms is fully connected, mirroring how
## dispatch routes the train: start at the far end of the anchor platform
## (the train's home; defaults to the first stop), route to each platform in
## turn, and finish back at the first so the loop closes. Returns the index
## of the first platform that cannot be reached from the stop before it, or
## -1 if the whole loop is routable. Safe to call whenever the network
## changes (e.g. before starting the simulation, or to revalidate orders
## after the track is edited mid-simulation).
##
## platforms: Array[Platform]
func first_unroutable_stop(platforms: Array, anchor: Platform = null) -> int:
	if platforms.size() == 0:
		return -1
	var from_node: NetworkNode
	var stop_indices: Array = []
	if anchor != null:
		from_node = anchor.segment.node_end
		for i in range(platforms.size()):
			stop_indices.append(i)
		stop_indices.append(0)
	else:
		from_node = platforms[0].segment.node_end
		for i in range(1, platforms.size() + 1):
			stop_indices.append(i % platforms.size())
	for idx in stop_indices:
		var route := find_route_to_platform(from_node, platforms[idx])
		if route.size() == 0:
			return idx
		from_node = route[-1].node_end
	return -1

## Total length of a route (array of segments).
func _route_length(route: Array) -> float:
	var total := 0.0
	for seg in route:
		total += seg.length()
	return total

## Blocks that would be traversed against another train's planned direction:
## for every segment still ahead on another live train's route, the reverse
## twin is opposed — entering it means driving at that train head-on inside
## a corridor neither can back out of. A train dwelling at a stop has no
## onward route yet, but its next leg is knowable from its orders, so its
## predicted exit path is opposed too — otherwise a train homing in on that
## platform can park in the only corridor the dweller can leave through and
## wedge both. Penalizing (not excluding) steers dispatch away from oncoming
## traffic before either train commits.
func opposed_blocks(for_train: Train) -> Dictionary:
	var opposed := {}
	if for_train == null:
		return opposed
	for t in trains:
		if t == for_train or t.stalled:
			continue
		for i in range(t.route_index + 1, t.route.size()):
			_oppose(opposed, t.route[i])
		if _terminates_at_stop(t):
			for seg in _predicted_departure(t):
				_oppose(opposed, seg)
	return opposed

## Mark a segment's reverse twin as opposed.
func _oppose(opposed: Dictionary, seg: TrackSegment) -> void:
	if seg.reverse != null:
		opposed[seg.reverse] = true

## Whether the train's current leg ends at a station stop it has yet to
## depart from — while approaching it (stop pending) or serving it (dwell).
func _terminates_at_stop(t: Train) -> bool:
	return t.has_route() and (t.stop_progress >= 0.0 or t.dwell_remaining > 0.0)

## The route a train will most plausibly take when it departs the stop its
## current leg ends at: from that platform toward its next order, as
## _depart_from_stop dispatches it. Computed without penalties (passing no
## train also keeps this from recursing into opposed_blocks) — a plain
## shortest path is prediction enough. Array[TrackSegment].
func _predicted_departure(t: Train) -> Array:
	if t.orders.size() == 0 or not t.has_route():
		return []
	var next_town: Town = t.orders[(t.current_order_index + 1) % t.orders.size()]
	if next_town == null or next_town.station == null \
			or next_town.station.platforms.size() == 0:
		return []
	var last: TrackSegment = t.route[-1]
	return find_route_to_platform(last.node_end, next_town.station.platforms[0])

## Route length plus occupancy and opposition penalties as seen by for_train
## — the same weighting Dijkstra uses, so alternative routes compare
## consistently. Busy segments in the first reservation span carry the
## dominating SPAN_BLOCKED_PENALTY (the route could not even be started).
func route_cost(route: Array, for_train: Train) -> float:
	var opposed := opposed_blocks(for_train)
	var total := 0.0
	var first_span := true
	for seg in route:
		total += seg.length()
		if for_train != null and (seg.is_occupied_by_other(for_train) or opposed.has(seg)):
			total += SPAN_BLOCKED_PENALTY if first_span else OCCUPIED_PENALTY
		first_span = first_span and not seg.ends_reservation_span()
	return total

## Find the shortest route between two nodes using Dijkstra (weighted by
## segment length). Pass for_train to add penalties for segments reserved by
## other trains or opposed by their planned routes, steering the route onto
## free track. The search state carries whether the path is still inside its
## first reservation span (no governing signal crossed yet): a busy segment
## there gets SPAN_BLOCKED_PENALTY instead of OCCUPIED_PENALTY, because such
## a route cannot even be started. The flag is part of the visited key — a
## costlier path that has already crossed a signal can beat a cheaper one
## that is still span-exposed.
func find_route(from: NetworkNode, to: NetworkNode, for_train: Train = null) -> Array:
	if from == to:
		return []

	var opposed := opposed_blocks(for_train)
	# Each entry: [cost, node, path, first_span]
	var queue: Array = [[0.0, from, [], true]]
	var visited: Dictionary = {}

	while queue.size() > 0:
		# Find the lowest-cost entry
		var best_idx := 0
		for i in range(1, queue.size()):
			if queue[i][0] < queue[best_idx][0]:
				best_idx = i
		var current: Array = queue[best_idx]
		queue.remove_at(best_idx)

		var cost: float = current[0]
		var node: NetworkNode = current[1]
		var path: Array = current[2]
		var first_span: bool = current[3]

		if visited.has([node, first_span]):
			continue
		visited[[node, first_span]] = true

		# Check at dequeue time — this is the shortest path to this node
		if node == to:
			return path

		for seg in get_outgoing(node):
			if not can_enter(seg):
				continue
			var next_first: bool = first_span and not seg.ends_reservation_span()
			var next_node: NetworkNode = seg.node_end
			if visited.has([next_node, next_first]):
				continue
			var new_path: Array = path.duplicate()
			new_path.append(seg)
			var new_cost: float = cost + seg.length()
			if for_train != null and (seg.is_occupied_by_other(for_train) or opposed.has(seg)):
				new_cost += SPAN_BLOCKED_PENALTY if first_span else OCCUPIED_PENALTY
			queue.append([new_cost, next_node, new_path, next_first])

	return []
