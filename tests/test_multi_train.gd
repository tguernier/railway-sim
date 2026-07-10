## Multiple trains driven through the real main.gd simulation loop: purchase,
## per-train orders and validation, independent movement, and the signalling
## acceptance scenarios (passing loop with and without signals).
class_name TestMultiTrain
extends TestBase

const TICK := 1.0 / 30.0

func run_all() -> void:
	print("[TestMultiTrain]")
	_t("purchase_deducts_money_and_selects", _test_purchase)
	_t("purchase_rejected_when_broke", _test_purchase_broke)
	_t("purchase_rejected_on_occupied_platform", _test_purchase_duplicate_home)
	_t("purchase_undo_removes_train_and_refunds", _test_purchase_undo)
	_t("resize_charges_and_refunds_immediately", _test_resize)
	_t("start_rejects_train_with_one_stop", _test_start_needs_two_stops)
	_t("start_reserves_home_platforms", _test_start_reserves_homes)
	_t("undo_stack_cleared_at_simulation_start", _test_undo_cleared_at_start)
	_t("trains_move_independently", _test_independent_trains)
	_t("dispatch_failure_halts_only_that_train", _test_dispatch_failure_isolated)
	_t("esc_parks_trains_and_releases_all_blocks", _test_stop_parks_and_releases)
	_t("ACCEPTANCE_passing_loop_with_signals", _test_passing_loop_signalled)
	_t("ACCEPTANCE_passing_loop_with_approach_signals", _test_passing_loop_approach_signals)
	_t("ACCEPTANCE_shared_corridor_with_one_way_bypass", _test_corridor_one_way_bypass)
	_t("ACCEPTANCE_directional_path_loop_through_stations", _test_directional_path_loop)
	_t("ACCEPTANCE_no_signals_standoff_at_platforms", _test_no_signal_standoff)
	_t("one_way_signals_enforce_branch_directions", _test_one_way_loop)
	_t("queued_behind_moving_train_not_deadlocked", _test_queued_not_deadlock)

## The tests drive a real instance of the main game node.
func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

