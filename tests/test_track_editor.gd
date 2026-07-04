class_name TestTrackEditor
extends TestBase

func _node(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

func _editor() -> TrackEditor:
	return TrackEditor.new(TrackNetwork.new())

## Build an editor with a straight bidirectional track from (0,0) to (300,0).
func _editor_with_track() -> TrackEditor:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(300, 0), [])
	return ed

func run_all() -> void:
	print("[TestTrackEditor]")
	_t("start_drawing_sets_state", _test_start_drawing)
	_t("add_waypoint", _test_add_waypoint)
	_t("undo_waypoint", _test_undo_waypoint)
	_t("undo_waypoint_empty_is_noop", _test_undo_empty)
	_t("cancel_resets_state", _test_cancel)
	_t("cancel_cleans_up_fresh_junction", _test_cancel_cleans_fresh_junction)
	_t("finish_at_creates_bidirectional_and_resets", _test_finish_at)
	_t("finish_and_continue_creates_track_and_continues", _test_finish_and_continue)
	_t("create_bidirectional_track", _test_create_bidirectional)
	_t("find_junction_at_found", _test_find_junction_found)
	_t("find_junction_at_miss", _test_find_junction_miss)
	_t("find_track_at_found", _test_find_track_found)
	_t("find_track_at_miss", _test_find_track_miss)
	_t("reverse_linked_on_create", _test_reverse_linked_on_create)
	_t("reverse_linked_on_split", _test_reverse_linked_on_split)
	_t("reverse_linked_on_place_station", _test_reverse_linked_on_station)
	_t("try_delete_track_at", _test_delete_track)
	_t("split_track_at_hit", _test_split_track)
	_t("finish_rejects_tight_curve", _test_finish_rejects_tight)
	_t("finish_accepts_gentle_curve", _test_finish_accepts_gentle)
	_t("turnout_shallow_angle_accepted", _test_turnout_shallow)
	_t("turnout_steep_angle_rejected", _test_turnout_steep)
	_t("turnout_no_existing_tracks_accepted", _test_turnout_no_existing)
	_t("finish_on_track_tangential_connects", _test_finish_on_track_connects)
	_t("finish_on_track_steep_rejected_without_split", _test_finish_on_track_steep_no_split)
	_t("finish_on_track_continue_keeps_drawing", _test_finish_on_track_continue)
	_t("finish_on_track_platform_rejected", _test_finish_on_track_platform)
	_t("place_station_creates_platform", _test_place_station)
	_t("place_station_snaps_to_endpoint", _test_place_station_snaps)
	_t("place_station_rejects_outside_town", _test_station_outside_town)
	_t("place_station_rejects_second_station", _test_station_second_rejected)
	_t("place_station_rejects_short_track", _test_station_short_track)
	_t("place_station_rejects_platform_overlap", _test_station_overlap_rejected)
	_t("split_rejected_on_platform", _test_split_rejected_on_platform)
	_t("delete_rejected_on_platform", _test_delete_rejected_on_platform)
	_t("remove_town_removes_station", _test_remove_town)

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

func _test_cancel_cleans_fresh_junction() -> void:
	# A junction placed to start a free draw is removed again on cancel.
	var ed := _editor()
	var j := _node(10, 10)
	ed.network.add_node(j)
	ed.start_drawing(j)
	ed.cancel()
	is_false(ed.network.nodes.has(j))

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
	var j := _node(100, 100)
	ed.network.add_node(j)
	var found := ed.find_junction_at(Vector2(105, 100))
	eq(found, j)

func _test_find_junction_miss() -> void:
	var ed := _editor()
	var j := _node(100, 100)
	ed.network.add_node(j)
	var found := ed.find_junction_at(Vector2(200, 200))
	eq(found, null)

func _test_find_track_found() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	var hit := ed.find_track_at(Vector2(100, 5))
	eq(hit.size(), 2)

func _test_find_track_miss() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	var hit := ed.find_track_at(Vector2(100, 100))
	eq(hit.size(), 0)

func _test_reverse_linked_on_create() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	var fwd := ed.network.segments[0]
	var rev := ed.network.segments[1]
	eq(fwd.reverse, rev)
	eq(rev.reverse, fwd)
	eq(rev.node_start, fwd.node_end)
	eq(rev.node_end, fwd.node_start)

