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
	_t("try_reserve_marks_segments", _test_reserve_marks)
	_t("try_reserve_atomic_all_or_nothing", _test_reserve_atomic)
	_t("reserve_blocks_reverse_twin", _test_reserve_blocks_twin)
	_t("own_twin_is_not_blocked", _test_own_twin_ok)
	_t("re_reserve_is_idempotent", _test_reserve_idempotent)
	_t("release_all_frees_segments", _test_release_all)
	_t("set_route_releases_reservations", _test_set_route_releases)
	_t("tail_clear_releases_segments", _test_tail_clear_release)
	_t("blocked_entry_halts_at_boundary", _test_blocked_entry_halts)
	_t("blocked_entry_proceeds_after_release", _test_blocked_entry_proceeds)
	_t("turnaround_keeps_span_held", _test_turnaround_keeps_held)
	_t("extension_stops_at_first_signal", _test_extend_stops_at_signal)
	_t("extension_failure_keeps_limit_and_records_blocker", _test_extend_atomic)
	_t("opposite_direction_signal_ignored", _test_extend_ignores_opposite_signal)
	_t("halts_at_signal_until_path_frees", _test_halts_at_signal)

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

## A linked forward/reverse segment pair between two nodes.
func _twin_pair(a: NetworkNode, b: NetworkNode) -> Array:
	var fwd := _seg(a, b)
	var rev := _seg(b, a)
	fwd.reverse = rev
	rev.reverse = fwd
	return [fwd, rev]

func _test_reserve_marks() -> void:
	var tr := Train.new()
	var s1 := _seg(_node(0, 0), _node(100, 0))
	var s2 := _seg(_node(100, 0), _node(200, 0))
	is_true(tr.try_reserve([s1, s2]))
	eq(s1.reserved_by, tr)
	eq(s2.reserved_by, tr)
	eq(tr.reserved.size(), 2)

func _test_reserve_atomic() -> void:
	var tr := Train.new()
	var other := Train.new()
	var s1 := _seg(_node(0, 0), _node(100, 0))
	var s2 := _seg(_node(100, 0), _node(200, 0))
	is_true(other.try_reserve([s2]))
	is_false(tr.try_reserve([s1, s2]))
	eq(s1.reserved_by, null)  # nothing was taken
	eq(tr.reserved.size(), 0)

func _test_reserve_blocks_twin() -> void:
	var other := Train.new()
	var pair := _twin_pair(_node(0, 0), _node(100, 0))
	is_true(other.try_reserve([pair[0]]))
	var tr := Train.new()
	is_false(tr.try_reserve([pair[1]]))

func _test_own_twin_ok() -> void:
	var tr := Train.new()
	var pair := _twin_pair(_node(0, 0), _node(100, 0))
	is_true(tr.try_reserve([pair[0]]))
	is_true(tr.try_reserve([pair[1]]))

func _test_reserve_idempotent() -> void:
	var tr := Train.new()
	var s := _seg(_node(0, 0), _node(100, 0))
	is_true(tr.try_reserve([s]))
	is_true(tr.try_reserve([s]))
	eq(tr.reserved.size(), 1)

func _test_release_all() -> void:
	var tr := Train.new()
	var s1 := _seg(_node(0, 0), _node(100, 0))
	var s2 := _seg(_node(100, 0), _node(200, 0))
	tr.try_reserve([s1, s2])
	tr.release_all()
	eq(s1.reserved_by, null)
	eq(tr.reserved.size(), 0)
	var other := Train.new()
	is_true(other.try_reserve([s1]))

func _test_set_route_releases() -> void:
	var tr := Train.new()
	var s := _seg(_node(0, 0), _node(100, 0))
	tr.try_reserve([s])
	tr.set_route([_seg(_node(0, 0), _node(200, 0))])
	eq(s.reserved_by, null)
	eq(tr.reserved.size(), 0)

func _test_tail_clear_release() -> void:
	var tr := Train.new()
	var segs := _route_of_three(tr)  # 3 × 100 px, 2-car consist (56 px)
	tr.try_reserve([segs[0]])  # seed the footprint like dispatch does
	tr.move(1.0)  # head at x=150: tail at 94, still on the first segment
	eq(segs[0].reserved_by, tr)
	eq(segs[1].reserved_by, tr)  # entered via the movement gate
	tr.move(1.0)  # head at x=300: the tail cleared segments 1 and 2
	eq(segs[0].reserved_by, null)
	eq(segs[1].reserved_by, null)
	eq(segs[2].reserved_by, tr)
	eq(tr.reserved, [segs[2]])

