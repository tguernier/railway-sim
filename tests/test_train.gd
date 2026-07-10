class_name TestTrain
extends TestBase

func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _node(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

func _seg(a: NetworkNode, b: NetworkNode) -> TrackSegment:
	return TrackSegment.new(a, b)

func run_all() -> void:
	print("[TestTrain]")
	_t("has_route_false_initially", _test_no_route)
	_t("set_route_stores_and_resets", _test_set_route)
	_t("set_route_resets_boarded_flag", _test_set_route_resets_boarded_flag)
	_t("has_route_true_after_set", _test_has_route)
	_t("halts_at_pending_stop_point", _test_halts_at_stop_point)
	_t("resumes_past_stop_once_cleared", _test_resumes_past_stop)
	_t("set_route_clears_stop_point", _test_set_route_clears_stop)
	_t("dwell_blocks_movement_and_counts_down", _test_dwell_blocks_movement)
	_t("moves_again_after_dwell_expires", _test_moves_after_dwell)
	_t("move_advances_segment_progress", _test_move_advances)
	_t("resume_from_stop_turns_around_on_reverse", _test_resume_turnaround)
	_t("resume_from_stop_prepends_forward_segment", _test_resume_forward)
	_t("has_completed_route_false_at_start", _test_not_completed_at_start)
	_t("has_completed_route_true_after_full_move", _test_completed_after_move)
	_t("unload_returns_count_and_clears", _test_unload)
	_t("board_from_picks_up_passengers", _test_board_from)
	_t("board_from_respects_capacity", _test_board_capacity)
	_t("orders_empty_initially", _test_orders_empty)
	_t("current_order_town_returns_correct_stop", _test_current_order_town)
	_t("advance_order_cycles", _test_advance_order_cycles)
	_t("advance_order_wraps_around", _test_advance_order_wraps)
	_t("consist_length_and_capacity_scale_with_cars", _test_consist_length_capacity)
	_t("history_keeps_segments_the_tail_needs", _test_history_trim)
	_t("point_behind_spans_segment_boundary", _test_point_behind_spans)
	_t("point_behind_clamps_at_oldest_point", _test_point_behind_clamps)
	_t("set_route_clears_history", _test_set_route_clears_history)
	_t("resume_forward_keeps_tail_continuous", _test_resume_forward_tail)
	_t("block_held_until_tail_clears_it", _test_block_held_until_tail_clears)
	_t("release_all_blocks_frees_footprint_and_span", _test_release_all_blocks)
	_t("set_route_releases_old_holdings", _test_set_route_releases)
	_t("release_block_spares_other_trains_hold", _test_release_block_other)

func _test_no_route() -> void:
	var tr := Train.new()
	is_false(tr.has_route())

func _test_set_route() -> void:
	var tr := Train.new()
	var seg := _seg(_node(0, 0), _node(200, 0))
	tr.set_route([seg])
	eq(tr.route_index, 0)
	eq(tr.segment_progress, 0.0)

func _test_set_route_resets_boarded_flag() -> void:
	var tr := Train.new()
	tr.boarded_this_leg = true
	tr.set_route([_seg(_node(0, 0), _node(200, 0))])
	is_false(tr.boarded_this_leg)

func _test_has_route() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(200, 0))])
	is_true(tr.has_route())

func _test_halts_at_stop_point() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	tr.stop_progress = 0.5
	tr.move(100.0)  # far more than enough to cross the whole segment
	eq(tr.segment_progress, 0.5)  # halted at the stop point
	is_true(tr.at_pending_stop())
	is_false(tr.has_completed_route())

func _test_resumes_past_stop() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	tr.stop_progress = 0.5
	tr.move(100.0)
	tr.stop_progress = -1.0  # dwell finished — pull away
	tr.move(100.0)
	is_true(tr.has_completed_route())

func _test_set_route_clears_stop() -> void:
	var tr := Train.new()
	tr.stop_progress = 0.5
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	eq(tr.stop_progress, -1.0)

func _test_dwell_blocks_movement() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	tr.dwell_remaining = 1.0
	tr.move(0.4)
	eq(tr.segment_progress, 0.0)  # stopped at the platform
	approx(tr.dwell_remaining, 0.6, 0.01)

func _test_moves_after_dwell() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	tr.dwell_remaining = 0.3
	tr.move(0.5)  # consumes the rest of the dwell
	eq(tr.dwell_remaining, 0.0)
	eq(tr.segment_progress, 0.0)
	tr.move(0.1)  # now the train moves again
	gt(tr.segment_progress, 0.0)

