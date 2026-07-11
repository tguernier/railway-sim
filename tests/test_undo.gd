class_name TestUndo
extends TestBase

func run_all() -> void:
	print("[TestUndo]")
	_t("place_town_undo_restores_color_index", _test_place_town_undo)
	_t("build_track_undo_removes_pair_and_fresh_junctions", _test_build_track_undo)
	_t("failed_finish_burns_no_undo", _test_failed_finish_no_push)
	_t("finish_on_track_undo_restores_single_segment", _test_finish_on_track_undo)
	_t("split_undo_restores_original_pair", _test_split_undo)
	_t("place_station_undo", _test_place_station_undo)
	_t("failed_station_burns_no_undo", _test_failed_station_no_push)
	_t("place_signal_undo_and_cycle_undo", _test_place_signal_undo)
	_t("failed_signal_burns_no_undo", _test_failed_signal_no_push)
	_t("delete_track_undo_restores_curve", _test_delete_track_undo)
	_t("delete_miss_and_platform_burn_no_undo", _test_delete_no_push)
	_t("remove_town_undo_restores_station_and_order", _test_remove_town_undo)
	_t("order_add_undo", _test_order_add_undo)
	_t("order_add_rejected_burns_no_undo", _test_order_rejected_no_push)
	_t("order_remove_undo_restores_index", _test_order_remove_undo)
	_t("order_pop_undo", _test_order_pop_undo)
	_t("buy_train_undo", _test_buy_train_undo)
	_t("sell_train_undo_restores_plan", _test_sell_train_undo)
	_t("sell_last_train_rejected", _test_sell_last_train)
	_t("two_actions_two_undos", _test_two_actions)
	_t("undo_empty_stack_shows_status", _test_empty_stack)
	_t("undo_stack_capped_at_limit", _test_stack_capped)
	_t("reset_clears_undo_stack", _test_reset_clears)

## Undo lives on the main game node, so tests drive a real instance.
func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

func _junction(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

## Straight track at height y with a stationed town beside its middle.
## Built through the editor directly, so it pushes no undo entries itself.
func _town_with_station(m: Node2D, y: float) -> Town:
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, y), _junction(600, y), [])
	var town := Town.new(Vector2(300, y + 30), Color.WHITE)
	m.towns.append(town)
	ed.place_station(Vector2(300, y), m.towns)
	return town

func _test_place_town_undo() -> void:
	var m := _main()
	m._place_town(Vector2(100, 100))
	eq(m.towns.size(), 1)
	eq(m.next_color_index, 1)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.towns.size(), 0)
	eq(m.next_color_index, 0)
	eq(m.undo_stack.size(), 0)
	m.free()

func _test_build_track_undo() -> void:
	var m := _main()
	m._handle_idle_click(Vector2(0, 0), false)  # free-draw start: no push
	is_true(m.editor.drawing)
	eq(m.undo_stack.size(), 0)
	m._handle_draw_click(Vector2(300, 0), true)  # shift-finish at new junction
	eq(m.network.segments.size(), 2)
	eq(m.undo_stack.size(), 1)
	m.editor.cancel()
	eq(m.network.nodes.size(), 2)
	m._undo()
	eq(m.network.segments.size(), 0)
	eq(m.network.nodes.size(), 0)  # both fresh junctions gone
	m.free()

func _test_failed_finish_no_push() -> void:
	var m := _main()
	var b := _junction(0, 60)
	m.network.add_node(b)
	m._handle_idle_click(Vector2(0, 0), false)
	m.editor.add_waypoint(Vector2(50, 0))
	m.editor.add_waypoint(Vector2(50, 30))
	m._handle_draw_click(Vector2(0, 60), false)  # tight curve — rejected
	is_true(m.editor.last_finish_rejected)
	eq(m.network.segments.size(), 0)
	eq(m.undo_stack.size(), 0)
	m.editor.cancel()
	m.free()

func _test_finish_on_track_undo() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	m._handle_idle_click(Vector2(900, 0), false)  # free-draw start
	m._handle_draw_click(Vector2(300, 0), false)  # finish onto the track
	is_false(m.editor.drawing)
	eq(m.network.segments.size(), 6)  # split pair x2 + new pair
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.network.segments.size(), 2)  # single original pair back
	eq(m.network.nodes.size(), 2)  # split junction and start junction gone
	m.free()

