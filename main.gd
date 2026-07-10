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
## All trains the player owns. Bought in edit mode (T key), parked at their
## home platforms between simulation runs.
var trains: Array[Train] = []
## Index into trains of the currently selected train — the one whose orders
## the O-mode edits and whose consist the [ ] keys resize.
var selected_train := 0
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
## Whether the player is placing signals.
var placing_signal := false
## Whether the player is buying a train (T key, then click a stationed town).
var buying_train := false
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
## Price of a new train (one car included), charged at purchase.
const TRAIN_COST := 200.0
## Price of each train car beyond the first, charged/refunded immediately
## when a consist is resized with [ / ].
const COST_PER_CAR := 150.0

## Rotating palette of colours assigned to trains (car bodies and stop
## badges), by train index.
const TRAIN_COLORS := [
	Color.DARK_SLATE_GRAY, Color.DARK_RED, Color.DARK_GREEN,
	Color.DARK_ORCHID, Color.SADDLE_BROWN, Color.TEAL,
]

## Runs when the node is ready
func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.YELLOW_GREEN)
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)
	network.trains = trains

## Reset the game to its initial editing state, discarding everything built.
func _reset_game() -> void:
	state = GameState.EDITING
	towns = []
	network = TrackNetwork.new()
	editor = TrackEditor.new(network)
	trains = []
	network.trains = trains
	selected_train = 0
	money = 1000.0
	frame_count = 0
	hovered_town = null
	hovered_junction = null
	editing_orders = false
	placing_station = false
	placing_signal = false
	buying_train = false
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
	elif state == GameState.SIMULATING:
		# ESC stops the simulation and parks every train back at its home
		# platform (money kept) — the escape hatch for deadlocks.
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_stop_simulation("Simulation stopped — trains returned to their home stations")

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
	if buying_train:
		_handle_buy_input(event)
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
					if trains.is_empty():
						_show_status("Buy a train first (T)")
					else:
						editing_orders = true
			KEY_P:
				if not editor.drawing:
					placing_station = true
			KEY_S:
				if not editor.drawing:
					placing_signal = true
			KEY_T:
				if not editor.drawing:
					buying_train = true
			KEY_BRACKETLEFT:
				_shrink_selected_train()
			KEY_BRACKETRIGHT:
				_grow_selected_train()

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

## Remove the signal, delete the track, or remove the town at a position, as
## one undo step each. Signals are checked first — a signal node always sits
## on a track, so the track hit would otherwise shadow it.
func _right_click_at(click_pos: Vector2) -> void:
	if editor.find_signal_at(click_pos) != null:
		_push_undo()
		editor.remove_signal_at(click_pos)
		return
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
		_remove_town(town)

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

## Handles inputs while placing signals.
func _handle_signal_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_signal_click(get_local_mouse_position(), event.shift_pressed)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			placing_signal = false

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_S:
				placing_signal = false

## A click in signal mode: on bare track, place a new two-way signal; on an
## existing signal, cycle its kind — or flip its facing with shift held. Each
## action is one undo step; the mode stays active throughout.
func _signal_click(pos: Vector2, shift: bool) -> void:
	var existing := editor.find_signal_at(pos)
	if existing != null:
		_push_undo()
		if shift:
			editor.flip_signal(existing)
		else:
			editor.cycle_signal_kind(existing)
		return
	_try_place_signal(pos)

## Place a signal at a position, as one undo step if it succeeds. The mode
## stays active so several signals can be dropped in a row.
func _try_place_signal(pos: Vector2) -> void:
	_push_undo()
	if editor.place_signal(pos) == null:
		_discard_undo()
		_show_status(editor.last_error)

