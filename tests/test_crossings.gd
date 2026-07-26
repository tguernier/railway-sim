class_name TestCrossings
extends TestBase

func run_all() -> void:
	print("[TestCrossings]")
	# Geometry (C.0)
	_t("square_tracks_cross_once", _test_square_cross)
	_t("parallel_tracks_never_cross", _test_parallel_no_cross)
	_t("tracks_sharing_a_node_do_not_cross", _test_shared_node_no_cross)
	_t("reverse_twins_do_not_cross", _test_twins_no_cross)
	_t("distant_tracks_rejected_by_bounds", _test_bounds_reject)
	_t("crossing_angle_square_and_symmetric", _test_angle_square)
	_t("crossing_angle_shallow", _test_angle_shallow)
	# Registration (C.1)
	_t("crossing_registered_on_all_four_segments", _test_register_four)
	_t("reverse_twin_does_not_duplicate", _test_no_duplicate)
	_t("other_track_from_either_direction", _test_other_track)
	_t("deleting_a_track_purges_the_crossing", _test_delete_purges)
	_t("splitting_a_crossed_track_keeps_one_half", _test_split_keeps_half)
	# Snapshot (C.2)
	_t("snapshot_clones_crossings_onto_clones", _test_snapshot_clone)
	_t("undo_restores_a_crossing", _test_undo_restores)
	# Exclusion (C.3)
	_t("crossing_track_is_blocked_by_holder", _test_exclusion)
	_t("release_frees_the_crossing_track", _test_exclusion_release)
	_t("unrelated_track_is_unaffected", _test_exclusion_unrelated)
	_t("own_reservation_does_not_block_self", _test_exclusion_self)
	_t("route_cost_penalises_occupied_crossing", _test_route_cost)
	_t("reservation_slice_refuses_occupied_diamond", _test_slice_refused)
	# Editor validation (C.4)
	_t("square_crossing_accepted", _test_validate_accept)
	_t("shallow_crossing_rejected", _test_validate_shallow)
	_t("crossing_a_platform_rejected", _test_validate_platform)
	_t("station_across_a_crossing_rejected", _test_station_over_crossing)
	_t("crossover_arm_onto_a_track_accepted", _test_crossover_arm)
	# Simulation (C.5 + integration)
	_t("start_rejected_when_first_stops_cross", _test_start_rejected)
	_t("crossing_lines_never_share_the_diamond", _test_sim_serialises)
	_t("scissors_arms_exclude_each_other", _test_scissors)

# --- Helpers ---

