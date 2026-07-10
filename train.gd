## A train that follows a route of track segments, carrying passengers between towns.
## A train is a consist of cars: the head advances along the route while
## trailing cars are sampled at fixed distances behind it.
class_name Train
extends RefCounted

## Length of one car along the track, in pixels.
const CAR_LENGTH := 26.0
## Coupling gap between consecutive cars, in pixels.
const CAR_GAP := 4.0
## Passenger capacity of one car.
const CAR_CAPACITY := 20

## Ordered list of track segments forming the current route. Array[TrackSegment]
var route: Array = []
## Index of the segment the train is currently traversing.
var route_index: int = 0
## Progress along the current segment, from 0.0 (start) to 1.0 (end).
var segment_progress: float = 0.0
## Segments the head has fully traversed, oldest first — kept only as far back
## as the tail needs so trailing cars can be positioned. Array[TrackSegment]
var history: Array = []
## Number of cars in the consist. The consist must fit within a platform.
var car_count: int = 2
## Travel speed in pixels per second.
var speed: float = 150.0
## Maximum number of passengers the train can carry (all cars combined).
var capacity: int:
	get: return car_count * CAR_CAPACITY
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
## Segments this train holds movement reservations on. Array[TrackSegment]
var reserved: Array = []
## True while the train is halted because the next route segment is held by
## another train (retried every move).
var waiting_for_track := false

## Ordered list of town stops the train visits in a loop. Array[Town]
var orders: Array[Town] = []
## Index into orders for the next stop the train is heading toward.
var current_order_index: int = 0

## Total length of the consist along the track, in pixels.
func consist_length() -> float:
	return car_count * CAR_LENGTH + (car_count - 1) * CAR_GAP

## Initialise a route. Clears the path history: routes are set while the whole
## consist sits on a platform segment (or at simulation start), and
## resume_from_stop() re-anchors the train on that segment afterwards.
##
## new_route: Array[TrackSegment]
func set_route(new_route: Array) -> void:
	release_all()
	route = new_route
	route_index = 0
	segment_progress = 0.0
	history = []
	boarded_this_leg = false
	stop_progress = -1.0
	waiting_for_track = false

## Check if the train has a route.
func has_route() -> bool:
	return route.size() > 0

## Get current track segment.
func current_segment() -> TrackSegment:
	if route_index < route.size():
		return route[route_index]
	return null

## Move train along a track segment. While dwelling at a station the train
## stays put and the dwell timer counts down instead. The head only advances
## onto the next route segment once its reservation is taken; a segment held
## by another train halts the head at the boundary, retried on every move.
func move(delta: float) -> void:
	if dwell_remaining > 0.0:
		dwell_remaining = maxf(dwell_remaining - delta, 0.0)
		return
	if not has_route():
		return
	waiting_for_track = false
	var distance := speed * delta
	while distance > 0.0 and not has_completed_route():
		var seg := current_segment()
		if seg.length() <= 0.0:
			if route_index < route.size() - 1:
				if not _advance_to_next_segment(seg):
					segment_progress = 1.0
					break
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
				if not _advance_to_next_segment(seg):
					break
			else:
				break
		else:
			segment_progress += distance / seg.length()
			distance = 0.0
	_trim_history()

## Advance the head onto the next route segment if its reservation can be
## taken; otherwise flag the train as waiting for track. The traversed segment
## moves into the history so trailing cars can still be positioned on it.
func _advance_to_next_segment(seg: TrackSegment) -> bool:
	if not try_reserve([route[route_index + 1]]):
		waiting_for_track = true
		return false
	history.append(seg)
	route_index += 1
	segment_progress = 0.0
	return true

## Check if train has fully progressed along a track segment.
func has_completed_route() -> bool:
	return route.size() > 0 and route_index >= route.size() - 1 and segment_progress >= 1.0

## Whether the train is at (or past) its pending station stop point.
func at_pending_stop() -> bool:
	return stop_progress >= 0.0 and route.size() > 0 \
		and route_index == route.size() - 1 and segment_progress >= stop_progress

