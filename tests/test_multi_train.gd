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
