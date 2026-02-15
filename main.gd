extends Node2D

enum GameState { EDITING, SIMULATING }

var state := GameState.EDITING
var towns: Array[Town] = []
var network: TrackNetwork
var train: Train
var money := 1000.0
var frame_count := 0

var drawing_track := false
var track_start_town: Town = null
var track_waypoints: Array[Vector2] = []
var hovered_town: Town = null
var mouse_pos := Vector2.ZERO

var town_palette := [
	Color.CORNFLOWER_BLUE, Color.INDIAN_RED, Color.SEA_GREEN,
	Color.ORANGE, Color.MEDIUM_PURPLE, Color.CADET_BLUE,
	Color.SALMON, Color.DARK_CYAN, Color.GOLDENROD,
]
var next_color_index := 0

const TOWN_RADIUS := 30.0
const TOWN_HIT_RADIUS := 35.0
const WAYPOINT_RADIUS := 5.0

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = get_local_mouse_position()
		hovered_town = _find_town_at(mouse_pos)
		queue_redraw()
		return

	if state == GameState.EDITING:
		_handle_edit_input(event)

func _handle_edit_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var click_pos := get_local_mouse_position()
			var town := _find_town_at(click_pos)

			if drawing_track:
				if town != null and town != track_start_town:
					_create_bidirectional_track(track_start_town, town, track_waypoints)
					_reset_drawing()
				elif town == null:
					track_waypoints.append(click_pos)
			else:
				if town != null:
					drawing_track = true
					track_start_town = town
					track_waypoints = []
				else:
					_place_town(click_pos)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if drawing_track:
				_reset_drawing()

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				if drawing_track:
					_reset_drawing()
			KEY_SPACE:
				_start_simulation()
			KEY_Z:
				if drawing_track and track_waypoints.size() > 0:
					track_waypoints.pop_back()

func _find_town_at(pos: Vector2) -> Town:
	for town in towns:
		if pos.distance_to(town.position) < TOWN_HIT_RADIUS:
			return town
	return null

func _place_town(pos: Vector2) -> void:
	var col: Color = town_palette[next_color_index % town_palette.size()]
	next_color_index += 1
	var town := Town.new(pos, col)
	towns.append(town)

func _create_bidirectional_track(from: Town, to: Town, waypoints: Array[Vector2]) -> void:
	network.add_segment(TrackSegment.new(from, to, waypoints))
	var reversed_wp: Array[Vector2] = []
	for i in range(waypoints.size() - 1, -1, -1):
		reversed_wp.append(waypoints[i])
	network.add_segment(TrackSegment.new(to, from, reversed_wp))

func _reset_drawing() -> void:
	drawing_track = false
	track_start_town = null
	track_waypoints = []

func _start_simulation() -> void:
	if towns.size() < 2 or network.segments.size() == 0:
		return
	state = GameState.SIMULATING
	train = Train.new()
	_dispatch_train(towns[0])

func _dispatch_train(from_town: Town) -> void:
	var next_town = null
	if network.get_outgoing(from_town).size() < 2:
		# if train is at a terminus, switch direction
		train.switch_direction()
	if train.direction == train.Direction.FORWARD:
		next_town = network.get_outgoing(from_town)[0].town_end
	else:
		next_town = network.get_outgoing(from_town)[-1].town_end
	var route := network.find_route(from_town, next_town)
	if route.size() > 0:
		train.set_route(route)
	else:
		train.route = []

func _process(delta: float) -> void:
	if state == GameState.SIMULATING:
		if frame_count > 9:
			for town in towns:
				town.generate_passengers()
			frame_count = 0

		train.move(delta)
		if train.has_completed_route():
			var dest := train.destination_town()
			if dest != null:
				money += train.unload() * 10
				train.board_from(dest)
				_dispatch_train(dest)

		frame_count += 1

	queue_redraw()

func _draw() -> void:
	_draw_tracks()
	_draw_towns()

	if state == GameState.EDITING:
		_draw_editor_overlay()
	elif state == GameState.SIMULATING:
		_draw_train()
		_draw_hud()

func _draw_tracks() -> void:
	var drawn: Dictionary = {}
	for seg in network.segments:
		var key_a := "%s-%s" % [seg.town_start.position, seg.town_end.position]
		var key_b := "%s-%s" % [seg.town_end.position, seg.town_start.position]
		if not drawn.has(key_a) and not drawn.has(key_b):
			draw_polyline(seg.get_baked_points(), Color.GRAY, 3.0)
			drawn[key_a] = true

func _draw_towns() -> void:
	for town in towns:
		draw_circle(town.position, TOWN_RADIUS, town.color)
		if state == GameState.EDITING and town == hovered_town and not drawing_track:
			draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
		if state == GameState.EDITING and drawing_track and town == track_start_town:
			draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
		if state == GameState.SIMULATING:
			draw_string(ThemeDB.fallback_font, town.position + Vector2(-30, -40),
				"Waiting: %d" % int(town.waiting))

func _draw_editor_overlay() -> void:
	if drawing_track:
		var preview_points: PackedVector2Array = []
		preview_points.append(track_start_town.position)
		for wp in track_waypoints:
			preview_points.append(wp)
		preview_points.append(mouse_pos)
		_draw_dashed_line(preview_points, Color(1, 1, 1, 0.5), 2.0, 8.0)
		for wp in track_waypoints:
			draw_circle(wp, WAYPOINT_RADIUS, Color.WHITE)
		if hovered_town != null and hovered_town != track_start_town:
			draw_arc(hovered_town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.GREEN, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"Click to add curve points | Click a town to finish | RIGHT-CLICK/ESC to cancel | Z to undo point")
	else:
		var hint := "LEFT-CLICK to place towns | Click a town to draw tracks"
		if towns.size() >= 2 and network.segments.size() > 0:
			hint += " | SPACE to start simulation"
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)

func _draw_dashed_line(points: PackedVector2Array, color: Color, width: float, dash_length: float) -> void:
	for i in range(points.size() - 1):
		var from := points[i]
		var to := points[i + 1]
		var dir := (to - from).normalized()
		var dist := from.distance_to(to)
		var p := from
		var drawn := 0.0
		var drawing := true
		while drawn < dist:
			var seg_len := minf(dash_length, dist - drawn)
			if drawing:
				draw_line(p, p + dir * seg_len, color, width)
			p += dir * seg_len
			drawn += seg_len
			drawing = not drawing

func _draw_train() -> void:
	var train_pos := train.current_position()
	var train_angle := train.current_angle()
	draw_set_transform(train_pos, train_angle)
	draw_rect(Rect2(-20, -7, 40, 14), Color.DIM_GRAY)
	draw_circle(Vector2(18, 0), 2.0, Color.YELLOW)
	draw_circle(Vector2(-18, 0), 2.0, Color.RED)
	draw_set_transform(Vector2.ZERO, 0)
	draw_string(ThemeDB.fallback_font, train_pos + Vector2(-20, -15),
		"%d" % train.passengers_on_board)

func _draw_hud() -> void:
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Money: %d | On board: %d" % [money, train.passengers_on_board])