## Resume a freshly set route from a station stop. prev_seg / prev_progress
## describe where the train's head was stopped; reverse_seg is the
## opposite-direction twin of prev_seg. If the new route leaves along
## reverse_seg (a dead-end station) the train turns around: the head takes the
## old tail's spot heading the other way, so the consist occupies the same
## physical span reversed. Otherwise prev_seg is prepended so the train first
## rolls forward through its remainder before joining the new route. Either
## way the whole consist lies on a single known segment afterwards (stops
## always leave the consist entirely on the platform segment).
func resume_from_stop(prev_seg: TrackSegment, prev_progress: float, reverse_seg: TrackSegment) -> void:
	if route.size() == 0:
		return
	if route[0] == reverse_seg:
		var back := consist_length() / prev_seg.length() if prev_seg.length() > 0.0 else 0.0
		segment_progress = clampf(1.0 - (prev_progress - back), 0.0, 1.0)
	else:
		route.insert(0, prev_seg)
		segment_progress = prev_progress

## Position and heading at a point back_offset px behind the head, walking
## back through the current segment and then the history. Clamps at the
## oldest known point, so cars compress there rather than leaving the track
## (only happens transiently right after a route is seeded).
func point_behind(back_offset: float) -> Transform2D:
	var seg := current_segment()
	if seg == null:
		return Transform2D(0.0, Vector2.ZERO)
	var remaining := back_offset
	# Distance of the head into the current segment.
	var available := segment_progress * seg.length()
	var idx := history.size()
	while remaining > available and idx > 0:
		remaining -= available
		idx -= 1
		seg = history[idx]
		available = seg.length()
	var dist := available - minf(remaining, available)
	var t := dist / seg.length() if seg.length() > 0.0 else 0.0
	return Transform2D(seg.angle_at(t), seg.position_at(t))

## Drop history segments the tail can no longer reach, releasing their track
## reservations — the tail clearing a segment is exactly when it frees up.
func _trim_history() -> void:
	var seg := current_segment()
	var behind := segment_progress * seg.length() if seg != null else 0.0
	var keep_from := history.size()
	while keep_from > 0 and behind < consist_length():
		keep_from -= 1
		behind += history[keep_from].length()
	if keep_from > 0:
		var dropped := history.slice(0, keep_from)
		history = history.slice(keep_from)
		for cleared in dropped:
			if not _still_occupies(cleared):
				release(cleared)

## Whether a segment is still under or ahead of the train — a looping route
## can revisit a segment, so a copy dropped from history must not release it.
func _still_occupies(seg: TrackSegment) -> bool:
	if history.has(seg):
		return true
	for i in range(route_index, route.size()):
		if route[i] == seg:
			return true
	return false

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

# --- Track reservations ---

## Reserve every segment for this train, all-or-nothing: if any segment (or
## its reverse twin) is held by another train, nothing is reserved.
##
## segs: Array[TrackSegment]
func try_reserve(segs: Array) -> bool:
	for seg in segs:
		if is_blocked(seg):
			return false
	for seg in segs:
		if seg.reserved_by != self:
			seg.reserved_by = self
			reserved.append(seg)
	return true

## Whether a segment is unavailable to this train: it or its reverse twin is
## reserved by a different train.
func is_blocked(seg: TrackSegment) -> bool:
	if seg.reserved_by != null and seg.reserved_by != self:
		return true
	var rev := seg.reverse
	return rev != null and rev.reserved_by != null and rev.reserved_by != self

## Release one held segment (no-op unless this train is the holder).
func release(seg: TrackSegment) -> void:
	if seg.reserved_by == self:
		seg.reserved_by = null
	reserved.erase(seg)

## Release every reservation this train holds.
func release_all() -> void:
	for seg in reserved:
		if seg.reserved_by == self:
			seg.reserved_by = null
	reserved = []
