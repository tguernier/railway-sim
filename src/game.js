import { radToDeg } from './vec2.js';
import { NetworkNode } from './network_node.js';
import { TrackNetwork } from './track_network.js';
import { TrackEditor } from './track_editor.js';
import { Town } from './town.js';
import { Train } from './train.js';
import { TrainPlan } from './train_plan.js';
import { GameSnapshot } from './game_snapshot.js';

// The two phases of the game: building the network, then watching it run.
export const GameState = Object.freeze({ EDITING: 0, SIMULATING: 1 });

// Rotating palette of colours assigned to new towns.
export const TOWN_PALETTE = [
  '#6495ed', '#cd5c5c', '#2e8b57',
  '#ffa500', '#9370db', '#5f9ea0',
  '#fa8072', '#008b8b', '#daa520',
];
// Names given to new towns, in placement order (numbered once exhausted).
export const TOWN_NAMES = [
  'Ashford', 'Brookvale', 'Carrow', 'Dunmere', 'Elmstead', 'Fernhill',
  'Glenbury', 'Harwick', 'Ivybridge', 'Kestrel', 'Larkfield', 'Millbrook',
  'Northcote', 'Oakham', 'Pendle', 'Quarry Bank', 'Redmoor', 'Stonely',
  'Thornbury', 'Upwell', 'Valemouth', 'Westerby', 'Yarrow', 'Zennor',
];

// The name for the index-th town placed.
export function townName(index) {
  const base = TOWN_NAMES[index % TOWN_NAMES.length];
  const round = Math.floor(index / TOWN_NAMES.length);
  return round === 0 ? base : `${base} ${round + 1}`;
}

// Colours identifying each train (head car, order badges, route preview).
export const TRAIN_COLORS = [
  '#2f4f4f', '#191970', '#8b0000',
  '#006400', '#663399', '#8b4513',
];

// Game state, rules and input handling (drawing lives in renderer.js). Input
// arrives as plain event objects (see handleInput) so the browser front end
// and the tests drive the same entry point:
//   { type: 'motion', pos }
//   { type: 'mouse', button: 'left' | 'right', shift, pos }
//   { type: 'key', code }   — a KeyboardEvent.code, e.g. 'KeyR', 'Space'
export class Game {
  // Maximum number of undo snapshots retained.
  static UNDO_LIMIT = 50;
  // How long status messages stay on screen, in seconds.
  static STATUS_DURATION = 3.0;
  // Seconds between deadlock checks (walking the wait-for graph is not free).
  static DEADLOCK_CHECK_INTERVAL = 1.0;
  // Every train blocked for this long is treated as a deadlock even when the
  // wait-for graph shows no cycle (net for cases the graph misses).
  static ALL_BLOCKED_TIMEOUT = 10.0;
  // Price of each train car beyond the first, charged at simulation start.
  static COST_PER_CAR = 150.0;
  // Price of each train beyond the first, charged at simulation start.
  static TRAIN_COST = 500.0;

  constructor() {
    this._reset();
    this.showReservations = false;
  }

  // The initial editing state (shared by construction and R).
  _reset() {
    // Current game phase.
    this.state = GameState.EDITING;
    // All towns placed on the map.
    this.towns = [];
    // The track network of junctions and segments.
    this.network = new TrackNetwork();
    // Track editor handling drawing state and track operations.
    this.editor = new TrackEditor(this.network);
    // The running trains, one per roster plan (created at simulation start).
    this.trains = [];
    // Player's current money, earned by delivering passengers.
    this.money = 1000.0;
    // Fleet cost charged when the current run started; refunded on stop.
    this.fleetCostPaid = 0.0;
    // Frame counter used to throttle passenger generation.
    this.frameCount = 0;
    // The town / junction currently under the mouse cursor, if any.
    this.hoveredTown = null;
    this.hoveredJunction = null;
    // Current mouse position in world coordinates (Vec2), or null.
    this.mousePos = null;
    // Edit sub-modes.
    this.editingOrders = false;
    this.placingStation = false;
    this.placingSignal = false;
    // Trains flagged as deadlocked by the last check.
    this.deadlockedTrains = [];
    this._deadlockTimer = 0.0;
    this._allBlockedTime = 0.0;
    // Per-train plans (orders + car count) built in edit mode.
    this.roster = [new TrainPlan()];
    // Index into roster of the train whose orders/cars are being edited.
    this.selectedTrain = 0;
    // Index into TOWN_PALETTE for the next town placed.
    this.nextColorIndex = 0;
    // Transient status/error message and its remaining display time.
    this.statusMessage = '';
    this.statusTimer = 0.0;
    // Snapshots of the editable world, most recent last; U pops and restores.
    this.undoStack = [];
    // Bumped whenever the static world (track, towns, stations) may have
    // changed — the renderer rebuilds its static scene when it moves.
    this.worldVersion = (this.worldVersion ?? 0) + 1;
  }

