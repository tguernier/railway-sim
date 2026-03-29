class_name TestTrain
extends TestBase

func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _seg(a: Town, b: Town) -> TrackSegment:
	return TrackSegment.new(a, b)

func run_all() -> void:
	print("[TestTrain]")
	_t("has_route_false_initially", _test_no_route)
	_t("set_route_stores_and_resets", _test_set_route)
	_t("has_route_true_after_set", _test_has_route)
	_t("move_advances_segment_progress", _test_move_advances)
	_t("has_completed_route_false_at_start", _test_not_completed_at_start)
	_t("has_completed_route_true_after_full_move", _test_completed_after_move)
	_t("unload_returns_count_and_clears", _test_unload)
	_t("board_from_picks_up_passengers", _test_board_from)
	_t("board_from_respects_capacity", _test_board_capacity)
	_t("switch_direction_toggles", _test_switch_direction)
	_t("destination_town", _test_destination_town)

func _test_no_route() -> void:
	var tr := Train.new()
	is_false(tr.has_route())

func _test_set_route() -> void:
	var tr := Train.new()
	var seg := _seg(_town(0, 0), _town(200, 0))
	tr.set_route([seg])
	eq(tr.route_index, 0)
	eq(tr.segment_progress, 0.0)

func _test_has_route() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_town(0, 0), _town(200, 0))])
	is_true(tr.has_route())

func _test_move_advances() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_town(0, 0), _town(500, 0))])
	tr.move(0.1)  # 150 px/s * 0.1 s = 15 px into a 500 px segment
	gt(tr.segment_progress, 0.0)

func _test_not_completed_at_start() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_town(0, 0), _town(200, 0))])
	is_false(tr.has_completed_route())

func _test_completed_after_move() -> void:
	var tr := Train.new()
	tr.set_route([_seg(_town(0, 0), _town(200, 0))])
	tr.move(100.0)  # More than enough time to traverse any reasonable segment.
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

func _test_switch_direction() -> void:
	var tr := Train.new()
	eq(tr.direction, Train.Direction.FORWARD)
	tr.switch_direction()
	eq(tr.direction, Train.Direction.BACKWARD)
	tr.switch_direction()
	eq(tr.direction, Train.Direction.FORWARD)

func _test_destination_town() -> void:
	var tr := Train.new()
	var dest := _town(300, 0)
	var seg := TrackSegment.new(_town(0, 0), dest)
	tr.set_route([seg])
	eq(tr.destination_town(), dest)
