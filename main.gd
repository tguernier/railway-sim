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
## The running trains, one per roster plan (created when simulation starts).
var trains: Array[Train] = []
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
## Whether the player is placing/cycling path signals.
var placing_signal := false
## Whether reserved track is tinted per-train during simulation (V toggles).
var show_reservations := false
## Trains flagged as deadlocked by the last check (empty when traffic flows).
var deadlocked_trains: Array = []
## Seconds since the last deadlock check.
var _deadlock_timer := 0.0
## How long every train has been simultaneously blocked, in seconds.
var _all_blocked_time := 0.0
## Per-train plans (orders + car count) built in edit mode, one per train.
var roster: Array[TrainPlan] = []
## Index into roster of the train whose orders/cars are being edited.
var selected_train := 0
## Orders of the selected roster train (the list order editing works on).
var train_orders: Array[Town]:
	get: return roster[selected_train].orders
## Number of cars for the selected roster train ([ / ] keys).
var car_count: int:
	get: return roster[selected_train].car_count
	set(v): roster[selected_train].car_count = v
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
## Seconds between deadlock checks (walking the wait-for graph is not free).
const DEADLOCK_CHECK_INTERVAL := 1.0
## Every train blocked for this long is treated as a deadlock even when the
## wait-for graph shows no cycle (net for cases the graph misses).
const ALL_BLOCKED_TIMEOUT := 10.0
## Price of each train car beyond the first, charged at simulation start.
const COST_PER_CAR := 150.0
## Price of each train beyond the first, charged at simulation start.
const TRAIN_COST := 500.0
## Colours identifying each train (head car, order badges, route preview).
const TRAIN_COLORS := [
	Color.DARK_SLATE_GRAY, Color.MIDNIGHT_BLUE, Color.DARK_RED,
	Color.DARK_GREEN, Color.REBECCA_PURPLE, Color.SADDLE_BROWN,
]

## Runs when the node is ready
func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)
	roster = [TrainPlan.new()]

## Reset the game to its initial editing state, discarding everything built.
func _reset_game() -> void:
	state = GameState.EDITING
	towns = []
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)
	trains = []
	money = 1000.0
	frame_count = 0
	hovered_town = null
	hovered_junction = null
	editing_orders = false
	placing_station = false
	placing_signal = false
	deadlocked_trains = []
	_deadlock_timer = 0.0
	_all_blocked_time = 0.0
	roster = [TrainPlan.new()]
	selected_train = 0
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

	# V toggles the reservation overlay (drawn while simulating).
	if event is InputEventKey and event.pressed and event.keycode == KEY_V:
		show_reservations = not show_reservations
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
	if placing_signal:
		_handle_signal_input(event)
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
			KEY_S:
				if not editor.drawing:
					placing_signal = true
			KEY_T:
				if not editor.drawing:
					_buy_train()
			KEY_X:
				if not editor.drawing:
					_sell_train()
			KEY_COMMA:
				_select_train(-1)
			KEY_PERIOD:
				_select_train(1)
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
		if track_hit.size() > 0 and not editor.hit_too_close_to_start(track_hit):
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
			if editor.hit_too_close_to_start(track_hit):
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
		var order_lists: Array = []
		for plan in roster:
			order_lists.append(plan.orders)
		editor.remove_town(town, towns, order_lists)

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

