class_name TestMultiTrain
extends TestBase

func run_all() -> void:
	print("[TestMultiTrain]")
	_t("fleet_cost_charged_at_start", _test_fleet_cost)
	_t("start_rejected_when_broke", _test_fleet_cost_rejected)
	_t("start_rejected_same_first_stop", _test_same_first_stop)
	_t("start_rejected_train_missing_stops", _test_missing_stops)
	_t("two_islands_both_trains_deliver", _test_two_islands)
	_t("head_on_single_track_never_overlaps", _test_head_on)
	_t("signals_let_opposing_trains_pass", _test_signals_pass)
	_t("one_way_passing_loop_lets_head_on_trains_pass", _test_passing_loop)
	_t("dispatch_routes_around_parked_train", _test_dispatch_around_parked)
	_t("dispatch_with_no_free_alternative_still_routes", _test_dispatch_all_blocked)
	_t("two_way_passing_loop_lets_head_on_trains_pass", _test_two_way_loop)
	_t("reroute_splices_tail_and_switches_platform_end", _test_reroute_splice)
	_t("reroute_unchanged_choice_is_noop", _test_reroute_noop)
	_t("reroute_skipped_at_anchored_platform", _test_reroute_anchored_skip)
	_t("nose_to_nose_deadlock_detected", _test_deadlock_detected)
	_t("queue_behind_moving_leader_not_deadlocked", _test_chase_no_deadlock)
	_t("all_blocked_timeout_flags_deadlock", _test_all_blocked_timeout)

## The simulation loop lives on the main game node, so tests drive a real
## instance.
func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

## A self-contained island at height y: a straight track with two stationed
## towns on it. Returns [town_a, town_b].
func _island(m: Node2D, y: float) -> Array:
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, y)),
		NetworkNode.junction(Vector2(1200, y)), [])
	var a := Town.new(Vector2(300, y + 30), Color.WHITE)
	var b := Town.new(Vector2(900, y + 30), Color.WHITE)
	m.towns.append(a)
	m.towns.append(b)
	ed.place_station(Vector2(300, y), m.towns)
	ed.place_station(Vector2(900, y), m.towns)
	return [a, b]

## No two trains may hold the same physical track: for every reserved segment,
## neither it nor its reverse twin may be reserved by another train.
func _reservations_disjoint(trains: Array) -> bool:
	for i in range(trains.size()):
		for seg in trains[i].reserved:
			for j in range(trains.size()):
				if j == i:
					continue
				if trains[j].reserved.has(seg):
					return false
				if seg.reverse != null and trains[j].reserved.has(seg.reverse):
					return false
	return true

func _test_fleet_cost() -> void:
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[1], t[0]])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	# 1 extra train (500) + 1 extra car on each of the two trains (2 × 150).
	eq(m.money, 1000.0 - 500.0 - 2 * 150.0)
	eq(m.trains.size(), 2)
	m.free()

func _test_fleet_cost_rejected() -> void:
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[1], t[0]])
	m.money = 700.0  # fleet costs 800
	m._start_simulation()
	eq(m.state, m.GameState.EDITING)
	eq(m.money, 700.0)
	is_true(m.status_message.contains("Not enough money"))
	m.free()

func _test_same_first_stop() -> void:
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[0], t[1]])
	m._start_simulation()
	eq(m.state, m.GameState.EDITING)
	eq(m.money, 1000.0)
	is_true(m.status_message.contains("same station"))
	m.free()

func _test_missing_stops() -> void:
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()  # second train left without orders
	m._start_simulation()
	eq(m.state, m.GameState.EDITING)
	is_true(m.status_message.contains("Train 2"))
	m.free()

func _test_two_islands() -> void:
	var m := _main()
	var i1 := _island(m, 0.0)
	var i2 := _island(m, 600.0)
	m.roster[0].orders.assign([i1[0], i1[1]])
	m._buy_train()
	m.roster[1].orders.assign([i2[0], i2[1]])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	# Run ~40 s of simulation: each shuttle needs ~6 s per leg, so both trains
	# should complete their loops several times without ever conflicting.
	var disjoint := true
	var wrapped := [false, false]
	for tick in range(2400):
		m._process(1.0 / 60.0)
		if not _reservations_disjoint(m.trains):
			disjoint = false
		for i in range(m.trains.size()):
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true  # completed a leg and wrapped its orders
	eq(m.state, m.GameState.SIMULATING)
	is_true(disjoint)
	is_true(wrapped[0])
	is_true(wrapped[1])
	m.free()

