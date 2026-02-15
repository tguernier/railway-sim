class_name TrackSegment
extends RefCounted

var town_start: Town
var town_end: Town
var curve: Curve2D

func _init(start: Town, end: Town, waypoints: Array = []) -> void:
	town_start = start
	town_end = end
	curve = Curve2D.new()
	_build_curve(waypoints)

func _build_curve(waypoints: Array) -> void:
	var points: Array[Vector2] = []
	points.append(town_start.position)
	for wp in waypoints:
		points.append(wp)
	points.append(town_end.position)

	for i in range(points.size()):
		var handle_in := Vector2.ZERO
		var handle_out := Vector2.ZERO

		if i == 0:
			var tangent := (points[1] - points[0]).normalized()
			var dist := points[0].distance_to(points[1])
			handle_out = tangent * dist * 0.3
		elif i == points.size() - 1:
			var tangent := (points[i] - points[i - 1]).normalized()
			var dist := points[i].distance_to(points[i - 1])
			handle_in = -tangent * dist * 0.3
		else:
			var tangent := (points[i + 1] - points[i - 1]).normalized()
			var dist_prev := points[i].distance_to(points[i - 1])
			var dist_next := points[i].distance_to(points[i + 1])
			handle_in = -tangent * dist_prev * 0.3
			handle_out = tangent * dist_next * 0.3

		curve.add_point(points[i], handle_in, handle_out)

func length() -> float:
	return curve.get_baked_length()

func position_at(t: float) -> Vector2:
	return curve.sample_baked(t * curve.get_baked_length())

func angle_at(t: float) -> float:
	var total := curve.get_baked_length()
	var offset := t * total
	var epsilon := 1.0
	var p1 := curve.sample_baked(maxf(offset - epsilon, 0.0))
	var p2 := curve.sample_baked(minf(offset + epsilon, total))
	return (p2 - p1).angle()

func get_baked_points() -> PackedVector2Array:
	return curve.get_baked_points()