  // Orders of the selected roster train (the list order editing works on).
  get trainOrders() {
    return this.roster[this.selectedTrain].orders;
  }

  // Number of cars for the selected roster train ([ / ] keys).
  get carCount() {
    return this.roster[this.selectedTrain].carCount;
  }
  set carCount(v) {
    this.roster[this.selectedTrain].carCount = v;
  }

  // Reset the game to its initial editing state, discarding everything built.
  resetGame() {
    this._reset();
  }

  // --- Undo ---

  // Capture a snapshot of the editable state onto the undo stack. Called
  // just before each build action; if the action then fails, the caller
  // discards the entry with _discardUndo().
  _pushUndo() {
    this.undoStack.push(GameSnapshot.capture(this));
    if (this.undoStack.length > Game.UNDO_LIMIT) this.undoStack.shift();
  }

  // Drop the snapshot pushed for an action that turned out to fail.
  _discardUndo() {
    this.undoStack.pop();
  }

  // Snapshot before finishing the track being drawn. A fresh free-draw start
  // junction is not part of the committed world yet, so it is captured
  // without it — undoing a finished track then removes it too.
  _pushUndoForFinish() {
    const start = this.editor.startNode;
    const fresh = this.network.getOutgoing(start).length === 0 && this.network.getIncoming(start).length === 0;
    if (fresh) this.network.nodes.splice(this.network.nodes.indexOf(start), 1);
    this._pushUndo();
    if (fresh) this.network.addNode(start);
  }

  // Revert the last build action by restoring the most recent snapshot.
  _undo() {
    if (this.undoStack.length === 0) {
      this._showStatus('Nothing to undo');
      return;
    }
    this.undoStack.pop().restore(this);
  }

  // --- Input ---

  // Runs for every input event.
  handleInput(event) {
    if (event.type === 'motion') {
      this.mousePos = event.pos;
      this.hoveredTown = this._findTownAt(event.pos);
      this.hoveredJunction = this.editor.findJunctionAt(event.pos);
      return;
    }
    if (event.type === 'mouse') this.mousePos = event.pos;
    this.worldVersion++;

    // R resets the whole game to the initial editing state from any phase.
    if (event.type === 'key' && event.code === 'KeyR') {
      this.resetGame();
      return;
    }
    // V toggles the reservation overlay (drawn while simulating).
    if (event.type === 'key' && event.code === 'KeyV') {
      this.showReservations = !this.showReservations;
      return;
    }
    // ESC while simulating stops the run and returns to editing — the
    // layout, roster, and earnings survive (unlike R, which wipes everything).
    if (this.state === GameState.SIMULATING && event.type === 'key' && event.code === 'Escape') {
      this._stopSimulation('Simulation stopped — back to editing (fleet cost refunded)');
      return;
    }
    if (this.state === GameState.EDITING) this._handleEditInput(event);
  }