func _test_move_advances() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(500, 0))])
	tr.move(0.1)  # 150 px/s * 0.1 s = 15 px into a 500 px segment
	gt(tr.segment_progress, 0.0)

func _test_resume_turnaround() -> void:
	# Head stopped at 0.3 along the platform; the new route leaves along the
	# reverse twin, so the train turns around: the head takes the old tail's
	# spot heading the other way (same physical span, reversed).
	var a := _node(0, 0)
	var b := _node(500, 0)
	var fwd := _seg(a, b)
	var rev := _seg(b, a)
	var out := _seg(a, _node(-500, 0))
	var tr := Train.new()
	tr.car_count = 2  # consist length 56
	tr.set_route([rev, out])
	tr.resume_from_stop(fwd, 0.3, rev)
	eq(tr.route.size(), 2)  # nothing prepended
	eq(tr.current_segment(), rev)
	# Old head at x=150, old tail at x=94; new head is the mirrored tail.
	approx(tr.segment_progress, 1.0 - (0.3 - tr.consist_length() / 500.0), 0.0001)
	approx(tr.current_position().x, 150.0 - tr.consist_length(), 1.0)
	# The new tail sits where the old head was.
	approx(tr.point_behind(tr.consist_length()).origin.x, 150.0, 1.0)

func _test_resume_forward() -> void:
	# The new route continues past the platform end, so the platform segment
	# is prepended and the train rolls forward from where it stopped.
	var a := _node(0, 0)
	var b := _node(500, 0)
	var platform_seg := _seg(a, b)
	var rev := _seg(b, a)
	var onward := _seg(b, _node(1000, 0))
	var tr := Train.new()
	tr.set_route([onward])
	tr.resume_from_stop(platform_seg, 0.5, rev)
	eq(tr.route.size(), 2)
	eq(tr.current_segment(), platform_seg)
	eq(tr.segment_progress, 0.5)
	tr.move(100.0)  # more than enough to finish both segments
	is_true(tr.has_completed_route())

func _test_not_completed_at_start() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(200, 0))])
	is_false(tr.has_completed_route())

func _test_completed_after_move() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(200, 0))])
	tr.move(100.0)
	is_true(tr.has_completed_route())

func _test_unload() -> void:
	var tr := Train.new()
	tr.passengers_on_board = 7
	var delivered := tr.unload()
	eq(delivered, 7)
	eq(tr.passengers_on_board, 0)

func _test_board_from() -> void:
	var t := _town(0, 0)
	t.waiting = 10.0
	var tr := Train.new()
	tr.board_from(t)
	eq(tr.passengers_on_board, 10)

func _test_board_capacity() -> void:
	var t := _town(0, 0)
	t.waiting = 100.0
	var tr := Train.new()
	tr.board_from(t)
	eq(tr.passengers_on_board, tr.capacity)

func _test_orders_empty() -> void:
	var tr := Train.new()
	eq(tr.orders.size(), 0)
	eq(tr.current_order_town(), null)

func _test_current_order_town() -> void:
	var tr := Train.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	tr.orders = [a, b]
	tr.current_order_index = 0
	eq(tr.current_order_town(), a)
	tr.current_order_index = 1
	eq(tr.current_order_town(), b)

func _test_advance_order_cycles() -> void:
	var tr := Train.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	var c := _town(200, 0)
	tr.orders = [a, b, c]
	tr.current_order_index = 0
	tr.advance_order()
	eq(tr.current_order_index, 1)
	eq(tr.current_order_town(), b)
	tr.advance_order()
	eq(tr.current_order_index, 2)
	eq(tr.current_order_town(), c)

func _test_advance_order_wraps() -> void:
	var tr := Train.new()
	var a := _town(0, 0)
	var b := _town(100, 0)
	tr.orders = [a, b]
	tr.current_order_index = 1
	tr.advance_order()
	eq(tr.current_order_index, 0)
	eq(tr.current_order_town(), a)

func _test_consist_length_capacity() -> void:
	var tr := Train.new()
	tr.car_count = 1
	approx(tr.consist_length(), Train.CAR_LENGTH, 0.001)
	eq(tr.capacity, Train.CAR_CAPACITY)
	tr.car_count = 2
	approx(tr.consist_length(), 2 * Train.CAR_LENGTH + Train.CAR_GAP, 0.001)
	eq(tr.capacity, 2 * Train.CAR_CAPACITY)
	tr.car_count = 4
	approx(tr.consist_length(), 4 * Train.CAR_LENGTH + 3 * Train.CAR_GAP, 0.001)
	eq(tr.capacity, 4 * Train.CAR_CAPACITY)