func _junction(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

## Straight track from x0 to x1 at height y with a stationed town at station_x.
func _stationed_town(m: Node2D, station_x: float, y: float) -> Town:
	var town := Town.new(Vector2(station_x, y + 40), Color.WHITE)
	m.towns.append(town)
	var ed: TrackEditor = m.editor
	ed.place_station(Vector2(station_x, y), m.towns)
	return town

## A train added directly (no purchase charge/undo), homed at a town.
func _add_train(m: Node2D, home: Town, stops: Array) -> Train:
	var t := Train.new()
	t.car_count = 1
	t.home_platform = home.station.platforms[0]
	for stop in stops:
		t.orders.append(stop)
	m.trains.append(t)
	return t

## Two stations at the ends of a single line with a passing loop between:
## station A on (0,0)-(600,0), corridor to J1(900,0), north/south loop
## branches to J2(1500,0), corridor to (1800,0), station B on
## (1800,0)-(2400,0). Optional signals at each end of each branch. Returns
## [m, town_a, town_b].
func _passing_loop_world(with_signals: bool) -> Array:
	var m := _main()
	var ed: TrackEditor = m.editor
	var a1 := _junction(600, 0)
	var j1 := _junction(900, 0)
	var j2 := _junction(1500, 0)
	var b0 := _junction(1800, 0)
	ed.create_bidirectional_track(_junction(0, 0), a1, [])
	ed.create_bidirectional_track(a1, j1, [])
	var north_wp: Array[Vector2] = [Vector2(1200, -80)]
	var south_wp: Array[Vector2] = [Vector2(1200, 80)]
	ed.create_bidirectional_track(j1, j2, north_wp)
	ed.create_bidirectional_track(j1, j2, south_wp)
	ed.create_bidirectional_track(j2, b0, [])
	ed.create_bidirectional_track(b0, _junction(2400, 0), [])
	var town_a := _stationed_town(m, 300, 0)
	var town_b := _stationed_town(m, 2100, 0)
	if with_signals:
		# A signal at each end of each loop branch. Sample the click points
		# before the first split invalidates the original curve.
		for branch in _loop_branches(m, j1, j2):
			var near: Vector2 = branch.position_at(0.06)
			var far: Vector2 = branch.position_at(0.94)
			is_true(ed.place_signal(near) != null)
			is_true(ed.place_signal(far) != null)
	return [m, town_a, town_b]

## The two forward branch segments of the loop (one per side).
func _loop_branches(m: Node2D, j1: NetworkNode, j2: NetworkNode) -> Array:
	var branches: Array = []
	for seg in m.network.get_outgoing(j1):
		if seg.node_end == j2:
			branches.append(seg)
	return branches

## Run the simulation for a number of ticks, tallying per-train arrivals
## (dwell just started) and recording whether any train was ever flagged
## deadlocked or any block was held by two trains at once.
func _run_sim(m: Node2D, ticks: int) -> Dictionary:
	var arrivals := {}
	var deadlocked := false
	var conflict := false
	for tick in range(ticks):
		m._process(TICK)
		for t in m.trains:
			if t.dwell_remaining == t.dwell_time:
				arrivals[t] = arrivals.get(t, 0) + 1
			if t.deadlocked:
				deadlocked = true
		for seg in m.network.segments:
			var o: Train = seg.occupying_train
			if o != null and seg.reverse != null \
					and seg.reverse.occupying_train != null \
					and seg.reverse.occupying_train != o:
				conflict = true
	return {"arrivals": arrivals, "deadlocked": deadlocked, "conflict": conflict}

func _test_purchase() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := _stationed_town(m, 300, 0)
	m.buying_train = true
	m._try_buy_train(town.position)
	eq(m.trains.size(), 1)
	eq(m.trains[0].car_count, 1)
	eq(m.trains[0].home_platform, town.station.platforms[0])
	eq(m.money, 1000.0 - m.TRAIN_COST)
	eq(m.selected_train, 0)
	is_false(m.buying_train)
	m.free()

func _test_purchase_broke() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := _stationed_town(m, 300, 0)
	m.money = m.TRAIN_COST - 1.0
	m.buying_train = true
	m._try_buy_train(town.position)
	eq(m.trains.size(), 0)
	is_true(m.status_message != "")
	is_true(m.buying_train)  # mode stays for another attempt
	m.free()

func _test_purchase_duplicate_home() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := _stationed_town(m, 300, 0)
	m.buying_train = true
	m._try_buy_train(town.position)
	m.buying_train = true
	m._try_buy_train(town.position)  # same platform — rejected
	eq(m.trains.size(), 1)
	is_true(m.status_message != "")
	eq(m.money, 1000.0 - m.TRAIN_COST)  # charged once
	m.free()

func _test_purchase_undo() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := _stationed_town(m, 300, 0)
	m.buying_train = true
	m._try_buy_train(town.position)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.trains.size(), 0)
	eq(m.money, 1000.0)
	m.free()

func _test_resize() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := _stationed_town(m, 300, 0)
	_add_train(m, town, [])
	m._grow_selected_train()
	eq(m.trains[0].car_count, 2)
	eq(m.money, 1000.0 - m.COST_PER_CAR)
	m._shrink_selected_train()
	eq(m.trains[0].car_count, 1)
	eq(m.money, 1000.0)
	m._shrink_selected_train()  # 1 car is the minimum
	eq(m.trains[0].car_count, 1)
	eq(m.money, 1000.0)
	m.money = 100000.0
	for i in range(10):
		m._grow_selected_train()
	eq(m.trains[0].car_count, m._max_car_count())  # capped to the platform
	m.free()

func _test_start_needs_two_stops() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(1200, 0), [])
	var a := _stationed_town(m, 300, 0)
	var b := _stationed_town(m, 900, 0)
	_add_train(m, a, [b, a])
	_add_train(m, b, [a])  # only one stop
	m._start_simulation()
	eq(m.state, m.GameState.EDITING)
	is_true(m.status_message.contains("Train 2"))
	m.free()