## Two branch pairs joined by one shared single-track middle (P═Q), with
## two-way signals (s) guarding every approach:
##
##   A ──s──╮              ╭──s── B
##          P ══════════ Q
##   C ──s──╯              ╰──s── D
##
## Train 1 shuttles A↔B (eastbound over the middle first), train 2 shuttles
## D↔C (westbound first). Path signals make them cross the shared middle one
## at a time — the loser waits at its signal — and both keep completing
## loops with disjoint reservations and no deadlock.
func _test_signals_pass() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	var p := NetworkNode.junction(Vector2(700, 300))
	var q := NetworkNode.junction(Vector2(1100, 300))
	var a_end := NetworkNode.junction(Vector2(500, 100))
	var c_end := NetworkNode.junction(Vector2(500, 500))
	var b_end := NetworkNode.junction(Vector2(1300, 100))
	var d_end := NetworkNode.junction(Vector2(1300, 500))
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, 100)), a_end, [])
	ed.create_bidirectional_track(a_end, p, [])
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, 500)), c_end, [])
	ed.create_bidirectional_track(c_end, p, [])
	ed.create_bidirectional_track(p, q, [])
	ed.create_bidirectional_track(q, b_end, [])
	ed.create_bidirectional_track(b_end, NetworkNode.junction(Vector2(1800, 100)), [])
	ed.create_bidirectional_track(q, d_end, [])
	ed.create_bidirectional_track(d_end, NetworkNode.junction(Vector2(1800, 500)), [])
	var a := Town.new(Vector2(200, 140), Color.WHITE)
	var b := Town.new(Vector2(1550, 140), Color.WHITE)
	var c := Town.new(Vector2(200, 540), Color.WHITE)
	var d := Town.new(Vector2(1550, 540), Color.WHITE)
	m.towns.assign([a, b, c, d])
	is_true(ed.place_station(Vector2(200, 100), m.towns) != null)
	is_true(ed.place_station(Vector2(1550, 100), m.towns) != null)
	is_true(ed.place_station(Vector2(200, 500), m.towns) != null)
	is_true(ed.place_station(Vector2(1550, 500), m.towns) != null)
	for pos in [Vector2(450, 100), Vector2(1350, 100), Vector2(450, 500), Vector2(1350, 500)]:
		is_true(ed.place_or_cycle_signal(pos))
	m.roster[0].orders.assign([a, b])
	m._buy_train()
	m.roster[1].orders.assign([d, c])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var disjoint := true
	var saw_wait := false
	var flagged := false
	var wrapped := [false, false]
	for tick in range(3600):  # 60 s
		m._process(1.0 / 60.0)
		if not _reservations_disjoint(m.trains):
			disjoint = false
		if not m.deadlocked_trains.is_empty():
			flagged = true
		for i in range(m.trains.size()):
			if m.trains[i].waiting_for_track:
				saw_wait = true
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true
	eq(m.state, m.GameState.SIMULATING)
	is_true(disjoint)
	is_true(saw_wait)  # the middle really was contested
	is_false(flagged)  # waiting at a signal is not a deadlock
	is_true(wrapped[0])
	is_true(wrapped[1])
	m.free()

