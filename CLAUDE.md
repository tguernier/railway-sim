# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A 2D top-down railway company simulator built in **Godot 4.6** (Mobile renderer). Players place towns, draw Bézier-curved tracks between them, then run trains that pick up and deliver passengers to earn money.

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
├── TrackNetwork          — directed graph; BFS pathfinding between towns
│   └── TrackSegment[]    — Bézier curve path between two towns (Curve2D)
├── Town[]                — position, color, waiting passenger count
└── Train                 — moves along a route, boards/unloads passengers
```

**Game states:** `EDITING` (place towns, draw tracks) → `SIMULATING` (train runs, money accumulates).

### Key systems

**Track drawing** (`main.gd`): Click a town to start a track, click empty space to add curve waypoints, click a destination town to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `position_at(t)`, `angle_at(t)`, and `length()`.

**Train movement** (`train.gd`): Advances `segment_progress` (0–1) along the current `TrackSegment`. At a terminus (town with fewer than 2 outgoing routes), the train reverses direction (`FORWARD`/`BACKWARD`). Capacity is 40 passengers, speed is 150 px/sec.

**Routing** (`track_network.gd`): BFS over the directed graph. `find_route(from, to)` returns an `Array[TrackSegment]`. `_outgoing` is a `Dictionary` keyed by `Town` object.

**Passenger economy** (`main.gd`): Towns generate 0.5 passengers/frame (every 10 frames). Delivering passengers earns `10 × passenger_count`. Starting money: 1000.

**Rendering**: Everything is drawn in `_draw()` on the root Node2D — no sprites or child nodes. `queue_redraw()` is called each frame.

### Input (editing mode)

| Action | Effect |
|---|---|
| Left-click empty | Place town |
| Left-click town | Start/complete track |
| Left-click empty (while drawing) | Add waypoint |
| Right-click / Escape | Cancel drawing |
| Z | Undo last waypoint |
| Space | Start simulation |