func _test_start_reserves_homes() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(1200, 0), [])
	var a := _stationed_town(m, 300, 0)
	var b := _stationed_town(m, 900, 0)
	var t1 := _add_train(m, a, [b, a])
	var t2 := _add_train(m, b, [a, b])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	# Each home platform pair is held by its own train (forward or reverse,
	# depending on the direction of the first leg).
	is_true(a.station.platforms[0].segment.is_occupied_by_other(t2))
	is_true(b.station.platforms[0].segment.is_occupied_by_other(t1))
	m.free()

func _test_undo_cleared_at_start() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(1200, 0), [])
	var a := _stationed_town(m, 300, 0)
	var b := _stationed_town(m, 900, 0)
	_add_train(m, a, [b, a])
	m._place_town(Vector2(400, 400))  # any undoable action
	eq(m.undo_stack.size(), 1)
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	eq(m.undo_stack.size(), 0)
	m.free()

## Two disconnected lines, one train each: both must run their loops without
## interfering with each other.
func _two_line_world() -> Array:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(1200, 0), [])
	ed.create_bidirectional_track(_junction(0, 400), _junction(1200, 400), [])
	var a1 := _stationed_town(m, 300, 0)
	var b1 := _stationed_town(m, 900, 0)
	var a2 := _stationed_town(m, 300, 400)
	var b2 := _stationed_town(m, 900, 400)
	_add_train(m, a1, [b1, a1])
	_add_train(m, a2, [b2, a2])
	return [m, b1]

func _test_independent_trains() -> void:
	var world := _two_line_world()
	var m: Node2D = world[0]
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var result := _run_sim(m, 900)  # 30 s: several stops each
	var arrivals: Dictionary = result["arrivals"]
	gt(arrivals.get(m.trains[0], 0), 1)
	gt(arrivals.get(m.trains[1], 0), 1)
	is_false(result["deadlocked"])
	is_false(result["conflict"])
	m.free()

func _test_dispatch_failure_isolated() -> void:
	var world := _two_line_world()
	var m: Node2D = world[0]
	var b1: Town = world[1]
	m._start_simulation()
	# Train 1's target town loses its station mid-run: train 1 must end up
	# halted while train 2 keeps serving its line.
	b1.station = null
	var result := _run_sim(m, 1200)
	var t1: Train = m.trains[0]
	var t2: Train = m.trains[1]
	is_true(t1.stalled)
	eq(m.state, m.GameState.SIMULATING)  # the simulation keeps running
	gt(result["arrivals"].get(t2, 0), 2)
	m.free()

func _test_stop_parks_and_releases() -> void:
	var world := _two_line_world()
	var m: Node2D = world[0]
	m._start_simulation()
	var result := _run_sim(m, 150)  # trains out on the line
	is_false(result["conflict"])
	m._stop_simulation("stopped")
	eq(m.state, m.GameState.EDITING)
	for t in m.trains:
		is_false(t.has_route())
		eq(t.passengers_on_board, 0)
	for seg in m.network.segments:
		eq(seg.occupying_train, null)
	m.free()

func _test_passing_loop_signalled() -> void:
	# The post-mortem scenario: two trains, two stations, a passing loop with
	# a signal at each end of each branch — trains must pass and keep
	# completing their orders, with no deadlock and no double-held block.
	var world := _passing_loop_world(true)
	var m: Node2D = world[0]
	var town_a: Town = world[1]
	var town_b: Town = world[2]
	_add_train(m, town_a, [town_b, town_a])
	_add_train(m, town_b, [town_a, town_b])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var result := _run_sim(m, 6000)  # 200 s of simulation
	var arrivals: Dictionary = result["arrivals"]
	gt(arrivals.get(m.trains[0], 0), 2)  # several full crossings each
	gt(arrivals.get(m.trains[1], 0), 2)
	is_false(result["deadlocked"])
	is_false(result["conflict"])
	eq(m.state, m.GameState.SIMULATING)
	m.free()

