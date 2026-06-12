class_name TestTrackNetwork
extends TestBase

func _node(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

func _seg(a: NetworkNode, b: NetworkNode) -> TrackSegment:
	return TrackSegment.new(a, b)

## Build a platform pair between two nodes and register it on a network.
func _platform(net: TrackNetwork, a: NetworkNode, b: NetworkNode) -> Platform:
	var fwd := TrackSegment.new(a, b)
	var rev := TrackSegment.new(b, a)
	net.add_segment(fwd)
	net.add_segment(rev)
	var platform := Platform.new(fwd, rev, 1.0)
	fwd.platform = platform
	rev.platform = platform
	return platform

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
	_t("cleanup_orphan_keeps_connected", _test_cleanup_keeps_connected)
	_t("route_through_junction", _test_route_through_junction)
	_t("route_to_platform_traverses_platform", _test_route_to_platform)
	_t("route_to_platform_from_entry_node", _test_route_to_platform_from_entry)
	_t("route_to_platform_from_exit_node", _test_route_to_platform_from_exit)
	_t("route_to_platform_no_path", _test_route_to_platform_no_path)

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
	var a := _node(0, 0)
	var b := _node(0, 200)
	var m := _node(0, 100)
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
	var j := _node(50, 50)
	net.add_node(j)
	is_true(net.nodes.has(j))
	var removed := net.cleanup_orphan(j)
	is_true(removed)
	is_false(net.nodes.has(j))

func _test_cleanup_keeps_connected() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(100, 0)
	net.add_segment(_seg(a, b))
	var removed := net.cleanup_orphan(a)
	is_false(removed)
	is_true(net.nodes.has(a))

func _test_route_through_junction() -> void:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var j := _node(100, 0)
	var b := _node(200, 0)
	var aj := TrackSegment.new(a, j)
	var jb := TrackSegment.new(j, b)
	net.add_segment(aj)
	net.add_segment(jb)
	var route := net.find_route(a, b)
	eq(route.size(), 2)
	eq(route[0], aj)
	eq(route[1], jb)

func _test_route_to_platform() -> void:
	# a --- entry ===platform=== exit: route enters at the nearer end and
	# always finishes having crossed the platform.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var entry := _node(100, 0)
	var exit := _node(220, 0)
	var approach := _seg(a, entry)
	net.add_segment(approach)
	net.add_segment(_seg(entry, a))
	var platform := _platform(net, entry, exit)
	var route := net.find_route_to_platform(a, platform)
	eq(route.size(), 2)
	eq(route[0], approach)
	eq(route[1], platform.segment)

func _test_route_to_platform_from_entry() -> void:
	var net := TrackNetwork.new()
	var entry := _node(0, 0)
	var exit := _node(120, 0)
	var platform := _platform(net, entry, exit)
	var route := net.find_route_to_platform(entry, platform)
	eq(route.size(), 1)
	eq(route[0], platform.segment)

func _test_route_to_platform_from_exit() -> void:
	var net := TrackNetwork.new()
	var entry := _node(0, 0)
	var exit := _node(120, 0)
	var platform := _platform(net, entry, exit)
	var route := net.find_route_to_platform(exit, platform)
	eq(route.size(), 1)
	eq(route[0], platform.reverse_segment)

func _test_route_to_platform_no_path() -> void:
	var net := TrackNetwork.new()
	var lonely := _node(-500, -500)
	net.add_node(lonely)
	var platform := _platform(net, _node(0, 0), _node(120, 0))
	var route := net.find_route_to_platform(lonely, platform)
	eq(route.size(), 0)
