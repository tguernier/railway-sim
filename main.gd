## Main game node. Manages game state, towns, tracks, trains, and rendering.
extends Node2D

## The two phases of the game: building the network, then watching it run.
enum GameState { EDITING, SIMULATING }

## Current game phase.
var state := GameState.EDITING
## All towns placed on the map.
var towns: Array[Town] = []
## The track network of junctions and segments.
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
## Whether the player is placing a station.
var placing_station := false
## The train's ordered stop list, built before simulation starts.
var train_orders: Array[Town] = []
## Number of cars for the train, chosen in edit mode ([ / ] keys).
var car_count := 2
## Transient status/error message shown below the hint text.
var status_message := ""
## Seconds remaining before the status message disappears.
var status_timer := 0.0
## Snapshots of the editable world, most recent last; U pops and restores.
var undo_stack: Array[GameSnapshot] = []

## Maximum number of undo snapshots retained.
const UNDO_LIMIT := 50

## Rotating palette of colours assigned to new towns.
var town_palette := [
	Color.CORNFLOWER_BLUE, Color.INDIAN_RED, Color.SEA_GREEN,
	Color.ORANGE, Color.MEDIUM_PURPLE, Color.CADET_BLUE,
	Color.SALMON, Color.DARK_CYAN, Color.GOLDENROD,
]
## Index into town_palette for the next town placed.
var next_color_index := 0

## Visual radius of a track waypoint dot.
const WAYPOINT_RADIUS := 5.0
## Visual size of a junction diamond (half-width).
const JUNCTION_RADIUS := 8.0
## How long status messages stay on screen, in seconds.
const STATUS_DURATION := 3.0
## Price of each train car beyond the first, charged at simulation start.
const COST_PER_CAR := 150.0

## Runs when the node is ready
func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)

## Reset the game to its initial editing state, discarding everything built.
func _reset_game() -> void:
	state = GameState.EDITING
	towns = []
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)
	train = null
	money = 1000.0
	frame_count = 0
	hovered_town = null
	hovered_junction = null
	editing_orders = false
	placing_station = false
	train_orders = []
	car_count = 2
	next_color_index = 0
	status_message = ""
	status_timer = 0.0
	undo_stack = []
	queue_redraw()

## Capture a snapshot of the editable state onto the undo stack. Called just
## before each build action; if the action then fails, the caller discards
## the entry with _discard_undo() so a rejected click doesn't burn an undo.
func _push_undo() -> void:
	undo_stack.append(GameSnapshot.capture(self))
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()

## Drop the snapshot pushed for an action that turned out to fail.
func _discard_undo() -> void:
	undo_stack.pop_back()

## Snapshot before finishing the track being drawn. A fresh free-draw start
## junction is not part of the committed world yet (cancelling would
## orphan-clean it), so it is captured without it — undoing a finished track
## then removes the fresh junction too instead of leaving a crumb.
func _push_undo_for_finish() -> void:
	var start := editor.start_node
	var fresh: bool = network.get_outgoing(start).size() == 0 \
		and network.get_incoming(start).size() == 0
	if fresh:
		network.nodes.erase(start)
	_push_undo()
	if fresh:
		network.add_node(start)

## Revert the last build action by restoring the most recent snapshot.
func _undo() -> void:
	if undo_stack.is_empty():
		_show_status("Nothing to undo")
		return
	var snap: GameSnapshot = undo_stack.pop_back()
	snap.restore(self)

## Runs when there is an input event
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = get_local_mouse_position()
		hovered_town = _find_town_at(mouse_pos)
		hovered_junction = editor.find_junction_at(mouse_pos)
		queue_redraw()
		return

	# R resets the whole game to the initial editing state from any phase.
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_reset_game()
		return

	if state == GameState.EDITING:
		_handle_edit_input(event)

