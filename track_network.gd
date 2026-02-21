## Graph of track segments connecting towns. Supports pathfinding via BFS.
class_name TrackNetwork
extends RefCounted

## All track segments in the network.
var segments: Array[TrackSegment] = []
## Adjacency list mapping each town to its outgoing segments. Dictionary[Town, Array[TrackSegment]]
var _outgoing: Dictionary = {}

## Add a track segment to the network.
func add_segment(segment: TrackSegment) -> void:
	segments.append(segment)
	if not _outgoing.has(segment.town_start):
		_outgoing[segment.town_start] = []
	_outgoing[segment.town_start].append(segment)

## Get outgoing track segments from a town.
func get_outgoing(town: Town) -> Array:
	if _outgoing.has(town):
		return _outgoing[town]
	return []

## Find a route between two towns.
func find_route(from: Town, to: Town) -> Array:
	var queue: Array = [[from, []]]
	var visited: Dictionary = {from: true}

	while queue.size() > 0:
		var current: Array = queue.pop_front()
		var town: Town = current[0]
		var path: Array = current[1]

		for seg in get_outgoing(town):
			var next_town: Town = seg.town_end
			var new_path: Array = path.duplicate()
			new_path.append(seg)
			if next_town == to:
				return new_path
			if not visited.has(next_town):
				visited[next_town] = true
				queue.append([next_town, new_path])

	return []
