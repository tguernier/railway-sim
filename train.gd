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
## Seconds a blocked train waits between re-path attempts. Reservation retries
## stay per-frame; only the Dijkstra re-path is throttled. Well under main.gd's
## ALL_BLOCKED_TIMEOUT so trains get several chances to self-resolve before a
## deadlock is flagged.
const REROUTE_RETRY_INTERVAL := 1.0
## Cost improvement a free alternative tail must offer before the train
## switches to it — hysteresis so near-equal branches don't flip-flop between
## extensions. A blocked tail is abandoned for any strictly cheaper one.
const SWITCH_MARGIN := CAR_LENGTH * 10.0

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
## Highest route index covered by the current reservation; the head may not
## advance past the end of route[limit_index]. -1 until the first extension.
var limit_index := -1
## True while the train is halted because the path ahead could not be
## reserved (retried every move).
var waiting_for_track := false
## Seconds continuously spent waiting for track since the last re-path
## attempt — throttles the blocked-retry Dijkstra in _repath_provisional_tail.
var blocked_time := 0.0
## Whether the previous move() ended waiting for track — distinguishes a fresh
## extension at a new boundary (re-path immediately) from a blocked retry
## (re-path only every REROUTE_RETRY_INTERVAL).
var _was_waiting := false

## The network the train routes on and the platform its current leg targets,
## set at dispatch — what try_extend_reservation re-paths against. Strong refs
## are safe: neither holds trains strongly (reserved_by is a weakref), so no
## RefCounted cycle.
var network: TrackNetwork = null
var target_platform: Platform = null

## The train whose reservation blocked this train's last failed reserve
## attempt — the edge of the wait-for graph used for deadlock detection.
## Weakref: two mutually blocked trains must not keep each other alive.
var _blocked_by_ref: WeakRef = null
var blocked_by: Train:
	get: return _blocked_by_ref.get_ref() as Train if _blocked_by_ref != null else null
	set(t): _blocked_by_ref = weakref(t) if t != null else null

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
	limit_index = -1
	waiting_for_track = false
	blocked_time = 0.0
	_was_waiting = false

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
	_was_waiting = waiting_for_track
	blocked_time = blocked_time + delta if _was_waiting else 0.0
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

## Advance the head onto the next route segment. Crossing past the reserved
## limit first requires extending the reservation to the next safe waiting
## point; on failure the train halts at the boundary — the exit of
## route[limit_index] is a signal (or the start of the route), which is
## exactly where it may stand. The traversed segment moves into the history
## so trailing cars can still be positioned on it.
func _advance_to_next_segment(seg: TrackSegment) -> bool:
	# Loop: the first extension after dispatch may stop at a signal on the
	# current segment itself, still short of the boundary being crossed.
	# Every successful extension raises limit_index, so this terminates.
	while route_index + 1 > limit_index:
		if not try_extend_reservation():
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
		if limit_index >= 0:
			limit_index += 1  # keep the reserved limit on the same segment

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

## Extend the reservation from just past limit_index through the next safe
## waiting point on the route: the first segment whose exit carries a signal
## for this direction of travel, or the end of the route (the platform stop).
## Before reserving, the provisional tail beyond limit_index is re-pathed with
## other trains' reservations penalized and a sufficiently better tail is
## spliced in — the per-signal lookahead that lets a train divert onto a free
## branch at speed instead of halting at a red signal first.
## The whole slice is reserved atomically; on failure limit_index and the
## held reservations are unchanged. Returns true if the path ahead is covered.
func try_extend_reservation() -> bool:
	if limit_index >= route.size() - 1:
		return true
	_repath_provisional_tail()
	var slice: Array = []
	var end := limit_index
	for i in range(limit_index + 1, route.size()):
		slice.append(route[i])
		end = i
		if route[i].exit_signal:
			break
	if not try_reserve(slice):
		return false
	limit_index = end
	return true

## Re-path the provisional tail (route[limit_index + 1:]) to target_platform
## with other trains' reservations penalized, and splice a better tail onto
## the kept prefix — history, indices, and held reservations stay intact (the
## discarded tail lies beyond limit_index, so it held nothing). Hysteresis:
## a free tail is only abandoned for one cheaper by SWITCH_MARGIN, so
## near-equal branches don't flip-flop; a blocked tail for any cheaper one.
## Skipped while the train is still anchored at its departure platform
## (limit_index == -1): the turnaround/roll-through anchoring came from the
## route's first segment and would not survive a tail swap, and dispatch was
## already traffic-aware. Blocked retries arrive every frame, so the Dijkstra
## is throttled to one attempt per REROUTE_RETRY_INTERVAL while waiting.
func _repath_provisional_tail() -> void:
	if network == null or target_platform == null:
		return
	if limit_index < route_index:
		return  # anchored at the departure platform (or an inconsistent state)
	if _was_waiting and blocked_time < REROUTE_RETRY_INTERVAL:
		return  # blocked retry — re-path at most once per interval
	blocked_time = 0.0
	var node: NetworkNode = route[limit_index].node_end
	var old_tail: Array = route.slice(limit_index + 1)
	# The tail must continue the rolling train's heading (no allow_reversal:
	# only a train standing at a stop may change direction).
	var new_tail: Array = network.find_route_to_platform(node, target_platform, self, route[limit_index])
	if new_tail.is_empty():
		return
	var old_cost := network.route_cost(old_tail, self)
	var new_cost := network.route_cost(new_tail, self)
	var old_blocked := false
	for seg in old_tail:
		if is_blocked(seg):
			old_blocked = true
			break
	var margin := 0.0 if old_blocked else SWITCH_MARGIN
	if new_cost >= old_cost - margin:
		return  # keep the current plan — waiting/staying is cheapest
	route = route.slice(0, limit_index + 1) + new_tail
	# The new tail may enter the destination platform from the other end, so
	# the halt fraction on the old final segment is meaningless.
	stop_progress = stop_point_on(route[-1])

## Head halt point (progress) on a platform segment that centers the consist
## on the platform. Consists always fit: car count is capped to the platform
## length, so the whole train sits on the platform segment while dwelling.
func stop_point_on(platform_seg: TrackSegment) -> float:
	var total := platform_seg.length()
	if total <= 0.0:
		return 1.0
	return clampf(0.5 + consist_length() / (2.0 * total), 0.0, 1.0)

## Reserve every segment for this train, all-or-nothing: if any segment (or
## its reverse twin) is held by another train, nothing is reserved and
## blocked_by records the holder.
##
## segs: Array[TrackSegment]
func try_reserve(segs: Array) -> bool:
	for seg in segs:
		var blocker := blocking_train(seg)
		if blocker != null:
			blocked_by = blocker
			return false
	for seg in segs:
		if seg.reserved_by != self:
			seg.reserved_by = self
			reserved.append(seg)
	blocked_by = null
	return true

## The other train making a segment unavailable to this one — the holder of
## the segment or of its reverse twin. Null when the segment is free.
func blocking_train(seg: TrackSegment) -> Train:
	if seg.reserved_by != null and seg.reserved_by != self:
		return seg.reserved_by
	var rev := seg.reverse
	if rev != null and rev.reserved_by != null and rev.reserved_by != self:
		return rev.reserved_by
	return null

## Whether a segment is unavailable to this train: it or its reverse twin is
## reserved by a different train.
func is_blocked(seg: TrackSegment) -> bool:
	return blocking_train(seg) != null

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
