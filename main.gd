## Main game node. Manages game state, towns, tracks, trains, and rendering.
extends Node2D

## The two phases of the game: building the network, then watching it run.
enum GameState { EDITING, SIMULATING }

## Current game phase.
var state := GameState.EDITING
## All towns placed on the map.
var towns: Array[Town] = []
## The track network connecting towns and junctions.
var network: TrackNetwork
## Track editor handling drawing state and track operations.
var editor: TrackEditor
## The active train (created when simulation starts).
var train: Train
## Player's current money, earned by delivering passengers.
var money := 1000.0
## Frame counter used to throttle passenger generation.
var frame_count := 0

## The town currently under the mouse cursor, if any.
var hovered_town: Town = null
## The junction currently under the mouse cursor, if any.
var hovered_junction: NetworkNode = null
## Current mouse position in local coordinates.
var mouse_pos := Vector2.ZERO
## Whether the player is editing train orders (stop list).
var editing_orders := false
## The train's ordered stop list, built before simulation starts.
var train_orders: Array[Town] = []

## Rotating palette of colours assigned to new towns.
var town_palette := [
	Color.CORNFLOWER_BLUE, Color.INDIAN_RED, Color.SEA_GREEN,
	Color.ORANGE, Color.MEDIUM_PURPLE, Color.CADET_BLUE,
	Color.SALMON, Color.DARK_CYAN, Color.GOLDENROD,
]
## Index into town_palette for the next town placed.
var next_color_index := 0

## Visual radius of a town circle.
const TOWN_RADIUS := 30.0
## Hit-test radius for clicking on a town.
const TOWN_HIT_RADIUS := 35.0
## Visual radius of a track waypoint dot.
const WAYPOINT_RADIUS := 5.0
## Visual size of a junction diamond (half-width).
const JUNCTION_RADIUS := 8.0

## Runs when the node is ready
func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)

## Runs when there is an input event
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = get_local_mouse_position()
		hovered_town = _find_town_at(mouse_pos)
		hovered_junction = editor.find_junction_at(mouse_pos) if hovered_town == null else null
		queue_redraw()
		return

	if state == GameState.EDITING:
		_handle_edit_input(event)

## Handles inputs for editing mode.
func _handle_edit_input(event: InputEvent) -> void:
	if editing_orders:
		_handle_order_input(event)
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var click_pos := get_local_mouse_position()
			var town := _find_town_at(click_pos)
			var shift: bool = event.shift_pressed

			if editor.drawing:
				var junction := editor.find_junction_at(click_pos) if town == null else null
				if town != null and town.node != editor.start_node:
					editor.finish_at(town.node)
				elif junction != null and junction != editor.start_node and not shift:
					editor.finish_at(junction)
				elif town == null and shift:
					# Shift+click: place a new junction, finish track to it, start new drawing from it
					var new_junction: NetworkNode
					if junction != null and junction != editor.start_node:
						new_junction = junction
					else:
						var track_hit := editor.find_track_at(click_pos)
						if track_hit.size() > 0:
							var hit_seg: TrackSegment = track_hit[0]
							if hit_seg.node_start != editor.start_node and hit_seg.node_end != editor.start_node:
								new_junction = editor.split_track_at_hit(track_hit)
						if new_junction == null:
							new_junction = NetworkNode.junction(click_pos)
							network.add_node(new_junction)
					if new_junction != null and new_junction != editor.start_node:
						editor.finish_and_continue(new_junction)
				elif town == null and junction == null:
					var track_hit := editor.find_track_at(click_pos)
					if track_hit.size() > 0:
						var hit_seg: TrackSegment = track_hit[0]
						if hit_seg.node_start == editor.start_node or hit_seg.node_end == editor.start_node:
							editor.add_waypoint(click_pos)
						else:
							var new_junction := editor.split_track_at_hit(track_hit)
							if new_junction != null and new_junction != editor.start_node:
								editor.finish_at(new_junction)
					else:
						editor.add_waypoint(click_pos)
			else:
				if town != null:
					editor.start_drawing(town.node)
				else:
					var junction := editor.find_junction_at(click_pos)
					if junction != null:
						editor.start_drawing(junction)
					elif shift:
						_place_town(click_pos)
					else:
						var track_hit := editor.find_track_at(click_pos)
						if track_hit.size() > 0:
							var new_junction := editor.split_track_at_hit(track_hit)
							editor.start_drawing(new_junction)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if editor.drawing:
				editor.cancel()
			else:
				var click_pos := get_local_mouse_position()
				var right_town := _find_town_at(click_pos)
				if right_town != null:
					editor.remove_town(right_town, towns, train_orders)
				else:
					editor.try_delete_track_at(click_pos)

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				if editor.drawing:
					editor.cancel()
			KEY_SPACE:
				_start_simulation()
			KEY_Z:
				editor.undo_waypoint()
			KEY_O:
				if not editor.drawing:
					editing_orders = true