## Handles inputs for editing mode.
func _handle_edit_input(event: InputEvent) -> void:
	# U undoes the last build action. Checked before the sub-mode dispatch so
	# it also works while editing orders or placing a station; while drawing a
	# track it is ignored (Z pops waypoints, ESC/right-click cancels).
	if event is InputEventKey and event.pressed and event.keycode == KEY_U:
		if not editor.drawing:
			_undo()
		return

	if editing_orders:
		_handle_order_input(event)
		return
	if placing_station:
		_handle_station_input(event)
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var click_pos := get_local_mouse_position()
			if editor.drawing:
				_handle_draw_click(click_pos, event.shift_pressed)
			else:
				_handle_idle_click(click_pos, event.shift_pressed)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_right_click()

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
			KEY_P:
				if not editor.drawing:
					placing_station = true
			KEY_BRACKETLEFT:
				car_count = maxi(car_count - 1, 1)
			KEY_BRACKETRIGHT:
				car_count = mini(car_count + 1, _max_car_count())

## Handles a left-click while a track is being drawn. Each finish attempt is
## an undo step: snapshot first, discard the entry if the finish is rejected.
func _handle_draw_click(click_pos: Vector2, shift: bool) -> void:
	var junction := editor.find_junction_at(click_pos)
	if junction != null and junction != editor.start_node and not shift:
		_push_undo_for_finish()
		if not editor.finish_at(junction):
			_discard_undo()
			_show_status(_rejection_message())
	elif shift:
		# Shift+click: finish at a junction (existing, on a track, or newly
		# placed) and continue drawing from it.
		if junction != null and junction != editor.start_node:
			_push_undo_for_finish()
			if not editor.finish_and_continue(junction):
				_discard_undo()
				_show_status(_rejection_message())
			return
		var track_hit := editor.find_track_at(click_pos)
		if track_hit.size() > 0:
			var hit_seg: TrackSegment = track_hit[0]
			if hit_seg.node_start != editor.start_node and hit_seg.node_end != editor.start_node:
				_push_undo_for_finish()
				if not editor.finish_on_track(track_hit, true):
					_discard_undo()
					_show_status(editor.last_error if editor.last_error != "" else _rejection_message())
				return
		_push_undo_for_finish()
		var new_junction := NetworkNode.junction(click_pos)
		network.add_node(new_junction)
		if not editor.finish_and_continue(new_junction):
			network.cleanup_orphan(new_junction)
			_discard_undo()
			_show_status(_rejection_message())
	elif junction == null:
		var track_hit := editor.find_track_at(click_pos)
		if track_hit.size() > 0:
			var hit_seg: TrackSegment = track_hit[0]
			if hit_seg.node_start == editor.start_node or hit_seg.node_end == editor.start_node:
				editor.add_waypoint(click_pos)
			else:
				_push_undo_for_finish()
				if not editor.finish_on_track(track_hit):
					_discard_undo()
					_show_status(editor.last_error if editor.last_error != "" else _rejection_message())
		else:
			editor.add_waypoint(click_pos)

## Status text explaining the last rejected finish attempt.
func _rejection_message() -> String:
	if editor.rejection_reason == "turnout":
		return "Turnout angle too steep (max %d°) — approach in line with the existing track" \
			% int(rad_to_deg(TrackEditor.MAX_TURNOUT_ANGLE))
	return "Curve too tight — add waypoints for a gentler bend"

## Handles a left-click while nothing is being drawn.
func _handle_idle_click(click_pos: Vector2, shift: bool) -> void:
	if shift:
		_place_town(click_pos)
		return
	var junction := editor.find_junction_at(click_pos)
	if junction != null:
		editor.start_drawing(junction)
		return
	var track_hit := editor.find_track_at(click_pos)
	if track_hit.size() > 0:
		# The split persists even if the drawing is later cancelled, so it is
		# its own undo step.
		_push_undo()
		var new_junction := editor.split_track_at_hit(track_hit)
		if new_junction == null:
			_discard_undo()
			_show_status(editor.last_error)
		else:
			editor.start_drawing(new_junction)
	else:
		# Free-draw start: place a fresh junction on empty ground.
		var new_junction := NetworkNode.junction(click_pos)
		network.add_node(new_junction)
		editor.start_drawing(new_junction)

## Handles a right-click: cancel drawing, delete track, or remove a town.
func _handle_right_click() -> void:
	if editor.drawing:
		editor.cancel()
		return
	_right_click_at(get_local_mouse_position())

