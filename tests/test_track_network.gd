class_name TestTrackNetwork
extends TestBase

func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _node(x: float, y: float) -> NetworkNode:
	return _town(x, y).node

func _seg(a: NetworkNode, b: NetworkNode) -> TrackSegment:
	return TrackSegment.new(a, b)

func run_all() -> void:
	print("[TestTrackNetwork]")
	_t("add_segment_stored", _test_add_stored)
	_t("add_segment_registers_nodes", _test_add_registers_nodes)
	_t("get_outgoing_returns_segment", _test_get_outgoing)
	_t("get_outgoing_unknown_node_empty", _test_get_outgoing_unknown)
	_t("find_route_direct", _test_find_route_direct)
	_t("find_route_two_hops", _test_find_route_two_hops)
	_t("find_route_no_path", _test_find_route_no_path)
	_t("find_route_same_node_no_loop", _test_find_route_same_node)
	_t("dijkstra_prefers_shorter_distance", _test_dijkstra_shorter_distance)
	_t("remove_segment", _test_remove_segment)
	_t("remove_segment_nonexistent_is_noop", _test_remove_nonexistent)
	_t("cleanup_orphan_junction", _test_cleanup_orphan)
	_t("cleanup_orphan_skips_towns", _test_cleanup_skips_towns)
	_t("route_through_junction", _test_route_through_junction)

func _test_add_stored() -> void:
	var net := TrackNetwork.new()
	var seg := _seg(_node(0, 0), _node(100, 0))
	net.add_segment(seg)
	eq(net.segments.size(), 1)
	eq(net.segments[0], seg)

func _test_add_registers_nodes() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	net.add_segment(_seg(a, b))
	is_true(net.nodes.has(a))
	is_true(net.nodes.has(b))

func _test_get_outgoing() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	var seg := _seg(a, b)
	net.add_segment(seg)
	var out := net.get_outgoing(a)
	eq(out.size(), 1)
	eq(out[0], seg)

func _test_get_outgoing_unknown() -> void:
	var net := TrackNetwork.new()
	var out := net.get_outgoing(_node(0, 0))
	eq(out.size(), 0)

func _test_find_route_direct() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	var seg := _seg(a, b)
	net.add_segment(seg)
	var route := net.find_route(a, b)
	eq(route.size(), 1)
	eq(route[0], seg)

func _test_find_route_two_hops() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	var c := _node(200, 0)
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
	var a := _node(0, 0)
	var b := _node(100, 0)
	var c := _node(200, 0)
	net.add_segment(_seg(a, b))
	var route := net.find_route(a, c)
	eq(route.size(), 0)

func _test_find_route_same_node() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	net.add_segment(_seg(a, _node(100, 0)))
	var route := net.find_route(a, a)
	eq(route.size(), 0)

func _test_dijkstra_shorter_distance() -> void:
	# A --[long detour]--> B vs A --> M --> B (shorter total distance)
	var net := TrackNetwork.new()
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(0, 200))
	var m := NetworkNode.junction(Vector2(0, 100))
	# Direct: A->B with a massive detour waypoint making the curve very long
	var detour_wp: Array[Vector2] = [Vector2(2000, 100)]
	var long_direct := TrackSegment.new(a, b, detour_wp)
	# Via M: two short straight segments
	var am := TrackSegment.new(a, m)
	var mb := TrackSegment.new(m, b)
	net.add_segment(long_direct)
	net.add_segment(am)
	net.add_segment(mb)
	# Verify the detour is actually longer
	gt(long_direct.length(), am.length() + mb.length())
	var route := net.find_route(a, b)
	# Dijkstra should pick the 2-hop shorter path
	eq(route.size(), 2)
	eq(route[0], am)
	eq(route[1], mb)

func _test_remove_segment() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	var seg := _seg(a, b)
	net.add_segment(seg)
	net.remove_segment(seg)
	eq(net.segments.size(), 0)
	eq(net.get_outgoing(a).size(), 0)

func _test_remove_nonexistent() -> void:
	var net := TrackNetwork.new()
	var seg := _seg(_node(0, 0), _node(100, 0))
	# Should not crash
	net.remove_segment(seg)
	eq(net.segments.size(), 0)

func _test_cleanup_orphan() -> void:
	var net := TrackNetwork.new()
	var j := NetworkNode.junction(Vector2(50, 50))
	net.add_node(j)
	is_true(net.nodes.has(j))
	var removed := net.cleanup_orphan(j)
	is_true(removed)
	is_false(net.nodes.has(j))

func _test_cleanup_skips_towns() -> void:
	var net := TrackNetwork.new()
	var t := _town(0, 0)
	net.add_node(t.node)
	var removed := net.cleanup_orphan(t.node)
	is_false(removed)
	is_true(net.nodes.has(t.node))

func _test_route_through_junction() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var j := NetworkNode.junction(Vector2(100, 0))
	var b := _node(200, 0)
	var aj := TrackSegment.new(a, j)
	var jb := TrackSegment.new(j, b)
	net.add_segment(aj)
	net.add_segment(jb)
	var route := net.find_route(a, b)
	eq(route.size(), 2)
	eq(route[0], aj)
	eq(route[1], jb)