## Handles inputs while editing train orders.
func _handle_order_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var town := _find_town_at(get_local_mouse_position())
			if town != null:
				var idx := train_orders.find(town)
				if idx >= 0:
					train_orders.remove_at(idx)
				else:
					train_orders.append(town)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if train_orders.size() > 0:
				train_orders.pop_back()

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_O:
				editing_orders = false
			KEY_SPACE:
				editing_orders = false
				_start_simulation()

## Returns the town at a screen position, if there is one.
func _find_town_at(pos: Vector2) -> Town:
	for town in towns:
		if pos.distance_to(town.position) < TOWN_HIT_RADIUS:
			return town
	return null

## Place a town at a screen position.
func _place_town(pos: Vector2) -> void:
	var col: Color = town_palette[next_color_index % town_palette.size()]
	next_color_index += 1
	var town := Town.new(pos, col)
	towns.append(town)
	network.add_node(town.node)

## Start the simulation.
func _start_simulation() -> void:
	if train_orders.size() < 2 or network.segments.size() == 0:
		return
	state = GameState.SIMULATING
	editing_orders = false
	train = Train.new()
	train.orders = train_orders.duplicate()
	train.current_order_index = 0
	_dispatch_to_next_order(train_orders[0].node)

## Dispatch the train toward its next order stop via Dijkstra.
func _dispatch_to_next_order(from_node: NetworkNode) -> void:
	train.advance_order()
	var target := train.current_order_town()
	if target == null:
		train.route = []
		return
	var route := network.find_route(from_node, target.node)
	if route.size() > 0:
		train.set_route(route)
	else:
		train.route = []

## Handle 1 simulation tick.
func _process(delta: float) -> void:
	if state == GameState.SIMULATING:
		if frame_count > 9:
			for town in towns:
				town.generate_passengers()
			frame_count = 0

		train.move(delta)
		if train.has_completed_route():
			var dest_town := train.destination_town()
			var end_node: NetworkNode = train.route[-1].node_end
			if dest_town != null:
				money += train.unload() * 10
				train.board_from(dest_town)
			_dispatch_to_next_order(end_node)

		frame_count += 1

	queue_redraw()

## Draw game scene.
func _draw() -> void:
	_draw_tracks()
	_draw_junctions()
	_draw_towns()

	if state == GameState.EDITING:
		_draw_editor_overlay()
	elif state == GameState.SIMULATING:
		_draw_train()
		_draw_hud()

## Draw tracks.
func _draw_tracks() -> void:
	var drawn: Dictionary = {}
	for seg in network.segments:
		var key_a := "%s-%s" % [seg.node_start.position, seg.node_end.position]
		var key_b := "%s-%s" % [seg.node_end.position, seg.node_start.position]
		if not drawn.has(key_a) and not drawn.has(key_b):
			draw_polyline(seg.get_baked_points(), Color.GRAY, 3.0)
			drawn[key_a] = true

## Draw junction nodes as diamonds.
func _draw_junctions() -> void:
	for node in network.nodes:
		if node.is_junction():
			var p := node.position
			var r := JUNCTION_RADIUS
			var diamond := PackedVector2Array([
				p + Vector2(0, -r), p + Vector2(r, 0),
				p + Vector2(0, r), p + Vector2(-r, 0),
				p + Vector2(0, -r),
			])
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(0, -r), p + Vector2(r, 0),
				p + Vector2(0, r), p + Vector2(-r, 0),
			]), Color.WHITE)
			draw_polyline(diamond, Color.DIM_GRAY, 2.0)
			if state == GameState.EDITING and not editing_orders:
				if node == hovered_junction:
					var hr := JUNCTION_RADIUS + 5
					if editor.drawing and node != editor.start_node:
						draw_polyline(PackedVector2Array([
							p + Vector2(0, -hr), p + Vector2(hr, 0),
							p + Vector2(0, hr), p + Vector2(-hr, 0),
							p + Vector2(0, -hr),
						]), Color.GREEN, 2.0)
					elif not editor.drawing:
						draw_polyline(PackedVector2Array([
							p + Vector2(0, -hr), p + Vector2(hr, 0),
							p + Vector2(0, hr), p + Vector2(-hr, 0),
							p + Vector2(0, -hr),
						]), Color.WHITE, 2.0)
				if editor.drawing and node == editor.start_node:
					var hr := JUNCTION_RADIUS + 5
					draw_polyline(PackedVector2Array([
						p + Vector2(0, -hr), p + Vector2(hr, 0),
						p + Vector2(0, hr), p + Vector2(-hr, 0),
						p + Vector2(0, -hr),
					]), Color.WHITE, 2.0)

