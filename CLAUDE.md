# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A railway company simulator in static HTML + JavaScript with basic 3D graphics (three.js). Players place towns, draw Bézier-curved tracks, build stations to connect towns to the railway, then run trains that pick up and deliver passengers to earn money. The game logic is 2D (top-down, pixel coordinates); only the view is 3D.

## Running the Project

There is no build step, no npm dependencies, and no lint tool. three.js 0.160.0 is vendored at `vendor/three.module.js` and mapped by the importmap in `index.html`, so the game works offline. Serve the repo root and open it (ES modules don't load from `file://`):
```
python3 -m http.server 8000    # then http://localhost:8000
```

Run the unit tests (Node 22+) with:
```
node tests/run_tests.js
```

Pushes to `main` run the tests and publish `index.html`, `src/` and `vendor/` to GitHub Pages (`.github/workflows/deploy-pages.yml`).

## Architecture

All modules are plain ES classes in `src/`. Back-references (`Station.town`, `Platform.station`, `TrackSegment.platform`, `reverse`, `reservedBy`, `blockedBy`, crossing tracks) are ordinary object references — the garbage collector handles cycles.

```
main.js                   — DOM input → Game.handleInput, camera controls, frame loop, HUD text
renderer.js               — three.js scene; reads Game state, never mutates it
game.js (Game)            — game state, rules, input handling, simulation tick
├── TrackNetwork          — directed graph of junctions; Dijkstra pathfinding
│   ├── NetworkNode[]     — junction nodes (position only)
│   ├── TrackSegment[]    — Bézier curve path between two junctions (Curve2D)
│   └── TrackCrossing[]   — flat crossing: two tracks that cross but don't
│                           connect; mutual exclusion only, no connectivity
├── TrackEditor           — drawing state, split/delete, station placement
├── Town[]                — circle on the map; color, radius, passenger pool
│   └── Station           — links a town to the track via Platform(s)
│       └── Platform      — forward/reverse platform segment pair + side/width
├── TrainPlan[]           — edit-mode roster: per-train orders + car count
├── Train[]               — moves along a route, boards/unloads passengers,
│                           holds track reservations (one Train per TrainPlan)
└── GameSnapshot[]        — undo stack: deep copies of the editable world
```

`vec2.js` provides the immutable `Vec2` (Godot-compatible semantics: `orthogonal()` is `(y, -x)`, `angleDifference` wraps to [-π, π]) plus `Rect2` and segment intersection; `curve2d.js` is a Bézier chain baked to a ~5 px polyline (`BAKE_INTERVAL`) that all length, sampling, and closest-point queries run on.

**Input is plain event objects** — `{type: 'motion', pos}`, `{type: 'mouse', button: 'left'|'right', shift, pos}`, `{type: 'key', code}` (a `KeyboardEvent.code`) — so the browser and the tests drive the same `Game.handleInput`. `main.js` raycasts the pointer onto the ground plane to get `pos`, and keeps the camera keys (arrows, Q/E) and middle-button drags to itself.

**Towns are not part of the track graph.** A town is a catchment circle that accumulates passengers. Building a station (on a track inside the town's radius) is what connects it to the railway: the hit segment is split into approach tracks and a platform segment with entry/exit junction nodes.

**Game states:** `EDITING` (place towns, draw tracks, build stations, configure the train roster) → `SIMULATING` (trains run, money accumulates). `Escape` while simulating stops the run and returns to editing with the world intact (`_stopSimulation`): trains despawn, reservations release, and the per-run fleet cost (`fleetCostPaid`) is refunded, so stop → tweak signals → restart is money-neutral while fares earned are kept. `R` is the destructive full reset.

### Key systems

**Track drawing** (`game.js`, `track_editor.js`): Click a junction or empty ground to start a track (empty ground creates a fresh junction), click empty space to add curve waypoints, click a junction or track to finish. Creating a segment automatically creates its reverse. `TrackSegment` wraps a `Curve2D` and exposes `positionAt(t)`, `angleAt(t)`, and `length()`. Tracks are validated for curve radius and turnout angle at both ends. A finish click on a track splits it into a junction (`finishOnTrack`) — including the segment the drawing departed from, which is how a passing loop rejoins its own line as a pair of 3-way junctions. Waypoint-vs-join disambiguation is by distance from the start node (`hitTooCloseToStart`): a short sliver zone (`MIN_JOIN_DISTANCE`) on any track, a long one (`DEPARTURE_JOIN_DISTANCE`) on segments touching the start node, because the turnout limit forces departing loops to hug their line at first. A rejoin whose curve never swings `MIN_LOOP_OFFSET` clear of the segment it left is rejected (it would bury an identical-looking track under the original). Parallel tracks between the same two junctions are legal, so hit-testing (`findTrackAt`) and rendering (`Renderer._physicalTracks`) deduplicate the two directions of a physical track by reverse-twin identity, never by endpoint positions.

**Stations** (`TrackEditor.placeStation`): Press `P`, click a track inside a town's circle. Validates: town has no station yet, segment ≥ `PLATFORM_LENGTH + 20`, platform span gentle enough, not already a platform. Span ends snap to existing endpoints when close (5% of length or `HIT_RADIUS`). Platform segments are protected — no splitting (junctions) and no deletion while the station exists; removing the town removes the station.

**Train movement** (`train.js`): Advances `segmentProgress` (0–1) along the current `TrackSegment`. Capacity is 20 passengers per car, speed is 150 px/sec. While `dwellRemaining > 0` the train is stopped at a station and `move()` only counts the timer down.

**Track reservations — OpenTTD-style path signals** (`train.js`, `track_segment.js`): `TrackSegment.reservedBy` marks the train holding a segment; a segment is blocked for a train if it, *its reverse twin*, or a track it meets at a **flat crossing** is held by another train (head-on exclusion on the same physical track, plus diamond exclusion — see Flat crossings). A train reserves a **path**: `Train.tryExtendReservation()` collects route segments from `limitIndex + 1` through the next *safe waiting point* — the first segment with `exitSignal` for its direction, or the end of the route (the destination platform) — and `tryReserve`s the slice atomically (all-or-nothing; `limitIndex` unchanged on failure). The head may not advance past `route[limitIndex]`; at the boundary it re-attempts the extension and on failure halts with `waitingForTrack` set (retried every `move()`), recording the holder in `blockedBy` (the wait-for graph edge). Segments release when the **tail** clears them (the `_trimHistory()` hook) and on `setRoute()`; after a stop, `Game` re-reserves the segment the consist sits on, then extends. At simulation start every train's footprint is seeded **before** anyone extends (extending earlier would claim paths through unspawned trains).

**Path signals** (`track_editor.js`, `game.js`): `S` enters signal mode; clicking a track calls `placeOrCycleSignal` — it splits the segment (`splitTrackAtHit`) and sets `exitSignal` on both directed segments arriving at the new junction (a two-way signal). Clicking an existing signal junction cycles two-way → loose one-way → other loose one-way → strict one-way → other strict one-way → removed (`SignalState`, `_applySignalState`); junctions with ≠2 incoming plain segments are rejected (no signals on real junctions or platforms — the platform is its own safe waiting point). One-way signals additionally affect *routing* against their direction, and `TrackSegment.looseOneWay` picks how: **strict** (the default for a bare `exitSignal`) bars it outright, **loose** merely penalizes it (see Routing). The two flags always travel together via `TrackSegment.copySignalFrom` — splits, station placement, and `GameSnapshot` all use it, so a loose one-way can never be resurrected as a strict one. Rendering: a mast with a lamp on the right-hand side of the direction served, red by default, green while a reservation passes *through* it; a strict one-way adds a dark red no-entry bar on the far side of the track (a loose one leaves that side clear, since traffic may still come through it).

**Loose vs strict one-way signals**: the difference that matters is the *waiting point*, not the routing rule. `exitSignal` is per direction, so a one-way signal is a place where trains going the signalled way may stand and trains coming the other way may not — the latter must reserve straight through to their next stopping place. On a shared single-track approach to a junction that is exactly what stops a train from halting *past* the junction and fouling it: it holds back at the previous signal instead (e.g. on its branch). Strict one-ways cannot be used there because the line has to carry both directions; loose ones can. Strict remains the right tool for genuinely directional track (passing-loop branches), where barring the wrong way is the point.

**Flat crossings — diamonds** (`track_crossing.js`, `track_network.js`, `track_segment.js`): two tracks that cross in space without connecting. A crossing adds **no connectivity** — it is deliberately *not* a `NetworkNode` (that would let trains turn at the diamond, invite signals and splits onto it, and fail turnout validation). It is purely a mutual-exclusion relation, and it carries no `reservedBy` of its own: whether a diamond is locked is derived from the two tracks' existing reservations, so release, `_trimHistory`, and turnaround logic are untouched. `Train.blockingTrain()` walks `seg.crossings` after the segment and its twin, and everything downstream (`isBlocked`, `tryReserve`, `routeCost`, Dijkstra relaxation, the `blockedBy` wait-for graph) inherits diamond exclusion from that one place — including routing *around* an occupied diamond via `BLOCKED_PENALTY`. Each crossing is registered on all four directed segments of the two tracks so lookup from any direction is one array walk. Detection is geometric and automatic in `TrackNetwork.addSegment` — the chokepoint every structural edit passes through, so crossings cannot drift from the geometry; `GameSnapshot` opts out (`detectCrossings = false`) and clones the known set through its `segmentMap` instead, since re-detecting per segment would make undo capture quadratic. Pairs sharing a node are exempt (`sharesNode`), and intersections within `CROSSING_NODE_CLEARANCE` of an endpoint are discarded — together these are what let a crossover arm terminate on the track it joins without registering a spurious diamond, so a scissors yields exactly one crossing (arm against arm) while trains running straight through on either main line are unaffected. Exclusion is at segment granularity, not the diamond itself: holding any part of a long line locks the whole crossing track. That matches the granularity path signalling already gives, and the player's lever is the same — a signal near the diamond splits the segment and tightens the block. The editor rejects crossings shallower than `MIN_CROSSING_ANGLE` (12°, reason `"crossing"`) and any crossing over a platform (`"crossing_platform"`), and `placeStation` refuses a platform span containing an existing diamond. Rendered as a hollow grey lozenge — deliberately unlike a junction's solid white diamond — tinted in the holder's colour under the `V` overlay.

**Deadlock detection** (`game.js`): once per second (`DEADLOCK_CHECK_INTERVAL`), walk the wait-for graph (`Train.blockedBy`) from each blocked train — a revisit on the walk is a cycle ⇒ deadlock; as a net, all trains simultaneously blocked for > `ALL_BLOCKED_TIMEOUT` (10 s) counts too. Deadlocked trains get a red ring and a status message; the simulation keeps running (the player resolves it with `Escape` — stop, fix the signals, restart — or wipes with `R`). A queue behind a moving or dwelling leader is *not* flagged.

**Multiple trains** (`game.js`, `train_plan.js`): The edit-mode roster is an array of `TrainPlan` (orders + car count each); `T` buys a train, `X` sells, `,`/`.` switch the selected train, and `O`/`[ ]` edit the selected plan (`Game.trainOrders`/`Game.carCount` are accessors forwarding to it). Simulation start validates every plan's loop, requires **distinct first stops** (each train spawns parked at its first stop's platform), and charges `TRAIN_COST` (500) per extra train plus `COST_PER_CAR` (150) per extra car. Each train is drawn in its `TRAIN_COLORS` hue (head car, order badges, order-loop preview, HUD swatch).

**Routing** (`track_network.js`): Dijkstra over the directed graph; `findRoute(from, to, forTrain = null, arriving = null, exitSeg = null, allowReversal = false)` returns an array of `TrackSegment`. **The search is direction-aware — no switchbacks**: its state is the directed segment a path arrives on (visited is keyed per segment, not per node), and a junction transition is only legal when `canContinue(prev, next)` holds — `next` is not `prev`'s reverse twin and the departure heading stays within `MAX_THROUGH_ANGLE` (90°) of the arrival heading, so a train never bends backward through a junction the way no real turnout allows. Reversal is permitted only as the *first* hop with `allowReversal` (a train standing at a station stop departing back along its own segment — how dead-end termini turn around); `arriving` seeds the heading at `from`, and `exitSeg` makes the goal count only when the path can continue onto it (used so the platform traversal appended by `findRouteToPlatform` is always physically takeable). Dispatch (`Game._dispatchToNextOrder`) passes the platform segment the train stands on with `allowReversal = true`; the mid-route re-path (`Train._repathProvisionalTail`) passes `route[limitIndex]` without reversal. **One-way signals oppose routing against them**: `oneWayAgainst(seg)` returns `OneWay.NONE`/`LOOSE`/`STRICT` for a directed segment whose start junction hosts a signal serving only the opposite direction (the segment's twin arriving there carries `exitSignal`, no other arriving segment does, and `looseOneWay` on that twin picks loose vs strict). `STRICT` skips the segment outright — this is what makes directional passing-loop branches work, forcing opposing trains onto different branches to pass inside the loop. `LOOSE` instead adds `ONE_WAY_PENALTY` (2 000) to the relaxation, so the direction is taken only when nothing better exists. The penalty sits *below* `BLOCKED_PENALTY` deliberately: running the wrong way past a loose signal is safe (reservations still keep trains apart), so a train prefers it to queueing behind occupied track — strict is the lever when that is not wanted. `routeCost` mirrors both penalties, since the lookahead compares its output against `findRoute`'s. `firstUnroutableStop` inherits both rules (it walks the loop with each leg's `arriving` platform traversal and `allowReversal = true`, mirroring dispatch), so mis-signalled layouts and order loops needing a mid-route switchback (e.g. two stations on branches fanning the same way off one junction) are rejected at simulation start — but it stays reservation-blind (always called without `forTrain`), so layouts are never rejected because of where trains happen to stand. Dispatch uses `findRouteToPlatform(from, platform, forTrain)`, which enters at the cheaper platform end and always finishes by traversing the platform segment.

