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
	_t("finish_rejects_tight_curve", _test_finish_rejects_tight)
	_t("finish_accepts_gentle_curve", _test_finish_accepts_gentle)
	_t("turnout_shallow_angle_accepted", _test_turnout_shallow)
	_t("turnout_steep_angle_rejected", _test_turnout_steep)
	_t("turnout_no_existing_tracks_accepted", _test_turnout_no_existing)
	_t("turnout_skipped_for_towns", _test_turnout_town_exempt)

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

func _test_finish_rejects_tight() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(0, 60)
	ed.start_drawing(a)
	ed.add_waypoint(Vector2(50, 0))
	ed.add_waypoint(Vector2(50, 30))
	var ok := ed.finish_at(b)
	is_false(ok)
	is_true(ed.last_finish_rejected)
	is_true(ed.drawing)  # still drawing — not cancelled
	eq(ed.network.segments.size(), 0)  # no track created

func _test_finish_accepts_gentle() -> void:
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(300, 0)
	ed.start_drawing(a)
	ed.add_waypoint(Vector2(150, 40))
	var ok := ed.finish_at(b)
	is_true(ok)
	is_false(ed.last_finish_rejected)
	eq(ed.network.segments.size(), 2)  # bidirectional

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

func _test_turnout_shallow() -> void:
	# Create a track A→B going right, then branch from A at ~10° — should be accepted
	var ed := _editor()
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(300, 0))
	ed.network.add_node(a)
	ed.network.add_node(b)
	ed.create_bidirectional_track(a, b, [])
	# New track from A at a shallow angle (~10° above horizontal)
	var c := NetworkNode.junction(Vector2(300, -53))  # atan(53/300) ≈ 10°
	ed.network.add_node(c)
	ed.start_drawing(a)
	var ok := ed.finish_at(c)
	is_true(ok)
	is_false(ed.last_finish_rejected)
	# 2 original + 2 new = 4
	eq(ed.network.segments.size(), 4)

func _test_turnout_steep() -> void:
	# Create a track A→B going right, then branch from A at 45° — should be rejected
	var ed := _editor()
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(300, 0))
	ed.network.add_node(a)
	ed.network.add_node(b)
	ed.create_bidirectional_track(a, b, [])
	# New track from A at 45° — way too steep
	var c := NetworkNode.junction(Vector2(300, -300))  # atan(300/300) = 45°
	ed.network.add_node(c)
	ed.start_drawing(a)
	var ok := ed.finish_at(c)
	is_false(ok)
	is_true(ed.last_finish_rejected)
	eq(ed.rejection_reason, "turnout")
	eq(ed.network.segments.size(), 2)  # only the original track

func _test_turnout_no_existing() -> void:
	# First track from a node — no existing tracks, so any angle is fine
	var ed := _editor()
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(100, 200))
	ed.network.add_node(a)
	ed.network.add_node(b)
	ed.start_drawing(a)
	var ok := ed.finish_at(b)
	is_true(ok)
	eq(ed.network.segments.size(), 2)

func _test_turnout_town_exempt() -> void:
	# Towns skip turnout angle validation — steep angle at a town is fine
	var ed := _editor()
	var ta := _town(0, 0)
	var tb := _town(300, 0)
	ed.network.add_node(ta.node)
	ed.network.add_node(tb.node)
	ed.create_bidirectional_track(ta.node, tb.node, [])
	# New track from town A at 45° — would fail at a junction, but towns are exempt
	var tc := _town(300, -300)
	ed.network.add_node(tc.node)
	ed.start_drawing(ta.node)
	var ok := ed.finish_at(tc.node)
	is_true(ok)
	eq(ed.network.segments.size(), 4)
