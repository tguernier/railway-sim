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