## Handles inputs while buying a train.
func _handle_buy_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_buy_train(get_local_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			buying_train = false

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_T:
				buying_train = false

## Buy a 1-car train homed at the clicked town's station platform, as one
## undo step. The new train becomes the selected one.
func _try_buy_train(pos: Vector2) -> void:
	var town := _find_town_at(pos)
	if town == null:
		return
	if town.station == null or town.station.platforms.size() == 0:
		_show_status("The town needs a station before a train can be based there")
		return
	var platform: Platform = town.station.platforms[0]
	for t in trains:
		if t.home_platform == platform:
			_show_status("A train is already based at this station")
			return
	if money < TRAIN_COST:
		_show_status("Not enough money for a train (costs %d)" % int(TRAIN_COST))
		return
	_push_undo()
	money -= TRAIN_COST
	var train := Train.new()
	train.car_count = 1
	train.home_platform = platform
	trains.append(train)
	selected_train = trains.size() - 1
	buying_train = false

## Add a car to the selected train, charged immediately. One undo step.
func _grow_selected_train() -> void:
	if trains.is_empty():
		return
	var train: Train = trains[selected_train]
	if train.car_count >= _max_car_count():
		_show_status("Consist already fills the platform")
		return
	if money < COST_PER_CAR:
		_show_status("Not enough money for a car (costs %d)" % int(COST_PER_CAR))
		return
	_push_undo()
	money -= COST_PER_CAR
	train.car_count += 1

## Remove a car from the selected train, refunded immediately. One undo step.
func _shrink_selected_train() -> void:
	if trains.is_empty():
		return
	var train: Train = trains[selected_train]
	if train.car_count <= 1:
		return
	_push_undo()
	money += COST_PER_CAR
	train.car_count -= 1

## Remove a town: refund any train homed at its station (purchase price plus
## extra cars), drop the town from every train's orders, then tear down its
## station and the town itself.
func _remove_town(town: Town) -> void:
	for i in range(trains.size() - 1, -1, -1):
		var t: Train = trains[i]
		if town.station != null and town.station.platforms.has(t.home_platform):
			money += TRAIN_COST + (t.car_count - 1) * COST_PER_CAR
			trains.remove_at(i)
	selected_train = clampi(selected_train, 0, maxi(trains.size() - 1, 0))
	for t in trains:
		t.orders.erase(town)
	editor.remove_town(town, towns)

## Handles inputs while editing train orders.
func _handle_order_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_toggle_order_stop(get_local_mouse_position())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_pop_order_stop()

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				editing_orders = false
			KEY_O:
				# O cycles the selection through the trains.
				selected_train = (selected_train + 1) % trains.size()
			KEY_SPACE:
				editing_orders = false
				_start_simulation()
			KEY_BRACKETLEFT:
				_shrink_selected_train()
			KEY_BRACKETRIGHT:
				_grow_selected_train()

## Add or remove the clicked town as a stop of the selected train's orders.
## Each actual edit of the order list is one undo step; the station-missing
## rejection is not.
func _toggle_order_stop(pos: Vector2) -> void:
	var town := _find_town_at(pos)
	if town == null or trains.is_empty():
		return
	var orders: Array[Town] = trains[selected_train].orders
	var idx := orders.find(town)
	if idx >= 0:
		_push_undo()
		orders.remove_at(idx)
	elif town.station == null:
		_show_status("Town needs a station before it can be a stop")
	else:
		_push_undo()
		orders.append(town)

## Remove the selected train's last order stop, as one undo step.
func _pop_order_stop() -> void:
	if not trains.is_empty() and trains[selected_train].orders.size() > 0:
		_push_undo()
		trains[selected_train].orders.pop_back()

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

## Start the simulation. Every train needs a routable order loop (anchored
## at its home platform); earned money can never be rewound, so the undo
## stack is cleared once the simulation actually starts.
func _start_simulation() -> void:
	if network.segments.size() == 0:
		return
	if trains.is_empty():
		_show_status("Buy a train first (T)")
		return
	for i in range(trains.size()):
		var t: Train = trains[i]
		if t.orders.size() < 2:
			_show_status("Train %d needs at least 2 stops (O to edit orders)" % (i + 1))
			return
		var stop_platforms: Array = []
		for town in t.orders:
			if town.station == null or town.station.platforms.size() == 0:
				_show_status("All stops need a station before starting")
				return
			stop_platforms.append(town.station.platforms[0])
		var unroutable := network.first_unroutable_stop(stop_platforms, t.home_platform)
		if unroutable != -1:
			_show_status("Train %d has no track route to stop %d — connect it to the other stops"
				% [i + 1, unroutable + 1])
			return
	undo_stack = []
	state = GameState.SIMULATING
	editing_orders = false
	placing_station = false
	placing_signal = false
	buying_train = false
	# Every train claims the platform it spawns on before anyone is dispatched,
	# so no first span can be reserved across an occupied platform.
	for t in trains:
		t.home_platform.segment.reserve(t)
	for t in trains:
		# The train starts parked at its home platform, as if it had just
		# finished a stop there — same anchoring as a departure. Its first
		# target is orders[0] (advance_order wraps around to it).
		t.current_order_index = t.orders.size() - 1
		_dispatch_to_next_order(t, t.home_platform.segment.node_end)
		if t.has_route():
			t.resume_from_stop(t.home_platform.segment,
				_stop_point(t.home_platform.segment, t), t.home_platform.reverse_segment)
			t.reserve_departure_span()

## Dispatch a train toward its next order stop's platform via Dijkstra, with
## segments held by other trains penalized so free parallel track (e.g. a
## passing-loop branch) is preferred. Orders are validated before the
## simulation starts, but a leg can still come up empty if the network or
## stations change mid-simulation — in that case only the affected train is
## halted and the rest keep running.
func _dispatch_to_next_order(t: Train, from_node: NetworkNode) -> void:
	t.advance_order()
	var target := t.current_order_town()
	if target == null or target.station == null or target.station.platforms.size() == 0:
		_halt_train(t, "Train %d lost its next station and was halted")
		return
	var route := network.find_route_to_platform(from_node, target.station.platforms[0], t)
	if route.size() > 0:
		t.set_route(route)
		# The route ends with the platform traversal — halt the head so the
		# consist is centered on the platform.
		t.stop_progress = _stop_point(route[-1], t)
	else:
		_halt_train(t, "Train %d has no track route to its next stop and was halted")

## Take one train out of service in place, keeping the others running. The
## message must contain a %d for the train's number.
func _halt_train(t: Train, msg: String) -> void:
	t.stalled = true
	_show_status(msg % (trains.find(t) + 1))

## Re-route a train's leg when trouble lies on its not-yet-reserved
## remainder: a block another train holds, or a block another train plans to
## cross the other way (meeting it would be a head-on neither can back out
## of). Candidate plans branch off at EVERY node of the held span, not just
## its end — the span may already have claimed past a junction (e.g. a
## bypass divergence) that the escape route needs, in which case the span is
## shrunk atomically (Train.adopt_route_tail) and the abandoned blocks are
## released. This runs BEFORE the train reserves its next span: route choice
## happens at span boundaries, and a train that reserves onward through a
## divergence along a stale route is committed — once inside a corridor it
## cannot reverse, and two trains doing so from opposite ends wedge
## nose-to-nose. Adopting a plan never moves the train; a waiting train
## picks the new tail up on its next reservation retry.
func _replan_blocked_route(t: Train) -> void:
	if not t.has_route():
		return
	var span_end := maxi(t.route_index, t.reserved_until)
	var opposed := network.opposed_blocks(t)
	var blocked := false
	for i in range(span_end + 1, t.route.size()):
		if t.route[i].is_occupied_by_other(t) or opposed.has(t.route[i]):
			blocked = true
			break
	if not blocked:
		return
	var target := t.current_order_town()
	if target == null or target.station == null or target.station.platforms.size() == 0:
		return
	var platform: Platform = target.station.platforms[0]
	# The current plan (priced from the head, like every candidate) is the
	# baseline to beat; requiring a strict improvement prevents plan churn.
	var best_cost := _plan_cost(t, span_end, t.route.slice(span_end + 1))
	var best_anchor := -1
	var best_tail: Array = []
	for anchor in range(t.route_index, span_end + 1):
		var last_kept: TrackSegment = t.route[anchor]
		var tail: Array = network.find_route_to_platform(last_kept.node_end, platform, t)
		if tail.size() == 0:
			continue
		# A tail that starts back along the kept route's own track would mean
		# reversing mid-route — a train may only wait, never back out.
		if tail[0] == last_kept.reverse:
			continue
		var cost := _plan_cost(t, anchor, tail)
		if cost < best_cost - 1.0:
			best_cost = cost
			best_anchor = anchor
			best_tail = tail
	if best_anchor == -1:
		return
	if t.adopt_route_tail(best_anchor, best_tail):
		t.stop_progress = _stop_point(t.route[-1], t)

## Cost of a candidate plan for t: the kept route from the head up to the
## anchor (penalty-free — t already holds those blocks) plus the tail as the
## router prices it, so plans from different anchors compare consistently.
func _plan_cost(t: Train, anchor: int, tail: Array) -> float:
	var total := 0.0
	for i in range(t.route_index, anchor + 1):
		total += t.route[i].length()
	return total + network.route_cost(tail, t)

## Head halt point (progress) on a platform segment that centers the consist
## on the platform. Consists always fit: car count is capped to the platform
## length, so the whole train sits on the platform segment while dwelling.
func _stop_point(platform_seg: TrackSegment, t: Train) -> float:
	var total := platform_seg.length()
	if total <= 0.0:
		return 1.0
	return clampf(0.5 + t.consist_length() / (2.0 * total), 0.0, 1.0)

## Largest consist size that fits within a station platform.
func _max_car_count() -> int:
	return int((TrackEditor.PLATFORM_LENGTH + Train.CAR_GAP) / (Train.CAR_LENGTH + Train.CAR_GAP))

## Halt the simulation and return to editing mode. Trains release their
## blocks and park back at their home platforms; money is kept.
func _stop_simulation(msg: String) -> void:
	state = GameState.EDITING
	for t in trains:
		t.reset_run()
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

		for t in trains:
			if t.stalled:
				continue
			if t.dwell_remaining <= 0.0:
				_replan_blocked_route(t)
			t.move(delta)
			if t.dwell_remaining <= 0.0:
				if t.at_pending_stop():
					if t.boarded_this_leg:
						_depart_from_stop(t)
					else:
						_arrive_at_platform(t)
				elif t.has_completed_route() and t.boarded_this_leg:
					# Fallback dispatch at the end of the track (e.g. the stop's
					# platform vanished mid-leg): re-anchor exactly like a
					# departure so blocks transfer/release through the history.
					var last: TrackSegment = t.route[-1]
					_dispatch_to_next_order(t, last.node_end)
					if not t.stalled and t.has_route():
						t.resume_from_stop(last, 1.0, last.reverse)
						t.reserve_departure_span()

		_detect_deadlocks()
		frame_count += 1

	queue_redraw()

## The dwell is over: dispatch the next leg while the train sits at its stop
## point. When the leg leaves back the way the train came in (a dead-end
## station), the train turns around at the platform instead of rolling to the
## end of the track and bouncing back; otherwise it keeps its place and rolls
## forward through the rest of the platform onto the new route. Departure is
## gated on the leg's first span inside Train.move() — until that span is
## reserved the train stays put on its platform.
func _depart_from_stop(t: Train) -> void:
	var seg := t.current_segment()
	t.stop_progress = -1.0  # dwell over — pull away
	if seg == null or not seg.is_platform_segment():
		return  # fall back to dispatching when the route completes
	var progress := t.segment_progress
	var p: Platform = seg.platform
	var reverse_seg := p.reverse_segment if seg == p.segment else p.segment
	_dispatch_to_next_order(t, seg.node_end)
	if not t.stalled and t.has_route():
		t.resume_from_stop(seg, progress, reverse_seg)
		t.reserve_departure_span()

## Safety net: path reservation makes mid-corridor head-on meetings
## impossible, but layout-level deadlocks remain (no passing loop on a shared
## single line, or a cycle of trains each waiting for a block another holds).
## Build a "waiting-for" graph over the blocked trains and flag every train
## on a cycle; a train merely queued behind a moving one has its blocker
## outside the graph and is never flagged.
func _detect_deadlocks() -> void:
	var blockers := {}
	for t in trains:
		t.deadlocked = false
		if t.stalled or not t.waiting_for_block:
			continue
		var holding: Array = []
		for seg in t.wanted_span():
			var o: Train = seg.occupying_train
			if o != null and o != t and not holding.has(o):
				holding.append(o)
			if seg.reverse != null:
				o = seg.reverse.occupying_train
				if o != null and o != t and not holding.has(o):
					holding.append(o)
		blockers[t] = holding
	var any_deadlock := false
	for t in blockers:
		for cycle_train in _wait_cycle(t, blockers, []):
			cycle_train.deadlocked = true
			any_deadlock = true
	if any_deadlock and status_timer <= 0.0:
		_show_status("Deadlock — add signals or a passing loop (ESC to stop and edit)")

## Depth-first search along waiting-for edges. Returns the trains forming the
## first cycle found from t, or an empty array. Only waiting trains appear in
## blockers, so a chain ending at a moving train is not a cycle.
func _wait_cycle(t: Train, blockers: Dictionary, path: Array) -> Array:
	var idx := path.find(t)
	if idx >= 0:
		return path.slice(idx)
	if not blockers.has(t):
		return []
	path.append(t)
	for blocker in blockers[t]:
		var cycle: Array = _wait_cycle(blocker, blockers, path)
		if cycle.size() > 0:
			return cycle
	path.pop_back()
	return []

## The train has halted at its stop point (the middle of the target platform):
## unload, board, and wait out the dwell time.
func _arrive_at_platform(t: Train) -> void:
	t.boarded_this_leg = true
	var seg := t.current_segment()
	if seg != null and seg.is_platform_segment() and seg.platform.station != null:
		var town := seg.platform.station.town
		if town != null:
			money += t.unload() * 10
			t.board_from(town)
	t.dwell_remaining = t.dwell_time

## Draw game scene.
func _draw() -> void:
	_draw_towns()
	_draw_tracks()
	_draw_platforms()
	_draw_junctions()

	_draw_trains()
	if state == GameState.EDITING:
		_draw_editor_overlay()
	elif state == GameState.SIMULATING:
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

## Draw junction nodes as diamonds. Signal nodes get their own marker.
func _draw_junctions() -> void:
	for node in network.nodes:
		if node.is_signal:
			_draw_signal(node)
			continue
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
		if state == GameState.EDITING and not editing_orders and not placing_station and not placing_signal:
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

## Draw one signal as a post beside the track. A two-way signal gets a lamp
## per travel direction: red when the segment leaving the signal that way (or
## its reverse) is reserved by a train, green otherwise. A directional signal
## gets its lamp (plus a facing arrowhead) on the governed side only; the back
## side shows a small white dot when freely passable (path signal) or a red
## bar when impassable (one-way signal).
func _draw_signal(node: NetworkNode) -> void:
	var p := node.position
	draw_circle(p, 4.0, Color.WHITE)
	draw_arc(p, 4.0, 0, TAU, 16, Color.DIM_GRAY, 1.5)
	for seg in network.get_outgoing(node):
		var dir := Vector2.from_angle(seg.angle_at(0.0))
		var lamp_pos: Vector2 = p + dir * 12.0
		if node.signal_kind == NetworkNode.SignalKind.TWO_WAY or node.signal_facing.dot(dir) > 0.0:
			var occupied: bool = seg.is_occupied_by_other(null)
			draw_line(p, lamp_pos, Color.DIM_GRAY, 2.0)
			draw_circle(lamp_pos, 4.0, Color.RED if occupied else Color.LIME_GREEN)
			if node.signal_kind != NetworkNode.SignalKind.TWO_WAY:
				var tip: Vector2 = lamp_pos + dir * 10.0
				var base: Vector2 = lamp_pos + dir * 4.0
				var side: Vector2 = dir.orthogonal() * 3.5
				draw_colored_polygon(PackedVector2Array([
					tip, base + side, base - side,
				]), Color.WHITE)
		elif node.signal_kind == NetworkNode.SignalKind.PATH:
			draw_circle(lamp_pos, 2.5, Color(1, 1, 1, 0.8))
		else:
			var bar: Vector2 = dir.orthogonal() * 5.0
			draw_line(lamp_pos - bar, lamp_pos + bar, Color.RED, 3.0)

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

		if state == GameState.EDITING and (editing_orders or placing_station or buying_train):
			if town == hovered_town:
				draw_arc(town.position, town.radius + 4, 0, TAU, 48, Color.YELLOW, 2.0)
		if state == GameState.SIMULATING:
			var label_color := Color.WHITE if town.station != null else Color.RED
			draw_string(ThemeDB.fallback_font, town.position + Vector2(-30, -town.radius - 8),
				"Waiting: %d" % int(town.waiting), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, label_color)

	# Stop-number badges for the selected train's order list, in its colour.
	if state == GameState.EDITING and not trains.is_empty():
		var color: Color = TRAIN_COLORS[selected_train % TRAIN_COLORS.size()]
		var orders: Array[Town] = trains[selected_train].orders
		for i in range(orders.size()):
			var town: Town = orders[i]
			var label_pos := town.position + Vector2(town.radius, -town.radius) * 0.75
			draw_circle(label_pos, 12, Color.WHITE)
			draw_arc(label_pos, 12, 0, TAU, 24, color, 2.0)
			draw_string(ThemeDB.fallback_font, label_pos + Vector2(-4, 5),
				str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color)

## Draw editor overlay.
func _draw_editor_overlay() -> void:
	if editing_orders:
		_draw_order_overlay()
	elif placing_station:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"STATION: Click a track inside a town's circle | ESC/P to cancel")
	elif placing_signal:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"SIGNAL: Click a track to place | Click a signal to cycle two-way/path/one-way | SHIFT+Click to flip direction | ESC/S to finish")
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
	elif buying_train:
		draw_string(ThemeDB.fallback_font, Vector2(10, 20),
			"BUY TRAIN (%d): Click a town with a station | ESC/T to cancel" % int(TRAIN_COST))
	else:
		var hint := "SHIFT+CLICK towns | CLICK to draw tracks | P station | S signals | T buy train | O orders | [ ] cars | RIGHT-CLICK delete | U undo | R reset"
		if not trains.is_empty():
			var t: Train = trains[selected_train]
			hint = ("Train %d of %d: %d cars, %d stops | " % [selected_train + 1, trains.size(),
				t.car_count, t.orders.size()]) + hint
			if _all_trains_ready():
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

