class_name Train
extends RefCounted

var route: Array = []
var route_index: int = 0
var segment_progress: float = 0.0
var speed: float = 150.0
var capacity: int = 40
var passengers_on_board: int = 0

func set_route(new_route: Array) -> void:
	route = new_route
	route_index = 0
	segment_progress = 0.0

func has_route() -> bool:
	return route.size() > 0

func current_segment() -> TrackSegment:
	if route_index < route.size():
		return route[route_index]
	return null

func move(delta: float) -> void:
	if not has_route():
		return
	var distance := speed * delta
	while distance > 0.0 and not has_completed_route():
		var seg := current_segment()
		if seg.length() <= 0.0:
			if route_index < route.size() - 1:
				route_index += 1
				segment_progress = 0.0
			else:
				segment_progress = 1.0
				break
			continue
		var remaining := (1.0 - segment_progress) * seg.length()
		if distance >= remaining:
			distance -= remaining
			segment_progress = 1.0
			if route_index < route.size() - 1:
				route_index += 1
				segment_progress = 0.0
			else:
				break
		else:
			segment_progress += distance / seg.length()
			distance = 0.0

func has_completed_route() -> bool:
	return route.size() > 0 and route_index >= route.size() - 1 and segment_progress >= 1.0

func current_position() -> Vector2:
	var seg := current_segment()
	if seg == null:
		return Vector2.ZERO
	return seg.position_at(segment_progress)

func current_angle() -> float:
	var seg := current_segment()
	if seg == null:
		return 0.0
	return seg.angle_at(segment_progress)

func destination_town() -> Town:
	if route.size() > 0:
		return route[route.size() - 1].town_end
	return null

func unload() -> int:
	var fare := passengers_on_board
	passengers_on_board = 0
	return fare

func board_from(town: Town) -> void:
	passengers_on_board = town.pickup_passengers(capacity)
