## Minimal test base class. Subclasses call _t(name, callable) to register tests.
class_name TestBase
extends RefCounted

var _pass: int = 0
var _fail: int = 0

## Run a named test function and report pass/fail.
func _t(name: String, fn: Callable) -> void:
	var prev_fail := _fail
	fn.call()
	if _fail == prev_fail:
		print("  pass  %s" % name)
	else:
		print("  FAIL  %s" % name)

## Assertion helpers — print detail on failure, silent on pass.

func check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("        -> %s" % msg)

func eq(actual, expected) -> void:
	check(actual == expected, "expected %s, got %s" % [str(expected), str(actual)])

func approx(actual: float, expected: float, tol := 1.0) -> void:
	check(abs(actual - expected) <= tol,
		"expected ~%.2f (±%.2f), got %.2f" % [expected, tol, actual])

func gt(actual: float, threshold: float) -> void:
	check(actual > threshold, "expected %s > %s" % [str(actual), str(threshold)])

func is_true(cond: bool) -> void:
	check(cond, "expected true")

func is_false(cond: bool) -> void:
	check(not cond, "expected false")
