class_name TestTown
extends TestBase

func run_all() -> void:
	print("[TestTown]")
	_t("init", _test_init)
	_t("generate_passengers_increases_waiting", _test_generate_passengers)
	_t("pickup_returns_floored_count", _test_pickup_returns_floored)
	_t("pickup_limited_by_capacity", _test_pickup_capacity_limit)
	_t("pickup_zero_when_waiting_below_one", _test_pickup_zero_below_one)

func _test_init() -> void:
	var pos := Vector2(100.0, 200.0)
	var col := Color.RED
	var t := Town.new(pos, col)
	eq(t.position, pos)
	eq(t.color, col)
	eq(t.waiting, 0.0)

func _test_generate_passengers() -> void:
	var t := Town.new(Vector2.ZERO, Color.WHITE)
	# After 1000 calls the expected value is ~250; this just confirms it's > 0.
	for i in 1000:
		t.generate_passengers()
	gt(t.waiting, 0.0)

func _test_pickup_returns_floored() -> void:
	var t := Town.new(Vector2.ZERO, Color.WHITE)
	t.waiting = 5.7
	var picked := t.pickup_passengers(40)
	eq(picked, 5)
	approx(t.waiting, 0.7, 0.01)

func _test_pickup_capacity_limit() -> void:
	var t := Town.new(Vector2.ZERO, Color.WHITE)
	t.waiting = 20.0
	var picked := t.pickup_passengers(10)
	eq(picked, 10)
	approx(t.waiting, 10.0, 0.01)

func _test_pickup_zero_below_one() -> void:
	var t := Town.new(Vector2.ZERO, Color.WHITE)
	t.waiting = 0.8
	var picked := t.pickup_passengers(40)
	eq(picked, 0)
	approx(t.waiting, 0.8, 0.01)
