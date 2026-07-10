class_name TestGameSnapshot
extends TestBase

func run_all() -> void:
	print("[TestGameSnapshot]")
	_t("clone_counts_match", _test_counts)
	_t("clone_twins_are_mutual", _test_twins)
	_t("clone_curves_preserved", _test_curves)
	_t("clone_station_wiring_survives", _test_station_wiring)
	_t("clone_orders_identity_mapped", _test_orders_mapped)
	_t("clone_routes_across_adjacency", _test_routing)
	_t("clone_isolated_junction_survives", _test_isolated_junction)
	_t("clone_copies_signal_kind_and_facing", _test_signal_cloned)
	_t("mutating_original_leaves_clone_untouched", _test_isolation)
	_t("restore_swaps_state_into_main", _test_restore)

## The snapshot targets the main game node, so tests drive a real instance.
func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

## Build a world with a curved pair, a split junction, and a stationed town:
## a(0,0) ~curve~ b(600,0), b–c(1200,0) split at (900,0), station on the
## b-side half serving a town at (750,30). 10 segments, 6 junctions.
func _build_world(m: Node2D) -> Town:
	var ed: TrackEditor = m.editor
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(600, 0))
	var c := NetworkNode.junction(Vector2(1200, 0))
	ed.create_bidirectional_track(a, b, [Vector2(300, 60)])
	ed.create_bidirectional_track(b, c, [])
	ed.split_track_at_hit(ed.find_track_at(Vector2(900, 0)))
	var town := Town.new(Vector2(750, 30), Color.SEA_GREEN)
	town.waiting = 7.0
	m.towns.append(town)
	ed.place_station(Vector2(750, 0), m.towns)
	var train := Train.new()
	train.car_count = 3
	train.home_platform = town.station.platforms[0]
	train.orders.append(town)
	m.trains.append(train)
	m.money = 750.0
	m.next_color_index = 3
	return town

## Find the network node at a position, or null.
func _node_at(net: TrackNetwork, pos: Vector2) -> NetworkNode:
	for node in net.nodes:
		if node.position.distance_to(pos) < 1.0:
			return node
	return null

## Find the segment running from p0 to p1 (by endpoint position), or null.
func _seg_between(net: TrackNetwork, p0: Vector2, p1: Vector2) -> TrackSegment:
	for seg in net.segments:
		if seg.node_start.position.distance_to(p0) < 1.0 \
				and seg.node_end.position.distance_to(p1) < 1.0:
			return seg
	return null

func _test_counts() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	eq(snap.network.segments.size(), m.network.segments.size())
	eq(snap.network.segments.size(), 10)
	eq(snap.network.nodes.size(), 6)
	eq(snap.towns.size(), 1)
	eq(snap.trains.size(), 1)
	eq(snap.money, 750.0)
	eq(snap.next_color_index, 3)
	m.free()

func _test_twins() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	for seg in snap.network.segments:
		is_true(seg.reverse != null)
		eq(seg.reverse.reverse, seg)
		eq(seg.reverse.node_start, seg.node_end)
		eq(seg.reverse.node_end, seg.node_start)
		is_false(m.network.segments.has(seg))
	m.free()

func _test_curves() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	var original := _seg_between(m.network, Vector2(0, 0), Vector2(600, 0))
	var clone := _seg_between(snap.network, Vector2(0, 0), Vector2(600, 0))
	is_true(clone != null)
	approx(clone.length(), original.length(), 1.0)
	approx(clone.position_at(0.5).y, original.position_at(0.5).y, 1.0)
	gt(clone.position_at(0.5).y, 20.0)  # the curve bulge survived cloning
	m.free()

func _test_station_wiring() -> void:
	var m := _main()
	var town := _build_world(m)
	var snap := GameSnapshot.capture(m)
	var clone_town: Town = snap.towns[0]
	is_true(clone_town != town)
	is_true(clone_town.station != null)
	is_true(clone_town.station != town.station)
	eq(clone_town.waiting, 7.0)
	var platform: Platform = clone_town.station.platforms[0]
	is_true(platform.segment.is_platform_segment())
	eq(platform.segment.platform, platform)
	eq(platform.reverse_segment.platform, platform)
	eq(platform.station.town, clone_town)
	eq(platform.segment.reverse, platform.reverse_segment)
	eq(platform.side, town.station.platforms[0].side)
	is_true(snap.network.segments.has(platform.segment))
	is_true(snap.network.segments.has(platform.reverse_segment))
	m.free()

func _test_orders_mapped() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	var train_clone: Train = snap.trains[0]
	is_true(train_clone != m.trains[0])
	eq(train_clone.car_count, 3)
	eq(train_clone.orders[0], snap.towns[0])
	eq(train_clone.home_platform, snap.towns[0].station.platforms[0])
	m.free()

func _test_routing() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	var from := _node_at(snap.network, Vector2(0, 0))
	var to := _node_at(snap.network, Vector2(1200, 0))
	is_true(from != null)
	is_true(to != null)
	var route := snap.network.find_route(from, to)
	gt(route.size(), 0)
	eq(route[-1].node_end, to)
	m.free()

func _test_isolated_junction() -> void:
	var m := _main()
	_build_world(m)
	m.network.add_node(NetworkNode.junction(Vector2(50, 500)))
	var snap := GameSnapshot.capture(m)
	is_true(_node_at(snap.network, Vector2(50, 500)) != null)
	m.free()

func _test_signal_cloned() -> void:
	var m := _main()
	_build_world(m)
	var sig: NetworkNode = m.editor.place_signal(Vector2(1050, 0))
	sig.signal_kind = NetworkNode.SignalKind.ONE_WAY
	sig.signal_facing = Vector2.LEFT
	var snap := GameSnapshot.capture(m)
	var clone := _node_at(snap.network, sig.position)
	is_true(clone != null)
	is_true(clone != sig)
	eq(clone.signal_kind, NetworkNode.SignalKind.ONE_WAY)
	eq(clone.signal_facing, Vector2.LEFT)
	m.free()

func _test_isolation() -> void:
	var m := _main()
	var town := _build_world(m)
	var snap := GameSnapshot.capture(m)
	m.editor.try_delete_track_at(Vector2(1050, 0))  # the c-side half pair
	town.waiting = 99.0
	m.towns.clear()
	eq(m.network.segments.size(), 8)
	eq(snap.network.segments.size(), 10)
	eq(snap.towns.size(), 1)
	eq(snap.towns[0].waiting, 7.0)
	m.free()

func _test_restore() -> void:
	var m := _main()
	_build_world(m)
	var snap := GameSnapshot.capture(m)
	m.hovered_town = m.towns[0]
	m.next_color_index = 8
	m.money = 20.0
	snap.restore(m)
	eq(m.network, snap.network)
	eq(m.editor.network, snap.network)
	eq(m.towns[0], snap.towns[0])
	eq(m.trains[0], snap.trains[0])
	eq(m.money, 750.0)
	eq(m.next_color_index, 3)
	eq(m.hovered_town, null)
	eq(m.hovered_junction, null)
	m.free()
