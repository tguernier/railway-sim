## A train that follows a route of track segments, carrying passengers between towns.
class_name Train
extends RefCounted

## Ordered list of track segments forming the current route. Array[TrackSegment]
var route: Array = []
## Index of the segment the train is currently traversing.
var route_index: int = 0
## Progress along the current segment, from 0.0 (start) to 1.0 (end).
var segment_progress: float = 0.0
## Travel speed in pixels per second.
var speed: float = 150.0
## Maximum number of passengers the train can carry.
var capacity: int = 40
## Number of passengers currently aboard.
var passengers_on_board: int = 0

## Ordered list of town stops the train visits in a loop. Array[Town]
var orders: Array[Town] = []
## Index into orders for the next stop the train is heading toward.
var current_order_index: int = 0

## Initialise a route.
##
## new_route: Array[TrackSegment]
func set_route(new_route: Array) -> void:
	route = new_route
	route_index = 0
	segment_progress = 0.0

## Check if the train has a route.
func has_route() -> bool:
	return route.size() > 0

## Get current track segment.
func current_segment() -> TrackSegment:
	if route_index < route.size():
		return route[route_index]
	return null

## Move train along a track segment
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

## Check if train has fully progressed along a track segment.
func has_completed_route() -> bool:
	return route.size() > 0 and route_index >= route.size() - 1 and segment_progress >= 1.0

## Get current train position.
func current_position() -> Vector2:
	var seg := current_segment()
	if seg == null:
		return Vector2.ZERO
	return seg.position_at(segment_progress)

## Get current train angle.
func current_angle() -> float:
	var seg := current_segment()
	if seg == null:
		return 0.0
	return seg.angle_at(segment_progress)

## Get current train destination town (null if destination is a junction).
func destination_town() -> Town:
	if route.size() > 0:
		return route[route.size() - 1].node_end.town
	return null

## Get the town the train is currently heading toward per its orders.
func current_order_town() -> Town:
	if orders.size() == 0:
		return null
	return orders[current_order_index]

## Advance to the next stop in the order list (wraps around).
func advance_order() -> void:
	if orders.size() == 0:
		return
	current_order_index = (current_order_index + 1) % orders.size()

## Unload passengers from train.
func unload() -> int:
	var fare := passengers_on_board
	passengers_on_board = 0
	return fare

## Pickup passengers onto train.
func board_from(town: Town) -> void:
	passengers_on_board = town.pickup_passengers(capacity)