## Delete the track or remove the town at a position, as one undo step each.
func _right_click_at(click_pos: Vector2) -> void:
	var track_hit := editor.find_track_at(click_pos)
	if track_hit.size() > 0:
		var seg: TrackSegment = track_hit[0]
		if seg.is_platform_segment():
			_show_status("Remove the town to delete its station")
		else:
			_push_undo()
			if not editor.try_delete_track_at(click_pos):
				_discard_undo()
		return
	var town := _find_town_at(click_pos)
	if town != null:
		_push_undo()
		editor.remove_town(town, towns, train_orders)

## Handles inputs while placing a station.
func _handle_station_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_place_station(get_local_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			placing_station = false

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_P:
				placing_station = false

## Build a station at a position, as one undo step if it succeeds.
func _try_place_station(pos: Vector2) -> void:
	_push_undo()
	var station := editor.place_station(pos, towns)
	if station != null:
		placing_station = false
	else:
		_discard_undo()
		_show_status(editor.last_error)

## Handles inputs while editing train orders.
func _handle_order_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_toggle_order_stop(get_local_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_pop_order_stop()

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_O:
				editing_orders = false
			KEY_SPACE:
				editing_orders = false
				_start_simulation()

## Add or remove the clicked town as a train order stop. Each actual edit of
## the order list is one undo step; the station-missing rejection is not.
func _toggle_order_stop(pos: Vector2) -> void:
	var town := _find_town_at(pos)
	if town == null:
		return
	var idx := train_orders.find(town)
	if idx >= 0:
		_push_undo()
		train_orders.remove_at(idx)
	elif town.station == null:
		_show_status("Town needs a station before it can be a stop")
	else:
		_push_undo()
		train_orders.append(town)

## Remove the last train order stop, as one undo step.
func _pop_order_stop() -> void:
	if train_orders.size() > 0:
		_push_undo()
		train_orders.pop_back()

## Show a transient status message below the hint text.
func _show_status(msg: String) -> void:
	if msg == "":
		return
	status_message = msg
	status_timer = STATUS_DURATION

## Returns the town whose circle contains a screen position, if there is one.
func _find_town_at(pos: Vector2) -> Town:
	for town in towns:
		if pos.distance_to(town.position) < town.radius:
			return town
	return null

## Place a town at a screen position. Towns are not part of the track graph.
func _place_town(pos: Vector2) -> void:
	_push_undo()
	var col: Color = town_palette[next_color_index % town_palette.size()]
	next_color_index += 1
	towns.append(Town.new(pos, col))

## Start the simulation.
func _start_simulation() -> void:
	if train_orders.size() < 2 or network.segments.size() == 0:
		return
	var stop_platforms: Array = []
	for town in train_orders:
		if town.station == null or town.station.platforms.size() == 0:
			_show_status("All stops need a station before starting")
			return
		stop_platforms.append(town.station.platforms[0])
	var unroutable := network.first_unroutable_stop(stop_platforms)
	if unroutable != -1:
		_show_status("No track route to stop %d — connect it to the other stops" % (unroutable + 1))
		return
	var car_cost := (car_count - 1) * COST_PER_CAR
	if money < car_cost:
		_show_status("Not enough money for %d cars (extra cars cost %d each)" % [car_count, int(COST_PER_CAR)])
		return
	money -= car_cost
	state = GameState.SIMULATING
	editing_orders = false
	placing_station = false
	train = Train.new()
	train.car_count = car_count
	train.orders = train_orders.duplicate()
	train.current_order_index = 0
	# The train starts parked at the first stop's platform, as if it had just
	# finished a stop there — same anchoring as a departure.
	var start_platform: Platform = train_orders[0].station.platforms[0]
	_dispatch_to_next_order(start_platform.segment.node_end)
	if train != null and train.has_route():
		train.resume_from_stop(start_platform.segment,
			_stop_point(start_platform.segment), start_platform.reverse_segment)

## Dispatch the train toward its next order stop's platform via Dijkstra.
## Orders are validated before the simulation starts, but a leg can still
## come up empty if the network or stations change mid-simulation — in that
## case the simulation is halted rather than leaving the train stranded.
func _dispatch_to_next_order(from_node: NetworkNode) -> void:
	train.advance_order()
	var target := train.current_order_town()
	if target == null or target.station == null or target.station.platforms.size() == 0:
		_stop_simulation("A stop lost its station — simulation stopped")
		return
	var route := network.find_route_to_platform(from_node, target.station.platforms[0])
	if route.size() > 0:
		train.set_route(route)
		# The route ends with the platform traversal — halt the head so the
		# consist is centered on the platform.
		train.stop_progress = _stop_point(route[-1])
	else:
		_stop_simulation("No track route to the next stop — simulation stopped")

## Head halt point (progress) on a platform segment that centers the consist
## on the platform. Consists always fit: car count is capped to the platform
## length, so the whole train sits on the platform segment while dwelling.
func _stop_point(platform_seg: TrackSegment) -> float:
	var total := platform_seg.length()
	if total <= 0.0:
		return 1.0
	return clampf(0.5 + train.consist_length() / (2.0 * total), 0.0, 1.0)

## Largest consist size that fits within a station platform.
func _max_car_count() -> int:
	return int((TrackEditor.PLATFORM_LENGTH + Train.CAR_GAP) / (Train.CAR_LENGTH + Train.CAR_GAP))

## Halt the simulation and return to editing mode.
func _stop_simulation(msg: String) -> void:
	state = GameState.EDITING
	train = null
	_show_status(msg)

## Handle 1 simulation tick.
func _process(delta: float) -> void:
	if status_timer > 0.0:
		status_timer -= delta

	if state == GameState.SIMULATING:
		if frame_count > 9:
			for town in towns:
				town.generate_passengers()
			frame_count = 0

		train.move(delta)
		if train.dwell_remaining <= 0.0:
			if train.at_pending_stop():
				if train.boarded_this_leg:
					_depart_from_stop()
				else:
					_arrive_at_platform()
			elif train.has_completed_route() and train.boarded_this_leg:
				_dispatch_to_next_order(train.route[-1].node_end)

		frame_count += 1

	queue_redraw()

## The dwell is over: dispatch the next leg while the train sits at its stop
## point. When the leg leaves back the way the train came in (a dead-end
## station), the train turns around at the platform instead of rolling to the
## end of the track and bouncing back; otherwise it keeps its place and rolls
## forward through the rest of the platform onto the new route.
func _depart_from_stop() -> void:
	var seg := train.current_segment()
	train.stop_progress = -1.0  # dwell over — pull away
	if seg == null or not seg.is_platform_segment():
		return  # fall back to dispatching when the route completes
	var progress := train.segment_progress
	var p: Platform = seg.platform
	var reverse_seg := p.reverse_segment if seg == p.segment else p.segment
	_dispatch_to_next_order(seg.node_end)
	if train != null and train.has_route():
		train.resume_from_stop(seg, progress, reverse_seg)

## The train has halted at its stop point (the middle of the target platform):
## unload, board, and wait out the dwell time.
func _arrive_at_platform() -> void:
	train.boarded_this_leg = true
	var seg := train.current_segment()
	if seg != null and seg.is_platform_segment() and seg.platform.station != null:
		var town := seg.platform.station.town
		if town != null:
			money += train.unload() * 10
			train.board_from(town)
	train.dwell_remaining = train.dwell_time

## Draw game scene.
func _draw() -> void:
	_draw_towns()
	_draw_tracks()
	_draw_platforms()
	_draw_junctions()

	if state == GameState.EDITING:
		_draw_editor_overlay()
	elif state == GameState.SIMULATING:
		_draw_train()
		_draw_hud()

	if status_timer > 0.0:
		draw_string(ThemeDB.fallback_font, Vector2(10, 40), status_message,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.RED)

## Draw tracks.
func _draw_tracks() -> void:
	var drawn: Dictionary = {}
	for seg in network.segments:
		var key_a := "%s-%s" % [seg.node_start.position, seg.node_end.position]
		var key_b := "%s-%s" % [seg.node_end.position, seg.node_start.position]
		if not drawn.has(key_a) and not drawn.has(key_b):
			draw_polyline(seg.get_baked_points(), Color.GRAY, 3.0)
			drawn[key_a] = true

## Draw station platforms alongside their track segments.
func _draw_platforms() -> void:
	for town in towns:
		if town.station == null:
			continue
		for platform in town.station.platforms:
			_draw_platform(platform, town.color)

## Draw one platform as a filled strip offset to one side of its segment.
func _draw_platform(platform: Platform, color: Color) -> void:
	var points := platform.segment.get_baked_points()
	if points.size() < 2:
		return
	var near := PackedVector2Array()
	var far := PackedVector2Array()
	for i in range(points.size()):
		var prev := points[maxi(i - 1, 0)]
		var next := points[mini(i + 1, points.size() - 1)]
		var perp := (next - prev).normalized().orthogonal() * platform.side
		near.append(points[i] + perp * 5.0)
		far.append(points[i] + perp * platform.width)
	var fill := color
	fill.a = 0.45
	for i in range(points.size() - 1):
		draw_colored_polygon(PackedVector2Array([
			near[i], near[i + 1], far[i + 1], far[i],
		]), fill)
	draw_polyline(near, color, 1.5)
	draw_polyline(far, color, 1.5)
	draw_line(near[0], far[0], color, 1.5)
	draw_line(near[near.size() - 1], far[far.size() - 1], color, 1.5)

## Draw junction nodes as diamonds.
func _draw_junctions() -> void:
	for node in network.nodes:
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
		if state == GameState.EDITING and not editing_orders and not placing_station:
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

## Draw towns as catchment circles. Stations link a town to the railway; a
## town without one gets a dashed outline.
func _draw_towns() -> void:
	for town in towns:
		var fill := town.color
		fill.a = 0.25
		draw_circle(town.position, town.radius, fill)
		if town.station != null:
			draw_arc(town.position, town.radius, 0, TAU, 48, town.color, 2.0)
			var platform_mid: Vector2 = town.station.platforms[0].segment.position_at(0.5)
			_draw_dashed_line(PackedVector2Array([town.position, platform_mid]),
				Color(town.color, 0.6), 1.5, 6.0)
		else:
			_draw_dashed_circle(town.position, town.radius, Color(town.color, 0.6), 2.0)
		draw_circle(town.position, 6.0, town.color)

		if state == GameState.EDITING and (editing_orders or placing_station):
			if town == hovered_town:
				draw_arc(town.position, town.radius + 4, 0, TAU, 48, Color.YELLOW, 2.0)
		if state == GameState.SIMULATING:
			var label_color := Color.WHITE if town.station != null else Color.RED
			draw_string(ThemeDB.fallback_font, town.position + Vector2(-30, -town.radius - 8),
				"Waiting: %d" % int(town.waiting), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, label_color)

	if state == GameState.EDITING:
		for i in range(train_orders.size()):
			var town: Town = train_orders[i]
			var label_pos := town.position + Vector2(town.radius, -town.radius) * 0.75
			draw_circle(label_pos, 12, Color.WHITE)
			draw_string(ThemeDB.fallback_font, label_pos + Vector2(-4, 5),
				str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)

## Draw editor overlay.
func _draw_editor_overlay() -> void:
	if editing_orders:
		_draw_order_overlay()
	elif placing_station:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"STATION: Click a track inside a town's circle | ESC/P to cancel")
	elif editor.drawing:
		_draw_curvature_preview()
		for wp in editor.waypoints:
			draw_circle(wp, WAYPOINT_RADIUS, Color.WHITE)
		_draw_turnout_angle_preview()
		_draw_finish_angle_preview()
		var hint_text := "Click to add curve points | Click junction/track to finish | SHIFT+Click to finish at a new junction | ESC to cancel | Z to undo"
		if editor.last_finish_rejected:
			if editor.rejection_reason == "turnout":
				hint_text = "TURNOUT ANGLE TOO STEEP — approach at a shallower angle | " + hint_text
			else:
				hint_text = "CURVE TOO TIGHT — add waypoints for a gentler bend | " + hint_text
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint_text)
	else:
		var hint := "SHIFT+CLICK to place towns | CLICK to draw tracks | P to place station | RIGHT-CLICK to delete | U to undo | O to edit orders | [ ] cars: %d | R to reset" % car_count
		if train_orders.size() >= 2 and network.segments.size() > 0:
			hint += " | SPACE to start"
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
	if preview.length() <= 0.0:
		return
	var min_diff := TrackEditor.min_divergence(existing, preview.angle_at(0.0))
	var color := Color.GREEN if min_diff <= TrackEditor.MAX_TURNOUT_ANGLE else Color.RED
	var label := "%d°" % int(rad_to_deg(min_diff))
	draw_string(ThemeDB.fallback_font,
		editor.start_node.position + Vector2(15, -15), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)

