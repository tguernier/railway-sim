## Path reservation between safe waiting points (signals and platforms), and
## occupancy-aware routing. The two-train acceptance scenarios that drive the
## full simulation loop live in TestMultiTrain.
class_name TestSignalling
extends TestBase

func _node(x: float, y: float, signal_node := false) -> NetworkNode:
	var n := NetworkNode.junction(Vector2(x, y))
	n.is_signal = signal_node
	return n

func _seg(a: NetworkNode, b: NetworkNode) -> TrackSegment:
	return TrackSegment.new(a, b)

## Four 100 px segments in a line with a signal after the second:
## n0 -s0- n1 -s1- SIG -s2- n3 -s3- n4
func _route_with_signal() -> Array:
	var n0 := _node(0, 0)
	var n1 := _node(100, 0)
	var sig := _node(200, 0, true)
	var n3 := _node(300, 0)
	var n4 := _node(400, 0)
	return [_seg(n0, n1), _seg(n1, sig), _seg(sig, n3), _seg(n3, n4)]

func run_all() -> void:
	print("[TestSignalling]")
	_t("span_ends_at_signal", _test_span_ends_at_signal)
	_t("span_ends_at_route_end", _test_span_ends_at_route_end)
	_t("reserve_span_all_or_nothing", _test_reserve_span_atomic)
	_t("move_reserves_first_span_on_departure", _test_departure_reserves)
	_t("departure_held_while_first_span_blocked", _test_departure_gated)
	_t("train_holds_at_signal_until_span_frees", _test_hold_at_signal)
	_t("wanted_span_reports_blocked_segments", _test_wanted_span)
	_t("turnaround_transfers_platform_block", _test_turnaround_transfer)
	_t("resume_forward_keeps_platform_block", _test_resume_forward_block)
	_t("dwelling_train_blocks_platform_span", _test_dwell_blocks_platform)
	_t("dijkstra_penalizes_occupied_segments", _test_penalty_routing)
	_t("route_to_platform_prefers_free_end", _test_penalty_platform_end)
	_t("directional_signal_governs_facing_only", _test_directional_governs)
	_t("one_way_signal_blocks_travel_from_behind", _test_blocks_travel)
	_t("span_passes_path_signal_from_behind", _test_span_passes_path_back)
	_t("span_defensively_ends_at_one_way_back", _test_span_one_way_back)
	_t("routing_forbids_crossing_one_way_backwards", _test_one_way_routing)
	_t("route_to_platform_skips_one_way_entry", _test_one_way_platform_entry)

func _test_span_ends_at_signal() -> void:
	var tr := Train.new()
	tr.set_route(_route_with_signal())
	eq(tr._span_end(0), 1)  # segment 1 ends at the signal
	eq(tr._span_end(2), 3)  # from beyond the signal to the route end

func _test_span_ends_at_route_end() -> void:
	var tr := Train.new()
	var route := _route_with_signal()
	tr.set_route([route[2], route[3]])  # no signal ahead
	eq(tr._span_end(0), 1)

func _test_reserve_span_atomic() -> void:
	var tr := Train.new()
	var other := Train.new()
	var route := _route_with_signal()
	tr.set_route(route)
	is_true(route[1].reserve(other))  # second span segment is taken
	is_false(tr._try_reserve_span(0))
	eq(route[0].occupying_train, null)  # rollback left no stray claim
	eq(tr.reserved_until, -1)

func _test_departure_reserves() -> void:
	var tr := Train.new()
	var route := _route_with_signal()
	tr.set_route(route)
	tr.move(0.1)  # 15 px
	is_false(tr.waiting_for_block)
	eq(tr.reserved_until, 1)  # span held up to the signal, not beyond
	eq(route[0].occupying_train, tr)
	eq(route[1].occupying_train, tr)
	eq(route[2].occupying_train, null)

func _test_departure_gated() -> void:
	var tr := Train.new()
	var other := Train.new()
	var route := _route_with_signal()
	route[1].reserve(other)  # first span is blocked before departure
	tr.set_route(route)
	tr.move(1.0)
	eq(tr.segment_progress, 0.0)  # never left the waiting point
	is_true(tr.waiting_for_block)
	eq(route[0].occupying_train, null)
	# The blocker clears; the next tick reserves and departs.
	route[1].release()
	tr.move(0.1)
	is_false(tr.waiting_for_block)
	gt(tr.segment_progress, 0.0)

func _test_hold_at_signal() -> void:
	var tr := Train.new()
	tr.car_count = 1
	var other := Train.new()
	var route := _route_with_signal()
	route[2].reserve(other)  # the span beyond the signal is taken
	tr.set_route(route)
	tr.move(2.0)  # 300 px — enough to reach the signal and want to pass it
	eq(tr.route_index, 1)
	eq(tr.segment_progress, 1.0)  # clamped at the signal
	is_true(tr.waiting_for_block)
	eq(route[2].occupying_train, other)
	tr.move(1.0)  # still blocked — holds in place
	eq(tr.route_index, 1)
	is_true(tr.waiting_for_block)
	route[2].release()
	tr.move(0.4)  # 60 px past the signal
	is_false(tr.waiting_for_block)
	eq(tr.route_index, 2)
	eq(route[2].occupying_train, tr)