## Handles inputs while placing/cycling path signals.
func _handle_signal_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_place_signal(get_local_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			placing_signal = false

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_S:
				placing_signal = false

## Place or cycle a signal at a position, as one undo step if it succeeds.
## The mode stays active so several signals can be placed in a row.
func _try_place_signal(pos: Vector2) -> void:
	_push_undo()
	if not editor.place_or_cycle_signal(pos):
		_discard_undo()
		_show_status(editor.last_error)

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
			KEY_COMMA:
				_select_train(-1)
			KEY_PERIOD:
				_select_train(1)
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

## Buy a new train (appended to the roster and selected), as one undo step.
## The purchase price is charged at simulation start.
func _buy_train() -> void:
	_push_undo()
	roster.append(TrainPlan.new())
	selected_train = roster.size() - 1

## Sell the selected train, as one undo step. The roster never goes empty.
func _sell_train() -> void:
	if roster.size() <= 1:
		_show_status("The last train cannot be sold")
		return
	_push_undo()
	roster.remove_at(selected_train)
	selected_train = mini(selected_train, roster.size() - 1)

## Select the previous/next roster train for editing (wraps around).
func _select_train(step: int) -> void:
	selected_train = (selected_train + step + roster.size()) % roster.size()

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

## Start the simulation: validate every roster plan, charge the fleet cost,
## and spawn each train parked at its first stop's platform.
func _start_simulation() -> void:
	if network.segments.size() == 0:
		return
	var first_stops := {}
	var total_cost := (roster.size() - 1) * TRAIN_COST
	for i in range(roster.size()):
		var plan: TrainPlan = roster[i]
		if plan.orders.size() < 2:
			_show_status("Train %d needs at least 2 stops" % (i + 1))
			return
		var stop_platforms: Array = []
		for town in plan.orders:
			if town.station == null or town.station.platforms.size() == 0:
				_show_status("All stops need a station before starting")
				return
			stop_platforms.append(town.station.platforms[0])
		var unroutable := network.first_unroutable_stop(stop_platforms)
		if unroutable != -1:
			_show_status("Train %d: no track route to stop %d — connect it to the other stops"
				% [i + 1, unroutable + 1])
			return
		# Each train parks at its first stop's platform, so first stops must
		# be distinct.
		var first: Town = plan.orders[0]
		if first_stops.has(first):
			_show_status("Trains %d and %d start at the same station — pick different first stops"
				% [first_stops[first] + 1, i + 1])
			return
		first_stops[first] = i
		total_cost += (plan.car_count - 1) * COST_PER_CAR
	if money < total_cost:
		_show_status("Not enough money for the fleet (costs %d: %d per extra train, %d per extra car)"
			% [int(total_cost), int(TRAIN_COST), int(COST_PER_CAR)])
		return
	money -= total_cost
	state = GameState.SIMULATING
	editing_orders = false
	placing_station = false
	placing_signal = false
	deadlocked_trains = []
	_deadlock_timer = 0.0
	_all_blocked_time = 0.0
	trains = []
	for plan in roster:
		var tr := Train.new()
		tr.car_count = plan.car_count
		tr.orders = plan.orders.duplicate()
		tr.current_order_index = 0
		trains.append(tr)
		# The train starts parked at its first stop's platform, as if it had
		# just finished a stop there — same anchoring as a departure.
		var start_platform: Platform = plan.orders[0].station.platforms[0]
		_dispatch_to_next_order(tr, start_platform.segment.node_end)
		if state != GameState.SIMULATING:
			return
		if tr.has_route():
			tr.resume_from_stop(start_platform.segment,
				tr.stop_point_on(start_platform.segment), start_platform.reverse_segment)
			tr.try_reserve([tr.current_segment()])
	# Only after every train's footprint is seeded may anyone reserve ahead —
	# extending earlier could claim a path through a not-yet-spawned train.
	# A failure just means the train starts out waiting (retried every move).
	for tr in trains:
		tr.try_extend_reservation()

## Dispatch a train toward its next order stop's platform via Dijkstra.
## Orders are validated before the simulation starts, but a leg can still
## come up empty if the network or stations change mid-simulation — in that
## case the simulation is halted rather than leaving the train stranded.
func _dispatch_to_next_order(tr: Train, from_node: NetworkNode) -> void:
	tr.advance_order()
	var target := tr.current_order_town()
	if target == null or target.station == null or target.station.platforms.size() == 0:
		_stop_simulation("A stop lost its station — simulation stopped")
		return
	tr.network = network
	tr.target_platform = target.station.platforms[0]
	var route := network.find_route_to_platform(from_node, tr.target_platform, tr)
	if route.size() > 0:
		tr.set_route(route)
		# The route ends with the platform traversal — halt the head so the
		# consist is centered on the platform.
		tr.stop_progress = tr.stop_point_on(route[-1])
	else:
		_stop_simulation("No track route to the next stop — simulation stopped")

## Largest consist size that fits within a station platform.
func _max_car_count() -> int:
	return int((TrackEditor.PLATFORM_LENGTH + Train.CAR_GAP) / (Train.CAR_LENGTH + Train.CAR_GAP))

## Halt the simulation and return to editing mode.
func _stop_simulation(msg: String) -> void:
	state = GameState.EDITING
	for tr in trains:
		tr.release_all()
	trains = []
	deadlocked_trains = []
	_all_blocked_time = 0.0
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

		for tr in trains:
			_update_train(tr, delta)
			if state != GameState.SIMULATING:
				break  # a dispatch failure stopped the simulation

		if state == GameState.SIMULATING:
			_update_deadlock_detection(delta)
		frame_count += 1

	queue_redraw()

## Advance one train by one tick, then handle its stop lifecycle. Routing
## around other trains' paths happens inside the move: every reservation
## extension re-paths the provisional tail (Train._repath_provisional_tail),
## so a train facing a blocked branch diverts at speed and a blocked one
## retries on a throttle. That runs before the deadlock check each tick, so
## trains get a chance to self-resolve; a genuine deadlock (no free
## alternative) still flags because a fruitless re-path leaves the wait-for
## edge (blocked_by) in place.
func _update_train(tr: Train, delta: float) -> void:
	tr.move(delta)
	if tr.dwell_remaining > 0.0:
		return
	if tr.at_pending_stop():
		if tr.boarded_this_leg:
			_depart_from_stop(tr)
		else:
			_arrive_at_platform(tr)
	elif tr.has_completed_route() and tr.boarded_this_leg:
		_dispatch_to_next_order(tr, tr.route[-1].node_end)

## Deadlock detection. Path reservation prevents collisions, not deadlocks:
## with signals in the wrong places trains can wait on each other in a cycle.
## Once per DEADLOCK_CHECK_INTERVAL, walk the wait-for graph (each blocked
## train points at the train holding what it needs) — revisiting a train on
## the walk means a cycle. As a net for cases the graph misses (e.g. stale
## blocker edges), every train being blocked for ALL_BLOCKED_TIMEOUT counts
## too. Deadlocked trains are flagged and the player notified; the simulation
## keeps running (the player resolves it with R or better signals).
func _update_deadlock_detection(delta: float) -> void:
	var all_blocked := trains.size() > 0
	for tr in trains:
		if not tr.waiting_for_track:
			all_blocked = false
			break
	_all_blocked_time = _all_blocked_time + delta if all_blocked else 0.0
	_deadlock_timer += delta
	if _deadlock_timer < DEADLOCK_CHECK_INTERVAL:
		return
	_deadlock_timer = 0.0
	deadlocked_trains = _find_deadlock_cycle()
	if deadlocked_trains.is_empty() and _all_blocked_time > ALL_BLOCKED_TIMEOUT:
		deadlocked_trains = trains.duplicate()
	if not deadlocked_trains.is_empty():
		_show_status("Deadlock — trains are waiting on each other (R to reset)")

## The trains forming a wait-for cycle, or [] when none exists. A walk only
## follows blocked trains, so a queue behind a moving or dwelling leader
## terminates and is not flagged.
func _find_deadlock_cycle() -> Array:
	for tr in trains:
		if not tr.waiting_for_track:
			continue
		var walk: Array = []
		var cur: Train = tr
		while cur != null and cur.waiting_for_track:
			var pos := walk.find(cur)
			if pos >= 0:
				return walk.slice(pos)
			walk.append(cur)
			cur = cur.blocked_by
	return []

## The dwell is over: dispatch the next leg while the train sits at its stop
## point. When the leg leaves back the way the train came in (a dead-end
## station), the train turns around at the platform instead of rolling to the
## end of the track and bouncing back; otherwise it keeps its place and rolls
## forward through the rest of the platform onto the new route.
func _depart_from_stop(tr: Train) -> void:
	var seg := tr.current_segment()
	tr.stop_progress = -1.0  # dwell over — pull away
	if seg == null or not seg.is_platform_segment():
		return  # fall back to dispatching when the route completes
	var progress := tr.segment_progress
	var p: Platform = seg.platform
	var reverse_seg := p.reverse_segment if seg == p.segment else p.segment
	_dispatch_to_next_order(tr, seg.node_end)
	if state == GameState.SIMULATING and tr.has_route():
		tr.resume_from_stop(seg, progress, reverse_seg)
		# Re-take the segment the consist sits on (set_route released it).
		# Sequential train updates mean nobody can have grabbed it in between.
		if not tr.try_reserve([tr.current_segment()]):
			_stop_simulation("Track conflict at a station — simulation stopped")
			return
		# Reserve out to the first safe waiting point. On failure the train
		# keeps sitting at the platform — itself a safe waiting point — and
		# retries every move.
		tr.try_extend_reservation()

## A train has halted at its stop point (the middle of the target platform):
## unload, board, and wait out the dwell time.
func _arrive_at_platform(tr: Train) -> void:
	tr.boarded_this_leg = true
	var seg := tr.current_segment()
	if seg != null and seg.is_platform_segment() and seg.platform.station != null:
		var town := seg.platform.station.town
		if town != null:
			money += tr.unload() * 10
			tr.board_from(town)
	tr.dwell_remaining = tr.dwell_time

## Draw game scene.
func _draw() -> void:
	_draw_towns()
	_draw_tracks()
	if state == GameState.SIMULATING and show_reservations:
		_draw_reservations()
	_draw_platforms()
	_draw_junctions()
	_draw_signals()

	if state == GameState.EDITING:
		_draw_editor_overlay()
	elif state == GameState.SIMULATING:
		_draw_trains()
		_draw_hud()

	if status_timer > 0.0:
		draw_string(ThemeDB.fallback_font, Vector2(10, 60), status_message,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.RED)

## Draw tracks. Each physical track is drawn once: a segment is skipped when
## its reverse twin was already drawn. Keying on endpoints would wrongly hide
## parallel tracks between the same two junctions (e.g. a passing loop).
func _draw_tracks() -> void:
	var drawn: Dictionary = {}
	for seg in network.segments:
		if drawn.has(seg):
			continue
		drawn[seg] = true
		if seg.reverse != null:
			drawn[seg.reverse] = true
		draw_polyline(seg.get_baked_points(), Color.GRAY, 3.0)

## Tint every reserved segment in its holder's colour (V toggles) — makes
## signal layouts debuggable and shows each train's claimed path.
func _draw_reservations() -> void:
	for i in range(trains.size()):
		var color: Color = TRAIN_COLORS[i % TRAIN_COLORS.size()]
		for seg in trains[i].reserved:
			var points: PackedVector2Array = seg.get_baked_points()
			if points.size() >= 2:
				draw_polyline(points, Color(color, 0.35), 7.0)

## Draw path signals as a pole-and-lamp dot beside the exit of each signalled
## segment, on the right-hand side of the direction served (so one-way
## signals read correctly). Red by default, green while a reservation passes
## through the signal.
func _draw_signals() -> void:
	for seg in network.segments:
		if not seg.exit_signal:
			continue
		var total: float = seg.length()
		if total <= 0.0:
			continue
		var t := clampf(1.0 - 10.0 / total, 0.0, 1.0)
		var pos: Vector2 = seg.position_at(t)
		var side := Vector2.from_angle(seg.angle_at(t)).rotated(PI / 2.0)
		var lamp := pos + side * 9.0
		draw_line(pos + side * 4.0, lamp, Color.DIM_GRAY, 2.0)
		var lit := Color.LIME_GREEN if _signal_is_green(seg) else Color.RED
		draw_circle(lamp, 3.5, lit)

## A signal shows green while its holder's reservation continues past it —
## the train may traverse the signalled segment and at least one more.
func _signal_is_green(seg: TrackSegment) -> bool:
	var tr: Train = seg.reserved_by
	if tr == null:
		return false
	var idx: int = tr.route.find(seg)
	return idx >= 0 and idx < tr.limit_index

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
		# Order badges, one row per roster train in its colour; the selected
		# train's badges get a white ring.
		for ti in range(roster.size()):
			var badge_color: Color = TRAIN_COLORS[ti % TRAIN_COLORS.size()]
			var orders: Array[Town] = roster[ti].orders
			for i in range(orders.size()):
				var stop: Town = orders[i]
				var label_pos := stop.position + Vector2(stop.radius, -stop.radius) * 0.75 \
					+ Vector2(0, ti * 28.0)
				draw_circle(label_pos, 12, badge_color)
				if ti == selected_train:
					draw_arc(label_pos, 13.5, 0, TAU, 24, Color.WHITE, 2.0)
				draw_string(ThemeDB.fallback_font, label_pos + Vector2(-4, 5),
					str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)

## Draw editor overlay.
func _draw_editor_overlay() -> void:
	if editing_orders:
		_draw_order_overlay()
	elif placing_station:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"STATION: Click a track inside a town's circle | ESC/P to cancel")
	elif placing_signal:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"SIGNALS: Click a track to place | Click a signal to cycle two-way > one-way > remove | ESC/S to finish")
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
		var hint := "SHIFT+CLICK to place towns | CLICK to draw tracks | P to place station | S to place signals | RIGHT-CLICK to delete | U to undo | O to edit orders | R to reset"
		if _ready_to_start():
			hint += " | SPACE to start"
		draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)
		_draw_roster_line()