## Draw towns.
func _draw_towns() -> void:
	for town in towns:
		draw_circle(town.position, TOWN_RADIUS, town.color)
		if state == GameState.EDITING and not editing_orders:
			if town == hovered_town and not editor.drawing:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
			if editor.drawing and town.node == editor.start_node:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
		if state == GameState.EDITING and editing_orders:
			if town == hovered_town:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.YELLOW, 2.0)
		if state == GameState.SIMULATING:
			draw_string(ThemeDB.fallback_font, town.position + Vector2(-30, -40),
				"Waiting: %d" % int(town.waiting))
	if state == GameState.EDITING:
		for i in range(train_orders.size()):
			var town: Town = train_orders[i]
			var label := str(i + 1)
			draw_circle(town.position + Vector2(TOWN_RADIUS, -TOWN_RADIUS), 12, Color.WHITE)
			draw_string(ThemeDB.fallback_font,
				town.position + Vector2(TOWN_RADIUS - 4, -TOWN_RADIUS + 5),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)

## Draw editor overlay.
func _draw_editor_overlay() -> void:
	if editing_orders:
		_draw_order_overlay()
	elif editor.drawing:
		_draw_curvature_preview()
		for wp in editor.waypoints:
			draw_circle(wp, WAYPOINT_RADIUS, Color.WHITE)
		if hovered_town != null and hovered_town.node != editor.start_node:
			draw_arc(hovered_town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.GREEN, 2.0)
		_draw_turnout_angle_preview()
		var hint_text := "Click to add curve points | Click town/junction/track to finish | SHIFT+Click for junction chain | ESC to cancel | Z to undo"
		if editor.last_finish_rejected:
			if editor.rejection_reason == "turnout":
				hint_text = "TURNOUT ANGLE TOO STEEP — approach at a shallower angle | " + hint_text
			else:
				hint_text = "CURVE TOO TIGHT — add waypoints for a gentler bend | " + hint_text
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint_text)
	else:
		var hint := "SHIFT+CLICK to place towns | Click town/junction/track to draw | RIGHT-CLICK to delete | O to edit orders"
		if train_orders.size() >= 2 and network.segments.size() > 0:
			hint += " | SPACE to start simulation"
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)

## Draw the track preview colored by curvature (green = OK, red = too tight).
func _draw_curvature_preview() -> void:
	var preview := editor.build_preview_segment(mouse_pos)
	var points := preview.get_baked_points()
	if points.size() < 3:
		_draw_dashed_line(points, Color(1, 1, 1, 0.5), 2.0, 8.0)
		return
	var total := preview.length()
	if total <= 0.0:
		return
	var step := maxf(total / 20.0, 2.0)
	for i in range(points.size() - 1):
		var mid_offset := 0.0
		for j in range(i + 1):
			if j > 0:
				mid_offset += points[j].distance_to(points[j - 1])
		var p0 := preview.curve.sample_baked(maxf(mid_offset - step, 0.0))
		var p1 := points[i]
		var p2 := preview.curve.sample_baked(minf(mid_offset + step, total))
		var r := TrackSegment._circumradius(p0, p1, p2)
		var color: Color
		if r >= TrackEditor.MIN_CURVE_RADIUS:
			color = Color(0.3, 1.0, 0.3, 0.7)
		else:
			color = Color(1.0, 0.2, 0.2, 0.7)
		draw_line(points[i], points[i + 1], color, 3.0)

## Draw turnout angle indicator at the start node if it has existing tracks.
func _draw_turnout_angle_preview() -> void:
	var existing := network.departure_angles_at(editor.start_node)
	if existing.size() == 0:
		return
	var preview := editor.build_preview_segment(mouse_pos)
	var new_angle := preview.angle_at(0.0)
	var min_diff := INF
	for a in existing:
		var diff := absf(TrackEditor.angle_difference(a, new_angle))
		var diff_rev := absf(TrackEditor.angle_difference(a, new_angle + PI))
		min_diff = minf(min_diff, minf(diff, diff_rev))
	var color := Color.GREEN if min_diff <= TrackEditor.MAX_TURNOUT_ANGLE else Color.RED
	var label := "%d°" % int(rad_to_deg(min_diff))
	draw_string(ThemeDB.fallback_font,
		editor.start_node.position + Vector2(15, -15), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)

## Draw order editing overlay — hint text and route preview.
func _draw_order_overlay() -> void:
	var hint := "ORDERS: Click towns to add/remove stops | RIGHT-CLICK to remove last | ESC/O to finish"
	if train_orders.size() >= 2:
		hint += " | SPACE to start simulation"
	draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)
	if train_orders.size() >= 2:
		for i in range(train_orders.size()):
			var from_pos: Vector2 = train_orders[i].position
			var to_pos: Vector2 = train_orders[(i + 1) % train_orders.size()].position
			_draw_dashed_line(PackedVector2Array([from_pos, to_pos]),
				Color(1, 1, 0, 0.4), 2.0, 10.0)

## Draw dashed line for track preview in editing mode.
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

## Draw train.
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

## Draw HUD.
func _draw_hud() -> void:
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Money: %d | On board: %d" % [money, train.passengers_on_board])
