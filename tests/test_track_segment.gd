class_name TestTrackSegment
extends TestBase

# Helpers to keep tests concise.
func _node(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

func _seg(ax: float, ay: float, bx: float, by: float,
		waypoints: Array[Vector2] = []) -> TrackSegment:
	return TrackSegment.new(_node(ax, ay), _node(bx, by), waypoints)

func run_all() -> void:
	print("[TestTrackSegment]")
	_t("stores_nodes", _test_stores_nodes)
	_t("not_platform_segment_by_default", _test_not_platform_by_default)
	_t("platform_marker", _test_platform_marker)
	_t("length_positive", _test_length_positive)
	_t("zero_length_segment_is_safe", _test_zero_length_safe)
	_t("position_at_zero_is_start", _test_position_at_zero)
	_t("position_at_one_is_end", _test_position_at_one)
	_t("angle_horizontal_track", _test_angle_horizontal)
	_t("angle_vertical_track", _test_angle_vertical)
	_t("waypoints_produce_longer_segment", _test_waypoints_longer)
	_t("straight_segment_infinite_radius", _test_straight_infinite_radius)
	_t("gentle_curve_large_radius", _test_gentle_curve_radius)
	_t("tight_uturn_small_radius", _test_tight_uturn_radius)

func _test_stores_nodes() -> void:
	var a := _node(0.0, 0.0)
	var b := _node(100.0, 0.0)
	var seg := TrackSegment.new(a, b)
	eq(seg.node_start, a)
	eq(seg.node_end, b)

func _test_not_platform_by_default() -> void:
	var seg := _seg(0.0, 0.0, 200.0, 0.0)
	is_false(seg.is_platform_segment())
	eq(seg.platform, null)

func _test_platform_marker() -> void:
	var fwd := _seg(0.0, 0.0, 200.0, 0.0)
	var rev := _seg(200.0, 0.0, 0.0, 0.0)
	var platform := Platform.new(fwd, rev, 1.0)
	fwd.platform = platform
	rev.platform = platform
	is_true(fwd.is_platform_segment())
	is_true(rev.is_platform_segment())
	eq(fwd.platform, platform)

func _test_length_positive() -> void:
	var seg := _seg(0.0, 0.0, 100.0, 0.0)
	gt(seg.length(), 0.0)

func _test_zero_length_safe() -> void:
	# Both endpoints at the same position (e.g. preview right after a
	# shift+click chain) must not crash curve sampling.
	var seg := _seg(100.0, 100.0, 100.0, 100.0)
	eq(seg.length(), 0.0)
	eq(seg.position_at(0.5), Vector2(100, 100))
	eq(seg.angle_at(0.5), 0.0)

func _test_position_at_zero() -> void:
	var seg := _seg(0.0, 0.0, 300.0, 0.0)
	approx(seg.position_at(0.0).x, 0.0, 1.0)
	approx(seg.position_at(0.0).y, 0.0, 1.0)

func _test_position_at_one() -> void:
	var seg := _seg(0.0, 0.0, 300.0, 0.0)
	approx(seg.position_at(1.0).x, 300.0, 1.0)
	approx(seg.position_at(1.0).y, 0.0, 1.0)

func _test_angle_horizontal() -> void:
	var seg := _seg(0.0, 0.0, 300.0, 0.0)
	approx(seg.angle_at(0.5), 0.0, 0.05)

func _test_angle_vertical() -> void:
	var seg := _seg(0.0, 0.0, 0.0, 300.0)
	approx(seg.angle_at(0.5), PI / 2.0, 0.05)

func _test_waypoints_longer() -> void:
	var direct := _seg(0.0, 0.0, 200.0, 0.0)
	var detour: Array[Vector2] = [Vector2(100.0, 150.0)]
	var curved := _seg(0.0, 0.0, 200.0, 0.0, detour)
	gt(curved.length(), direct.length())

func _test_straight_infinite_radius() -> void:
	var seg := _seg(0.0, 0.0, 300.0, 0.0)
	var r := seg.min_radius_of_curvature()
	gt(r, 10000.0)  # effectively infinite for a straight line

func _test_gentle_curve_radius() -> void:
	# A gentle arc — waypoint offset only slightly from the midpoint
	var wps: Array[Vector2] = [Vector2(150.0, 40.0)]
	var seg := _seg(0.0, 0.0, 300.0, 0.0, wps)
	var r := seg.min_radius_of_curvature()
	gt(r, TrackEditor.MIN_CURVE_RADIUS)  # should pass the minimum

func _test_tight_uturn_radius() -> void:
	# A sharp U-turn: go right then immediately back left
	var wps: Array[Vector2] = [Vector2(50.0, 0.0), Vector2(50.0, 30.0)]
	var seg := _seg(0.0, 0.0, 0.0, 60.0, wps)
	var r := seg.min_radius_of_curvature()
	check(r < TrackEditor.MIN_CURVE_RADIUS,
		"expected tight U-turn radius %.1f < %.1f" % [r, TrackEditor.MIN_CURVE_RADIUS])