## Whether every roster train has enough stops to start the simulation.
func _ready_to_start() -> bool:
	if network.segments.size() == 0:
		return false
	for plan in roster:
		if plan.orders.size() < 2:
			return false
	return true

## One-line roster readout in the selected train's colour.
func _draw_roster_line() -> void:
	var color: Color = TRAIN_COLORS[selected_train % TRAIN_COLORS.size()]
	var line := "Train %d/%d — cars: %d, stops: %d | T to buy | , . to select | X to sell | [ ] cars" \
		% [selected_train + 1, roster.size(), car_count, train_orders.size()]
	draw_string(ThemeDB.fallback_font, Vector2(10, 40), line,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color)

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

## Draw order editing overlay — hint text and per-train route previews.
func _draw_order_overlay() -> void:
	var hint := "ORDERS (Train %d): Click towns with stations to add/remove stops | RIGHT-CLICK to remove last | , . to switch train | U to undo | ESC/O to finish" \
		% (selected_train + 1)
	if _ready_to_start():
		hint += " | SPACE to start simulation"
	draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)
	_draw_roster_line()
	for ti in range(roster.size()):
		var orders: Array[Town] = roster[ti].orders
		if orders.size() < 2:
			continue
		var color: Color = TRAIN_COLORS[ti % TRAIN_COLORS.size()]
		var alpha := 0.55 if ti == selected_train else 0.2
		for i in range(orders.size()):
			var from_pos: Vector2 = orders[i].position
			var to_pos: Vector2 = orders[(i + 1) % orders.size()].position
			_draw_dashed_line(PackedVector2Array([from_pos, to_pos]),
				Color(color, alpha), 2.0, 10.0)

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