  // Handles inputs for editing mode.
  _handleEditInput(event) {
    // U undoes the last build action. Checked before the sub-mode dispatch
    // so it also works while editing orders or placing a station; while
    // drawing a track it is ignored.
    if (event.type === 'key' && event.code === 'KeyU') {
      if (!this.editor.drawing) this._undo();
      return;
    }
    if (this.editingOrders) return this._handleOrderInput(event);
    if (this.placingStation) return this._handleStationInput(event);
    if (this.placingSignal) return this._handleSignalInput(event);

    if (event.type === 'mouse') {
      if (event.button === 'left') {
        if (this.editor.drawing) this._handleDrawClick(event.pos, event.shift);
        else this._handleIdleClick(event.pos, event.shift);
      } else if (event.button === 'right') {
        this._handleRightClick(event.pos);
      }
    }

    if (event.type === 'key') {
      const drawing = this.editor.drawing;
      switch (event.code) {
        case 'Escape': if (drawing) this.editor.cancel(); break;
        case 'Space': this._startSimulation(); break;
        case 'KeyZ': this.editor.undoWaypoint(); break;
        case 'KeyO': if (!drawing) this.editingOrders = true; break;
        case 'KeyP': if (!drawing) this.placingStation = true; break;
        case 'KeyS': if (!drawing) this.placingSignal = true; break;
        case 'KeyT': if (!drawing) this._buyTrain(); break;
        case 'KeyX': if (!drawing) this._sellTrain(); break;
        case 'Comma': this._selectTrain(-1); break;
        case 'Period': this._selectTrain(1); break;
        case 'BracketLeft': this.carCount = Math.max(this.carCount - 1, 1); break;
        case 'BracketRight': this.carCount = Math.min(this.carCount + 1, this.maxCarCount()); break;
      }
    }
  }

  // Handles a left-click while a track is being drawn. Each finish attempt
  // is an undo step: snapshot first, discard the entry if rejected.
  _handleDrawClick(clickPos, shift) {
    const editor = this.editor;
    const junction = editor.findJunctionAt(clickPos);
    if (junction !== null && junction !== editor.startNode && !shift) {
      this._pushUndoForFinish();
      if (!editor.finishAt(junction)) {
        this._discardUndo();
        this._showStatus(this._rejectionMessage());
      }
    } else if (shift) {
      // Shift+click: finish at a junction (existing, on a track, or newly
      // placed) and continue drawing from it.
      if (junction !== null && junction !== editor.startNode) {
        this._pushUndoForFinish();
        if (!editor.finishAndContinue(junction)) {
          this._discardUndo();
          this._showStatus(this._rejectionMessage());
        }
        return;
      }
      const trackHit = editor.findTrackAt(clickPos);
      if (trackHit.length > 0 && !editor.hitTooCloseToStart(trackHit)) {
        this._pushUndoForFinish();
        if (!editor.finishOnTrack(trackHit, true)) {
          this._discardUndo();
          this._showStatus(editor.lastError !== '' ? editor.lastError : this._rejectionMessage());
        }
        return;
      }
      this._pushUndoForFinish();
      const newJunction = NetworkNode.junction(clickPos);
      this.network.addNode(newJunction);
      if (!editor.finishAndContinue(newJunction)) {
        this.network.cleanupOrphan(newJunction);
        this._discardUndo();
        this._showStatus(this._rejectionMessage());
      }
    } else if (junction === null) {
      const trackHit = editor.findTrackAt(clickPos);
      if (trackHit.length > 0) {
        if (editor.hitTooCloseToStart(trackHit)) {
          editor.addWaypoint(clickPos);
        } else {
          this._pushUndoForFinish();
          if (!editor.finishOnTrack(trackHit)) {
            this._discardUndo();
            this._showStatus(editor.lastError !== '' ? editor.lastError : this._rejectionMessage());
          }
        }
      } else {
        editor.addWaypoint(clickPos);
      }
    }
  }

  // Status text explaining the last rejected finish attempt.
  _rejectionMessage() {
    switch (this.editor.rejectionReason) {
      case 'turnout':
        return `Turnout angle too steep (max ${Math.round(radToDeg(TrackEditor.MAX_TURNOUT_ANGLE))}°) — approach in line with the existing track`;
      case 'crossing':
        return `Crosses another track too shallowly (min ${Math.round(radToDeg(TrackEditor.MIN_CROSSING_ANGLE))}°) — cross it more squarely`;
      case 'crossing_platform':
        return 'Tracks cannot cross a station platform';
      default:
        return 'Curve too tight — add waypoints for a gentler bend';
    }
  }

  // Handles a left-click while nothing is being drawn.
  _handleIdleClick(clickPos, shift) {
    if (shift) {
      this._placeTown(clickPos);
      return;
    }
    const junction = this.editor.findJunctionAt(clickPos);
    if (junction !== null) {
      this.editor.startDrawing(junction);
      return;
    }
    const trackHit = this.editor.findTrackAt(clickPos);
    if (trackHit.length > 0) {
      // The split persists even if the drawing is later cancelled, so it is
      // its own undo step.
      this._pushUndo();
      const newJunction = this.editor.splitTrackAtHit(trackHit);
      if (newJunction === null) {
        this._discardUndo();
        this._showStatus(this.editor.lastError);
      } else {
        this.editor.startDrawing(newJunction);
      }
    } else {
      // Free-draw start: place a fresh junction on empty ground.
      const newJunction = NetworkNode.junction(clickPos);
      this.network.addNode(newJunction);
      this.editor.startDrawing(newJunction);
    }
  }