func _test_blocked_entry_halts() -> void:
	var tr := Train.new()
	var other := Train.new()
	var s1 := _seg(_node(0, 0), _node(100, 0))
	var s2 := _seg(_node(100, 0), _node(200, 0))
	other.try_reserve([s2])
	tr.set_route([s1, s2])
	tr.try_reserve([s1])
	tr.move(1.0)  # 150 px — enough to overshoot the boundary
	eq(tr.route_index, 0)
	eq(tr.segment_progress, 1.0)  # halted at the segment end
	is_true(tr.waiting_for_track)
	is_false(tr.has_completed_route())

func _test_blocked_entry_proceeds() -> void:
	var tr := Train.new()
	var other := Train.new()
	var s1 := _seg(_node(0, 0), _node(100, 0))
	var s2 := _seg(_node(100, 0), _node(200, 0))
	other.try_reserve([s2])
	tr.set_route([s1, s2])
	tr.try_reserve([s1])
	tr.move(1.0)  # blocked at the boundary
	other.release_all()
	tr.move(1.0)  # the retry succeeds and the train rolls on
	is_false(tr.waiting_for_track)
	is_true(tr.has_completed_route())
	eq(s2.reserved_by, tr)

func _test_turnaround_keeps_held() -> void:
	# Dead-end departure: the consist swaps from the platform segment to its
	# reverse twin; the physical span must stay barred to other trains.
	var a := _node(0, 0)
	var b := _node(500, 0)
	var pair := _twin_pair(a, b)
	var out := _seg(a, _node(-500, 0))
	var tr := Train.new()
	tr.car_count = 2
	tr.try_reserve([pair[0]])  # parked on the platform segment
	tr.set_route([pair[1], out])  # releases, as dispatch does
	tr.resume_from_stop(pair[0], 0.3, pair[1])
	is_true(tr.try_reserve([tr.current_segment()]))  # re-take the twin
	eq(pair[1].reserved_by, tr)
	var other := Train.new()
	is_false(other.try_reserve([pair[0]]))  # twin exclusion holds the span

func _test_extend_stops_at_signal() -> void:
	var tr := Train.new()
	var segs := _route_of_three(tr)
	segs[1].exit_signal = true
	is_true(tr.try_extend_reservation())
	# The slice runs through the signalled segment and no further.
	eq(tr.limit_index, 1)
	eq(segs[0].reserved_by, tr)
	eq(segs[1].reserved_by, tr)
	eq(segs[2].reserved_by, null)
	# The next extension takes the rest of the route.
	is_true(tr.try_extend_reservation())
	eq(tr.limit_index, 2)
	eq(segs[2].reserved_by, tr)

func _test_extend_atomic() -> void:
	var tr := Train.new()
	var other := Train.new()
	var segs := _route_of_three(tr)
	segs[1].exit_signal = true
	other.try_reserve([segs[2]])
	is_true(tr.try_extend_reservation())  # up to the signal is free
	eq(tr.limit_index, 1)
	is_false(tr.try_extend_reservation())  # beyond it is not
	eq(tr.limit_index, 1)  # unchanged on failure
	eq(segs[2].reserved_by, other)
	eq(tr.blocked_by, other)  # wait-for edge recorded

func _test_extend_ignores_opposite_signal() -> void:
	# A one-way signal for the opposite direction lives on the reverse twin;
	# it is not a waiting point for this train, so the slice runs past it.
	var tr := Train.new()
	var segs := _route_of_three(tr)
	var rev := _seg(segs[1].node_end, segs[1].node_start)
	segs[1].reverse = rev
	rev.reverse = segs[1]
	rev.exit_signal = true
	is_true(tr.try_extend_reservation())
	eq(tr.limit_index, 2)  # reserved to the end of the route

func _test_halts_at_signal() -> void:
	var tr := Train.new()
	var other := Train.new()
	var segs := _route_of_three(tr)
	segs[0].exit_signal = true
	other.try_reserve([segs[2]])
	tr.move(1.0)  # 150 px — would cross into the second segment
	eq(tr.route_index, 0)
	eq(tr.segment_progress, 1.0)  # halted at the signal
	is_true(tr.waiting_for_track)
	other.release_all()
	tr.move(2.0)  # the retry reserves the rest and the train rolls on
	is_false(tr.waiting_for_track)
	is_true(tr.has_completed_route())
	eq(segs[2].reserved_by, tr)

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