func _test_wanted_span() -> void:
	var tr := Train.new()
	var other := Train.new()
	var route := _route_with_signal()
	route[3].reserve(other)
	tr.set_route(route)
	tr.move(2.0)  # halted at the signal
	is_true(tr.waiting_for_block)
	var wanted: Array = tr.wanted_span()
	eq(wanted.size(), 2)
	eq(wanted[0], route[2])
	eq(wanted[1], route[3])
	route[3].release()
	tr.move(0.1)
	eq(tr.wanted_span().size(), 0)  # holding its path again

func _test_turnaround_transfer() -> void:
	var a := _node(0, 0)
	var b := _node(500, 0)
	var fwd := _seg(a, b)
	var rev := _seg(b, a)
	fwd.reverse = rev
	rev.reverse = fwd
	var out := _seg(a, _node(-500, 0))
	var tr := Train.new()
	fwd.reserve(tr)  # the train dwells on the forward platform segment
	tr.set_route([rev, out])
	tr.resume_from_stop(fwd, 0.6, rev)
	eq(fwd.occupying_train, null)
	eq(rev.occupying_train, tr)

func _test_resume_forward_block() -> void:
	var a := _node(0, 0)
	var b := _node(500, 0)
	var platform_seg := _seg(a, b)
	var rev := _seg(b, a)
	platform_seg.reverse = rev
	rev.reverse = platform_seg
	var onward := _seg(b, _node(1000, 0))
	var tr := Train.new()
	platform_seg.reserve(tr)
	tr.set_route([onward])
	tr.resume_from_stop(platform_seg, 0.6, rev)
	eq(platform_seg.occupying_train, tr)  # still held while rolling through

func _test_dwell_blocks_platform() -> void:
	# A dwelling consist holds its platform segment, so a second train routed
	# to the same platform cannot reserve its final span.
	var route := _route_with_signal()
	var dweller := Train.new()
	route[3].reserve(dweller)  # parked on the last segment (the "platform")
	var tr := Train.new()
	tr.set_route(route)
	tr.move(2.0)  # to the signal; the span beyond includes the platform
	eq(tr.route_index, 1)
	is_true(tr.waiting_for_block)

func _test_penalty_routing() -> void:
	# Two parallel branches J1->J2: north 200 px, south 260 px. Free, the
	# shorter north branch wins; with north reserved by another train, the
	# penalty steers the route through the south branch.
	var net := TrackNetwork.new()
	var j1 := _node(0, 0)
	var j2 := _node(200, 0)
	var north := _seg(j1, j2)
	var mid := _node(100, 130)
	var south_a := TrackSegment.new(j1, mid)
	var south_b := TrackSegment.new(mid, j2)
	net.add_segment(north)
	net.add_segment(south_a)
	net.add_segment(south_b)
	var me := Train.new()
	var other := Train.new()
	var free_route := net.find_route(j1, j2, me)
	eq(free_route.size(), 1)
	eq(free_route[0], north)
	north.reserve(other)
	var steered := net.find_route(j1, j2, me)
	eq(steered.size(), 2)
	eq(steered[0], south_a)
	# Without a train context there is no penalty.
	eq(net.find_route(j1, j2).size(), 1)

func _test_penalty_platform_end() -> void:
	# A platform reachable at both ends; the approach to the near end is
	# occupied, so the penalized comparison enters via the far end.
	var net := TrackNetwork.new()
	var start := _node(0, 0)
	var entry := _node(100, 0)
	var exit := _node(300, 0)
	var approach_near := _seg(start, entry)  # 100 px to the entry
	var approach_far := TrackSegment.new(start, exit,
		[Vector2(150, 200)] as Array[Vector2])  # long way round to the exit
	var platform_seg := _seg(entry, exit)
	var platform_rev := _seg(exit, entry)
	platform_seg.reverse = platform_rev
	platform_rev.reverse = platform_seg
	net.add_segment(approach_near)
	net.add_segment(approach_far)
	net.add_segment(platform_seg)
	net.add_segment(platform_rev)
	var platform := Platform.new(platform_seg, platform_rev, 1.0)
	var me := Train.new()
	var other := Train.new()
	var free_route: Array = net.find_route_to_platform(start, platform, me)
	eq(free_route[-1], platform_seg)  # short way in via the entry
	approach_near.reserve(other)
	var steered: Array = net.find_route_to_platform(start, platform, me)
	eq(steered[-1], platform_rev)  # penalty flips it to the far end

