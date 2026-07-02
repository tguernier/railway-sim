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
## Set to true after the station stop on the current route leg is done.
var boarded_this_leg := false
## How long the train waits at each station stop, in seconds.
var dwell_time: float = 2.0
## Seconds remaining of the current station stop (0 when moving).
var dwell_remaining: float = 0.0
## Progress on the final route segment where the train halts for its station
## stop (the middle of the platform). -1 when no stop is pending.
var stop_progress: float = -1.0

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
	boarded_this_leg = false
	stop_progress = -1.0

## Check if the train has a route.
func has_route() -> bool:
	return route.size() > 0

## Get current track segment.
func current_segment() -> TrackSegment:
	if route_index < route.size():
		return route[route_index]
	return null

## Move train along a track segment. While dwelling at a station the train
## stays put and the dwell timer counts down instead.
func move(delta: float) -> void:
	if dwell_remaining > 0.0:
		dwell_remaining = maxf(dwell_remaining - delta, 0.0)
		return
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
		# Halt short of the segment end when a station stop is pending on the
		# final segment.
		var target := 1.0
		var is_stop := false
		if route_index == route.size() - 1 and stop_progress >= 0.0 and segment_progress < stop_progress:
			target = stop_progress
			is_stop = true
		var remaining := (target - segment_progress) * seg.length()
		if distance >= remaining:
			distance -= remaining
			segment_progress = target
			if is_stop:
				break  # arrived at the platform stop
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

## Whether the train is at (or past) its pending station stop point.
func at_pending_stop() -> bool:
	return stop_progress >= 0.0 and route.size() > 0 \
		and route_index == route.size() - 1 and segment_progress >= stop_progress

## Resume a freshly set route from a station stop. prev_seg / prev_progress
## describe where the train was stopped; reverse_seg is the opposite-direction
## twin of prev_seg. If the new route leaves along reverse_seg (a dead-end
## station) the train turns around in place — same point, opposite heading —
## otherwise prev_seg is prepended so the train first rolls forward through
## its remainder before joining the new route.
func resume_from_stop(prev_seg: TrackSegment, prev_progress: float, reverse_seg: TrackSegment) -> void:
	if route.size() == 0:
		return
	if route[0] == reverse_seg:
		segment_progress = 1.0 - prev_progress
	else:
		route.insert(0, prev_seg)
		segment_progress = prev_progress

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
