## Graph of track segments connecting network nodes. Supports pathfinding via Dijkstra.
class_name TrackNetwork
extends RefCounted

## All track segments in the network.
var segments: Array[TrackSegment] = []
## All nodes (towns and junctions) in the network.
var nodes: Array[NetworkNode] = []
## Adjacency list mapping each node to its outgoing segments.
var _outgoing: Dictionary = {}

## Add a network node (town or junction).
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

## Remove a junction node if it has no connections. Returns true if removed.
func cleanup_orphan(node: NetworkNode) -> bool:
	if not node.is_junction():
		return false
	if get_outgoing(node).size() == 0 and get_incoming(node).size() == 0:
		nodes.erase(node)
		_outgoing.erase(node)
		return true
	return false

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