## Draw all running trains, each in its roster colour. Deadlocked trains get
## a red ring so the player can see who is waiting on whom.
func _draw_trains() -> void:
	for i in range(trains.size()):
		var tr: Train = trains[i]
		_draw_train(tr, TRAIN_COLORS[i % TRAIN_COLORS.size()])
		if deadlocked_trains.has(tr):
			draw_arc(tr.current_position(), 24.0, 0, TAU, 32, Color.RED, 2.5)

## Draw one train as a chain of cars, each sampled at its own point along the
## track so the consist bends with the curves.
func _draw_train(tr: Train, color: Color) -> void:
	var half := Train.CAR_LENGTH / 2.0
	for i in range(tr.car_count):
		var back := i * (Train.CAR_LENGTH + Train.CAR_GAP) + half
		var xf := tr.point_behind(back)
		draw_set_transform(xf.origin, xf.get_rotation())
		draw_rect(Rect2(-half + 1, -7, Train.CAR_LENGTH - 2, 14),
			color if i == 0 else Color.DIM_GRAY)
		if i == 0:
			draw_circle(Vector2(half - 3, 0), 2.0, Color.YELLOW)
		if i == tr.car_count - 1:
			draw_circle(Vector2(-half + 3, 0), 2.0, Color.RED)
	draw_set_transform(Vector2.ZERO, 0)
	var head_pos := tr.current_position()
	draw_string(ThemeDB.fallback_font, head_pos + Vector2(-20, -15),
		"%d/%d" % [tr.passengers_on_board, tr.capacity])
	if tr.dwell_remaining > 0.0:
		draw_string(ThemeDB.fallback_font, head_pos + Vector2(-30, 28),
			"Boarding...", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	elif tr.waiting_for_track:
		draw_string(ThemeDB.fallback_font, head_pos + Vector2(-40, 28),
			"Waiting for path...", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.RED)

## Draw HUD: money plus each train's passenger load in its colour.
func _draw_hud() -> void:
	draw_string(ThemeDB.fallback_font, Vector2(10, 20),
		"Money: %d | R to reset | V to toggle reservations" % money)
	var x := 10.0
	for i in range(trains.size()):
		var tr: Train = trains[i]
		var label := "Train %d: %d/%d" % [i + 1, tr.passengers_on_board, tr.capacity]
		draw_string(ThemeDB.fallback_font, Vector2(x, 40), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TRAIN_COLORS[i % TRAIN_COLORS.size()])
		x += 130.0
