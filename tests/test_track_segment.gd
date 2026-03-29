class_name TestTrackSegment
extends TestBase

# Helpers to keep tests concise.
func _town(x: float, y: float) -> Town:
	return Town.new(Vector2(x, y), Color.WHITE)

func _seg(ax: float, ay: float, bx: float, by: float,
		waypoints: Array[Vector2] = []) -> TrackSegment:
	return TrackSegment.new(_town(ax, ay), _town(bx, by), waypoints)

func run_all() -> void:
	print("[TestTrackSegment]")
	_t("stores_towns", _test_stores_towns)
	_t("length_positive", _test_length_positive)
	_t("position_at_zero_is_start", _test_position_at_zero)
	_t("position_at_one_is_end", _test_position_at_one)
	_t("angle_horizontal_track", _test_angle_horizontal)
	_t("angle_vertical_track", _test_angle_vertical)
	_t("waypoints_produce_longer_segment", _test_waypoints_longer)

func _test_stores_towns() -> void:
	var a := _town(0.0, 0.0)
	var b := _town(100.0, 0.0)
	var seg := TrackSegment.new(a, b)
	eq(seg.town_start, a)
	eq(seg.town_end, b)

func _test_length_positive() -> void:
	var seg := _seg(0.0, 0.0, 100.0, 0.0)
	gt(seg.length(), 0.0)

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
	# Midpoint tangent of a horizontal line should be ~0 radians.
	approx(seg.angle_at(0.5), 0.0, 0.05)

func _test_angle_vertical() -> void:
	var seg := _seg(0.0, 0.0, 0.0, 300.0)
	# Godot's Y axis points down; angle of (0,1) is PI/2.
	approx(seg.angle_at(0.5), PI / 2.0, 0.05)

func _test_waypoints_longer() -> void:
	var direct := _seg(0.0, 0.0, 200.0, 0.0)
	var detour: Array[Vector2] = [Vector2(100.0, 150.0)]
	var curved := _seg(0.0, 0.0, 200.0, 0.0, detour)
	gt(curved.length(), direct.length())