## Draw order editing overlay — hint text and the selected train's route
## preview in its colour.
func _draw_order_overlay() -> void:
	var orders: Array[Town] = trains[selected_train].orders
	var hint := "ORDERS for train %d of %d: Click towns with stations to add/remove stops | RIGHT-CLICK remove last | O next train | [ ] cars | U undo | ESC to finish" \
		% [selected_train + 1, trains.size()]
	if _all_trains_ready():
		hint += " | SPACE to start simulation"
	draw_string(ThemeDB.fallback_font, Vector2(10, 20), hint)
	if orders.size() >= 2:
		var color: Color = TRAIN_COLORS[selected_train % TRAIN_COLORS.size()]
		for i in range(orders.size()):
			var from_pos: Vector2 = orders[i].position
			var to_pos: Vector2 = orders[(i + 1) % orders.size()].position
			_draw_dashed_line(PackedVector2Array([from_pos, to_pos]),
				Color(color, 0.55), 2.0, 10.0)

## Whether every train has enough stops to start the simulation.
func _all_trains_ready() -> bool:
	if trains.is_empty():
		return false
	for t in trains:
		if t.orders.size() < 2:
			return false
	return true

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

## Draw every train. While simulating, trains follow their routes; in edit
## mode they sit parked on their home platforms. The selected train gets a
## highlight ring in edit mode.
func _draw_trains() -> void:
	for i in range(trains.size()):
		var t: Train = trains[i]
		var color: Color = TRAIN_COLORS[i % TRAIN_COLORS.size()]
		if state == GameState.SIMULATING and t.has_route():
			_draw_running_train(t, i, color)
		elif state == GameState.EDITING and t.home_platform != null:
			_draw_parked_train(t, i, color)