**Adaptive routing — per-signal lookahead** (`track_network.js`, `train.js`): with `forTrain` given, a segment unavailable to that train (`Train.isBlocked` — held by another train directly or via the reverse twin) costs `BLOCKED_PENALTY` (10 000) extra: traffic is a *penalty* to route around, never a reason to fail, and with no free alternative the shortest route is still returned. The train's own reservations cost nothing; `oneWayAgainst` stays layout rather than traffic — a hard skip when strict, a fixed `ONE_WAY_PENALTY` when loose, neither of which depends on who is where. Both dispatch sites pass the train (and set `Train.network`/`Train.targetPlatform`), so the initial branch and platform-entry-end choices avoid parked traffic. The payoff is `Train._repathProvisionalTail`, run inside **every** `tryExtendReservation` before the slice is reserved: the provisional tail beyond `limitIndex` is re-pathed from `route[limitIndex].nodeEnd` to `targetPlatform` with penalties, and a better tail is spliced onto the kept prefix — history, indices, and held reservations intact (the discarded tail lies beyond `limitIndex`, so it held nothing) — then `stopProgress` is recomputed via `Train.stopPointOn` (the new tail may enter the destination platform from the other end). Hysteresis: a *blocked* tail is abandoned for any strictly cheaper one, a *free* tail only for one cheaper by `SWITCH_MARGIN` (`CAR_LENGTH`×10), so near-equal branches never flip-flop (`network.routeCost` does the comparing). Because the re-path runs while the train is still rolling toward the boundary, a train facing a blocked loop branch diverts onto the free one **at speed**, and convoy followers spread across parallel branches; a blocked train's per-frame reservation retries re-path on a throttle (`Train.blockedTime` ≥ `REROUTE_RETRY_INTERVAL`, 1 s; `_wasWaiting` distinguishes a fresh boundary from a blocked retry). Skipped while the train is still anchored at its departure platform (`limitIndex == -1`, before the first extension): the turnaround/roll-through anchoring came from the route's first segment and would not survive a tail swap, and dispatch was already traffic-aware. There is deliberately no `getOutgoing(node).length < 2` early-out: outgoing counts the reverse twin (only dead ends have < 2), and a train waiting at an approach signal diverges further on, so skipping there would break exactly the passing-loop case. This is what makes passing loops work with plain **two-way** signals. The re-path happens inside `move()` and thus before deadlock detection each tick, and a fruitless re-path leaves `blockedBy` in place, so genuine deadlocks still flag. The train halts at the middle of the platform (`Train.stopProgress`, set via `stopPointOn` on dispatch): `Game._arriveAtPlatform()` unloads/boards and starts a 2 s dwell (`Train.dwellTime`); when it expires `Game._departFromStop()` dispatches the next order from the platform's exit node and re-anchors the train via `Train.resumeFromStop()` — if the new route leaves along the platform's reverse segment (a dead-end station) the train turns around in place, otherwise the platform segment is prepended so the train rolls forward through its remainder onto the new route (`Train.boardedThisLeg` marks the stop as done for the leg).

