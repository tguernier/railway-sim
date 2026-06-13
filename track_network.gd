## Graph of track segments connecting network nodes. Supports pathfinding via Dijkstra.
class_name TrackNetwork
extends RefCounted

## All track segments in the network.
var segments: Array[TrackSegment] = []
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

## Find the shortest route from a node to a station platform. The route always
## ends with a traversal of the platform segment (entering at whichever end
## gives the shorter path), so the train passes alongside the platform and
## finishes at its far end.
func find_route_to_platform(from: NetworkNode, platform: Platform) -> Array:
	var entry := platform.segment.node_start
	var exit := platform.segment.node_end
	if from == entry:
		return [platform.segment]
	if from == exit:
		return [platform.reverse_segment]
	var route_a := find_route(from, entry)
	var route_b := find_route(from, exit)
	var len_a := _route_length(route_a) if route_a.size() > 0 else INF
	var len_b := _route_length(route_b) if route_b.size() > 0 else INF
	if is_inf(len_a) and is_inf(len_b):
		return []
	if len_a <= len_b:
		route_a.append(platform.segment)
		return route_a
	route_b.append(platform.reverse_segment)
	return route_b

## Check that a loop of station platforms is fully connected, mirroring how
## dispatch routes the train: start at the far end of the first platform,
## route to each subsequent platform in turn, and finish back at the first.
## Returns the index of the first platform that cannot be reached from the
## stop before it, or -1 if the whole loop is routable. Safe to call whenever
## the network changes (e.g. before starting the simulation, or to revalidate
## orders after the track is edited mid-simulation).
##
## platforms: Array[Platform]
func first_unroutable_stop(platforms: Array) -> int:
	if platforms.size() == 0:
		return -1
	var from_node: NetworkNode = platforms[0].segment.node_end
	for i in range(1, platforms.size() + 1):
		var idx := i % platforms.size()
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

## Find the shortest route between two nodes using Dijkstra (weighted by segment length).
func find_route(from: NetworkNode, to: NetworkNode) -> Array:
	if from == to:
		return []

	# Each entry: [cost, node, path]
	var queue: Array = [[0.0, from, []]]
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

		if visited.has(node):
			continue
		visited[node] = true

		# Check at dequeue time — this is the shortest path to this node
		if node == to:
			return path

		for seg in get_outgoing(node):
			var next_node: NetworkNode = seg.node_end
			if visited.has(next_node):
				continue
			var new_path: Array = path.duplicate()
			new_path.append(seg)
			var new_cost: float = cost + seg.length()
			queue.append([new_cost, next_node, new_path])

	return []