## The classic symmetric passing loop on a single-track line — the very
## layout that deadlocks without signals (see _test_head_on):
##
##            branch1 (one-way east ⟶)
##   A ────╮ ╭───────────────────────╮ ╭──── B
##          LW                        LE
##           ╰───────────────────────╯
##            branch2 (⟵ one-way west)
##
## One-way signals bar routing against them, so the eastbound and westbound
## trains are forced onto different branches and pass each other inside the
## loop, cleanly, forever (waiting at their exit signals only when timing
## requires it).
func _test_passing_loop() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	var lw := NetworkNode.junction(Vector2(500, 300))
	var le := NetworkNode.junction(Vector2(900, 300))
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, 300)), lw, [])
	ed.create_bidirectional_track(le, NetworkNode.junction(Vector2(1400, 300)), [])
	var branch1 := ed.create_bidirectional_track(lw, le, [Vector2(700, 220)] as Array[Vector2])
	var branch2 := ed.create_bidirectional_track(lw, le, [Vector2(700, 380)] as Array[Vector2])
	branch1.exit_signal = true  # one-way signal at LE serving eastbound
	branch2.reverse.exit_signal = true  # one-way signal at LW serving westbound
	var a := Town.new(Vector2(200, 350), Color.WHITE)
	var b := Town.new(Vector2(1150, 350), Color.WHITE)
	m.towns.assign([a, b])
	is_true(ed.place_station(Vector2(200, 300), m.towns) != null)
	is_true(ed.place_station(Vector2(1150, 300), m.towns) != null)
	m.roster[0].orders.assign([a, b])
	m._buy_train()
	m.roster[1].orders.assign([b, a])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	# Routing splits the head-on traffic across the branches.
	is_true(m.trains[0].route.has(branch1))
	is_false(m.trains[0].route.has(branch2))
	is_true(m.trains[1].route.has(branch2.reverse))
	is_false(m.trains[1].route.has(branch1.reverse))
	var disjoint := true
	var saw_pass := false
	var flagged := false
	var wrapped := [false, false]
	for tick in range(3600):  # 60 s
		m._process(1.0 / 60.0)
		if not _reservations_disjoint(m.trains):
			disjoint = false
		if not m.deadlocked_trains.is_empty():
			flagged = true
		# The actual pass: both trains inside the loop at the same moment,
		# each on its own branch.
		var seg0: TrackSegment = m.trains[0].current_segment()
		var seg1: TrackSegment = m.trains[1].current_segment()
		if (seg0 == branch1 or seg0 == branch2.reverse) \
				and (seg1 == branch1 or seg1 == branch2.reverse):
			saw_pass = true
		for i in range(m.trains.size()):
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true
	eq(m.state, m.GameState.SIMULATING)
	is_true(disjoint)
	is_true(saw_pass)  # they really crossed inside the loop
	is_false(flagged)  # no deadlock — the loop actually works now
	is_true(wrapped[0])
	is_true(wrapped[1])
	m.free()

func _test_deadlock_detected() -> void:
	# The head-on island: both trains need the platform the other occupies,
	# a wait-for cycle from the very first extension attempt. The checker
	# flags both trains within its first ticks and the simulation keeps
	# running (resolution is the player's move, as in OpenTTD).
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[1], t[0]])
	m._start_simulation()
	for tick in range(150):  # 2.5 s — a couple of 1 s checks have fired
		m._process(1.0 / 60.0)
	eq(m.state, m.GameState.SIMULATING)
	eq(m.deadlocked_trains.size(), 2)
	is_true(m.status_message.contains("Deadlock"))
	m.free()

## Two trains chasing each other clockwise around a loop of three stations:
## the follower queues behind the dwelling leader but traffic keeps flowing,
## so the deadlock detector must stay quiet.
func _test_chase_no_deadlock() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	var c00 := NetworkNode.junction(Vector2(0, 0))
	var c10 := NetworkNode.junction(Vector2(1200, 0))
	var c11 := NetworkNode.junction(Vector2(1200, 1200))
	var c01 := NetworkNode.junction(Vector2(0, 1200))
	ed.create_bidirectional_track(c00, c10, [])
	ed.create_bidirectional_track(c10, c11, [])
	ed.create_bidirectional_track(c11, c01, [])
	ed.create_bidirectional_track(c01, c00, [])
	var a := Town.new(Vector2(400, 50), Color.WHITE)
	var b := Town.new(Vector2(1150, 600), Color.WHITE)
	var c := Town.new(Vector2(600, 1150), Color.WHITE)
	m.towns.assign([a, b, c])
	is_true(ed.place_station(Vector2(400, 0), m.towns) != null)
	is_true(ed.place_station(Vector2(1200, 600), m.towns) != null)
	is_true(ed.place_station(Vector2(600, 1200), m.towns) != null)
	m.roster[0].orders.assign([a, b, c])
	m._buy_train()
	m.roster[1].orders.assign([b, c, a])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	for tr in m.trains:
		tr.speed = 450.0  # shorten the loop so the test stays fast
	var flagged := false
	var saw_wait := false
	var wrapped := [false, false]
	for tick in range(2700):  # 45 s
		m._process(1.0 / 60.0)
		if not m.deadlocked_trains.is_empty():
			flagged = true
		for i in range(m.trains.size()):
			if m.trains[i].waiting_for_track:
				saw_wait = true
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true
	eq(m.state, m.GameState.SIMULATING)
	is_false(flagged)  # a queue behind a live leader is not a deadlock
	is_true(saw_wait)  # the follower really did queue
	is_true(wrapped[0])
	is_true(wrapped[1])
	m.free()