func _test_split_undo() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	m._handle_idle_click(Vector2(300, 0), false)  # split, then start drawing
	is_true(m.editor.drawing)
	eq(m.network.segments.size(), 4)
	eq(m.undo_stack.size(), 1)
	m.editor.cancel()  # the split persists after a cancel...
	eq(m.network.segments.size(), 4)
	m._undo()  # ...and undo reverts it
	eq(m.network.segments.size(), 2)
	eq(m.network.nodes.size(), 2)
	m.free()

func _test_place_station_undo() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	var town := Town.new(Vector2(300, 30), Color.WHITE)
	m.towns.append(town)
	m.placing_station = true
	m._try_place_station(Vector2(300, 0))
	is_false(m.placing_station)
	is_true(m.towns[0].station != null)
	eq(m.network.segments.size(), 6)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.towns[0].station, null)
	eq(m.network.segments.size(), 2)
	for seg in m.network.segments:
		is_false(seg.is_platform_segment())
	m.free()

func _test_failed_station_no_push() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	m.placing_station = true
	m._try_place_station(Vector2(300, 300))  # no track here
	is_true(m.placing_station)
	is_true(m.status_message != "")
	eq(m.undo_stack.size(), 0)
	m.free()

## Segments currently carrying a signal for their direction of travel.
func _signalled(m: Node2D) -> int:
	var n := 0
	for seg in m.network.segments:
		if seg.exit_signal:
			n += 1
	return n

func _test_place_signal_undo() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	m.placing_signal = true
	m._try_place_signal(Vector2(300, 0))  # split + two-way signal
	is_true(m.placing_signal)  # the mode stays active
	eq(m.network.segments.size(), 4)
	eq(_signalled(m), 2)
	eq(m.undo_stack.size(), 1)
	m._try_place_signal(Vector2(300, 0))  # cycle to one-way
	eq(_signalled(m), 1)
	eq(m.undo_stack.size(), 2)
	m._undo()  # the cycle is its own undo step
	eq(_signalled(m), 2)
	m._undo()  # placement undone: split junction and flags both gone
	eq(_signalled(m), 0)
	eq(m.network.segments.size(), 2)
	m.free()

func _test_failed_signal_no_push() -> void:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(600, 0), [])
	m.placing_signal = true
	m._try_place_signal(Vector2(300, 300))  # no track here
	is_true(m.status_message != "")
	eq(m.undo_stack.size(), 0)
	m.free()

func _test_delete_track_undo() -> void:
	var m := _main()
	var waypoints: Array[Vector2] = [Vector2(300, 40)]
	m.editor.create_bidirectional_track(_junction(0, 0), _junction(600, 0), waypoints)
	m._right_click_at(Vector2(300, 40))
	eq(m.network.segments.size(), 0)
	eq(m.network.nodes.size(), 0)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.network.segments.size(), 2)
	eq(m.network.nodes.size(), 2)
	approx(m.network.segments[0].position_at(0.5).y, 40.0, 10.0)  # curve intact
	m.free()

func _test_delete_no_push() -> void:
	var m := _main()
	_town_with_station(m, 0.0)
	m._right_click_at(Vector2(1000, 1000))  # miss
	eq(m.undo_stack.size(), 0)
	m._right_click_at(Vector2(300, 0))  # platform centre — protected
	is_true(m.status_message != "")
	eq(m.network.segments.size(), 6)
	eq(m.undo_stack.size(), 0)
	m.free()

func _test_remove_town_undo() -> void:
	var m := _main()
	var town := _town_with_station(m, 0.0)
	m.train_orders.append(town)
	eq(m.network.segments.size(), 6)
	m._right_click_at(town.position)
	eq(m.towns.size(), 0)
	eq(m.train_orders.size(), 0)
	eq(m.network.segments.size(), 4)  # platform pair gone, approaches remain
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.towns.size(), 1)
	is_true(m.towns[0].station != null)
	eq(m.train_orders.size(), 1)
	eq(m.train_orders[0], m.towns[0])
	eq(m.network.segments.size(), 6)
	m.free()