  // Handles a right-click: cancel drawing, delete track, or remove a town.
  _handleRightClick(pos) {
    if (this.editor.drawing) {
      this.editor.cancel();
      return;
    }
    this._rightClickAt(pos);
  }

  // Delete the track or remove the town at a position, as one undo step each.
  _rightClickAt(clickPos) {
    const trackHit = this.editor.findTrackAt(clickPos);
    if (trackHit.length > 0) {
      if (trackHit[0].isPlatformSegment()) {
        this._showStatus('Remove the town to delete its station');
      } else {
        this._pushUndo();
        if (!this.editor.tryDeleteTrackAt(clickPos)) this._discardUndo();
      }
      return;
    }
    const town = this._findTownAt(clickPos);
    if (town !== null) {
      this._pushUndo();
      this.editor.removeTown(town, this.towns, this.roster.map((plan) => plan.orders));
    }
  }

  // Handles inputs while placing a station.
  _handleStationInput(event) {
    if (event.type === 'mouse') {
      if (event.button === 'left') this._tryPlaceStation(event.pos);
      else if (event.button === 'right') this.placingStation = false;
    }
    if (event.type === 'key' && (event.code === 'Escape' || event.code === 'KeyP')) {
      this.placingStation = false;
    }
  }

  // Handles inputs while placing/cycling path signals.
  _handleSignalInput(event) {
    if (event.type === 'mouse') {
      if (event.button === 'left') this._tryPlaceSignal(event.pos);
      else if (event.button === 'right') this.placingSignal = false;
    }
    if (event.type === 'key' && (event.code === 'Escape' || event.code === 'KeyS')) {
      this.placingSignal = false;
    }
  }

  // Place or cycle a signal at a position, as one undo step if it succeeds.
  // The mode stays active so several signals can be placed in a row.
  _tryPlaceSignal(pos) {
    this._pushUndo();
    if (!this.editor.placeOrCycleSignal(pos)) {
      this._discardUndo();
      this._showStatus(this.editor.lastError);
    }
  }

  // Build a station at a position, as one undo step if it succeeds.
  _tryPlaceStation(pos) {
    this._pushUndo();
    const station = this.editor.placeStation(pos, this.towns);
    if (station !== null) {
      this.placingStation = false;
    } else {
      this._discardUndo();
      this._showStatus(this.editor.lastError);
    }
  }

  // Handles inputs while editing train orders.
  _handleOrderInput(event) {
    if (event.type === 'mouse') {
      if (event.button === 'left') this._clickOrderStop(event.pos);
      else if (event.button === 'right') this._popOrderStop();
    }
    if (event.type === 'key') {
      switch (event.code) {
        case 'Escape':
        case 'KeyO':
          this.editingOrders = false;
          break;
        case 'Comma': this._selectTrain(-1); break;
        case 'Period': this._selectTrain(1); break;
        case 'Space':
          this.editingOrders = false;
          this._startSimulation();
          break;
      }
    }
  }

  // Append the clicked town to the selected train's orders. A station may be
  // visited several times in one loop (A → B → C → B), so clicking an
  // existing stop adds it again rather than removing it — removal is
  // right-click (last stop) or the orders panel.
  _clickOrderStop(pos) {
    const town = this._findTownAt(pos);
    if (town !== null) this.addOrder(this.selectedTrain, town);
  }

  // Remove the last train order stop, as one undo step.
  _popOrderStop() {
    const orders = this.trainOrders;
    if (orders.length > 0) this.removeOrder(this.selectedTrain, orders.length - 1);
  }

  // --- Order editing API (keyboard/map input and the orders panel) ---
  // Every successful edit is one undo step; rejected edits burn none and
  // explain themselves in the status line. All are edit-mode only.

