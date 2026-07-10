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
## Route index of the last segment in the reserved span ahead of the head.
## -1 when no span is held (the head may not advance until one is reserved).
var reserved_until: int = -1
## True while the train is halted at a safe waiting point because the next
## span could not be reserved (retried every move tick).
var waiting_for_block := false
## True when a mid-simulation dispatch failed and the train was taken out of
## service in place; it keeps its blocks but is no longer processed.
var stalled := false
## True while the train is part of a detected deadlock cycle.
var deadlocked := false

## Ordered list of town stops the train visits in a loop. Array[Town]
var orders: Array[Town] = []
## Index into orders for the next stop the train is heading toward.
var current_order_index: int = 0
## The platform the train was bought at: where it parks between simulation
## runs and starts from when one begins.
var home_platform: Platform = null

## Total length of the consist along the track, in pixels.
func consist_length() -> float:
	return car_count * CAR_LENGTH + (car_count - 1) * CAR_GAP

## Initialise a route. Clears the path history: routes are set while the whole
## consist sits on a platform segment (or at simulation start), and
## resume_from_stop() re-anchors the train on that segment afterwards.
## Blocks the old route held ahead of the head and under the dropped history
## are released; the head's segment stays reserved (the train is still on it).
##
## new_route: Array[TrackSegment]
func set_route(new_route: Array) -> void:
	for i in range(route_index + 1, mini(reserved_until, route.size() - 1) + 1):
		release_block(route[i])
	for seg in history:
		release_block(seg)
	route = new_route
	route_index = 0
	segment_progress = 0.0
	history = []
	boarded_this_leg = false
	stop_progress = -1.0
	reserved_until = -1
	waiting_for_block = false

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
##
## Path reservation: the head may only be on (or advance into) segments of an
## atomically reserved span, which runs from one safe waiting point to the
## next (a signal node or the final platform). When the next span cannot be
## reserved the train holds at the boundary — a platform on departure, or a
## signal mid-route — and retries every tick.
func move(delta: float) -> void:
	if dwell_remaining > 0.0:
		dwell_remaining = maxf(dwell_remaining - delta, 0.0)
		return
	if not has_route():
		return
	# Departure gate: after set_route no span is held yet; the first span must
	# be reserved before the train leaves its waiting point at all.
	if route_index > reserved_until and not _try_reserve_span(route_index):
		waiting_for_block = true
		return
	waiting_for_block = false
	var distance := speed * delta
	while distance > 0.0 and not has_completed_route():
		var seg := current_segment()
		if seg.length() <= 0.0:
			if route_index < route.size() - 1:
				if not _advance_to_next_segment():
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
				if not _advance_to_next_segment():
					break
			else:
				break
		else:
			segment_progress += distance / seg.length()
			distance = 0.0
	_trim_history()

## Step the head into the next route segment, reserving the next span first
## when the boundary being crossed ends the held one. Returns false (and
## flags the wait) if the span is unavailable — the head stays clamped at the
## boundary, which is always a safe waiting point (signal or platform end).
func _advance_to_next_segment() -> bool:
	if route_index + 1 > reserved_until and not _try_reserve_span(route_index + 1):
		waiting_for_block = true
		return false
	history.append(route[route_index])
	route_index += 1
	segment_progress = 0.0
	return true

## Index of the last segment of the span starting at from_idx: the route is
## walked until a segment ends at a signal governing this direction of travel
## or the route ends (the final platform — spans always finish on a safe
## waiting point). A directional signal met from behind is not a boundary.
func _span_end(from_idx: int) -> int:
	var i := from_idx
	while i < route.size() - 1 and not _signal_boundary(route[i]):
		i += 1
	return i

## Whether the signal (if any) at the end of seg bounds a reservation span
## for travel along seg.
func _signal_boundary(seg: TrackSegment) -> bool:
	return seg.ends_reservation_span()

## Atomically reserve every segment of the span starting at from_idx:
## all-or-nothing, rolling back on partial failure so a failed attempt
## leaves no stray claims.
func _try_reserve_span(from_idx: int) -> bool:
	if from_idx >= route.size():
		return true
	var end := _span_end(from_idx)
	var newly_reserved: Array = []
	for i in range(from_idx, end + 1):
		var seg: TrackSegment = route[i]
		if seg.occupying_train == self:
			continue  # already part of this train's footprint
		if not seg.reserve(self):
			for taken in newly_reserved:
				taken.release()
			return false
		newly_reserved.append(seg)
	reserved_until = end
	return true

