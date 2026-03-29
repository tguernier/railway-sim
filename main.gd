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
## The active train (created when simulation starts).
var train: Train
## Player's current money, earned by delivering passengers.
var money := 1000.0
## Frame counter used to throttle passenger generation.
var frame_count := 0

## Whether the player is currently drawing a track.
var drawing_track := false
## The network node where the current track being drawn starts.
var track_start_node: NetworkNode = null
## Intermediate waypoints for the track currently being drawn.
var track_waypoints: Array[Vector2] = []
## The town currently under the mouse cursor, if any.
var hovered_town: Town = null
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
## Hit-test distance for clicking on a track segment.
const TRACK_HIT_RADIUS := 15.0
## Visual size of a junction diamond (half-width).
const JUNCTION_RADIUS := 8.0

## Runs when the node is ready
func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()

## Runs when there is an input event
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = get_local_mouse_position()
		hovered_town = _find_town_at(mouse_pos)
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

			if drawing_track:
				if town != null and town.node != track_start_node:
					_create_bidirectional_track(track_start_node, town.node, track_waypoints)
					_reset_drawing()
				elif town == null and shift:
					# Shift+click: place a junction, finish track to it, start new drawing from it
					var junction := NetworkNode.junction(click_pos)
					network.add_node(junction)
					_create_bidirectional_track(track_start_node, junction, track_waypoints)
					track_start_node = junction
					track_waypoints = []
				elif town == null:
					track_waypoints.append(click_pos)
			else:
				if town != null:
					drawing_track = true
					track_start_node = town.node
					track_waypoints = []
				else:
					# Check if clicking on an existing junction
					var junction := _find_junction_at(click_pos)
					if junction != null:
						drawing_track = true
						track_start_node = junction
						track_waypoints = []
					else:
						_place_town(click_pos)

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if drawing_track:
				_reset_drawing()
			else:
				# Right-click on a track to delete it
				var click_pos := get_local_mouse_position()
				_try_delete_track_at(click_pos)

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
			KEY_O:
				if not drawing_track:
					editing_orders = true

## Handles inputs while editing train orders.
func _handle_order_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var town := _find_town_at(get_local_mouse_position())
			if town != null:
				var idx := train_orders.find(town)
				if idx >= 0:
					# Clicking an already-added town removes it
					train_orders.remove_at(idx)
				else:
					train_orders.append(town)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Right-click removes the last order
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

## Returns the junction node at a screen position, if there is one.
func _find_junction_at(pos: Vector2) -> NetworkNode:
	for node in network.nodes:
		if node.is_junction() and pos.distance_to(node.position) < TRACK_HIT_RADIUS:
			return node
	return null

## Find the closest track segment to a screen position. Returns [segment, t] or null.
func _find_track_at(pos: Vector2) -> Array:
	var best_seg: TrackSegment = null
	var best_dist := TRACK_HIT_RADIUS
	var best_t := 0.0
	var drawn: Dictionary = {}
	for seg in network.segments:
		# Skip reverse duplicates
		var key_a := "%s-%s" % [seg.node_start.position, seg.node_end.position]
		var key_b := "%s-%s" % [seg.node_end.position, seg.node_start.position]
		if drawn.has(key_a) or drawn.has(key_b):
			continue
		drawn[key_a] = true

		var points := seg.get_baked_points()
		var total_len := seg.length()
		if total_len <= 0.0:
			continue
		var accumulated := 0.0
		for i in range(points.size()):
			var d := pos.distance_to(points[i])
			if d < best_dist:
				best_dist = d
				best_seg = seg
				if i > 0:
					accumulated += points[i].distance_to(points[i - 1])
				best_t = accumulated / total_len
			elif i > 0:
				accumulated += points[i].distance_to(points[i - 1])
	if best_seg != null:
		return [best_seg, best_t]
	return []

## Try to delete the track at a screen position.
func _try_delete_track_at(pos: Vector2) -> void:
	var hit := _find_track_at(pos)
	if hit.size() == 0:
		return
	var seg: TrackSegment = hit[0]
	# Find and remove the reverse segment too
	var reverse := _find_reverse_segment(seg)
	network.remove_segment(seg)
	if reverse != null:
		network.remove_segment(reverse)
	# Clean up orphan junctions at both ends
	network.cleanup_orphan(seg.node_start)
	network.cleanup_orphan(seg.node_end)

## Find the reverse of a segment (same endpoints, opposite direction).
func _find_reverse_segment(seg: TrackSegment) -> TrackSegment:
	for s in network.segments:
		if s.node_start == seg.node_end and s.node_end == seg.node_start:
			return s
	return null

## Place a town at a screen position.
func _place_town(pos: Vector2) -> void:
	var col: Color = town_palette[next_color_index % town_palette.size()]
	next_color_index += 1
	var town := Town.new(pos, col)
	towns.append(town)
	network.add_node(town.node)

## Create a bidirectional track between two network nodes.
func _create_bidirectional_track(from: NetworkNode, to: NetworkNode, waypoints: Array[Vector2]) -> void:
	network.add_segment(TrackSegment.new(from, to, waypoints))
	var reversed_wp: Array[Vector2] = []
	for i in range(waypoints.size() - 1, -1, -1):
		reversed_wp.append(waypoints[i])
	network.add_segment(TrackSegment.new(to, from, reversed_wp))

## Reset the drawing state.
func _reset_drawing() -> void:
	drawing_track = false
	track_start_node = null
	track_waypoints = []

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
		# No path to this stop — skip to next
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

## Draw towns.
func _draw_towns() -> void:
	for town in towns:
		draw_circle(town.position, TOWN_RADIUS, town.color)
		if state == GameState.EDITING and not editing_orders:
			if town == hovered_town and not drawing_track:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
			if drawing_track and town.node == track_start_node:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.WHITE, 2.0)
		if state == GameState.EDITING and editing_orders:
			# Highlight hovered town
			if town == hovered_town:
				draw_arc(town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.YELLOW, 2.0)
		if state == GameState.SIMULATING:
			draw_string(ThemeDB.fallback_font, town.position + Vector2(-30, -40),
				"Waiting: %d" % int(town.waiting))
	# Draw order numbers on towns that are in the order list
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
	elif drawing_track:
		var preview_points: PackedVector2Array = []
		preview_points.append(track_start_node.position)
		for wp in track_waypoints:
			preview_points.append(wp)
		preview_points.append(mouse_pos)
		_draw_dashed_line(preview_points, Color(1, 1, 1, 0.5), 2.0, 8.0)
		for wp in track_waypoints:
			draw_circle(wp, WAYPOINT_RADIUS, Color.WHITE)
		if hovered_town != null and hovered_town.node != track_start_node:
			draw_arc(hovered_town.position, TOWN_RADIUS + 4, 0, TAU, 32, Color.GREEN, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"Click to add curve points | SHIFT+Click for junction | Click a town to finish | RIGHT-CLICK/ESC to cancel | Z to undo point")
	else:
		var hint := "LEFT-CLICK to place towns | Click a town or junction to draw tracks | RIGHT-CLICK track to delete | O to edit orders"
		if train_orders.size() >= 2 and network.segments.size() > 0:
			hint += " | SPACE to start simulation"
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)

## Draw order editing overlay — hint text and route preview.
func _draw_order_overlay() -> void:
	var hint := "ORDERS: Click towns to add/remove stops | RIGHT-CLICK to remove last | ESC/O to finish"
	if train_orders.size() >= 2:
		hint += " | SPACE to start simulation"
	draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)
	# Draw dashed lines between consecutive order stops
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