## Three 100 px segments in a line; a 2-car consist is 56 px long.
func _route_of_three(tr: Train) -> Array:
	var segs := [
		_seg(_node(0, 0), _node(100, 0)),
		_seg(_node(100, 0), _node(200, 0)),
		_seg(_node(200, 0), _node(300, 0)),
	]
	tr.car_count = 2
	tr.set_route(segs)
	return segs

func _test_history_trim() -> void:
	var tr := Train.new()
	var segs := _route_of_three(tr)
	tr.move(1.0)  # 150 px: head halfway into the second segment
	eq(tr.route_index, 1)
	# Only 50 px of the current segment is behind the head — the 56 px
	# consist still needs the first segment.
	eq(tr.history.size(), 1)
	eq(tr.history[0], segs[0])
	tr.move(1.0)  # 300 px total: route complete, 100 px behind the head
	is_true(tr.has_completed_route())
	eq(tr.history.size(), 0)  # tail fits on the final segment alone

func _test_point_behind_spans() -> void:
	var tr := Train.new()
	var _segs := _route_of_three(tr)
	tr.move(1.0)  # head at x=150
	approx(tr.point_behind(0.0).origin.x, 150.0, 1.0)
	approx(tr.point_behind(13.0).origin.x, 137.0, 1.0)
	approx(tr.point_behind(100.0).origin.x, 50.0, 1.0)  # back on segment 1

func _test_point_behind_clamps() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_node(0, 0), _node(100, 0))])
	# No history and the head at the very start: everything clamps to x=0.
	approx(tr.point_behind(50.0).origin.x, 0.0, 0.001)

func _test_set_route_clears_history() -> void:
	var tr := Train.new()
	var _segs := _route_of_three(tr)
	tr.move(1.0)
	eq(tr.history.size(), 1)
	tr.set_route([_seg(_node(0, 0), _node(100, 0))])
	eq(tr.history.size(), 0)

func _test_block_held_until_tail_clears() -> void:
	# 100 px segments, 56 px consist: the first block must stay reserved while
	# the tail still needs it, and free the moment the tail clears it.
	var tr := Train.new()
	var segs := _route_of_three(tr)
	for seg in segs:
		is_true(seg.reserve(tr))
	tr.move(1.0)  # head at x=150: tail at x=94, still on the first segment
	eq(segs[0].occupying_train, tr)
	tr.move(0.1)  # head at x=165: tail at x=109 — first block cleared
	eq(segs[0].occupying_train, null)
	eq(segs[1].occupying_train, tr)

func _test_release_all_blocks() -> void:
	var tr := Train.new()
	var segs := _route_of_three(tr)
	for seg in segs:
		is_true(seg.reserve(tr))
	tr.move(1.0)  # head mid-route with one history segment
	tr.release_all_blocks()
	for seg in segs:
		eq(seg.occupying_train, null)

func _test_set_route_releases() -> void:
	var tr := Train.new()
	var segs := _route_of_three(tr)
	for seg in segs:
		is_true(seg.reserve(tr))
	tr.reserved_until = 2
	tr.move(1.0)  # head on segs[1], history [segs[0]]
	var next_seg := _seg(_node(300, 0), _node(400, 0))
	tr.set_route([next_seg])
	# History and the reserved span ahead are freed; the old head segment stays
	# held (the consist is still physically on it until re-anchored).
	eq(segs[0].occupying_train, null)
	eq(segs[1].occupying_train, tr)
	eq(segs[2].occupying_train, null)
	eq(tr.reserved_until, -1)

func _test_release_block_other() -> void:
	var tr := Train.new()
	var other := Train.new()
	var seg := _seg(_node(0, 0), _node(100, 0))
	is_true(seg.reserve(other))
	tr.release_block(seg)  # not ours — must not free it
	eq(seg.occupying_train, other)

func _test_resume_forward_tail() -> void:
	# Roll-forward departure: the platform segment is prepended, so the tail
	# trails behind the head on the same segment with no discontinuity.
	var a := _node(0, 0)
	var b := _node(500, 0)
	var platform_seg := _seg(a, b)
	var rev := _seg(b, a)
	var onward := _seg(b, _node(1000, 0))
	var tr := Train.new()
	tr.car_count = 2
	tr.set_route([onward])
	tr.resume_from_stop(platform_seg, 0.5, rev)
	approx(tr.current_position().x, 250.0, 1.0)
	approx(tr.point_behind(tr.consist_length()).origin.x, 250.0 - tr.consist_length(), 1.0)