func _test_all_blocked_timeout() -> void:
	# The net for cycles the wait-for graph misses: trains blocked with no
	# recorded blocker still count as deadlocked once ALL of them have been
	# stuck for longer than the timeout.
	var m := _main()
	m.state = m.GameState.SIMULATING
	var a := Train.new()
	var b := Train.new()
	a.waiting_for_track = true
	b.waiting_for_track = true
	m.trains.assign([a, b])
	for tick in range(660):  # 11 s > the 10 s timeout
		m._process(1.0 / 60.0)
	eq(m.deadlocked_trains.size(), 2)
	is_true(m.status_message.contains("Deadlock"))
	m.free()

func _test_head_on() -> void:
	# Two trains facing each other on one single-track line: without signals
	# they must both halt at the contested span (a deadlock — resolved by the
	# path-signal steps) but never overlap or pass through each other.
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[1], t[0]])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var disjoint := true
	for tick in range(900):
		m._process(1.0 / 60.0)
		if not _reservations_disjoint(m.trains):
			disjoint = false
	is_true(disjoint)
	is_true(m.trains[0].waiting_for_track)
	is_true(m.trains[1].waiting_for_track)
	m.free()

## Dispatch is reservation-aware: B —— j1 ══A══ j2 —— C on a straight line,
## with a longer free bypass arcing j1→j2 around A's platform. Train 1 parks
## at A; train 2's initial dispatch B→C routes over the bypass instead of
## through the parked train.
func _test_dispatch_around_parked() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	var j1 := NetworkNode.junction(Vector2(600, 0))
	var j2 := NetworkNode.junction(Vector2(1400, 0))
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, 0)), j1, [])
	ed.create_bidirectional_track(j1, j2, [])
	ed.create_bidirectional_track(j2, NetworkNode.junction(Vector2(2000, 0)), [])
	var bypass := ed.create_bidirectional_track(j1, j2, [Vector2(1000, 250)] as Array[Vector2])
	var b := Town.new(Vector2(200, 50), Color.WHITE)
	var a := Town.new(Vector2(1000, 50), Color.WHITE)
	var c := Town.new(Vector2(1800, 50), Color.WHITE)
	m.towns.assign([b, a, c])
	is_true(ed.place_station(Vector2(200, 0), m.towns) != null)
	is_true(ed.place_station(Vector2(1000, 0), m.towns) != null)
	is_true(ed.place_station(Vector2(1800, 0), m.towns) != null)
	m.roster[0].orders.assign([a, b])
	m._buy_train()
	m.roster[1].orders.assign([b, c])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var t2: Train = m.trains[1]
	is_true(t2.route.has(bypass) or t2.route.has(bypass.reverse))
	var a_plat: Platform = a.station.platforms[0]
	is_false(t2.route.has(a_plat.segment))
	is_false(t2.route.has(a_plat.reverse_segment))
	m.free()

