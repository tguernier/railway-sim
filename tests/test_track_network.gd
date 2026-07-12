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
	_t("unroutable_stop_connected_loop", _test_unroutable_stop_connected)
	_t("unroutable_stop_disconnected", _test_unroutable_stop_disconnected)
	_t("unroutable_stop_on_wrap_leg", _test_unroutable_stop_wrap)
	_t("two_way_signal_passable_both_directions", _test_two_way_signal_routable)
	_t("one_way_signal_bars_reverse_direction", _test_one_way_signal_bars)
	_t("one_way_signal_forces_other_branch", _test_one_way_forces_branch)
	_t("unroutable_when_only_path_is_one_way_against", _test_one_way_unroutable_stop)
	_t("penalty_prefers_free_branch", _test_penalty_prefers_free_branch)
	_t("penalty_all_blocked_returns_shortest", _test_penalty_all_blocked)
	_t("reverse_twin_reservation_penalizes", _test_reverse_twin_penalized)
	_t("one_way_still_bars_with_for_train", _test_one_way_bars_with_train)
	_t("platform_entry_end_avoids_traffic", _test_platform_entry_end)
	_t("unroutable_stop_ignores_reservations", _test_unroutable_ignores_reservations)

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

func _test_unroutable_stop_connected() -> void:
	# p1(a-b) <-> p2(c-d) joined by bidirectional track on both legs.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(120, 0)
	var c := _node(240, 0)
	var d := _node(360, 0)
	var p1 := _platform(net, a, b)
	var p2 := _platform(net, c, d)
	net.add_segment(_seg(b, c))
	net.add_segment(_seg(c, b))
	net.add_segment(_seg(d, a))
	net.add_segment(_seg(a, d))
	eq(net.first_unroutable_stop([p1, p2]), -1)

func _test_unroutable_stop_disconnected() -> void:
	# Two platforms on separate track islands — stop 2 is unreachable.
	var net := TrackNetwork.new()
	var p1 := _platform(net, _node(0, 0), _node(120, 0))
	var p2 := _platform(net, _node(500, 0), _node(620, 0))
	eq(net.first_unroutable_stop([p1, p2]), 1)

## A linked twin pair added to the network. Returns the forward segment.
func _twin(net: TrackNetwork, a: NetworkNode, b: NetworkNode) -> TrackSegment:
	var fwd := TrackSegment.new(a, b)
	var rev := TrackSegment.new(b, a)
	fwd.reverse = rev
	rev.reverse = fwd
	net.add_segment(fwd)
	net.add_segment(rev)
	return fwd

func _test_two_way_signal_routable() -> void:
	# a —— J —— b with a two-way signal at J: both directions still route.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var j := _node(100, 0)
	var b := _node(200, 0)
	var aj := _twin(net, a, j)
	var jb := _twin(net, j, b)
	aj.exit_signal = true  # arriving at J eastbound
	jb.reverse.exit_signal = true  # arriving at J westbound
	eq(net.find_route(a, b).size(), 2)
	eq(net.find_route(b, a).size(), 2)

func _test_one_way_signal_bars() -> void:
	# The same line with a one-way signal at J serving a→b only: the reverse
	# direction may not pass J any more.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var j := _node(100, 0)
	var b := _node(200, 0)
	var aj := _twin(net, a, j)
	_twin(net, j, b)
	aj.exit_signal = true
	eq(net.find_route(a, b).size(), 2)
	eq(net.find_route(b, a).size(), 0)

func _test_one_way_forces_branch() -> void:
	# A passing loop: two parallel branches between LW and LE, branch 1
	# signalled eastbound-only, branch 2 westbound-only. Each direction is
	# forced onto its own branch.
	var net := TrackNetwork.new()
	var w := _node(0, 0)
	var lw := _node(100, 0)
	var le := _node(300, 0)
	var e := _node(400, 0)
	_twin(net, w, lw)
	var branch1 := _twin(net, lw, le)
	var branch2 := _twin(net, lw, le)
	_twin(net, le, e)
	branch1.exit_signal = true  # one-way signal at LE serving eastbound
	branch2.reverse.exit_signal = true  # one-way signal at LW serving westbound
	var east := net.find_route(w, e)
	eq(east.size(), 3)
	is_true(east.has(branch1))
	is_false(east.has(branch2))
	var west := net.find_route(e, w)
	eq(west.size(), 3)
	is_true(west.has(branch2.reverse))
	is_false(west.has(branch1.reverse))

func _test_one_way_unroutable_stop() -> void:
	# p1(a-b) —— p2(c-d) joined by one twin pair; the loop validates until a
	# one-way signal turns the middle eastbound-only, breaking the wrap leg.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(120, 0)
	var c := _node(240, 0)
	var d := _node(360, 0)
	var p1 := _platform(net, a, b)
	var p2 := _platform(net, c, d)
	var link := _twin(net, b, c)
	eq(net.first_unroutable_stop([p1, p2]), -1)
	link.exit_signal = true  # one-way at c serving b→c only
	eq(net.first_unroutable_stop([p1, p2]), 0)

