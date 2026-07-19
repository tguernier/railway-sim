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

**Game states:** `EDITING` (place towns, draw tracks, build stations, configure the train roster) → `SIMULATING` (trains run, money accumulates). `Escape` while simulating stops the run and returns to editing with the world intact (`_stop_simulation`): trains despawn, reservations release, and the per-run fleet cost (`fleet_cost_paid`) is refunded, so stop → tweak signals → restart is money-neutral while fares earned are kept. `R` is the destructive full reset.

### Key systems

**Track drawing** (`main.gd`, `track_editor.gd`): Click a junction or empty ground to start a track (empty ground creates a fresh junction), click empty space to add curve waypoints, click a junction or track to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `position_at(t)`, `angle_at(t)`, and `length()`. Tracks are validated for curve radius and turnout angle at both ends. A finish click on a track splits it into a junction (`finish_on_track`) — including the segment the drawing departed from, which is how a passing loop rejoins its own line as a pair of 3-way junctions. Waypoint-vs-join disambiguation is by distance from the start node (`hit_too_close_to_start`): a short sliver zone (`MIN_JOIN_DISTANCE`) on any track, a long one (`DEPARTURE_JOIN_DISTANCE`) on segments touching the start node, because the turnout limit forces departing loops to hug their line at first. A rejoin whose curve never swings `MIN_LOOP_OFFSET` clear of the segment it left is rejected (it would bury an identical-looking track under the original). Parallel tracks between the same two junctions are legal, so hit-testing (`find_track_at`) and rendering (`_draw_tracks`) deduplicate the two directions of a physical track by reverse-twin identity, never by endpoint positions.

**Stations** (`track_editor.place_station`): Press `P`, click a track inside a town's circle. Validates: town has no station yet, segment ≥ `PLATFORM_LENGTH + 20`, platform span gentle enough, not already a platform. Span ends snap to existing endpoints when close (5% of length or `HIT_RADIUS`). Platform segments are protected — no splitting (junctions) and no deletion while the station exists; removing the town removes the station.

**Train movement** (`train.gd`): Advances `segment_progress` (0–1) along the current `TrackSegment`. Capacity is 20 passengers per car, speed is 150 px/sec. While `dwell_remaining > 0` the train is stopped at a station and `move()` only counts the timer down.

**Track reservations — OpenTTD-style path signals** (`train.gd`, `track_segment.gd`): `TrackSegment.reserved_by` (weakref) marks the train holding a segment; a segment is blocked for a train if it *or its reverse twin* is held by another train (head-on exclusion on the same physical track). A train reserves a **path**: `Train.try_extend_reservation()` collects route segments from `limit_index + 1` through the next *safe waiting point* — the first segment with `exit_signal` for its direction, or the end of the route (the destination platform) — and `try_reserve`s the slice atomically (all-or-nothing; `limit_index` unchanged on failure). The head may not advance past `route[limit_index]`; at the boundary it re-attempts the extension and on failure halts with `waiting_for_track` set (retried every `move()`), recording the holder in `blocked_by` (weakref — the wait-for graph edge). Segments release when the **tail** clears them (the `_trim_history()` hook) and on `set_route()`; after a stop, `main.gd` re-reserves the segment the consist sits on, then extends. At simulation start every train's footprint is seeded **before** anyone extends (extending earlier would claim paths through unspawned trains).

**Path signals** (`track_editor.gd`, `main.gd`): `S` enters signal mode; clicking a track calls `place_or_cycle_signal` — it splits the segment (`split_track_at_hit`) and sets `exit_signal` on both directed segments arriving at the new junction (a two-way signal). Clicking an existing signal junction cycles two-way → one-way → other one-way → removed; junctions with ≠2 incoming plain segments are rejected (no signals on real junctions or platforms — the platform is its own safe waiting point). One-way signals additionally bar *routing* against their direction (see Routing). Splits and station placement preserve `exit_signal` on the piece still ending at the signal; `GameSnapshot` clones the flag. Rendering: pole-and-lamp dot on the right-hand side of the direction served, red by default, green while a reservation passes *through* it.