## With no free alternative the penalty still yields a route — dispatch never
## fails because of traffic, the train just waits on the contested path.
func _test_dispatch_all_blocked() -> void:
	var m := _main()
	var t := _island(m, 0.0)
	m.roster[0].orders.assign([t[0], t[1]])
	m._buy_train()
	m.roster[1].orders.assign([t[1], t[0]])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	is_true(m.trains[0].has_route())
	is_true(m.trains[1].has_route())
	m.free()

## The Phase A payoff: the passing loop of _test_passing_loop with plain
## two-way signals only — on both approaches (sa, sb) and at both loop
## mouths. The loop is deliberately asymmetric (branch2 bulges further out)
## so routing provably sends both trains down branch1; the loser halts at
## its approach signal, the splice-on-block reroute diverts it onto the free
## branch2, and the trains pass inside the loop.
##
##   A ──s│s──╮ ╭────s branch1 s────╮ ╭──s│s── B
##       sa    LW                    LE    sb
##              ╰─────s branch2 s─────╯
func _test_two_way_loop() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	var sa := NetworkNode.junction(Vector2(380, 300))
	var sb := NetworkNode.junction(Vector2(1020, 300))
	var lw := NetworkNode.junction(Vector2(500, 300))
	var le := NetworkNode.junction(Vector2(900, 300))
	ed.create_bidirectional_track(NetworkNode.junction(Vector2(0, 300)), sa, [])
	ed.create_bidirectional_track(sa, lw, [])
	var branch1 := ed.create_bidirectional_track(lw, le, [Vector2(700, 240)] as Array[Vector2])
	var branch2 := ed.create_bidirectional_track(lw, le, [Vector2(700, 430)] as Array[Vector2])
	ed.create_bidirectional_track(le, sb, [])
	ed.create_bidirectional_track(sb, NetworkNode.junction(Vector2(1400, 300)), [])
	var a := Town.new(Vector2(200, 350), Color.WHITE)
	var b := Town.new(Vector2(1150, 350), Color.WHITE)
	m.towns.assign([a, b])
	is_true(ed.place_station(Vector2(200, 300), m.towns) != null)
	is_true(ed.place_station(Vector2(1150, 300), m.towns) != null)
	# Two-way signals only: every direction arriving at a signal junction is
	# served, so nothing is barred for routing.
	for seg in [branch1, branch1.reverse, branch2, branch2.reverse]:
		seg.exit_signal = true
	for seg in m.network.get_incoming(sa) + m.network.get_incoming(sb):
		seg.exit_signal = true
	m.roster[0].orders.assign([a, b])
	m._buy_train()
	m.roster[1].orders.assign([b, a])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	# Both dispatches pick the short branch — the conflict is real, and only
	# the reroute can split them.
	is_true(m.trains[0].route.has(branch1))
	is_true(m.trains[1].route.has(branch1.reverse))
	var loop_segs := [branch1, branch1.reverse, branch2, branch2.reverse]
	var disjoint := true
	var saw_wait := false
	var saw_pass := false
	var flagged := false
	var wrapped := [false, false]
	for tick in range(3600):  # 60 s
		m._process(1.0 / 60.0)
		if not _reservations_disjoint(m.trains):
			disjoint = false
		if not m.deadlocked_trains.is_empty():
			flagged = true
		# The actual pass: both trains on loop branches at the same moment.
		if loop_segs.has(m.trains[0].current_segment()) \
				and loop_segs.has(m.trains[1].current_segment()):
			saw_pass = true
		for i in range(m.trains.size()):
			if m.trains[i].waiting_for_track:
				saw_wait = true
			if m.trains[i].current_order_index == 0:
				wrapped[i] = true
	eq(m.state, m.GameState.SIMULATING)
	is_true(disjoint)
	is_true(saw_wait)  # both routed onto one branch — the loser really waited
	is_true(saw_pass)  # the reroute split them across the branches
	is_false(flagged)  # waiting out a reroute is not a deadlock
	is_true(wrapped[0])
	is_true(wrapped[1])
	m.free()

