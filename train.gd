class_name Train
extends RefCounted

var progress: float = 0.0
var direction: float = 1.0
var speed: float = 0.1
var capacity: int = 40
var passengers_on_board: int = 0

func move(delta: float) -> void:
	progress += direction * delta * speed
	progress = clampf(progress, 0.0, 1.0)

func has_arrived_at_end() -> bool:
	return progress >= 1.0

func has_arrived_at_start() -> bool:
	return progress <= 0.0

func reverse() -> void:
	direction *= -1.0

func unload() -> int:
	var fare := passengers_on_board
	passengers_on_board = 0
	return fare

func board_from(town: Town) -> void:
	passengers_on_board = town.pickup_passengers(capacity)

func world_position(from: Vector2, to: Vector2) -> Vector2:
	return from.lerp(to, progress)
