# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A 2D top-down railway company simulator built in **Godot 4.6** (Mobile renderer). Players place towns, draw Bézier-curved tracks, build stations to connect towns to the railway, then run trains that pick up and deliver passengers to earn money.

## Running the Project

Open the project folder in the Godot 4.6 editor and press **F5**, or run:
```
godot --path /home/tom/code/railway-sim
```

There is no separate build step or lint tool. Run the unit tests headlessly with:
```
godot --path /home/tom/code/railway-sim --headless --script res://tests/run_tests.gd
```

## Architecture

All game entities are `RefCounted` (not Nodes), managed and rendered by `main.gd`.

```
main.gd (Node2D)          — game state, input handling, all drawing (_draw)
├── TrackNetwork          — directed graph of junctions; Dijkstra pathfinding
│   ├── NetworkNode[]     — junction nodes (position only)
│   └── TrackSegment[]    — Bézier curve path between two junctions (Curve2D)
├── TrackEditor           — drawing state, split/delete, station placement
├── Town[]                — circle on the map; color, radius, passenger pool
│   └── Station           — links a town to the track via Platform(s)
│       └── Platform      — forward/reverse platform segment pair + side/width
├── TrainPlan[]           — edit-mode roster: per-train orders + car count
└── Train[]               — moves along a route, boards/unloads passengers,
                            holds track reservations (one Train per TrainPlan)
```

**Towns are not part of the track graph.** A town is a catchment circle that accumulates passengers. Building a station (on a track inside the town's radius) is what connects it to the railway: the hit segment is split into approach tracks and a platform segment with entry/exit junction nodes. Back-references (`Station.town`, `Platform.station`, `TrackSegment.platform`) are weakrefs to avoid RefCounted cycles.

**Game states:** `EDITING` (place towns, draw tracks, build stations, configure the train roster) → `SIMULATING` (trains run, money accumulates).

### Key systems

**Track drawing** (`main.gd`, `track_editor.gd`): Click a junction or empty ground to start a track (empty ground creates a fresh junction), click empty space to add curve waypoints, click a junction or track to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `position_at(t)`, `angle_at(t)`, and `length()`. Tracks are validated for curve radius and turnout angle at both ends.

**Stations** (`track_editor.place_station`): Press `P`, click a track inside a town's circle. Validates: town has no station yet, segment ≥ `PLATFORM_LENGTH + 20`, platform span gentle enough, not already a platform. Span ends snap to existing endpoints when close (5% of length or `HIT_RADIUS`). Platform segments are protected — no splitting (junctions) and no deletion while the station exists; removing the town removes the station.

**Train movement** (`train.gd`): Advances `segment_progress` (0–1) along the current `TrackSegment`. Capacity is 20 passengers per car, speed is 150 px/sec. While `dwell_remaining > 0` the train is stopped at a station and `move()` only counts the timer down.

**Track reservations** (`train.gd`, `track_segment.gd`): `TrackSegment.reserved_by` (weakref) marks the train holding a segment; a segment is blocked for a train if it *or its reverse twin* is held by another train (head-on exclusion on the same physical track). `Train.try_reserve(segs)` is atomic (all-or-nothing); the head may only advance onto the next route segment after reserving it — on failure it halts at the boundary with `waiting_for_track` set and retries every `move()`. Segments release when the **tail** clears them (the `_trim_history()` hook) and on `set_route()`; after a stop, `main.gd` re-reserves the segment the consist sits on. Two trains facing off on single track therefore stall instead of colliding — deadlock resolution arrives with path signals (see `docs/multi-train-signalling-plan.md`, steps 2.3–2.4).

**Multiple trains** (`main.gd`, `train_plan.gd`): The edit-mode roster is `Array[TrainPlan]` (orders + car count each); `T` buys a train, `X` sells, `,`/`.` switch the selected train, and `O`/`[ ]` edit the selected plan (`main.train_orders`/`main.car_count` are properties forwarding to it). Simulation start validates every plan's loop, requires **distinct first stops** (each train spawns parked at its first stop's platform), and charges `TRAIN_COST` (500) per extra train plus `COST_PER_CAR` (150) per extra car. Each train is drawn in its `TRAIN_COLORS` hue (head car, order badges, order-loop preview).

**Routing** (`track_network.gd`): Dijkstra over the directed graph; `find_route(from, to)` returns an `Array[TrackSegment]`. Dispatch uses `find_route_to_platform(from, platform)`, which enters at the cheaper platform end and always finishes by traversing the platform segment. The train halts at the middle of the platform (`Train.stop_progress`, set to 0.5 of the final segment on dispatch): `main.gd._arrive_at_platform()` unloads/boards and starts a 2 s dwell (`Train.dwell_time`); when it expires `main.gd._depart_from_stop()` dispatches the next order from the platform's exit node and re-anchors the train via `Train.resume_from_stop()` — if the new route leaves along the platform's reverse segment (a dead-end station) the train turns around in place, otherwise the platform segment is prepended so the train rolls forward through its remainder onto the new route (`Train.boarded_this_leg` marks the stop as done for the leg).

**Passenger economy** (`main.gd`): Towns generate 0.5 passengers/frame (every 10 frames) whether or not they have a station. Delivering passengers earns `10 × passenger_count`. Starting money: 1000; the fleet cost (extra trains and cars) is deducted at simulation start. Only towns with stations can be train order stops.

**Rendering**: Everything is drawn in `_draw()` on the root Node2D — no sprites or child nodes. `queue_redraw()` is called each frame. Towns are translucent circles (dashed outline = no station); platforms are filled strips offset to the town-facing side of the track.

### Input (editing mode)

| Action | Effect |
|---|---|
| Shift+Left-click empty | Place town |
| Left-click junction/track/empty | Start track (empty ground creates a junction) |
| Left-click empty (while drawing) | Add waypoint |
| Shift+Left-click (while drawing) | Finish at new junction and continue drawing |
| Right-click / Escape | Cancel drawing |
| Right-click track / town | Delete track / remove town (and its station) |
| Z | Undo last waypoint (of the in-progress track only) |
| U | Undo the last build action — town, track, split, station, delete, order edit (LIFO snapshots; works in the orders/station sub-modes, ignored while drawing) |
| P | Place a station (click a track inside a town circle) |
| O | Edit the selected train's orders (click towns with stations) |
| T | Buy a train (added to the roster and selected; undoable) |
| X | Sell the selected train (the roster never goes empty; undoable) |
| , / . | Select the previous / next roster train (also in orders mode) |
| [ / ] | Remove / add a car on the selected train |
| R | Reset the game to the initial empty editing state (works in any phase) |
| Space | Start simulation |
