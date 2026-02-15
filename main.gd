extends Node2D

var town_a: Town
var town_b: Town
var train: Train
var money := 1000.0
var frame_count := 0

func _ready() -> void:
	town_a = Town.new(Vector2(200, 300), Color.BLUE)
	town_b = Town.new(Vector2(800, 400), Color.RED)
	train = Train.new()

func _process(delta: float) -> void:
	if frame_count > 9:
		town_a.generate_passengers()
		town_b.generate_passengers()
		print(town_a.waiting)
		print(town_b.waiting)
		frame_count = 0

	train.move(delta)
	if train.has_arrived_at_end():
		money += train.unload() * 10
		train.board_from(town_b)
		train.reverse()
	elif train.has_arrived_at_start():
		money += train.unload() * 10
		train.board_from(town_a)
		train.reverse()

	frame_count += 1
	queue_redraw()

func _draw() -> void:
	draw_circle(town_a.position, 30, town_a.color)
	draw_circle(town_b.position, 30, town_b.color)
	draw_line(town_a.position, town_b.position, Color.GRAY, 3.0)
	var train_world := train.world_position(town_a.position, town_b.position)
	var track_angle := (town_b.position - town_a.position).angle()
	draw_set_transform(train_world, track_angle)
	draw_rect(Rect2(-20, -7, 40, 14), Color.YELLOW)
	draw_set_transform(Vector2.ZERO, 0)
	draw_string(ThemeDB.fallback_font, town_a.position + Vector2(-30, -40),
		"Waiting: %d" % int(town_a.waiting))
	draw_string(ThemeDB.fallback_font, town_b.position + Vector2(-30, -40),
		"Waiting: %d" % int(town_b.waiting))
	draw_string(ThemeDB.fallback_font, train_world + Vector2(-20, -15),
		"%d" % train.passengers_on_board)
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Money: %d | On board: %d" % [money, train.passengers_on_board])
