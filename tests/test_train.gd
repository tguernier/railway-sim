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
	# Stopped at 0.3 along the platform; the new route leaves along the
	# reverse twin, so the train flips in place to the mirrored point.
	var a := _node(0, 0)
	var b := _node(500, 0)
	var fwd := _seg(a, b)
	var rev := _seg(b, a)
	var out := _seg(a, _node(-500, 0))
	var tr := Train.new()
	tr.set_route([rev, out])
	tr.resume_from_stop(fwd, 0.3, rev)
	eq(tr.route.size(), 2)  # nothing prepended
	eq(tr.current_segment(), rev)
	approx(tr.segment_progress, 0.7, 0.0001)
	approx(tr.current_position().x, 150.0, 1.0)  # same spot, other direction

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