  // Append a stop to a train's orders. Rejected when the town has no
  // station, or when it would directly repeat the stop before it (a train
  // cannot travel from a platform to itself).
  addOrder(trainIndex, town) {
    if (this.state !== GameState.EDITING) return false;
    const orders = this.roster[trainIndex].orders;
    if (town.station === null) {
      this._showStatus('Town needs a station before it can be a stop');
      return false;
    }
    if (orders.length > 0 && orders[orders.length - 1] === town) {
      this._showStatus(`${town.name || 'That town'} is already the previous stop — add a different stop in between`);
      return false;
    }
    this._pushUndo();
    orders.push(town);
    return true;
  }

  // Remove one stop from a train's orders.
  removeOrder(trainIndex, orderIndex) {
    if (this.state !== GameState.EDITING) return false;
    const orders = this.roster[trainIndex].orders;
    if (orderIndex < 0 || orderIndex >= orders.length) return false;
    this._pushUndo();
    orders.splice(orderIndex, 1);
    return true;
  }

  // Move a stop up (delta -1) or down (+1) in a train's orders.
  moveOrder(trainIndex, orderIndex, delta) {
    if (this.state !== GameState.EDITING) return false;
    const orders = this.roster[trainIndex].orders;
    const target = orderIndex + delta;
    if (orderIndex < 0 || orderIndex >= orders.length || target < 0 || target >= orders.length) return false;
    this._pushUndo();
    [orders[orderIndex], orders[target]] = [orders[target], orders[orderIndex]];
    return true;
  }

  // Remove every stop from a train's orders.
  clearOrders(trainIndex) {
    if (this.state !== GameState.EDITING) return false;
    const orders = this.roster[trainIndex].orders;
    if (orders.length === 0) return false;
    this._pushUndo();
    orders.length = 0;
    return true;
  }

  // Set a train's car count, clamped to 1..maxCarCount(). Like the [ / ]
  // keys, not an undo step.
  setCarCount(trainIndex, count) {
    if (this.state !== GameState.EDITING) return false;
    this.roster[trainIndex].carCount = Math.max(1, Math.min(count, this.maxCarCount()));
    return true;
  }

  // Make a roster train the one the keyboard and map clicks edit.
  selectTrain(trainIndex) {
    if (trainIndex < 0 || trainIndex >= this.roster.length) return;
    this.selectedTrain = trainIndex;
  }

  // What is wrong with a plan's order list on its own terms, or '' when it
  // is fine. Routing is checked only at simulation start (it needs Dijkstra
  // over the whole loop). The loop wraps, so the last stop must not repeat
  // the first either.
  static orderProblem(plan) {
    const orders = plan.orders;
    if (orders.length < 2) return 'needs at least 2 stops';
    for (let i = 0; i < orders.length; i++) {
      if (orders[i].station === null || orders[i].station.platforms.length === 0) {
        return `stop ${i + 1} has no station`;
      }
      const next = (i + 1) % orders.length;
      if (orders[i] === orders[next]) {
        return `stops ${i + 1} and ${next + 1} are the same station back to back`;
      }
    }
    return '';
  }

  // Fleet cost charged at simulation start: every train and car beyond the
  // first of each.
  fleetCost() {
    let total = (this.roster.length - 1) * Game.TRAIN_COST;
    for (const plan of this.roster) total += (plan.carCount - 1) * Game.COST_PER_CAR;
    return total;
  }

  // Buy a new train (appended to the roster and selected), as one undo
  // step. The purchase price is charged at simulation start.
  _buyTrain() {
    this._pushUndo();
    this.roster.push(new TrainPlan());
    this.selectedTrain = this.roster.length - 1;
  }

  // Sell a train (the selected one by default), as one undo step. The
  // roster never goes empty.
  _sellTrain(trainIndex = this.selectedTrain) {
    if (this.roster.length <= 1) {
      this._showStatus('The last train cannot be sold');
      return;
    }
    this._pushUndo();
    this.roster.splice(trainIndex, 1);
    if (this.selectedTrain > trainIndex) this.selectedTrain -= 1;
    this.selectedTrain = Math.min(this.selectedTrain, this.roster.length - 1);
  }

  // Select the previous/next roster train for editing (wraps around).
  _selectTrain(step) {
    this.selectedTrain = (this.selectedTrain + step + this.roster.length) % this.roster.length;
  }

  // Show a transient status message.
  _showStatus(msg) {
    if (msg === '') return;
    this.statusMessage = msg;
    this.statusTimer = Game.STATUS_DURATION;
  }