**Undo** (`game_snapshot.js`, `game.js`): every build action calls `_pushUndo()` first (a deep `GameSnapshot.capture` of towns, network, roster) and `_discardUndo()` if the action then fails, so rejected clicks never burn an undo. `U` pops and restores (`UNDO_LIMIT` 50). A fresh free-draw start junction is captured without itself (`_pushUndoForFinish`), so undoing a finished track removes it too.

**Passenger economy** (`game.js`): Towns generate 0–0.5 passengers every 10 frames whether or not they have a station. Delivering passengers earns `10 × passenger_count`. Starting money: 1000; the fleet cost (extra trains and cars) is deducted at simulation start. Only towns with stations can be train order stops.

**Rendering** (`renderer.js`): game pixels map onto the ground plane as `(x, 0, y)` — one pixel is one world unit, and the default camera looks north (-z) at the original 1152×648 play area. The scene has three layers: **static** (towns with houses kept clear of the track, ballast/sleepers/rails, platforms with shelters, junction diamonds, crossing lozenges, signal masts) rebuilt whenever `Game.worldVersion` changes — `Game` bumps it on every non-motion input, undo, reset, and simulation stop, so any new mutation path must bump it too; **trains**, pooled meshes re-posed each frame from `Train.pointBehind`; and **overlay** (drawing preview coloured by curvature, waypoints, hover rings, order-loop previews, deadlock rings) rebuilt every frame, plus the `V` reservation tint rebuilt when the reservation set changes. Signal lamps and crossing tints are recoloured per frame. Text (order badges, "Waiting: N", train loads, "Boarding..."/"Waiting for path...", turnout-angle readouts) is drawn on a 2D canvas over the WebGL one at projected positions; the hint line, roster line, per-train loads and status message are DOM elements in `index.html`, filled from `Game.hintText()`/`rosterLine()`.