func _node(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

func _seg(ax: float, ay: float, bx: float, by: float) -> TrackSegment:
	return TrackSegment.new(_node(ax, ay), _node(bx, by))

## A network with a track laid between each pair of coordinates, built through
## the editor so reverse twins and crossing detection run as in the game.
func _editor() -> TrackEditor:
	return TrackEditor.new(TrackNetwork.new())

func _track(ed: TrackEditor, ax: float, ay: float, bx: float, by: float) -> TrackSegment:
	return ed.create_bidirectional_track(_node(ax, ay), _node(bx, by), [])

func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

## Trains holding either side of a crossing. More than one means two trains
## are inside the same diamond, which must never happen.
func _diamond_holders(crossing: TrackCrossing, trains: Array) -> int:
	var count := 0
	for tr in trains:
		var inside := false
		for track in [crossing.track_a, crossing.track_b]:
			if track == null:
				continue
			if tr.reserved.has(track) or (track.reverse != null and tr.reserved.has(track.reverse)):
				inside = true
		if inside:
			count += 1
	return count

# --- Geometry (C.0) ---

func _test_square_cross() -> void:
	var a := _seg(0.0, 300.0, 600.0, 300.0)
	var b := _seg(300.0, 0.0, 300.0, 600.0)
	var points := TrackSegment.crossing_points(a, b)
	eq(points.size(), 1)
	approx(points[0].x, 300.0, 2.0)
	approx(points[0].y, 300.0, 2.0)
	# Symmetric in argument order.
	eq(TrackSegment.crossing_points(b, a).size(), 1)

func _test_parallel_no_cross() -> void:
	var a := _seg(0.0, 0.0, 600.0, 0.0)
	var b := _seg(0.0, 30.0, 600.0, 30.0)
	eq(TrackSegment.crossing_points(a, b).size(), 0)

func _test_shared_node_no_cross() -> void:
	# Two tracks meeting at a junction touch but do not cross: the shared
	# endpoint falls inside CROSSING_NODE_CLEARANCE.
	var shared := _node(300.0, 300.0)
	var a := TrackSegment.new(_node(0.0, 300.0), shared)
	var b := TrackSegment.new(shared, _node(600.0, 100.0))
	eq(TrackSegment.crossing_points(a, b).size(), 0)

func _test_twins_no_cross() -> void:
	var ed := _editor()
	var fwd := _track(ed, 0.0, 0.0, 600.0, 0.0)
	eq(TrackSegment.crossing_points(fwd, fwd.reverse).size(), 0)

func _test_bounds_reject() -> void:
	var a := _seg(0.0, 0.0, 100.0, 0.0)
	var b := _seg(5000.0, 5000.0, 5100.0, 5000.0)
	eq(TrackSegment.crossing_points(a, b).size(), 0)

func _test_angle_square() -> void:
	var a := _seg(0.0, 300.0, 600.0, 300.0)
	var b := _seg(300.0, 0.0, 300.0, 600.0)
	var p := Vector2(300.0, 300.0)
	approx(TrackSegment.crossing_angle(a, b, p), PI / 2.0, 0.05)
	approx(TrackSegment.crossing_angle(b, a, p), PI / 2.0, 0.05)
	# Direction of travel must not change the answer.
	var b_rev := _seg(300.0, 600.0, 300.0, 0.0)
	approx(TrackSegment.crossing_angle(a, b_rev, p), PI / 2.0, 0.05)

func _test_angle_shallow() -> void:
	# ~11.3° apart: rises 60 over 300 against a level track.
	var a := _seg(0.0, 300.0, 600.0, 300.0)
	var b := _seg(0.0, 240.0, 600.0, 360.0)
	var points := TrackSegment.crossing_points(a, b)
	eq(points.size(), 1)
	var ang := TrackSegment.crossing_angle(a, b, points[0])
	approx(rad_to_deg(ang), 11.3, 1.5)
	check(ang < TrackEditor.MIN_CROSSING_ANGLE, "expected shallow crossing to be under the limit")

# --- Registration (C.1) ---

func _test_register_four() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	eq(ed.network.crossings.size(), 1)
	var crossing: TrackCrossing = ed.network.crossings[0]
	is_true(a.crossings.has(crossing))
	is_true(a.reverse.crossings.has(crossing))
	is_true(b.crossings.has(crossing))
	is_true(b.reverse.crossings.has(crossing))
	approx(crossing.position.x, 300.0, 2.0)
	approx(crossing.angle, PI / 2.0, 0.05)

func _test_no_duplicate() -> void:
	# create_bidirectional_track adds both twins; only one scan must register.
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	_track(ed, 300.0, 0.0, 300.0, 600.0)
	eq(ed.network.crossings.size(), 1)
	for seg in ed.network.segments:
		check(seg.crossings.size() <= 1, "segment carries %d crossings" % seg.crossings.size())

func _test_other_track() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var crossing: TrackCrossing = ed.network.crossings[0]
	eq(crossing.other_track(a), b)
	eq(crossing.other_track(a.reverse), b)
	eq(crossing.other_track(b), a)
	eq(crossing.other_track(b.reverse), a)
	eq(crossing.other_track(_seg(0.0, 0.0, 10.0, 0.0)), null)

func _test_delete_purges() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	eq(ed.network.crossings.size(), 1)
	is_true(ed.try_delete_track_at(Vector2(300.0, 100.0)))  # delete track b
	eq(ed.network.crossings.size(), 0)
	eq(a.crossings.size(), 0)
	eq(a.reverse.crossings.size(), 0)
	eq(b.crossings.size(), 0)

func _test_split_keeps_half() -> void:
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	_track(ed, 300.0, 0.0, 300.0, 600.0)
	# Split the horizontal track well left of the diamond; only the right-hand
	# half still carries it.
	ed.split_track_at_hit(ed.find_track_at(Vector2(100.0, 300.0)))
	eq(ed.network.crossings.size(), 1)
	var carrying := 0
	for seg in ed.network.segments:
		if seg.crossings.size() > 0:
			carrying += 1
	eq(carrying, 4)  # both directions of the right-hand half and of the vertical

# --- Snapshot (C.2) ---

func _test_snapshot_clone() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	_track(ed, 300.0, 0.0, 300.0, 600.0)
	eq(m.network.crossings.size(), 1)
	var snap := GameSnapshot.capture(m)
	eq(snap.network.crossings.size(), 1)
	var original: TrackCrossing = m.network.crossings[0]
	var clone: TrackCrossing = snap.network.crossings[0]
	check(clone != original, "snapshot must not share the live crossing object")
	approx(clone.position.x, original.position.x, 0.5)
	approx(clone.angle, original.angle, 0.01)
	# The clone must reference cloned segments, registered on all four.
	check(not m.network.segments.has(clone.track_a),
		"cloned crossing still points at a live segment")
	is_true(snap.network.segments.has(clone.track_a))
	is_true(clone.track_a.crossings.has(clone))
	is_true(clone.track_b.reverse.crossings.has(clone))
	m.free()

func _test_undo_restores() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	_track(ed, 300.0, 0.0, 300.0, 600.0)
	m._push_undo()
	ed.try_delete_track_at(Vector2(300.0, 100.0))
	eq(m.network.crossings.size(), 0)
	m._undo()
	eq(m.network.crossings.size(), 1)
	# The restored crossing must actually exclude, not just exist in the list.
	var crossing: TrackCrossing = m.network.crossings[0]
	is_true(crossing.track_a != null and crossing.track_b != null)
	is_true(crossing.track_a.crossings.has(crossing))
	m.free()

# --- Exclusion (C.3) ---

func _test_exclusion() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var t1 := Train.new()
	var t2 := Train.new()
	is_true(t1.try_reserve([a]))
	is_true(t2.is_blocked(b))
	eq(t2.blocking_train(b), t1)
	# Barred from the far direction of the crossing track too.
	is_true(t2.is_blocked(b.reverse))
	is_false(t2.try_reserve([b]))
	eq(t2.blocked_by, t1)

func _test_exclusion_release() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var t1 := Train.new()
	var t2 := Train.new()
	t1.try_reserve([a])
	is_false(t2.try_reserve([b]))
	t1.release_all()
	is_false(t2.is_blocked(b))
	is_true(t2.try_reserve([b]))
	# And now the first train is the one shut out.
	is_true(t1.is_blocked(a))

func _test_exclusion_unrelated() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var far := _track(ed, 0.0, 900.0, 600.0, 900.0)
	var t1 := Train.new()
	var t2 := Train.new()
	t1.try_reserve([a])
	is_false(t2.is_blocked(far))
	is_true(t2.try_reserve([far]))
	eq(b.crossings.size(), 1)
	eq(far.crossings.size(), 0)

func _test_exclusion_self() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var t1 := Train.new()
	is_true(t1.try_reserve([a]))
	# A train's own hold on one side must not shut it out of the other.
	is_false(t1.is_blocked(b))
	is_true(t1.try_reserve([b]))

func _test_route_cost() -> void:
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var t1 := Train.new()
	var t2 := Train.new()
	var free_cost := ed.network.route_cost([b], t2)
	t1.try_reserve([a])
	var blocked_cost := ed.network.route_cost([b], t2)
	approx(blocked_cost - free_cost, TrackNetwork.BLOCKED_PENALTY, 1.0)

func _test_slice_refused() -> void:
	# A reservation slice is all-or-nothing: one crossed segment in it is
	# enough to leave the whole slice unreserved.
	var ed := _editor()
	var a := _track(ed, 0.0, 300.0, 600.0, 300.0)
	var b := _track(ed, 300.0, 0.0, 300.0, 600.0)
	var far := _track(ed, 0.0, 900.0, 600.0, 900.0)
	var t1 := Train.new()
	var t2 := Train.new()
	t1.try_reserve([a])
	is_false(t2.try_reserve([far, b]))
	eq(t2.reserved.size(), 0)
	eq(far.reserved_by, null)

# --- Editor validation (C.4) ---

func _test_validate_accept() -> void:
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	ed.start_drawing(_node(300.0, 0.0))
	is_true(ed.finish_at(_node(300.0, 600.0)))
	eq(ed.network.crossings.size(), 1)

func _test_validate_shallow() -> void:
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	# Rises 60 over 600: ~5.7°, well under MIN_CROSSING_ANGLE.
	ed.start_drawing(_node(0.0, 270.0))
	is_false(ed.finish_at(_node(600.0, 330.0)))
	eq(ed.rejection_reason, "crossing")
	eq(ed.network.crossings.size(), 0)
	eq(ed.network.segments.size(), 2)  # only the original track

func _test_validate_platform() -> void:
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	var towns: Array[Town] = [Town.new(Vector2(300.0, 330.0), Color.WHITE)]
	is_true(ed.place_station(Vector2(300.0, 300.0), towns) != null)
	ed.start_drawing(_node(300.0, 0.0))
	is_false(ed.finish_at(_node(300.0, 600.0)))
	eq(ed.rejection_reason, "crossing_platform")
	eq(ed.network.crossings.size(), 0)

func _test_station_over_crossing() -> void:
	# The mirror case: the crossing exists first and the player tries to build
	# a platform over it.
	var ed := _editor()
	_track(ed, 0.0, 300.0, 600.0, 300.0)
	_track(ed, 300.0, 0.0, 300.0, 600.0)
	var towns: Array[Town] = [Town.new(Vector2(300.0, 340.0), Color.WHITE)]
	eq(ed.place_station(Vector2(300.0, 300.0), towns), null)
	is_true(ed.last_error.contains("crossing"))
	eq(towns[0].station, null)

func _test_crossover_arm() -> void:
	# A crossover arm terminates on the track it joins; the shared node must
	# keep that join out of the crossing test entirely.
	var ed := _editor()
	_track(ed, 0.0, 0.0, 1200.0, 0.0)
	_track(ed, 0.0, 60.0, 1200.0, 60.0)
	ed.start_drawing(ed.split_track_at_hit(ed.find_track_at(Vector2(400.0, 0.0))))
	is_true(ed.finish_on_track(ed.find_track_at(Vector2(700.0, 60.0))))
	eq(ed.network.crossings.size(), 0)

# --- Simulation (C.5 + integration) ---

## Two crossing lines, each with two stationed towns. Returns
## [[town_a1, town_a2], [town_b1, town_b2]].
func _crossed_lines(m: Node2D) -> Array:
	var ed: TrackEditor = m.editor
	_track(ed, 0.0, 300.0, 1200.0, 300.0)
	_track(ed, 600.0, -300.0, 600.0, 900.0)
	var a1 := Town.new(Vector2(200.0, 330.0), Color.WHITE)
	var a2 := Town.new(Vector2(1000.0, 330.0), Color.WHITE)
	var b1 := Town.new(Vector2(630.0, -100.0), Color.WHITE)
	var b2 := Town.new(Vector2(630.0, 700.0), Color.WHITE)
	m.towns.append_array([a1, a2, b1, b2])
	ed.place_station(Vector2(200.0, 300.0), m.towns)
	ed.place_station(Vector2(1000.0, 300.0), m.towns)
	ed.place_station(Vector2(600.0, -100.0), m.towns)
	ed.place_station(Vector2(600.0, 700.0), m.towns)
	return [[a1, a2], [b1, b2]]

## A self-contained island at height y: a straight track with two stationed
## towns on it. Returns [town_a, town_b].
func _island(m: Node2D, y: float) -> Array:
	var ed: TrackEditor = m.editor
	_track(ed, 0.0, y, 1200.0, y)
	var a := Town.new(Vector2(300.0, y + 30.0), Color.WHITE)
	var b := Town.new(Vector2(900.0, y + 30.0), Color.WHITE)
	m.towns.append_array([a, b])
	ed.place_station(Vector2(300.0, y), m.towns)
	ed.place_station(Vector2(900.0, y), m.towns)
	return [a, b]

func _test_start_rejected() -> void:
	# Two first-stop platforms that exclude each other: the second train cannot
	# hold the track it spawns on, so the run must be refused rather than
	# started with a train standing on track it does not own. The editor now
	# prevents building this (a platform may not span a crossing), so the state
	# is set up directly — the guard is there for the next tool that creates
	# geometry without going through _validate_track.
	var m := _main()
	var i1 := _island(m, 0.0)
	var i2 := _island(m, 600.0)
	m.network.register_crossing(i1[0].station.platforms[0].segment,
		i2[0].station.platforms[0].segment, Vector2(300.0, 300.0))
	m.roster[0].orders.assign(i1)
	m._buy_train()
	m.roster[1].orders.assign(i2)
	m._start_simulation()
	eq(m.state, m.GameState.EDITING)
	eq(m.money, 1000.0)  # the fleet charge is refunded on a refused start
	eq(m.trains.size(), 0)
	is_true(m.status_message.contains("cross"))
	m.free()

func _test_sim_serialises() -> void:
	var m := _main()
	var lines := _crossed_lines(m)
	eq(m.network.crossings.size(), 1)
	m.roster[0].orders.assign(lines[0])
	m._buy_train()
	m.roster[1].orders.assign(lines[1])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var shared := false
	var wrapped := [false, false]
	for tick in range(3600):  # ~60 s
		m._process(1.0 / 60.0)
		for crossing in m.network.crossings:
			if _diamond_holders(crossing, m.trains) > 1:
				shared = true
		for i in range(m.trains.size()):
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true
	eq(m.state, m.GameState.SIMULATING)
	is_false(shared)          # never two trains in the diamond
	is_true(wrapped[0])       # and both still get their work done
	is_true(wrapped[1])
	m.free()

func _test_scissors() -> void:
	# Two parallel tracks joined by opposed crossovers whose arms cross. The
	# diamond is what stops both routes being used at once.
	var ed := _editor()
	_track(ed, 0.0, 0.0, 1200.0, 0.0)
	_track(ed, 0.0, 60.0, 1200.0, 60.0)
	var j1 := ed.split_track_at_hit(ed.find_track_at(Vector2(400.0, 0.0)))
	ed.start_drawing(j1)
	is_true(ed.finish_on_track(ed.find_track_at(Vector2(700.0, 60.0))))
	var j2 := ed.split_track_at_hit(ed.find_track_at(Vector2(400.0, 60.0)))
	ed.start_drawing(j2)
	is_true(ed.finish_on_track(ed.find_track_at(Vector2(700.0, 0.0))))
	# Exactly one diamond, where the two arms cross.
	eq(ed.network.crossings.size(), 1)
	var crossing: TrackCrossing = ed.network.crossings[0]
	approx(crossing.position.x, 550.0, 40.0)
	approx(crossing.position.y, 30.0, 10.0)
	# The two arms exclude each other...
	var t1 := Train.new()
	var t2 := Train.new()
	is_true(t1.try_reserve([crossing.track_a]))
	is_false(t2.try_reserve([crossing.track_b]))
	# ...while a train running straight through on either main line does not
	# touch the diamond, exactly as at a real scissors.
	var main_line: TrackSegment = ed.find_track_at(Vector2(1000.0, 0.0))[0]
	is_false(t2.is_blocked(main_line))
