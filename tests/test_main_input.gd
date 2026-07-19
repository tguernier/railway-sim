class_name TestMainInput
extends TestBase

func run_all() -> void:
	print("[TestMainInput]")
	_t("rejoin_departure_track_closes_passing_loop", _test_passing_loop_rejoin)
	_t("shift_rejoin_departure_track_continues", _test_passing_loop_rejoin_shift)
	_t("click_near_start_still_adds_waypoint", _test_near_start_waypoint)
	_t("shallow_departure_click_is_waypoint", _test_shallow_departure_click)
	_t("flat_rejoin_rejected_with_message", _test_flat_rejoin_rejected)
	_t("escape_stops_sim_and_keeps_world", _test_escape_stops_sim)

## Draw-click handling lives on the main game node, so tests drive a real instance.
func _main() -> Node2D:
	var m: Node2D = load("res://main.gd").new()
	m._ready()
	return m

func _junction(x: float, y: float) -> NetworkNode:
	return NetworkNode.junction(Vector2(x, y))

## Split a straight track at (150, 0) and leave the editor drawing from the
## new junction — the setup for closing a passing loop back onto that track.
func _main_drawing_from_split() -> Node2D:
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(900, 0), [])
	m._handle_idle_click(Vector2(150, 0), false)
	is_true(ed.drawing)
	return m

func _test_passing_loop_rejoin() -> void:
	var m := _main_drawing_from_split()
	var ed: TrackEditor = m.editor
	m._handle_draw_click(Vector2(450, -40), false)  # clear of the track: waypoint
	eq(ed.waypoints.size(), 1)
	m._handle_draw_click(Vector2(750, 0), false)  # rejoin the segment we left
	is_false(ed.last_finish_rejected)
	is_false(ed.drawing)
	# Original pair split twice (3 physical tracks) + the loop pair.
	eq(m.network.segments.size(), 8)
	eq(m.undo_stack.size(), 2)  # the idle-click split + the finish
	# The loop parallels the straight middle track yet stays clickable.
	var hit: Array = ed.find_track_at(Vector2(450, -40))
	is_true(hit.size() > 0)
	m.free()

func _test_passing_loop_rejoin_shift() -> void:
	var m := _main_drawing_from_split()
	var ed: TrackEditor = m.editor
	m._handle_draw_click(Vector2(450, -40), false)
	m._handle_draw_click(Vector2(750, 0), true)  # shift: rejoin and keep drawing
	is_false(ed.last_finish_rejected)
	is_true(ed.drawing)
	approx(ed.start_node.position.x, 750.0, 5.0)
	eq(m.network.segments.size(), 8)
	ed.cancel()
	m.free()

func _test_near_start_waypoint() -> void:
	# A click on the track right next to the start junction is a waypoint,
	# not a join — joining there would create a sliver segment.
	var m := _main_drawing_from_split()
	var ed: TrackEditor = m.editor
	m._handle_draw_click(Vector2(170, 5), false)
	is_true(ed.drawing)
	eq(ed.waypoints.size(), 1)
	eq(m.network.segments.size(), 4)  # nothing built
	eq(m.undo_stack.size(), 1)  # only the idle-click split
	ed.cancel()
	m.free()

func _test_shallow_departure_click() -> void:
	# The turnout limit forces loops to depart shallowly, so an early waypoint
	# click lands within the hit radius of the line being left (12px off,
	# 130px along). It must stay a waypoint, not become an instant join.
	var m := _main_drawing_from_split()
	var ed: TrackEditor = m.editor
	m._handle_draw_click(Vector2(280, -12), false)
	is_true(ed.drawing)
	eq(ed.waypoints.size(), 1)
	eq(m.network.segments.size(), 4)
	ed.cancel()
	m.free()

func _test_escape_stops_sim() -> void:
	# ESC during a run returns to editing with the world intact: tracks, towns,
	# roster, and money survive (the per-run fleet cost is refunded), and every
	# reservation is released so a restart begins clean.
	var m := _main()
	var ed: TrackEditor = m.editor
	ed.create_bidirectional_track(_junction(0, 0), _junction(1200, 0), [])
	var a := Town.new(Vector2(300, 30), Color.WHITE)
	var b := Town.new(Vector2(900, 30), Color.WHITE)
	m.towns.assign([a, b])
	ed.place_station(Vector2(300, 0), m.towns)
	ed.place_station(Vector2(900, 0), m.towns)
	m.roster[0].orders.assign([a, b])
	m._buy_train()
	m.roster[1].orders.assign([b, a])
	var segments_before: int = m.network.segments.size()
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	eq(m.money, 1000.0 - 500.0 - 2 * 150.0)  # extra train + one extra car each
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	m._input(esc)
	eq(m.state, m.GameState.EDITING)
	eq(m.trains.size(), 0)
	eq(m.money, 1000.0)  # fleet cost refunded, nothing earned yet
	eq(m.network.segments.size(), segments_before)
	eq(m.towns.size(), 2)
	eq(m.roster.size(), 2)
	for seg in m.network.segments:
		eq(seg.reserved_by, null)
	# The run can start again immediately.
	m._start_simulation()
	eq(m.state, m.GameState.SIMULATING)
	eq(m.trains.size(), 2)
	m.free()

func _test_flat_rejoin_rejected() -> void:
	# Rejoining with no waypoints would bury a second track exactly under the
	# first — rejected with guidance, drawing still live, no undo burned.
	var m := _main_drawing_from_split()
	var ed: TrackEditor = m.editor
	m._handle_draw_click(Vector2(750, 0), false)
	is_true(ed.drawing)
	eq(m.network.segments.size(), 4)
	is_true(m.status_message != "")
	eq(m.undo_stack.size(), 1)  # only the idle-click split
	ed.cancel()
	m.free()