  // Returns the town whose circle contains a position, if there is one.
  _findTownAt(pos) {
    if (pos === null) return null;
    for (const town of this.towns) {
      if (pos.distanceTo(town.position) < town.radius) return town;
    }
    return null;
  }

  // Place a town at a position. Towns are not part of the track graph.
  _placeTown(pos) {
    this._pushUndo();
    const col = TOWN_PALETTE[this.nextColorIndex % TOWN_PALETTE.length];
    this.towns.push(new Town(pos, col, townName(this.nextColorIndex)));
    this.nextColorIndex += 1;
  }

  // --- Simulation ---

  // Start the simulation: validate every roster plan, charge the fleet cost,
  // and spawn each train parked at its first stop's platform.
  _startSimulation() {
    if (this.network.segments.length === 0) return;
    const firstStops = new Map();
    for (let i = 0; i < this.roster.length; i++) {
      const plan = this.roster[i];
      const problem = Game.orderProblem(plan);
      if (problem !== '') {
        this._showStatus(`Train ${i + 1} ${problem}`);
        return;
      }
      const stopPlatforms = plan.orders.map((town) => town.station.platforms[0]);
      const unroutable = this.network.firstUnroutableStop(stopPlatforms);
      if (unroutable !== -1) {
        this._showStatus(`Train ${i + 1}: no track route to stop ${unroutable + 1} — connect it to the other stops`);
        return;
      }
      // Each train parks at its first stop's platform, so first stops must
      // be distinct.
      const first = plan.orders[0];
      if (firstStops.has(first)) {
        this._showStatus(`Trains ${firstStops.get(first) + 1} and ${i + 1} start at the same station — pick different first stops`);
        return;
      }
      firstStops.set(first, i);
    }
    const totalCost = this.fleetCost();
    if (this.money < totalCost) {
      this._showStatus(`Not enough money for the fleet (costs ${Math.trunc(totalCost)}: ${Game.TRAIN_COST} per extra train, ${Game.COST_PER_CAR} per extra car)`);
      return;
    }
    this.money -= totalCost;
    this.fleetCostPaid = totalCost;
    this.state = GameState.SIMULATING;
    this.editingOrders = false;
    this.placingStation = false;
    this.placingSignal = false;
    this.deadlockedTrains = [];
    this._deadlockTimer = 0.0;
    this._allBlockedTime = 0.0;
    this.trains = [];
    for (const plan of this.roster) {
      const tr = new Train();
      tr.carCount = plan.carCount;
      tr.orders = plan.orders.slice();
      tr.currentOrderIndex = 0;
      this.trains.push(tr);
      // The train starts parked at its first stop's platform, as if it had
      // just finished a stop there — same anchoring as a departure.
      const startPlatform = plan.orders[0].station.platforms[0];
      this._dispatchToNextOrder(tr, startPlatform.segment.nodeEnd, startPlatform.segment);
      if (this.state !== GameState.SIMULATING) return;
      if (tr.hasRoute()) {
        tr.resumeFromStop(startPlatform.segment, tr.stopPointOn(startPlatform.segment), startPlatform.reverseSegment);
        // Two platforms can still exclude each other through a flat crossing
        // — a train that cannot hold the track it stands on must not spawn.
        if (!tr.tryReserve([tr.currentSegment()])) {
          this._stopSimulation('Two trains start on tracks that cross — move a station');
          return;
        }
      }
    }
    // Only after every train's footprint is seeded may anyone reserve ahead
    // — extending earlier could claim a path through a not-yet-spawned
    // train. A failure just means the train starts out waiting.
    for (const tr of this.trains) tr.tryExtendReservation();
  }

  // Dispatch a train toward its next order stop's platform via Dijkstra.
  // `arriving` is the segment the train stands on (its heading at fromNode);
  // a stationary train may depart forward or reverse back along it.
  _dispatchToNextOrder(tr, fromNode, arriving) {
    tr.advanceOrder();
    const target = tr.currentOrderTown();
    if (target === null || target.station === null || target.station.platforms.length === 0) {
      this._stopSimulation('A stop lost its station — simulation stopped');
      return;
    }
    tr.network = this.network;
    tr.targetPlatform = target.station.platforms[0];
    const route = this.network.findRouteToPlatform(fromNode, tr.targetPlatform, tr, arriving, true);
    if (route.length > 0) {
      tr.setRoute(route);
      // The route ends with the platform traversal — halt the head so the
      // consist is centered on the platform.
      tr.stopProgress = tr.stopPointOn(route[route.length - 1]);
    } else {
      this._stopSimulation('No track route to the next stop — simulation stopped');
    }
  }