func _test_reverse_linked_on_split() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	var hit := ed.find_track_at(Vector2(100, 0))
	ed.split_track_at_hit(hit)
	eq(ed.network.segments.size(), 4)
	for seg in ed.network.segments:
		is_true(seg.reverse != null)
		eq(seg.reverse.node_start, seg.node_end)
		eq(seg.reverse.node_end, seg.node_start)
		eq(seg.reverse.reverse, seg)

func _test_reverse_linked_on_station() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(400, 0), [])
	var town := Town.new(Vector2(200, 30), Color.WHITE)
	var station := ed.place_station(Vector2(200, 0), [town])
	is_true(station != null)
	var platform: Platform = station.platforms[0]
	eq(platform.segment.reverse, platform.reverse_segment)
	eq(platform.reverse_segment.reverse, platform.segment)
	# Approach segments created around the platform are linked too.
	for seg in ed.network.segments:
		is_true(seg.reverse != null)
		eq(seg.reverse.reverse, seg)

func _test_delete_track() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	eq(ed.network.segments.size(), 2)
	is_false(ed.try_delete_track_at(Vector2(100, 100)))  # miss reports false
	is_true(ed.try_delete_track_at(Vector2(100, 0)))
	eq(ed.network.segments.size(), 0)

func _test_split_track() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(200, 0), [])
	var hit := ed.find_track_at(Vector2(100, 0))
	var junction := ed.split_track_at_hit(hit)
	is_true(junction != null)
	is_true(ed.network.nodes.has(junction))
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

func _test_turnout_shallow() -> void:
	# Create a track A→B going right, then branch from A at ~10° — should be accepted
	var ed := _editor()
	var a := _node(0, 0)
	var b := _node(300, 0)
	ed.create_bidirectional_track(a, b, [])
	# New track from A at a shallow angle (~10° above horizontal)
	var c := _node(300, -53)  # atan(53/300) ≈ 10°
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
	var a := _node(0, 0)
	var b := _node(300, 0)
	ed.create_bidirectional_track(a, b, [])
	# New track from A at 45° — way too steep
	var c := _node(300, -300)  # atan(300/300) = 45°
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
	var a := _node(0, 0)
	var b := _node(100, 200)
	ed.network.add_node(a)
	ed.network.add_node(b)
	ed.start_drawing(a)
	var ok := ed.finish_at(b)
	is_true(ok)
	eq(ed.network.segments.size(), 2)

func _test_finish_on_track_connects() -> void:
	# Approach the track in line with its tangent — split and connect.
	var ed := _editor_with_track()
	var c := _node(500, 0)
	ed.network.add_node(c)
	ed.start_drawing(c)
	var hit := ed.find_track_at(Vector2(150, 0))
	var ok := ed.finish_on_track(hit)
	is_true(ok)
	is_false(ed.drawing)
	# 2 original split into 4, plus the new bidirectional pair
	eq(ed.network.segments.size(), 6)

func _test_finish_on_track_steep_no_split() -> void:
	# A perpendicular approach is rejected BEFORE the track is split.
	var ed := _editor_with_track()
	var c := _node(150, 300)
	ed.network.add_node(c)
	ed.start_drawing(c)
	var nodes_before := ed.network.nodes.size()
	var hit := ed.find_track_at(Vector2(150, 0))
	var ok := ed.finish_on_track(hit)
	is_false(ok)
	is_true(ed.last_finish_rejected)
	eq(ed.rejection_reason, "turnout")
	is_true(ed.drawing)  # still drawing
	eq(ed.network.segments.size(), 2)  # track NOT split
	eq(ed.network.nodes.size(), nodes_before)  # no junction crumb

func _test_finish_on_track_continue() -> void:
	var ed := _editor_with_track()
	var c := _node(500, 0)
	ed.network.add_node(c)
	ed.start_drawing(c)
	var hit := ed.find_track_at(Vector2(150, 0))
	var ok := ed.finish_on_track(hit, true)
	is_true(ok)
	is_true(ed.drawing)  # chain continues from the new junction
	approx(ed.start_node.position.x, 150.0, 5.0)
	eq(ed.waypoints.size(), 0)
	eq(ed.network.segments.size(), 6)