## Loop layout for the reroute unit tests: from s, a short path (via x) to the
## platform's entry end and a long free path (via y) to its exit end.
##
##   q ── s ── x ── entry ═platform═ exit ── y
##         ╰────────────(long arc)───────────╯
##
## Returns [m, town, qs, sx, sy, tr] with tr a hand-built train waiting at s:
## head at the end of q→s, planned tail running via x.
func _reroute_world() -> Array:
	var m := _main()
	var ed: TrackEditor = m.editor
	var q := NetworkNode.junction(Vector2(-100, 0))
	var s := NetworkNode.junction(Vector2(0, 0))
	var x := NetworkNode.junction(Vector2(100, 0))
	var entry := NetworkNode.junction(Vector2(200, 0))
	var exit := NetworkNode.junction(Vector2(400, 0))
	var y := NetworkNode.junction(Vector2(500, 0))
	var qs := ed.create_bidirectional_track(q, s, [])
	var sx := ed.create_bidirectional_track(s, x, [])
	ed.create_bidirectional_track(x, entry, [])
	ed.create_bidirectional_track(entry, exit, [])
	ed.create_bidirectional_track(exit, y, [])
	var sy := ed.create_bidirectional_track(y, s, [Vector2(250, 350)] as Array[Vector2])
	var town := Town.new(Vector2(300, 50), Color.WHITE)
	m.towns.assign([town])
	is_true(ed.place_station(Vector2(300, 0), m.towns) != null)
	var plat: Platform = town.station.platforms[0]
	var tr := Train.new()
	tr.orders.assign([town])
	tr.current_order_index = 0
	tr.route = [qs] + m.network.find_route_to_platform(s, plat)
	tr.route_index = 0
	tr.segment_progress = 1.0
	tr.stop_progress = m._stop_point(tr, tr.route[-1])
	return [m, town, qs, sx, sy, tr]

func _test_reroute_splice() -> void:
	var w := _reroute_world()
	var m: Node2D = w[0]
	var town: Town = w[1]
	var tr: Train = w[5]
	var plat: Platform = town.station.platforms[0]
	# Sanity: the planned tail runs the short way, entering at the entry end.
	is_true(tr.route.has(w[3]))
	eq(tr.route[-1], plat.segment)
	var blocker := Train.new()
	is_true(blocker.try_reserve([w[3]]))
	m._try_reroute_blocked(tr)
	# The traversed prefix is kept, the tail now runs the long way via y and
	# enters the platform from the other end, with the halt point recomputed.
	eq(tr.route[0], w[2])
	is_true(tr.route.has(w[4].reverse))
	eq(tr.route[-1], plat.reverse_segment)
	approx(tr.stop_progress, m._stop_point(tr, plat.reverse_segment), 0.001)
	# The new tail was reserved (no signals — it runs to the route end), and
	# nothing leaked: every held segment is on the spliced route.
	eq(tr.limit_index, tr.route.size() - 1)
	for seg in tr.reserved:
		is_true(tr.route.has(seg))
	m.free()

func _test_reroute_noop() -> void:
	# With nothing blocked the cheapest tail equals the planned one — the
	# reroute must not churn the route or touch reservations.
	var w := _reroute_world()
	var m: Node2D = w[0]
	var tr: Train = w[5]
	var before: Array = tr.route.duplicate()
	m._try_reroute_blocked(tr)
	eq(tr.route, before)
	eq(tr.limit_index, -1)
	eq(tr.reserved.size(), 0)
	m.free()

func _test_reroute_anchored_skip() -> void:
	# A train still anchored at its departure platform (route_index 0 on a
	# platform segment) keeps waiting even when a better tail exists: its
	# turnaround/roll-through anchoring cannot survive a tail swap.
	var w := _reroute_world()
	var m: Node2D = w[0]
	var town: Town = w[1]
	var tr: Train = w[5]
	var plat: Platform = town.station.platforms[0]
	tr.route = [plat.segment] + m.network.find_route(plat.segment.node_end, w[2].node_start)
	tr.route_index = 0
	tr.segment_progress = 1.0
	tr.orders.assign([town])
	var blocker := Train.new()
	is_true(blocker.try_reserve([tr.route[1]]))
	var before: Array = tr.route.duplicate()
	m._try_reroute_blocked(tr)
	eq(tr.route, before)
	eq(tr.reserved.size(), 0)
	m.free()