func _test_passing_loop_approach_signals() -> void:
	# Regression: the signalled passing loop plus a signal on each single-line
	# corridor between a station and the loop. Departure spans then end at the
	# approach signals — nowhere near the loop — so at dispatch neither train
	# sees the other and both plan through the same branch. The route must be
	# replanned before a train reserves onward through the loop divergence
	# (_replan_blocked_route); without that, both trains commit into one branch
	# from opposite ends and wedge while the other branch sits empty.
	var world := _passing_loop_world(true)
	var m: Node2D = world[0]
	var town_a: Town = world[1]
	var town_b: Town = world[2]
	var ed: TrackEditor = m.editor
	is_true(ed.place_signal(Vector2(750, 0)) != null)   # west approach
	is_true(ed.place_signal(Vector2(1650, 0)) != null)  # east approach
	_add_train(m, town_a, [town_b, town_a])
	_add_train(m, town_b, [town_a, town_b])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var result := _run_sim(m, 6000)  # 200 s of simulation
	var arrivals: Dictionary = result["arrivals"]
	gt(arrivals.get(m.trains[0], 0), 2)
	gt(arrivals.get(m.trains[1], 0), 2)
	is_false(result["deadlocked"])
	is_false(result["conflict"])
	eq(m.state, m.GameState.SIMULATING)
	m.free()

## A main line with THROUGH stations near both ends (stub track beyond them)
## and a bowed bypass branch between two mid-line junctions. Signals: two on
## the main-line corridor (x 350 and 795) and one on each half of the bypass.
## kinds is 4 chars for [corridor-west, corridor-east, bypass-west,
## bypass-east]: "2" two-way, "P" path, "1" one-way; facings "E"/"W" each.
## Returns [m, town_a, town_b].
func _bypass_world(kinds: String, facings: String) -> Array:
	var m := _main()
	var ed: TrackEditor = m.editor
	var j1 := _junction(275, 300)
	var j2 := _junction(920, 300)
	var mid_n := _junction(580, 262)
	ed.create_bidirectional_track(_junction(50, 300), j1, [])
	ed.create_bidirectional_track(j1, j2, [])  # the corridor is the main line
	ed.create_bidirectional_track(j2, _junction(1190, 300), [])
	ed.create_bidirectional_track(j1, mid_n, [Vector2(410, 275)] as Array[Vector2])
	ed.create_bidirectional_track(mid_n, j2, [Vector2(760, 275)] as Array[Vector2])
	var town_a := _stationed_town(m, 160, 300)
	var town_b := _stationed_town(m, 1060, 300)
	var spots := [Vector2(350, 300), Vector2(795, 300), Vector2(410, 275), Vector2(760, 275)]
	for i in range(4):
		var node: NetworkNode = ed.place_signal(spots[i])
		is_true(node != null)
		match kinds[i]:
			"2": node.signal_kind = NetworkNode.SignalKind.TWO_WAY
			"P": node.signal_kind = NetworkNode.SignalKind.PATH
			"1": node.signal_kind = NetworkNode.SignalKind.ONE_WAY
		node.signal_facing = Vector2.RIGHT if facings[i] == "E" else Vector2.LEFT
	return [m, town_a, town_b]

## Run a bypass world with a train homed at each station shuttling A<->B.
## Train 2 runs slightly slower so the pair drifts through every relative
## phase, hunting the wedge-prone timings. Asserts sustained service with no
## deadlock and no double-held block.
func _run_bypass_world(kinds: String, facings: String) -> void:
	var world := _bypass_world(kinds, facings)
	var m: Node2D = world[0]
	var town_a: Town = world[1]
	var town_b: Town = world[2]
	_add_train(m, town_a, [town_b, town_a])
	_add_train(m, town_b, [town_a, town_b])
	m.trains[1].speed *= 0.91
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var result := _run_sim(m, 2500)  # ~83 s of simulation
	gt(result["arrivals"].get(m.trains[0], 0), 4)
	gt(result["arrivals"].get(m.trains[1], 0), 4)
	is_false(result["deadlocked"])
	is_false(result["conflict"])
	m.free()

func _test_corridor_one_way_bypass() -> void:
	# Regression: the bypass one-way EASTBOUND (facing never flipped), so
	# westbound traffic must use the corridor. An eastbound train entering the
	# corridor toward a train that is arriving at / dwelling in station B used
	# to wedge nose-to-nose with it when it departed westward — the dweller's
	# only exit is the corridor the other train parked in. Departure-route
	# prediction (TrackNetwork.opposed_blocks) plus span re-anchoring
	# (Train.adopt_route_tail) must keep them apart.
	_run_bypass_world("2211", "EEEE")