## Draw a moving train as a chain of cars, each sampled at its own point
## along the track so the consist bends with the curves. Status markers show
## why a train is not moving: boarding (dwell), waiting at a red signal,
## halted (no route), or deadlocked.
func _draw_running_train(t: Train, index: int, color: Color) -> void:
	var half := Train.CAR_LENGTH / 2.0
	for i in range(t.car_count):
		var back := i * (Train.CAR_LENGTH + Train.CAR_GAP) + half
		var xf := t.point_behind(back)
		draw_set_transform(xf.origin, xf.get_rotation())
		draw_rect(Rect2(-half + 1, -7, Train.CAR_LENGTH - 2, 14),
			color if i == 0 else color.lerp(Color.DIM_GRAY, 0.5))
		if i == 0:
			draw_circle(Vector2(half - 3, 0), 2.0, Color.YELLOW)
		if i == t.car_count - 1:
			draw_circle(Vector2(-half + 3, 0), 2.0, Color.RED)
	draw_set_transform(Vector2.ZERO, 0)
	var head_pos := t.current_position()
	draw_string(ThemeDB.fallback_font, head_pos + Vector2(-20, -15),
		"%d" % t.passengers_on_board)
	var status := ""
	var status_color := Color.WHITE
	if t.deadlocked:
		status = "DEADLOCK"
		status_color = Color.RED
	elif t.stalled:
		status = "No route"
		status_color = Color.RED
	elif t.dwell_remaining > 0.0:
		status = "Boarding..."
	elif t.waiting_for_block:
		status = "Waiting"
		status_color = Color.ORANGE_RED
	if status != "":
		draw_string(ThemeDB.fallback_font, head_pos + Vector2(-30, 28),
			status, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, status_color)
	if index == selected_train:
		draw_arc(head_pos, 18.0, 0, TAU, 24, Color(color, 0.7), 1.5)