func _test_order_add_undo() -> void:
	var m := _main()
	var town := _town_with_station(m, 0.0)
	m.editing_orders = true
	m._toggle_order_stop(town.position)
	eq(m.train_orders.size(), 1)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.train_orders.size(), 0)
	m.free()

func _test_order_rejected_no_push() -> void:
	var m := _main()
	var town := Town.new(Vector2(300, 300), Color.WHITE)
	m.towns.append(town)
	m.editing_orders = true
	m._toggle_order_stop(town.position)  # no station — rejected
	eq(m.train_orders.size(), 0)
	is_true(m.status_message != "")
	eq(m.undo_stack.size(), 0)
	m.free()

func _test_order_remove_undo() -> void:
	var m := _main()
	var a := _town_with_station(m, 0.0)
	var b := _town_with_station(m, 400.0)
	m.train_orders.append(a)
	m.train_orders.append(b)
	m._toggle_order_stop(a.position)  # already a stop — removes it
	eq(m.train_orders.size(), 1)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.train_orders.size(), 2)
	eq(m.train_orders[0].position, a.position)  # back at its original index
	eq(m.train_orders[1].position, b.position)
	m.free()

func _test_order_pop_undo() -> void:
	var m := _main()
	var a := _town_with_station(m, 0.0)
	var b := _town_with_station(m, 400.0)
	m.train_orders.append(a)
	m.train_orders.append(b)
	m._pop_order_stop()
	eq(m.train_orders.size(), 1)
	m._pop_order_stop()
	eq(m.train_orders.size(), 0)
	m._pop_order_stop()  # empty list: no push
	eq(m.undo_stack.size(), 2)
	m._undo()
	eq(m.train_orders.size(), 1)
	eq(m.train_orders[0].position, a.position)
	m._undo()
	eq(m.train_orders.size(), 2)
	eq(m.train_orders[1].position, b.position)
	m.free()

func _test_buy_train_undo() -> void:
	var m := _main()
	m._buy_train()
	eq(m.roster.size(), 2)
	eq(m.selected_train, 1)
	eq(m.undo_stack.size(), 1)
	m._undo()
	eq(m.roster.size(), 1)
	eq(m.selected_train, 0)
	m.free()

func _test_sell_train_undo() -> void:
	var m := _main()
	var town := _town_with_station(m, 0.0)
	m._buy_train()
	m.roster[1].car_count = 3
	m.roster[1].orders.append(town)
	m._sell_train()
	eq(m.roster.size(), 1)
	eq(m.undo_stack.size(), 2)
	m._undo()
	eq(m.roster.size(), 2)
	eq(m.roster[1].car_count, 3)
	eq(m.roster[1].orders.size(), 1)
	eq(m.roster[1].orders[0], m.towns[0])
	m.free()

func _test_sell_last_train() -> void:
	var m := _main()
	m._sell_train()
	eq(m.roster.size(), 1)
	is_true(m.status_message != "")
	eq(m.undo_stack.size(), 0)
	m.free()

func _test_two_actions() -> void:
	var m := _main()
	m._place_town(Vector2(100, 100))
	m._place_town(Vector2(400, 100))
	eq(m.towns.size(), 2)
	eq(m.undo_stack.size(), 2)
	m._undo()
	eq(m.towns.size(), 1)
	eq(m.next_color_index, 1)
	m._undo()
	eq(m.towns.size(), 0)
	eq(m.next_color_index, 0)
	m.free()

func _test_empty_stack() -> void:
	var m := _main()
	m._undo()
	eq(m.status_message, "Nothing to undo")
	eq(m.towns.size(), 0)
	m.free()

func _test_stack_capped() -> void:
	var m := _main()
	for i in range(m.UNDO_LIMIT + 5):
		m._place_town(Vector2(10 * i, 100))
	eq(m.undo_stack.size(), m.UNDO_LIMIT)
	for i in range(m.UNDO_LIMIT):
		m._undo()
	eq(m.undo_stack.size(), 0)
	eq(m.towns.size(), 5)  # the oldest 5 snapshots were dropped
	m.free()

func _test_reset_clears() -> void:
	var m := _main()
	m._place_town(Vector2(100, 100))
	eq(m.undo_stack.size(), 1)
	m._reset_game()
	eq(m.undo_stack.size(), 0)
	m._undo()
	eq(m.status_message, "Nothing to undo")
	m.free()
