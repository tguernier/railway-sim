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
│                           (occupancy-aware: reserved segments are penalized)
│   ├── NetworkNode[]     — junction nodes (position + signal_kind/facing)
│   └── TrackSegment[]    — Bézier curve path between two junctions (Curve2D);
│                           also the block unit (occupying_train weakref)
├── TrackEditor           — drawing state, split/delete, station/signal placement
├── Town[]                — circle on the map; color, radius, passenger pool
│   └── Station           — links a town to the track via Platform(s)
│       └── Platform      — forward/reverse platform segment pair + side/width
└── Train[]               — bought in edit mode (homed at a platform); each has
							its own orders, moves along a route, reserves spans
```

**Towns are not part of the track graph.** A town is a catchment circle that accumulates passengers. Building a station (on a track inside the town's radius) is what connects it to the railway: the hit segment is split into approach tracks and a platform segment with entry/exit junction nodes. Back-references (`Station.town`, `Platform.station`, `TrackSegment.platform`) are weakrefs to avoid RefCounted cycles.

**Game states:** `EDITING` (place towns, draw tracks, build stations/signals, buy trains) → `SIMULATING` (trains run, money accumulates). ESC stops the simulation and parks every train back at its home platform, money kept.

### Key systems

**Track drawing** (`main.gd`, `track_editor.gd`): Click a junction or empty ground to start a track (empty ground creates a fresh junction), click empty space to add curve waypoints, click a junction or track to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `position_at(t)`, `angle_at(t)`, and `length()`. Tracks are validated for curve radius and turnout angle at both ends.

**Stations** (`track_editor.place_station`): Press `P`, click a track inside a town's circle. Validates: town has no station yet, segment ≥ `PLATFORM_LENGTH + 20`, platform span gentle enough, not already a platform. Span ends snap to existing endpoints when close (5% of length or `HIT_RADIUS`). Platform segments are protected — no splitting (junctions) and no deletion while the station exists; removing the town removes the station.

**Train movement** (`train.gd`): Advances `segment_progress` (0–1) along the current `TrackSegment`. Capacity is 20 passengers/car, speed is 150 px/sec. While `dwell_remaining > 0` the train is stopped at a station and `move()` only counts the timer down.

**Block signalling** (`track_segment.gd`, `train.gd`): each segment is a block (`occupying_train` weakref; its reverse twin is the same physical block). A **safe waiting point** is a platform or a player-placed signal node (`NetworkNode.signal_kind`, placed with `S` by splitting a segment). Signals come in three kinds (OpenTTD-style; clicking an existing signal in `S` mode cycles them, shift+click flips `signal_facing`): `TWO_WAY` bounds spans in both directions; `PATH` bounds spans only along its facing and is passed freely from behind; `ONE_WAY` additionally forbids crossing from behind — `TrackNetwork.can_enter()` excludes such crossings from Dijkstra and from platform-end selection, and `Train._signal_boundary()` decides span ends per travel direction. A train may only move while it holds the **span** from its position to the next waiting point, reserved **atomically** (`Train._try_reserve_span`); if the next span is unavailable it holds at the signal/platform (`waiting_for_block`) and retries every tick. Routing for a train prices trouble at three levels: a busy block inside the route's **first** reservation span costs `SPAN_BLOCKED_PENALTY` (the route could not even be started — Dijkstra tracks a first-span flag as part of its search state), any other held block costs `OCCUPIED_PENALTY`, and blocks **opposed** by another train's planned route — including the *predicted* departure of a train arriving at or dwelling in a station, derived from its orders (`TrackNetwork.opposed_blocks`) — also cost `OCCUPIED_PENALTY`, so trains keep out of corridors an oncoming train needs before either commits. Whenever a held/opposed block lies on the not-yet-reserved remainder of a route, `main._replan_blocked_route` (run *before* each move) re-plans from **every node of the held span**, not just its end — if the escape needs a junction the span already claimed past, the span is shrunk atomically (`Train.adopt_route_tail`: the new continuation is reserved before the abandoned blocks are released, so spans always end on a safe waiting point). The first span of a leg is claimed at dispatch (`Train.reserve_departure_span()`) so simultaneous dispatches see each other. Blocks are freed as the **tail** clears them (`Train._trim_history`). `main.gd._detect_deadlocks()` flags waiting-for cycles (red trains + status hint) — path reservation prevents mid-corridor head-ons, but a layout without loops/signals can still stand off.

**Routing** (`track_network.gd`): Dijkstra over the directed graph; `find_route(from, to, for_train)` returns an `Array[TrackSegment]`. Dispatch uses `find_route_to_platform(from, platform, for_train)`, which enters at the cheaper platform end and always finishes by traversing the platform segment. The train halts at the middle of the platform (`Train.stop_progress`): `main.gd._arrive_at_platform()` unloads/boards and starts a 2 s dwell (`Train.dwell_time`); when it expires `main.gd._depart_from_stop()` dispatches the next order from the platform's exit node and re-anchors the train via `Train.resume_from_stop()` — if the new route leaves along the platform's reverse segment (a dead-end station) the train turns around in place (transferring its platform block to the reverse direction), otherwise the platform segment is prepended so the train rolls forward through its remainder onto the new route (`Train.boarded_this_leg` marks the stop as done for the leg).

**Trains** (`main.gd`): bought in edit mode (`T`, click a stationed town) for `TRAIN_COST` 200 with 1 car; `[`/`]` resize the **selected train** at `COST_PER_CAR` 150, charged/refunded immediately. Each train has its own `orders` (edited in `O` mode; `O` cycles the selection) and home platform; removing a town refunds trains homed there. Validation at start: every train needs ≥ 2 stops and a routable loop anchored at its home platform. A mid-simulation dispatch failure halts only that train (`Train.stalled`). Undo snapshots include money and trains; the undo stack is cleared at simulation start.

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
| Right-click signal / track / town | Remove signal / delete track / remove town (and its station + refund homed trains) |
| Z | Undo last waypoint (of the in-progress track only) |
| U | Undo the last build action — town, track, split, station, signal, train purchase/resize, delete, order edit (LIFO snapshots; works in the sub-modes, ignored while drawing) |
| P | Place a station (click a track inside a town circle) |
| S | Place signals (click tracks; click a signal to cycle two-way/path/one-way, Shift+click to flip its direction; mode stays active) |
| T | Buy a train (click a town with a station; 200) |
| O | Edit the selected train's orders (click towns with stations); O again cycles trains |
| [ / ] | Remove/add a car on the selected train (150 each, immediate) |
| R | Reset the game to the initial empty editing state (works in any phase) |
| Space | Start simulation |
| Esc (simulating) | Stop the simulation; trains park at their home platforms, money kept |