## Draw the angle indicator at the prospective finish target under the mouse —
## the junction or track point the click would connect to.
func _draw_finish_angle_preview() -> void:
	var target_pos: Vector2
	var existing: Array[float] = []
	if hovered_junction != null and hovered_junction != editor.start_node:
		existing = network.departure_angles_at(hovered_junction)
		target_pos = hovered_junction.position
	else:
		var hit := editor.find_track_at(mouse_pos)
		if hit.size() == 0:
			return
		var seg: TrackSegment = hit[0]
		if seg.node_start == editor.start_node or seg.node_end == editor.start_node:
			return
		existing.append(seg.angle_at(hit[1]))
		target_pos = seg.position_at(hit[1])
	if existing.size() == 0:
		return
	var preview := editor.build_preview_segment(target_pos)
	if preview.length() <= 0.0:
		return
	var arrival := preview.angle_at(1.0) + PI
	var min_diff := TrackEditor.min_divergence(existing, arrival)
	var color := Color.GREEN if min_diff <= TrackEditor.MAX_TURNOUT_ANGLE else Color.RED
	draw_string(ThemeDB.fallback_font, target_pos + Vector2(15, 25),
		"%d°" % int(rad_to_deg(min_diff)), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)

## Draw order editing overlay — hint text and route preview.
func _draw_order_overlay() -> void:
	var hint := "ORDERS: Click towns with stations to add/remove stops | RIGHT-CLICK to remove last | U to undo | ESC/O to finish"
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