## Draw a parked train centred on its home platform segment.
func _draw_parked_train(t: Train, index: int, color: Color) -> void:
	var seg: TrackSegment = t.home_platform.segment
	var total := seg.length()
	if total <= 0.0:
		return
	var head_dist := _stop_point(seg, t) * total
	var half := Train.CAR_LENGTH / 2.0
	for i in range(t.car_count):
		var dist := head_dist - i * (Train.CAR_LENGTH + Train.CAR_GAP) - half
		var progress := clampf(dist / total, 0.0, 1.0)
		var pos := seg.position_at(progress)
		var angle := seg.angle_at(progress)
		draw_set_transform(pos, angle)
		draw_rect(Rect2(-half + 1, -7, Train.CAR_LENGTH - 2, 14),
			color if i == 0 else color.lerp(Color.DIM_GRAY, 0.5))
	draw_set_transform(Vector2.ZERO, 0)
	var head_pos := seg.position_at(clampf(head_dist / total, 0.0, 1.0))
	draw_string(ThemeDB.fallback_font, head_pos + Vector2(-12, -12),
		"T%d" % (index + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
	if index == selected_train:
		draw_arc(head_pos, 18.0, 0, TAU, 24, Color(color, 0.7), 1.5)

## Draw HUD.
func _draw_hud() -> void:
	var text := "Money: %d" % int(money)
	for i in range(trains.size()):
		var t: Train = trains[i]
		text += " | T%d: %d/%d" % [i + 1, t.passengers_on_board, t.capacity]
	text += " | ESC to stop | R to reset"
	draw_string(ThemeDB.fallback_font, Vector2(10, 20), text)
