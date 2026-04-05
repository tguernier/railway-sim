class_name TestTrackEditor
extends TestBase

func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _node(x: float, y: float) -> NetworkNode:
	return _town(x, y).node

func _editor() -> TrackEditor:
	return TrackEditor.new(TrackNetwork.new())

func run_all() -> void:
	print("[TestTrackEditor]")
	_t("start_drawing_sets_state", _test_start_drawing)
	_t("add_waypoint", _test_add_waypoint)
	_t("undo_waypoint", _test_undo_waypoint)
	_t("undo_waypoint_empty_is_noop", _test_undo_empty)
	_t("cancel_resets_state", _test_cancel)
	_t("finish_at_creates_bidirectional_and_resets", _test_finish_at)
	_t("finish_and_continue_creates_track_and_continues", _test_finish_and_continue)
	_t("create_bidirectional_track", _test_create_bidirectional)
	_t("find_junction_at_found", _test_find_junction_found)
	_t("find_junction_at_miss", _test_find_junction_miss)
	_t("find_track_at_found", _test_find_track_found)
	_t("find_track_at_miss", _test_find_track_miss)
	_t("find_reverse_segment", _test_find_reverse)
	_t("try_delete_track_at", _test_delete_track)
	_t("split_track_at_hit", _test_split_track)
	_t("remove_town_cleans_up", _test_remove_town)

func _test_start_drawing() -> void:
	var ed := _editor()
	var n := _node(0, 0)
	ed.start_drawing(n)
	is_true(ed.drawing)
	eq(ed.start_node, n)
	eq(ed.waypoints.size(), 0)

func _test_add_waypoint() -> void:
	var ed := _editor()
	ed.start_drawing(_node(0, 0))
	ed.add_waypoint(Vector2(50, 50))
	ed.add_waypoint(Vector2(100, 100))
	eq(ed.waypoints.size(), 2)

func _test_undo_waypoint() -> void:
	var ed := _editor()
	ed.start_drawing(_node(0, 0))
	ed.add_waypoint(Vector2(50, 50))
	ed.add_waypoint(Vector2(100, 100))
	ed.undo_waypoint()
	eq(ed.waypoints.size(), 1)

func _test_undo_empty() -> void:
	var ed := _editor()
	ed.undo_waypoint()
	eq(ed.waypoints.size(), 0)

func _test_cancel() -> void:
	var ed := _editor()
	ed.start_drawing(_node(0, 0))
	ed.add_waypoint(Vector2(50, 50))
	ed.cancel()
	is_false(ed.drawing)
	eq(ed.start_node, null)
	eq(ed.waypoints.size(), 0)

func _test_finish_at() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.start_drawing(a)
	ed.finish_at(b)
	is_false(ed.drawing)
	eq(ed.network.segments.size(), 2)  # bidirectional

func _test_finish_and_continue() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.start_drawing(a)
	ed.finish_and_continue(b)
	is_true(ed.drawing)
	eq(ed.start_node, b)
	eq(ed.waypoints.size(), 0)
	eq(ed.network.segments.size(), 2)

func _test_create_bidirectional() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	eq(ed.network.segments.size(), 2)
	eq(ed.network.segments[0].node_start, a)
	eq(ed.network.segments[0].node_end, b)
	eq(ed.network.segments[1].node_start, b)
	eq(ed.network.segments[1].node_end, a)

func _test_find_junction_found() -> void:
	var ed := _editor()
	var j := NetworkNode.junction(Vector2(100, 100))
	ed.network.add_node(j)
	var found := ed.find_junction_at(Vector2(105, 100))
	eq(found, j)

func _test_find_junction_miss() -> void:
	var ed := _editor()
	var j := NetworkNode.junction(Vector2(100, 100))
	ed.network.add_node(j)
	var found := ed.find_junction_at(Vector2(200, 200))
	eq(found, null)

func _test_find_track_found() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	var hit := ed.find_track_at(Vector2(100, 5))
	eq(hit.size(), 2)

func _test_find_track_miss() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	var hit := ed.find_track_at(Vector2(100, 100))
	eq(hit.size(), 0)

func _test_find_reverse() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	var fwd := ed.network.segments[0]
	var rev := ed.find_reverse_segment(fwd)
	eq(rev.node_start, fwd.node_end)
	eq(rev.node_end, fwd.node_start)

func _test_delete_track() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	eq(ed.network.segments.size(), 2)
	ed.try_delete_track_at(Vector2(100, 0))
	eq(ed.network.segments.size(), 0)

func _test_split_track() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(200, 0)
	ed.create_bidirectional_track(a, b, [])
	var hit := ed.find_track_at(Vector2(100, 0))
	var junction := ed.split_track_at_hit(hit)
	is_true(junction.is_junction())
	# Original 2 segments replaced by 4 (2 halves x bidirectional)
	eq(ed.network.segments.size(), 4)

func _test_remove_town() -> void:
	var ed := _editor()
	var ta := _town(0, 0)
	var tb := _town(200, 0)
	var towns: Array[Town] = [ta, tb]
	var orders: Array[Town] = [ta, tb]
	ed.network.add_node(ta.node)
	ed.network.add_node(tb.node)
	ed.create_bidirectional_track(ta.node, tb.node, [])
	ed.remove_town(ta, towns, orders)
	eq(ed.network.segments.size(), 0)
	is_false(towns.has(ta))
	is_false(orders.has(ta))
	is_true(towns.has(tb))