## Draw a dashed circle outline.
func _draw_dashed_circle(center: Vector2, radius: float, color: Color, width: float) -> void:
	var dashes := 24
	for i in range(dashes):
		var a0 := TAU * float(i) / float(dashes)
		draw_arc(center, radius, a0, a0 + TAU / float(dashes) * 0.6, 4, color, width)

## Draw the train as a chain of cars, each sampled at its own point along the
## track so the consist bends with the curves.
func _draw_train() -> void:
	var half := Train.CAR_LENGTH / 2.0
	for i in range(train.car_count):
		var back := i * (Train.CAR_LENGTH + Train.CAR_GAP) + half
		var xf := train.point_behind(back)
		draw_set_transform(xf.origin, xf.get_rotation())
		draw_rect(Rect2(-half + 1, -7, Train.CAR_LENGTH - 2, 14),
			Color.DARK_SLATE_GRAY if i == 0 else Color.DIM_GRAY)
		if i == 0:
			draw_circle(Vector2(half - 3, 0), 2.0, Color.YELLOW)
		if i == train.car_count - 1:
			draw_circle(Vector2(-half + 3, 0), 2.0, Color.RED)
	draw_set_transform(Vector2.ZERO, 0)
	var head_pos := train.current_position()
	draw_string(ThemeDB.fallback_font, head_pos + Vector2(-20, -15),
		"%d" % train.passengers_on_board)
	if train.dwell_remaining > 0.0:
		draw_string(ThemeDB.fallback_font, head_pos + Vector2(-30, 28),
			"Boarding...", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)

## Draw HUD.
func _draw_hud() -> void:
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Money: %d | Cars: %d | On board: %d/%d | R to reset" % [money, train.car_count,
			train.passengers_on_board, train.capacity])