  // Largest consist size that fits within a station platform.
  maxCarCount() {
    return Math.trunc((TrackEditor.PLATFORM_LENGTH + Train.CAR_GAP) / (Train.CAR_LENGTH + Train.CAR_GAP));
  }

  // Halt the simulation and return to editing mode. The world is kept; only
  // the running trains despawn, and the fleet cost is refunded.
  _stopSimulation(msg) {
    this.state = GameState.EDITING;
    for (const tr of this.trains) tr.releaseAll();
    this.trains = [];
    this.deadlockedTrains = [];
    this._allBlockedTime = 0.0;
    this.money += this.fleetCostPaid;
    this.fleetCostPaid = 0.0;
    this._showStatus(msg);
    this.worldVersion++;
  }

  // Handle one simulation tick.
  process(delta) {
    if (this.statusTimer > 0) this.statusTimer -= delta;
    if (this.state !== GameState.SIMULATING) return;
    if (this.frameCount > 9) {
      for (const town of this.towns) town.generatePassengers();
      this.frameCount = 0;
    }
    for (const tr of this.trains) {
      this._updateTrain(tr, delta);
      if (this.state !== GameState.SIMULATING) break; // a dispatch failure stopped the run
    }
    if (this.state === GameState.SIMULATING) this._updateDeadlockDetection(delta);
    this.frameCount += 1;
  }

  // Advance one train by one tick, then handle its stop lifecycle.
  _updateTrain(tr, delta) {
    tr.move(delta);
    if (tr.dwellRemaining > 0) return;
    if (tr.atPendingStop()) {
      if (tr.boardedThisLeg) this._departFromStop(tr);
      else this._arriveAtPlatform(tr);
    } else if (tr.hasCompletedRoute() && tr.boardedThisLeg) {
      const last = tr.route[tr.route.length - 1];
      this._dispatchToNextOrder(tr, last.nodeEnd, last);
    }
  }

  // Deadlock detection. Once per DEADLOCK_CHECK_INTERVAL, walk the wait-for
  // graph — revisiting a train on the walk means a cycle. As a net, every
  // train being blocked for ALL_BLOCKED_TIMEOUT counts too. Deadlocked
  // trains are flagged; the simulation keeps running.
  _updateDeadlockDetection(delta) {
    const allBlocked = this.trains.length > 0 && this.trains.every((tr) => tr.waitingForTrack);
    this._allBlockedTime = allBlocked ? this._allBlockedTime + delta : 0.0;
    this._deadlockTimer += delta;
    if (this._deadlockTimer < Game.DEADLOCK_CHECK_INTERVAL) return;
    this._deadlockTimer = 0.0;
    this.deadlockedTrains = this._findDeadlockCycle();
    if (this.deadlockedTrains.length === 0 && this._allBlockedTime > Game.ALL_BLOCKED_TIMEOUT) {
      this.deadlockedTrains = this.trains.slice();
    }
    if (this.deadlockedTrains.length > 0) {
      this._showStatus('Deadlock — trains are waiting on each other (ESC to edit signals)');
    }
  }

  // The trains forming a wait-for cycle, or [] when none exists. A walk only
  // follows blocked trains, so a queue behind a moving or dwelling leader
  // terminates and is not flagged.
  _findDeadlockCycle() {
    for (const tr of this.trains) {
      if (!tr.waitingForTrack) continue;
      const walk = [];
      let cur = tr;
      while (cur !== null && cur.waitingForTrack) {
        const pos = walk.indexOf(cur);
        if (pos >= 0) return walk.slice(pos);
        walk.push(cur);
        cur = cur.blockedBy;
      }
    }
    return [];
  }