func _test_finish_on_track_platform() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 0), towns)
	var platform: Platform = station.platforms[0]
	var c := _node(500, 0)
	ed.network.add_node(c)
	ed.start_drawing(c)
	var ok := ed.finish_on_track([platform.segment, 0.5])
	is_false(ok)
	is_true(ed.last_error != "")
	eq(ed.network.segments.size(), 6)  # unchanged

func _test_place_station() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 5), towns)
	is_true(station != null)
	eq(town.station, station)
	eq(station.town, town)
	eq(station.platforms.size(), 1)
	var platform: Platform = station.platforms[0]
	is_true(platform.segment.is_platform_segment())
	is_true(platform.reverse_segment.is_platform_segment())
	eq(platform.station, station)
	approx(platform.segment.length(), TrackEditor.PLATFORM_LENGTH, 15.0)
	# Entry/exit junctions registered in the network
	is_true(ed.network.nodes.has(platform.segment.node_start))
	is_true(ed.network.nodes.has(platform.segment.node_end))
	# approach pair + platform pair + exit pair
	eq(ed.network.segments.size(), 6)

func _test_place_station_snaps() -> void:
	# Clicking near a segment end snaps the platform to the existing node
	# instead of creating a stub segment.
	var ed := _editor()
	var a := _node(0, 0)
	ed.create_bidirectional_track(a, _node(300, 0), [])
	var town := Town.new(Vector2(40, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(40, 0), towns)
	is_true(station != null)
	eq(station.platforms[0].segment.node_start, a)
	# platform pair + exit pair only — no approach stub
	eq(ed.network.segments.size(), 4)

func _test_station_outside_town() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 300), Color.WHITE)  # far from the track
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 0), towns)
	eq(station, null)
	is_true(ed.last_error != "")
	eq(ed.network.segments.size(), 2)  # untouched

func _test_station_second_rejected() -> void:
	# Two parallel tracks inside one town — only one station allowed.
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(300, 0), [])
	ed.create_bidirectional_track(_node(0, 40), _node(300, 40), [])
	var town := Town.new(Vector2(150, 20), Color.WHITE)
	var towns: Array[Town] = [town]
	var first := ed.place_station(Vector2(150, 0), towns)
	is_true(first != null)
	var second := ed.place_station(Vector2(150, 40), towns)
	eq(second, null)
	is_true(ed.last_error != "")
	eq(town.station, first)

func _test_station_short_track() -> void:
	var ed := _editor()
	ed.create_bidirectional_track(_node(0, 0), _node(120, 0), [])
	var town := Town.new(Vector2(60, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(60, 0), towns)
	eq(station, null)
	is_true(ed.last_error != "")
	eq(ed.network.segments.size(), 2)  # untouched

func _test_station_overlap_rejected() -> void:
	# Clicking on an existing platform segment is rejected.
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var other := Town.new(Vector2(160, 0), Color.WHITE)
	var towns: Array[Town] = [town, other]
	var first := ed.place_station(Vector2(150, 0), towns)
	is_true(first != null)
	var second := ed.place_station(Vector2(160, 0), towns)
	eq(second, null)
	is_true(ed.last_error != "")
	eq(other.station, null)

func _test_split_rejected_on_platform() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 0), towns)
	var platform: Platform = station.platforms[0]
	var junction := ed.split_track_at_hit([platform.segment, 0.5])
	eq(junction, null)
	is_true(ed.last_error != "")
	eq(ed.network.segments.size(), 6)  # unchanged

func _test_delete_rejected_on_platform() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var towns: Array[Town] = [town]
	ed.place_station(Vector2(150, 0), towns)
	eq(ed.network.segments.size(), 6)
	is_false(ed.try_delete_track_at(Vector2(150, 0)))  # platform centre
	is_true(ed.last_error != "")
	eq(ed.network.segments.size(), 6)  # unchanged

func _test_remove_town() -> void:
	var ed := _editor_with_track()
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	var other := Town.new(Vector2(500, 500), Color.WHITE)
	var towns: Array[Town] = [town, other]
	var orders: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 0), towns)
	is_true(station != null)
	ed.remove_town(town, towns, orders)
	eq(town.station, null)
	is_false(towns.has(town))
	is_true(towns.has(other))
	eq(orders.size(), 0)
	# Platform pair removed, approach tracks remain
	eq(ed.network.segments.size(), 4)
	for seg in ed.network.segments:
		is_false(seg.is_platform_segment())