**Tests** (`tests/`): a tiny harness (`test_base.js`: `suite`, `t`, `eq`, `approx`, `gt`, `isTrue`, `isFalse`) and one file per module; simulation tests drive a real `Game` with `process(1 / 60)` ticks. `window.railway` exposes `{ game, view }` in the browser for console debugging and automated checks.

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
| S | Place signals (click a track to place a two-way signal; click a signal to cycle two-way → loose one-way ↔ → strict one-way ↔ → removed) |
| V | Toggle the reservation overlay (any phase; drawn while simulating) |
| O | Edit the selected train's orders (click towns with stations) |
| T | Buy a train (added to the roster and selected; undoable) |
| X | Sell the selected train (the roster never goes empty; undoable) |
| , / . | Select the previous / next roster train (also in orders mode) |
| [ / ] | Remove / add a car on the selected train |
| R | Reset the game to the initial empty editing state (works in any phase) |
| Space | Start simulation |
| Escape (while simulating) | Stop the run and return to editing — world, roster, and earnings kept; fleet cost refunded |

### Camera (any phase)

| Action | Effect |
|---|---|
| Mouse wheel | Zoom toward the cursor |
| Middle-drag | Pan (the grabbed ground point follows the cursor) |
| Shift+Middle-drag | Orbit (yaw and pitch) |
| Arrow keys | Pan |
| Q / E | Rotate |