  // The dwell is over: dispatch the next leg while the train sits at its
  // stop point. A leg leaving back the way the train came in turns it around
  // at the platform; otherwise it rolls forward onto the new route.
  _departFromStop(tr) {
    const seg = tr.currentSegment();
    tr.stopProgress = -1.0; // dwell over — pull away
    if (seg === null || !seg.isPlatformSegment()) return; // dispatch when the route completes
    const progress = tr.segmentProgress;
    const p = seg.platform;
    const reverseSeg = seg === p.segment ? p.reverseSegment : p.segment;
    this._dispatchToNextOrder(tr, seg.nodeEnd, seg);
    if (this.state === GameState.SIMULATING && tr.hasRoute()) {
      tr.resumeFromStop(seg, progress, reverseSeg);
      // Re-take the segment the consist sits on (setRoute released it).
      if (!tr.tryReserve([tr.currentSegment()])) {
        this._stopSimulation('Track conflict at a station — simulation stopped');
        return;
      }
      // Reserve out to the first safe waiting point. On failure the train
      // keeps sitting at the platform and retries every move.
      tr.tryExtendReservation();
    }
  }

  // A train has halted at its stop point: unload, board, and wait out the
  // dwell time.
  _arriveAtPlatform(tr) {
    tr.boardedThisLeg = true;
    const seg = tr.currentSegment();
    if (seg !== null && seg.isPlatformSegment() && seg.platform.station !== null) {
      const town = seg.platform.station.town;
      if (town !== null) {
        this.money += tr.unload() * 10;
        tr.boardFrom(town);
      }
    }
    tr.dwellRemaining = tr.dwellTime;
  }

  // --- Queries used by the renderer ---

  // Whether every roster train has enough stops to start the simulation.
  readyToStart() {
    if (this.network.segments.length === 0) return false;
    return this.roster.every((plan) => plan.orders.length >= 2);
  }

  // A signal shows green while its holder's reservation continues past it.
  signalIsGreen(seg) {
    const tr = seg.reservedBy;
    if (tr === null) return false;
    const idx = tr.route.indexOf(seg);
    return idx >= 0 && idx < tr.limitIndex;
  }

  // The train whose reservation currently owns a crossing, or null.
  crossingHolder(crossing) {
    for (const track of [crossing.trackA, crossing.trackB]) {
      if (track === null) continue;
      if (track.reservedBy !== null) return track.reservedBy;
      if (track.reverse !== null && track.reverse.reservedBy !== null) return track.reverse.reservedBy;
    }
    return null;
  }

  // The hint line for the current mode.
  hintText() {
    if (this.state === GameState.SIMULATING) {
      return `Money: ${Math.trunc(this.money)} | ESC to stop and edit | R to reset | V to toggle reservations`;
    }
    if (this.editingOrders) {
      let hint = `ORDERS (Train ${this.selectedTrain + 1}): Click towns with stations to append stops (repeats allowed) | RIGHT-CLICK to remove last | , . to switch train | U to undo | ESC/O to finish`;
      if (this.readyToStart()) hint += ' | SPACE to start simulation';
      return hint;
    }
    if (this.placingStation) return "STATION: Click a track inside a town's circle | ESC/P to cancel";
    if (this.placingSignal) {
      return 'SIGNALS: Click a track to place | Click a signal to cycle two-way > loose one-way > strict one-way > remove | ESC/S to finish';
    }
    if (this.editor.drawing) {
      let hint = 'Click to add curve points | Click junction/track to finish | SHIFT+Click to finish at a new junction | ESC to cancel | Z to undo';
      if (this.editor.lastFinishRejected) {
        hint = (this.editor.rejectionReason === 'turnout'
          ? 'TURNOUT ANGLE TOO STEEP — approach at a shallower angle | '
          : 'CURVE TOO TIGHT — add waypoints for a gentler bend | ') + hint;
      }
      return hint;
    }
    let hint = 'SHIFT+CLICK to place towns | CLICK to draw tracks | P to place station | S to place signals | RIGHT-CLICK to delete | U to undo | O to edit orders | R to reset';
    if (this.readyToStart()) hint += ' | SPACE to start';
    return hint;
  }

  // One-line roster readout (shown in the selected train's colour), or ''
  // when it should not be shown.
  rosterLine() {
    if (this.state !== GameState.EDITING) return '';
    if (this.placingStation || this.placingSignal || (this.editor.drawing && !this.editingOrders)) return '';
    return `Train ${this.selectedTrain + 1}/${this.roster.length} — cars: ${this.carCount}, stops: ${this.trainOrders.length} | T to buy | , . to select | X to sell | [ ] cars`;
  }
}