## Replace the route beyond anchor with tail (a route continuing from
## route[anchor].node_end). When the anchor cuts into the reserved span the
## span is shrunk: the continuation along the new tail (up to its first
## signal boundary) is reserved BEFORE the abandoned blocks are released, so
## the held span never stops ending on a safe waiting point. All-or-nothing:
## on failure the old route and reservation are kept. Returns success.
##
## tail: Array[TrackSegment]
func adopt_route_tail(anchor: int, tail: Array) -> bool:
	var new_route: Array = route.slice(0, anchor + 1)
	new_route.append_array(tail)
	if anchor >= reserved_until:
		# Nothing is reserved beyond the anchor — a pure plan change.
		route = new_route
		return true
	var old_route: Array = route
	var old_reserved := reserved_until
	route = new_route
	reserved_until = anchor
	if not _try_reserve_span(anchor + 1):
		route = old_route
		reserved_until = old_reserved
		return false
	for i in range(anchor + 1, mini(old_reserved, old_route.size() - 1) + 1):
		var seg: TrackSegment = old_route[i]
		if not route.has(seg):
			release_block(seg)
	return true

## Claim the first span of a freshly dispatched leg immediately, before the
## train leaves the platform. Doing this at dispatch (rather than on the next
## move tick) makes the claim visible to other trains' occupancy-aware
## routing right away — the second train dispatched steers around it. On
## failure the train stays put; move() retries every tick.
func reserve_departure_span() -> void:
	waiting_for_block = not _try_reserve_span(route_index)

## The span this train needs next but has not reserved. Empty when the train
## holds its path. Used by deadlock detection to see who is blocking whom.
func wanted_span() -> Array:
	var start := reserved_until + 1
	if start >= route.size() or not waiting_for_block:
		return []
	return route.slice(start, _span_end(start) + 1)

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
		# Turnaround: transfer the block to the opposite direction. Cannot
		# fail — the reverse-pair check means only this train can hold either
		# side of the platform it is standing on.
		release_block(prev_seg)
		reverse_seg.reserve(self)
		var back := consist_length() / prev_seg.length() if prev_seg.length() > 0.0 else 0.0
		segment_progress = clampf(1.0 - (prev_progress - back), 0.0, 1.0)
	else:
		prev_seg.reserve(self)
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

## Drop history segments the tail can no longer reach, freeing their blocks —
## a block stays reserved until the tail clears it.
func _trim_history() -> void:
	var seg := current_segment()
	var behind := segment_progress * seg.length() if seg != null else 0.0
	var keep_from := history.size()
	while keep_from > 0 and behind < consist_length():
		keep_from -= 1
		behind += history[keep_from].length()
	if keep_from > 0:
		for i in range(keep_from):
			release_block(history[i])
		history = history.slice(keep_from)

## Release a block if this train is the one holding it.
func release_block(seg: TrackSegment) -> void:
	if seg.occupying_train == self:
		seg.release()

## Release every block this train holds: the footprint (history + the head's
## segment) and any reserved span ahead. Used when the simulation stops or the
## train is removed.
func release_all_blocks() -> void:
	for seg in history:
		release_block(seg)
	for seg in route:
		release_block(seg)

## Clear all runtime state and blocks, parking the train back at its home
## platform. Orders, car count, and home are kept — this is what ESC (stop
## simulation) does to every train.
func reset_run() -> void:
	release_all_blocks()
	# A train that never left its platform may hold it outside the route
	# (e.g. its very first dispatch failed) — free the home pair explicitly.
	if home_platform != null:
		release_block(home_platform.segment)
		if home_platform.reverse_segment != null:
			release_block(home_platform.reverse_segment)
	route = []
	route_index = 0
	segment_progress = 0.0
	history = []
	boarded_this_leg = false
	dwell_remaining = 0.0
	stop_progress = -1.0
	reserved_until = -1
	waiting_for_block = false
	stalled = false
	deadlocked = false
	passengers_on_board = 0
	current_order_index = 0

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