func _test_directional_governs() -> void:
	var sig := _node(0, 0, true)  # TWO_WAY
	is_true(sig.signal_governs(Vector2.RIGHT))
	is_true(sig.signal_governs(Vector2.LEFT))
	sig.signal_kind = NetworkNode.SignalKind.PATH
	sig.signal_facing = Vector2.RIGHT
	is_true(sig.signal_governs(Vector2.RIGHT))
	is_false(sig.signal_governs(Vector2.LEFT))  # met from behind: pass freely
	sig.signal_kind = NetworkNode.SignalKind.ONE_WAY
	is_true(sig.signal_governs(Vector2.RIGHT))
	is_false(sig.signal_governs(Vector2.LEFT))
	sig.signal_kind = NetworkNode.SignalKind.NONE
	is_false(sig.signal_governs(Vector2.RIGHT))

func _test_blocks_travel() -> void:
	var sig := _node(0, 0, true)
	sig.signal_facing = Vector2.RIGHT
	is_false(sig.blocks_travel(Vector2.LEFT))  # two-way: passable, just a boundary
	sig.signal_kind = NetworkNode.SignalKind.PATH
	is_false(sig.blocks_travel(Vector2.LEFT))
	sig.signal_kind = NetworkNode.SignalKind.ONE_WAY
	is_true(sig.blocks_travel(Vector2.LEFT))
	is_false(sig.blocks_travel(Vector2.RIGHT))

func _test_span_passes_path_back() -> void:
	var tr := Train.new()
	var route := _route_with_signal()  # travel runs +x, signal after segment 1
	var sig: NetworkNode = route[1].node_end
	sig.signal_kind = NetworkNode.SignalKind.PATH
	sig.signal_facing = Vector2.LEFT  # faces against the travel direction
	tr.set_route(route)
	eq(tr._span_end(0), 3)  # not a boundary from behind: span runs to the end
	sig.signal_facing = Vector2.RIGHT  # faces with the travel direction
	eq(tr._span_end(0), 1)  # governs it: normal signal boundary

func _test_span_one_way_back() -> void:
	# Routing never crosses a one-way signal backwards, but if a stale route
	# does, the span still ends there rather than sailing through.
	var tr := Train.new()
	var route := _route_with_signal()
	var sig: NetworkNode = route[1].node_end
	sig.signal_kind = NetworkNode.SignalKind.ONE_WAY
	sig.signal_facing = Vector2.LEFT
	tr.set_route(route)
	eq(tr._span_end(0), 1)

func _test_one_way_routing() -> void:
	# A short straight j0 -> sig -> j2 with a longer detour via mid. Forward
	# travel uses the straight; backwards the one-way signal forbids it, so
	# the route goes around the detour — or fails without one.
	var net := TrackNetwork.new()
	var j0 := _node(0, 0)
	var sig := _node(100, 0, true)
	sig.signal_kind = NetworkNode.SignalKind.ONE_WAY
	sig.signal_facing = Vector2.RIGHT
	var j2 := _node(200, 0)
	var mid := _node(100, 150)
	net.add_segment(_seg(j0, sig))
	net.add_segment(_seg(sig, j2))
	var back_a := _seg(j2, sig)
	var back_b := _seg(sig, j0)
	net.add_segment(back_a)
	net.add_segment(back_b)
	var detour_a := _seg(j2, mid)
	var detour_b := _seg(mid, j0)
	net.add_segment(detour_a)
	net.add_segment(detour_b)
	eq(net.find_route(j0, j2).size(), 2)  # straight through, with the signal
	var back := net.find_route(j2, j0)
	eq(back.size(), 2)
	eq(back[0], detour_a)  # forced around, even though the straight is shorter
	net.remove_segment(detour_a)
	eq(net.find_route(j2, j0).size(), 0)  # no legal way back at all

func _test_one_way_platform_entry() -> void:
	# Same layout as the penalty test, but the platform's entry node carries a
	# one-way signal facing out of the platform: the near entry is illegal, so
	# the route must come in the long way via the exit end.
	var net := TrackNetwork.new()
	var start := _node(0, 0)
	var entry := _node(100, 0, true)
	entry.signal_kind = NetworkNode.SignalKind.ONE_WAY
	entry.signal_facing = Vector2.LEFT  # faces back toward start
	var exit := _node(300, 0)
	net.add_segment(_seg(start, entry))
	net.add_segment(TrackSegment.new(start, exit,
		[Vector2(150, 200)] as Array[Vector2]))
	var platform_seg := _seg(entry, exit)
	var platform_rev := _seg(exit, entry)
	platform_seg.reverse = platform_rev
	platform_rev.reverse = platform_seg
	net.add_segment(platform_seg)
	net.add_segment(platform_rev)
	var platform := Platform.new(platform_seg, platform_rev, 1.0)
	var route: Array = net.find_route_to_platform(start, platform)
	eq(route[-1], platform_rev)  # entered via the exit end
	# The direct shortcut is guarded too: standing at the entry node, the
	# forward platform traversal is not offered.
	eq(net.find_route_to_platform(entry, platform).size(), 0)