**Deadlock detection** (`main.gd`): once per second (`DEADLOCK_CHECK_INTERVAL`), walk the wait-for graph (`Train.blocked_by`) from each blocked train — a revisit on the walk is a cycle ⇒ deadlock; as a net, all trains simultaneously blocked for > `ALL_BLOCKED_TIMEOUT` (10 s) counts too. Deadlocked trains get a red ring and a status message; the simulation keeps running (the player resolves it with `Escape` — stop, fix the signals, restart — or wipes with `R`). A queue behind a moving or dwelling leader is *not* flagged.

**Multiple trains** (`main.gd`, `train_plan.gd`): The edit-mode roster is `Array[TrainPlan]` (orders + car count each); `T` buys a train, `X` sells, `,`/`.` switch the selected train, and `O`/`[ ]` edit the selected plan (`main.train_orders`/`main.car_count` are properties forwarding to it). Simulation start validates every plan's loop, requires **distinct first stops** (each train spawns parked at its first stop's platform), and charges `TRAIN_COST` (500) per extra train plus `COST_PER_CAR` (150) per extra car. Each train is drawn in its `TRAIN_COLORS` hue (head car, order badges, order-loop preview).

**Routing** (`track_network.gd`): Dijkstra over the directed graph; `find_route(from, to, for_train = null, arriving = null, exit_seg = null, allow_reversal = false)` returns an `Array[TrackSegment]`. **The search is direction-aware — no switchbacks**: its state is the directed segment a path arrives on (visited is keyed per segment, not per node), and a junction transition is only legal when `can_continue(prev, next)` holds — `next` is not `prev`'s reverse twin and the departure heading stays within `MAX_THROUGH_ANGLE` (90°) of the arrival heading, so a train never bends backward through a junction the way no real turnout allows. Reversal is permitted only as the *first* hop with `allow_reversal` (a train standing at a station stop departing back along its own segment — how dead-end termini turn around); `arriving` seeds the heading at `from`, and `exit_seg` makes the goal count only when the path can continue onto it (used so the platform traversal appended by `find_route_to_platform` is always physically takeable). Dispatch (`main._dispatch_to_next_order`) passes the platform segment the train stands on with `allow_reversal = true`; the mid-route re-path (`Train._repath_provisional_tail`) passes `route[limit_index]` without reversal. **One-way signals bar routing against them**: a directed segment is skipped when the junction at its start hosts a signal serving only the opposite direction (`one_way_against` — the segment's twin arriving there carries `exit_signal` and no other arriving segment does). This is what makes directional passing-loop branches work: opposing trains are forced onto different branches and pass inside the loop. `first_unroutable_stop` inherits both rules (it walks the loop with each leg's `arriving` platform traversal and `allow_reversal = true`, mirroring dispatch), so mis-signalled layouts and order loops needing a mid-route switchback (e.g. two stations on branches fanning the same way off one junction) are rejected at simulation start — but it stays reservation-blind (always called without `for_train`), so layouts are never rejected because of where trains happen to stand. Dispatch uses `find_route_to_platform(from, platform, for_train)`, which enters at the cheaper platform end and always finishes by traversing the platform segment.

**Adaptive routing — per-signal lookahead** (`track_network.gd`, `train.gd`): with `for_train` given, a segment unavailable to that train (`Train.is_blocked` — held by another train directly or via the reverse twin) costs `BLOCKED_PENALTY` (10 000) extra: traffic is a *penalty* to route around, never a reason to fail, and with no free alternative the shortest route is still returned. The train's own reservations cost nothing; `one_way_against` stays a hard skip (layout, not traffic). Both dispatch sites pass the train (and set `Train.network`/`Train.target_platform`, strong refs — safe, nothing holds trains strongly), so the initial branch and platform-entry-end choices avoid parked traffic. The payoff is `Train._repath_provisional_tail`, run inside **every** `try_extend_reservation` before the slice is reserved: the provisional tail beyond `limit_index` is re-pathed from `route[limit_index].node_end` to `target_platform` with penalties, and a better tail is spliced onto the kept prefix — history, indices, and held reservations intact (the discarded tail lies beyond `limit_index`, so it held nothing) — then `stop_progress` is recomputed via `Train.stop_point_on` (the new tail may enter the destination platform from the other end). Hysteresis: a *blocked* tail is abandoned for any strictly cheaper one, a *free* tail only for one cheaper by `SWITCH_MARGIN` (`CAR_LENGTH`×10), so near-equal branches never flip-flop (`network.route_cost` does the comparing). Because the re-path runs while the train is still rolling toward the boundary, a train facing a blocked loop branch diverts onto the free one **at speed**, and convoy followers spread across parallel branches; a blocked train's per-frame reservation retries re-path on a throttle (`Train.blocked_time` ≥ `REROUTE_RETRY_INTERVAL`, 1 s — both now `Train` members; `_was_waiting` distinguishes a fresh boundary from a blocked retry). Skipped while the train is still anchored at its departure platform (`limit_index == -1`, before the first extension): the turnaround/roll-through anchoring came from the route's first segment and would not survive a tail swap (3.3b in `docs/adaptive-routing-plan.md`), and dispatch was already traffic-aware. Note the plan's `get_outgoing(node) < 2` early-out is deliberately absent: outgoing counts the reverse twin (only dead ends have < 2), and a train waiting at an approach signal diverges further on, so skipping there would break exactly the passing-loop case. This is what makes passing loops work with plain **two-way** signals. The re-path happens inside `move()` and thus before deadlock detection each tick, and a fruitless re-path leaves `blocked_by` in place, so genuine deadlocks still flag. The train halts at the middle of the platform (`Train.stop_progress`, set to 0.5 of the final segment on dispatch): `main.gd._arrive_at_platform()` unloads/boards and starts a 2 s dwell (`Train.dwell_time`); when it expires `main.gd._depart_from_stop()` dispatches the next order from the platform's exit node and re-anchors the train via `Train.resume_from_stop()` — if the new route leaves along the platform's reverse segment (a dead-end station) the train turns around in place, otherwise the platform segment is prepended so the train rolls forward through its remainder onto the new route (`Train.boarded_this_leg` marks the stop as done for the leg).

**Passenger economy** (`main.gd`): Towns generate 0.5 passengers/frame (every 10 frames) whether or not they have a station. Delivering passengers earns `10 × passenger_count`. Starting money: 1000; the fleet cost (extra trains and cars) is deducted at simulation start. Only towns with stations can be train order stops.

**Rendering**: Everything is drawn in `_draw()` on the root Node2D — no sprites or child nodes. `queue_redraw()` is called each frame. Towns are translucent circles (dashed outline = no station); platforms are filled strips offset to the town-facing side of the track. `V` toggles a per-train reservation overlay (reserved segments tinted in the holder's colour); the HUD shows money plus each train's passenger load, and halted trains show a "Waiting for path..." label.

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
| S | Place signals (click a track to place a two-way signal; click a signal to cycle two-way → one-way → other one-way → removed) |
| V | Toggle the reservation overlay (any phase; drawn while simulating) |
| O | Edit the selected train's orders (click towns with stations) |
| T | Buy a train (added to the roster and selected; undoable) |
| X | Sell the selected train (the roster never goes empty; undoable) |
| , / . | Select the previous / next roster train (also in orders mode) |
| [ / ] | Remove / add a car on the selected train |
| R | Reset the game to the initial empty editing state (works in any phase) |
| Space | Start simulation |
| Escape (while simulating) | Stop the run and return to editing — world, roster, and earnings kept; fleet cost refunded |
