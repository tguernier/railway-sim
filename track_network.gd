class_name TrackNetwork
extends RefCounted

var segments: Array[TrackSegment] = []
var _outgoing: Dictionary = {}

func add_segment(segment: TrackSegment) -> void:
	segments.append(segment)
	if not _outgoing.has(segment.town_start):
		_outgoing[segment.town_start] = []
	_outgoing[segment.town_start].append(segment)

func get_outgoing(town: Town) -> Array:
	if _outgoing.has(town):
		return _outgoing[town]
	return []

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