func _test_directional_path_loop() -> void:
	# Regression: PATH signals facing east on the corridor and west on the
	# bypass. For each travel direction one branch has NO governing signals,
	# so a route through it spans all the way to the destination platform.
	# When both trains dwell at home at once, routing must not steer each
	# onto its signal-less branch (to dodge the other's predicted exit) —
	# those spans end at each other's occupied platforms and neither train
	# could even depart. SPAN_BLOCKED_PENALTY prices that unreservable first
	# span above any post-signal congestion.
	_run_bypass_world("PPPP", "EEWW")

func _test_no_signal_standoff() -> void:
	# The same layout with no signals: spans run platform to platform, so
	# both trains hold at their home platforms — a visible stationary
	# standoff that deadlock detection reports, not a mid-track wedge.
	var world := _passing_loop_world(false)
	var m: Node2D = world[0]
	var town_a: Town = world[1]
	var town_b: Town = world[2]
	_add_train(m, town_a, [town_b, town_a])
	_add_train(m, town_b, [town_a, town_b])
	m._start_simulation()
	var result := _run_sim(m, 300)
	eq(result["arrivals"].size(), 0)  # nobody ever left
	is_false(result["conflict"])
	is_true(result["deadlocked"])
	for t in m.trains:
		is_true(t.waiting_for_block)
		is_true(t.deadlocked)
		is_true(t.current_segment().is_platform_segment())  # still at home
	m.free()

func _test_one_way_loop() -> void:
	# The passing-loop layout with its four signals made one-way: the north
	# branch eastbound-only, the south branch westbound-only (both branches run
	# left-to-right in x, so RIGHT/LEFT facings pick the direction). Trains
	# must keep crossing, never standing on a segment they entered illegally.
	var world := _passing_loop_world(true)
	var m: Node2D = world[0]
	var town_a: Town = world[1]
	var town_b: Town = world[2]
	for node in m.network.nodes:
		if node.is_signal:
			node.signal_kind = NetworkNode.SignalKind.ONE_WAY
			node.signal_facing = Vector2.RIGHT if node.position.y < 0.0 else Vector2.LEFT
	_add_train(m, town_a, [town_b, town_a])
	_add_train(m, town_b, [town_a, town_b])
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	var arrivals := {}
	var deadlocked := false
	var illegal := false
	for tick in range(6000):
		m._process(TICK)
		for t in m.trains:
			if t.dwell_remaining == t.dwell_time:
				arrivals[t] = arrivals.get(t, 0) + 1
			if t.deadlocked:
				deadlocked = true
			var seg: TrackSegment = t.current_segment()
			if seg != null and not TrackNetwork.can_enter(seg):
				illegal = true
	gt(arrivals.get(m.trains[0], 0), 2)
	gt(arrivals.get(m.trains[1], 0), 2)
	is_false(deadlocked)
	is_false(illegal)
	m.free()

func _test_queued_not_deadlock() -> void:
	var m := _main()
	var s1 := TrackSegment.new(_junction(0, 0), _junction(100, 0))
	var s2 := TrackSegment.new(_junction(100, 0), _junction(200, 0))
	var s3 := TrackSegment.new(_junction(200, 0), _junction(300, 0))
	var t1 := Train.new()
	var t2 := Train.new()
	m.trains.append(t1)
	m.trains.append(t2)
	# t1 waits for a block held by t2 while t2 is still moving: not a deadlock.
	t1.route = [s1, s2]
	t1.reserved_until = 0
	t1.waiting_for_block = true
	s1.reserve(t1)
	s2.reserve(t2)
	m._detect_deadlocks()
	is_false(t1.deadlocked)
	is_false(t2.deadlocked)
	# Now t2 waits for a block t1 holds: a cycle — both are deadlocked.
	t2.route = [s3]
	t2.reserved_until = -1
	t2.waiting_for_block = true
	s3.reserve(t1)
	m._detect_deadlocks()
	is_true(t1.deadlocked)
	is_true(t2.deadlocked)
	m.free()