## A short and a long branch between the same two nodes, the short one held
## by another train. Returns [net, a, b, short_seg, long_seg, holder].
func _blocked_branch_pair() -> Array:
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(200, 0)
	var short_seg := _twin(net, a, b)
	var wps: Array[Vector2] = [Vector2(100, 300)]
	var long_seg := TrackSegment.new(a, b, wps)
	net.add_segment(long_seg)
	var holder := Train.new()
	holder.try_reserve([short_seg])
	return [net, a, b, short_seg, long_seg, holder]

func _test_penalty_prefers_free_branch() -> void:
	var w := _blocked_branch_pair()
	var net: TrackNetwork = w[0]
	var tr := Train.new()
	# The routing train pays the penalty on the held branch and detours...
	var route := net.find_route(w[1], w[2], tr)
	eq(route.size(), 1)
	eq(route[0], w[4])
	# ...while trainless routing and the holder itself still get the short one.
	eq(net.find_route(w[1], w[2])[0], w[3])
	eq(net.find_route(w[1], w[2], w[5])[0], w[3])

func _test_penalty_all_blocked() -> void:
	# With every branch held, the penalties cancel out and the shortest route
	# is still returned — traffic is never a reason for routing to fail.
	var w := _blocked_branch_pair()
	var net: TrackNetwork = w[0]
	var holder: Train = w[5]
	holder.try_reserve([w[4]])
	var route := net.find_route(w[1], w[2], Train.new())
	eq(route.size(), 1)
	eq(route[0], w[3])

func _test_reverse_twin_penalized() -> void:
	# Head-on case: the twin of the short branch being held blocks it just as
	# hard as the branch itself.
	var w := _blocked_branch_pair()
	var net: TrackNetwork = w[0]
	var holder: Train = w[5]
	var short_seg: TrackSegment = w[3]
	holder.release_all()
	holder.try_reserve([short_seg.reverse])
	eq(net.find_route(w[1], w[2], Train.new())[0], w[4])

func _test_one_way_bars_with_train() -> void:
	# one_way_against stays a hard exclusion, not a penalty: the barred
	# direction is unroutable no matter who asks.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var j := _node(100, 0)
	var b := _node(200, 0)
	var aj := _twin(net, a, j)
	_twin(net, j, b)
	aj.exit_signal = true
	eq(net.find_route(b, a, Train.new()).size(), 0)

func _test_platform_entry_end() -> void:
	# s → x → entry ═platform═ exit ← y ← s: with the short approach to the
	# entry end held by another train, the routing train pays the long way
	# around and enters the platform from the exit end instead.
	var net := TrackNetwork.new()
	var s := _node(0, 0)
	var x := _node(100, 0)
	var entry := _node(200, 0)
	var exit := _node(320, 0)
	var y := _node(420, 0)
	var platform := _platform(net, entry, exit)
	var sx := _twin(net, s, x)
	_twin(net, x, entry)
	var wps: Array[Vector2] = [Vector2(210, 300)]
	var sy := TrackSegment.new(s, y, wps)
	net.add_segment(sy)
	net.add_segment(_seg(y, exit))
	var tr := Train.new()
	eq(net.find_route_to_platform(s, platform, tr)[-1], platform.segment)
	var holder := Train.new()
	holder.try_reserve([sx])
	var route := net.find_route_to_platform(s, platform, tr)
	eq(route[-1], platform.reverse_segment)
	is_true(route.has(sy))

func _test_unroutable_ignores_reservations() -> void:
	# Loop validation stays on the plain graph: a layout must not be rejected
	# because of where trains happen to stand.
	var net := TrackNetwork.new()
	var a := _node(0, 0)
	var b := _node(120, 0)
	var c := _node(240, 0)
	var d := _node(360, 0)
	var p1 := _platform(net, a, b)
	var p2 := _platform(net, c, d)
	var bc := _twin(net, b, c)
	var da := _twin(net, d, a)
	var holder := Train.new()
	holder.try_reserve([bc, da, p1.segment, p2.segment])
	eq(net.first_unroutable_stop([p1, p2]), -1)

func _test_unroutable_stop_wrap() -> void:
	# One-way link p1 -> p2 but no way back: the loop fails on the wrap-around
	# leg, so stop 1 (index 0) is the unreachable one.
	var net := TrackNetwork.new()
	var b := _node(120, 0)
	var c := _node(240, 0)
	var p1 := _platform(net, _node(0, 0), b)
	var p2 := _platform(net, c, _node(360, 0))
	net.add_segment(_seg(b, c))
	eq(net.first_unroutable_stop([p1, p2]), 0)
