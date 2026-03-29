class_name TestTrackNetwork
extends TestBase

func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _seg(a: Town, b: Town) -> TrackSegment:
	return TrackSegment.new(a, b)

func run_all() -> void:
	print("[TestTrackNetwork]")
	_t("add_segment_stored", _test_add_stored)
	_t("get_outgoing_returns_segment", _test_get_outgoing)
	_t("get_outgoing_unknown_town_empty", _test_get_outgoing_unknown)
	_t("find_route_direct", _test_find_route_direct)
	_t("find_route_two_hops", _test_find_route_two_hops)
	_t("find_route_no_path", _test_find_route_no_path)
	_t("find_route_same_town_no_loop", _test_find_route_same_town)

func _test_add_stored() -> void:
	var net := TrackNetwork.new()
	var seg := _seg(_town(0, 0), _town(100, 0))
	net.add_segment(seg)
	eq(net.segments.size(), 1)
	eq(net.segments[0], seg)

func _test_get_outgoing() -> void:
	var net := TrackNetwork.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	var seg := _seg(a, b)
	net.add_segment(seg)
	var out := net.get_outgoing(a)
	eq(out.size(), 1)
	eq(out[0], seg)

func _test_get_outgoing_unknown() -> void:
	var net := TrackNetwork.new()
	var out := net.get_outgoing(_town(0, 0))
	eq(out.size(), 0)

func _test_find_route_direct() -> void:
	var net := TrackNetwork.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	var seg := _seg(a, b)
	net.add_segment(seg)
	var route := net.find_route(a, b)
	eq(route.size(), 1)
	eq(route[0], seg)

func _test_find_route_two_hops() -> void:
	var net := TrackNetwork.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	var c := _town(200, 0)
	var ab := _seg(a, b)
	var bc := _seg(b, c)
	net.add_segment(ab)
	net.add_segment(bc)
	var route := net.find_route(a, c)
	eq(route.size(), 2)
	eq(route[0], ab)
	eq(route[1], bc)

func _test_find_route_no_path() -> void:
	var net := TrackNetwork.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	var c := _town(200, 0)
	net.add_segment(_seg(a, b))
	# No segment from b to c, or directly from a to c.
	var route := net.find_route(a, c)
	eq(route.size(), 0)

func _test_find_route_same_town() -> void:
	# BFS never enqueues the start town again, so from==to returns [].
	var net := TrackNetwork.new()
	var a := _town(0, 0)
	net.add_segment(_seg(a, _town(100, 0)))
	var route := net.find_route(a, a)
	eq(route.size(), 0)
