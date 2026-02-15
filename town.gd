class_name Town
extends RefCounted

var position: Vector2
var color: Color
var waiting: float = 0.0

func _init(pos: Vector2, col: Color) -> void:
	position = pos
	color = col

func generate_passengers() -> void:
	waiting += randf() * 0.5

func pickup_passengers(capacity: int) -> int:
	var count := int(waiting) if int(waiting) <= capacity else capacity
	waiting -= count
	return count
