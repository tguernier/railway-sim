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
└── Train                 — moves along a route, boards/unloads passengers
```

**Towns are not part of the track graph.** A town is a catchment circle that accumulates passengers. Building a station (on a track inside the town's radius) is what connects it to the railway: the hit segment is split into approach tracks and a platform segment with entry/exit junction nodes. Back-references (`Station.town`, `Platform.station`, `TrackSegment.platform`) are weakrefs to avoid RefCounted cycles.

**Game states:** `EDITING` (place towns, draw tracks, build stations) → `SIMULATING` (train runs, money accumulates).

### Key systems

**Track drawing** (`main.gd`, `track_editor.gd`): Click a junction or empty ground to start a track (empty ground creates a fresh junction), click empty space to add curve waypoints, click a junction or track to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `position_at(t)`, `angle_at(t)`, and `length()`. Tracks are validated for curve radius and turnout angle at both ends.

**Stations** (`track_editor.place_station`): Press `P`, click a track inside a town's circle. Validates: town has no station yet, segment ≥ `PLATFORM_LENGTH + 20`, platform span gentle enough, not already a platform. Span ends snap to existing endpoints when close (5% of length or `HIT_RADIUS`). Platform segments are protected — no splitting (junctions) and no deletion while the station exists; removing the town removes the station.

**Train movement** (`train.gd`): Advances `segment_progress` (0–1) along the current `TrackSegment`. Capacity is 40 passengers, speed is 150 px/sec. While `dwell_remaining > 0` the train is stopped at a station and `move()` only counts the timer down.

**Routing** (`track_network.gd`): Dijkstra over the directed graph; `find_route(from, to)` returns an `Array[TrackSegment]`. Dispatch uses `find_route_to_platform(from, platform)`, which enters at the cheaper platform end and always finishes by traversing the platform segment. The train halts at the middle of the platform (`Train.stop_progress`, set to 0.5 of the final segment on dispatch): `main.gd._arrive_at_platform()` unloads/boards and starts a 2 s dwell (`Train.dwell_time`); when it expires `main.gd._depart_from_stop()` dispatches the next order from the platform's exit node and re-anchors the train via `Train.resume_from_stop()` — if the new route leaves along the platform's reverse segment (a dead-end station) the train turns around in place, otherwise the platform segment is prepended so the train rolls forward through its remainder onto the new route (`Train.boarded_this_leg` marks the stop as done for the leg).

**Passenger economy** (`main.gd`): Towns generate 0.5 passengers/frame (every 10 frames) whether or not they have a station. Delivering passengers earns `10 × passenger_count`. Starting money: 1000. Only towns with stations can be train order stops.

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
| Z | Undo last waypoint |
| P | Place a station (click a track inside a town circle) |
| O | Edit train orders (click towns with stations) |
| Space | Start simulation |
