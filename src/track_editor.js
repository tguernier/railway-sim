import { Vec2, clamp, degToRad, angleDifference, erase } from './vec2.js';
import { NetworkNode } from './network_node.js';
import { TrackSegment } from './track_segment.js';
import { TrackNetwork } from './track_network.js';
import { Station } from './station.js';
import { Platform } from './platform.js';

// The signal state carried by the two directions arriving at a node, in
// click order. Loose comes before strict: it is the milder of the two, and
// the one that suits a line still worked in both directions.
export const SignalState = Object.freeze({
  NONE: 0,
  TWO_WAY: 1,
  LOOSE_A: 2,   // one-way serving a, opposing direction penalized
  LOOSE_B: 3,
  STRICT_A: 4,  // one-way serving a, opposing direction barred
  STRICT_B: 5,
});
const SIGNAL_STATE_COUNT = 6;

// Handles track drawing state and track manipulation operations on a TrackNetwork.
export class TrackEditor {
  // Hit-test distance for clicking on a track segment or junction.
  static HIT_RADIUS = 15.0;
  // A track hit closer than this to the drawing's start node is treated as a
  // waypoint click, not a join — joining there would create a sliver segment.
  static MIN_JOIN_DISTANCE = TrackEditor.HIT_RADIUS * 2.0;
  // On segments touching the start node the waypoint zone extends farther:
  // the turnout limit forces shallow departures, so a loop's early waypoint
  // clicks inevitably land within the hit radius of the track being left.
  static DEPARTURE_JOIN_DISTANCE = 150.0;
  // A track rejoining a segment it departs from must swing at least this far
  // clear of it somewhere, or the two would overlap indistinguishably.
  static MIN_LOOP_OFFSET = TrackEditor.HIT_RADIUS * 1.0;
  // Minimum allowed radius of curvature for a track segment (in pixels).
  static MIN_CURVE_RADIUS = 80.0;
  // Shallowest legal flat crossing. Below this the two tracks read as one
  // overlapping line.
  static MIN_CROSSING_ANGLE = degToRad(12.0);
  // Maximum allowed divergence angle between a new track and the nearest
  // existing track at a shared node (turnout angle). 15 degrees.
  static MAX_TURNOUT_ANGLE = degToRad(15.0);
  // Half the length of a station platform along the track (in pixels).
  static PLATFORM_HALF_LENGTH = 60.0;
  // Full length of a station platform along the track (in pixels).
  static PLATFORM_LENGTH = TrackEditor.PLATFORM_HALF_LENGTH * 2.0;
  // Minimum segment length that can host a platform.
  static MIN_STATION_SEGMENT_LENGTH = TrackEditor.PLATFORM_LENGTH + 20.0;

  constructor(network) {
    // The track network this editor operates on.
    this.network = network;
    // Whether the player is currently drawing a track.
    this.drawing = false;
    // The network node where the current track being drawn starts.
    this.startNode = null;
    // Intermediate waypoints for the track currently being drawn.
    this.waypoints = [];
    // Set to true when the last finish attempt was rejected.
    this.lastFinishRejected = false;
    // Rejection reason: "curve", "turnout", "crossing" or "crossing_platform".
    this.rejectionReason = '';
    // Human-readable reason the last station/split/delete operation failed.
    this.lastError = '';
  }

  // Start drawing a new track from a node.
  startDrawing(node) {
    this.drawing = true;
    this.startNode = node;
    this.waypoints = [];
  }

  // Add a curve waypoint to the track being drawn.
  addWaypoint(pos) {
    this.waypoints.push(pos);
  }

  // Remove the last waypoint from the track being drawn.
  undoWaypoint() {
    this.waypoints.pop();
  }

  // Finish drawing: create a bidirectional track to the target node and
  // reset. Returns false if the track is invalid (segment not created).
  finishAt(node) {
    const reason = this._validateTrack(this.startNode, node, this.waypoints);
    if (reason !== '') {
      this.lastFinishRejected = true;
      this.rejectionReason = reason;
      return false;
    }
    this.lastFinishRejected = false;
    this.rejectionReason = '';
    this.createBidirectionalTrack(this.startNode, node, this.waypoints);
    this.cancel();
    return true;
  }

  // Finish drawing to a node, then immediately start a new drawing from it.
  finishAndContinue(node) {
    const reason = this._validateTrack(this.startNode, node, this.waypoints);
    if (reason !== '') {
      this.lastFinishRejected = true;
      this.rejectionReason = reason;
      return false;
    }
    this.lastFinishRejected = false;
    this.rejectionReason = '';
    this.createBidirectionalTrack(this.startNode, node, this.waypoints);
    this.startNode = node;
    this.waypoints = [];
    return true;
  }

  // Validate a candidate track for curve radius, turnout angle and crossings.
  // Returns "" if valid, or a reason string.
  _validateTrack(from, to, wps) {
    const candidate = new TrackSegment(from, to, wps);
    if (candidate.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) return 'curve';
    if (!this._validateTurnoutAngle(from, candidate, true) || !this._validateTurnoutAngle(to, candidate, false)) {
      return 'turnout';
    }
    return this.validateCrossings(candidate);
  }

  // Check a candidate segment against every track it would cross. Returns ""
  // if valid, "crossing" for a diamond too shallow to read as two tracks, or
  // "crossing_platform" for one over a station platform. Crossings at a
  // shared node are exempt.
  validateCrossings(candidate) {
    const seen = new Set();
    for (const other of this.network.segments) {
      if (seen.has(other)) continue;
      seen.add(other);
      if (other.reverse !== null) seen.add(other.reverse);
      if (TrackNetwork.sharesNode(candidate, other)) continue;
      for (const point of TrackSegment.crossingPoints(candidate, other)) {
        if (other.isPlatformSegment()) return 'crossing_platform';
        if (TrackSegment.crossingAngle(candidate, other, point) < TrackEditor.MIN_CROSSING_ANGLE) return 'crossing';
      }
    }
    return '';
  }

  // Check that a new segment's departure angle at a node doesn't diverge too
  // much from any existing track.
  _validateTurnoutAngle(node, seg, isStart) {
    const existing = this.network.departureAnglesAt(node);
    if (existing.length === 0) return true;
    // For the end node, the "departure" direction from that node along this
    // segment is the reverse of the segment's arrival direction.
    const newAngle = isStart ? seg.angleAt(0.0) : seg.angleAt(1.0) + Math.PI;
    return TrackEditor.minDivergence(existing, newAngle) <= TrackEditor.MAX_TURNOUT_ANGLE;
  }

  // Smallest undirected divergence (radians) between newAngle and any of the
  // existing departure angles. Both travel directions are considered.
  static minDivergence(existing, newAngle) {
    let lowest = Infinity;
    for (const a of existing) {
      const diff = Math.abs(angleDifference(a, newAngle));
      const diffRev = Math.abs(angleDifference(a, newAngle + Math.PI));
      lowest = Math.min(lowest, diff, diffRev);
    }
    return lowest;
  }

  // Finish drawing onto a point on an existing track: split the track there
  // and connect. The connection is validated BEFORE the split, so a rejected
  // finish leaves the network untouched. With continueAfter, drawing resumes
  // from the new junction. Returns true on success.
  finishOnTrack(hit, continueAfter = false) {
    const [seg, t] = hit;
    if (seg.isPlatformSegment()) {
      this.lastError = 'Cannot create junctions inside a station';
      return false;
    }
    this.lastError = '';
    const splitPos = seg.positionAt(t);
    const candidate = new TrackSegment(this.startNode, NetworkNode.junction(splitPos), this.waypoints);
    let reason = '';
    if (candidate.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) {
      reason = 'curve';
    } else if (!this._validateTurnoutAngle(this.startNode, candidate, true)) {
      reason = 'turnout';
    } else if (TrackEditor.minDivergence([seg.angleAt(t)], candidate.angleAt(1.0) + Math.PI) > TrackEditor.MAX_TURNOUT_ANGLE) {
      // After the split, the junction's departure angles are the track's
      // tangent at the split point (both directions).
      reason = 'turnout';
    } else {
      reason = this.validateCrossings(candidate);
    }
    if (reason !== '') {
      this.lastFinishRejected = true;
      this.rejectionReason = reason;
      return false;
    }
    // Rejoining a segment the drawing departs from must produce a visible
    // loop, not a second track hidden underneath the first.
    if ((seg.nodeStart === this.startNode || seg.nodeEnd === this.startNode)
        && TrackEditor._maxOffsetFrom(candidate, seg) < TrackEditor.MIN_LOOP_OFFSET) {
      this.lastError = 'New track overlaps the one it left — add waypoints to swing the loop clear';
      return false;
    }
    this.lastFinishRejected = false;
    this.rejectionReason = '';
    const junction = this.splitTrackAtHit(hit);
    this.createBidirectionalTrack(this.startNode, junction, this.waypoints);
    if (continueAfter) {
      this.startNode = junction;
      this.waypoints = [];
    } else {
      this.cancel();
    }
    return true;
  }

  // True when a findTrackAt hit lands so close to the current drawing's
  // start node that it reads as a waypoint click, not a join.
  hitTooCloseToStart(hit) {
    const [seg, t] = hit;
    const dist = seg.positionAt(t).distanceTo(this.startNode.position);
    if (seg.nodeStart === this.startNode || seg.nodeEnd === this.startNode) {
      return dist < TrackEditor.DEPARTURE_JOIN_DISTANCE;
    }
    return dist < TrackEditor.MIN_JOIN_DISTANCE;
  }

  // Build a preview segment for the current drawing state.
  buildPreviewSegment(mouse) {
    return new TrackSegment(this.startNode, NetworkNode.junction(mouse), this.waypoints);
  }

  // Cancel the current drawing. Cleans up the start node if it was a freshly
  // placed junction that never got a track.
  cancel() {
    if (this.startNode !== null) this.network.cleanupOrphan(this.startNode);
    this.drawing = false;
    this.startNode = null;
    this.waypoints = [];
  }

  // --- Track operations ---

  // Create a bidirectional track between two network nodes. The two segments
  // are linked as each other's reverse twin. Returns the forward segment.
  createBidirectionalTrack(from, to, wps) {
    const fwd = new TrackSegment(from, to, wps);
    const rev = new TrackSegment(to, from, wps.slice().reverse());
    fwd.reverse = rev;
    rev.reverse = fwd;
    this.network.addSegment(fwd);
    this.network.addSegment(rev);
    return fwd;
  }

  // Split an existing track at a hit point, creating a junction. Returns the
  // new junction node, or null if the segment is a station platform.
  splitTrackAtHit(hit) {
    const [seg, t] = hit;
    if (seg.isPlatformSegment()) {
      this.lastError = 'Cannot create junctions inside a station';
      return null;
    }
    this.lastError = '';
    const junction = NetworkNode.junction(seg.positionAt(t));
    this.network.addNode(junction);
    const reverse = seg.reverse;
    const wpFirst = this._sampleCurveWaypoints(seg, 0.0, t);
    const wpSecond = this._sampleCurveWaypoints(seg, t, 1.0);
    this.network.removeSegment(seg);
    if (reverse !== null) this.network.removeSegment(reverse);
    const first = this.createBidirectionalTrack(seg.nodeStart, junction, wpFirst);
    const second = this.createBidirectionalTrack(junction, seg.nodeEnd, wpSecond);
    // A signal at either end of the split track stays with the half that
    // still ends there.
    second.copySignalFrom(seg);
    if (reverse !== null) first.reverse.copySignalFrom(reverse);
    return junction;
  }

  // Try to delete the track at a position. Platform segments are protected —
  // the station must be removed first. Returns true if a track pair was
  // deleted.
  tryDeleteTrackAt(pos) {
    const hit = this.findTrackAt(pos);
    if (hit.length === 0) return false;
    const seg = hit[0];
    if (seg.isPlatformSegment()) {
      this.lastError = 'Remove the station before deleting its platform track';
      return false;
    }
    this.lastError = '';
    const reverse = seg.reverse;
    this.network.removeSegment(seg);
    if (reverse !== null) this.network.removeSegment(reverse);
    this.network.cleanupOrphan(seg.nodeStart);
    this.network.cleanupOrphan(seg.nodeEnd);
    return true;
  }

  // Remove a town from the map: tear down its station (if any) and drop it
  // from the town list and every train's order list. A town can be a stop
  // several times over, so every occurrence goes; stops left back to back
  // (A → town → A becomes A → A) collapse into one.
  removeTown(town, towns, orderLists = []) {
    this.removeStation(town);
    erase(towns, town);
    for (const orders of orderLists) {
      const kept = orders.filter((stop) => stop !== town);
      const collapsed = kept.filter((stop, i) => i === 0 || stop !== kept[i - 1]);
      orders.splice(0, orders.length, ...collapsed);
    }
  }

  // Remove a town's station: delete its platform segments and clean up the
  // entry/exit junctions if nothing else connects to them.
  removeStation(town) {
    if (town.station === null) return;
    for (const platform of town.station.platforms) {
      const fwd = platform.segment;
      this.network.removeSegment(fwd);
      if (platform.reverseSegment !== null) this.network.removeSegment(platform.reverseSegment);
      this.network.cleanupOrphan(fwd.nodeStart);
      this.network.cleanupOrphan(fwd.nodeEnd);
    }
    town.station = null;
  }

  // Build a station on the track at a position, inside a town's radius.
  // Splits the hit segment into approach tracks and a platform segment with
  // entry/exit junctions. Returns the new Station, or null (with lastError
  // set) if placement is invalid.
  placeStation(pos, towns) {
    const hit = this.findTrackAt(pos);
    if (hit.length === 0) {
      this.lastError = 'Click on a track to place a station';
      return null;
    }
    const [seg, t] = hit;
    if (seg.isPlatformSegment()) {
      this.lastError = 'There is already a platform here';
      return null;
    }

    const point = seg.positionAt(t);
    let town = null;
    let bestDist = Infinity;
    for (const candidate of towns) {
      const d = point.distanceTo(candidate.position);
      if (d <= candidate.radius && d < bestDist) {
        bestDist = d;
        town = candidate;
      }
    }
    if (town === null) {
      this.lastError = "Stations must be placed inside a town's circle";
      return null;
    }
    if (town.station !== null) {
      this.lastError = 'This town already has a station';
      return null;
    }

    const total = seg.length();
    if (total < TrackEditor.MIN_STATION_SEGMENT_LENGTH) {
      this.lastError = 'Track too short for a platform';
      return null;
    }

    // Centre the platform span on the click, shifted to fit within the segment.
    const startOff = clamp(t * total - TrackEditor.PLATFORM_HALF_LENGTH, 0, total - TrackEditor.PLATFORM_LENGTH);
    const endOff = startOff + TrackEditor.PLATFORM_LENGTH;
    // Snap to an existing endpoint when the span ends close to it, to avoid
    // creating tiny stub segments.
    const snap = Math.max(total * 0.05, TrackEditor.HIT_RADIUS);
    const snapStart = startOff <= snap;
    const snapEnd = endOff >= total - snap;
    const tStart = snapStart ? 0.0 : startOff / total;
    const tEnd = snapEnd ? 1.0 : endOff / total;

    const entry = snapStart ? seg.nodeStart : NetworkNode.junction(seg.positionAt(tStart));
    const exit = snapEnd ? seg.nodeEnd : NetworkNode.junction(seg.positionAt(tEnd));
    const platformWps = this._sampleCurveWaypoints(seg, tStart, tEnd);
    const platformSeg = new TrackSegment(entry, exit, platformWps);
    if (platformSeg.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) {
      this.lastError = 'Track too curved for a platform';
      return null;
    }
    // The mirror of the "no crossings over a platform" drawing rule.
    if (this._spanContainsCrossing(seg, tStart, tEnd)) {
      this.lastError = 'Cannot build a platform across a track crossing';
      return null;
    }

    // Replace the hit segment with approach tracks + the platform pair.
    const reverse = seg.reverse;
    this.network.removeSegment(seg);
    if (reverse !== null) this.network.removeSegment(reverse);
    if (!snapStart) {
      const approachIn = this.createBidirectionalTrack(seg.nodeStart, entry,
        this._sampleCurveWaypoints(seg, 0.0, tStart));
      if (reverse !== null) approachIn.reverse.copySignalFrom(reverse);
    }
    if (!snapEnd) {
      const approachOut = this.createBidirectionalTrack(exit, seg.nodeEnd,
        this._sampleCurveWaypoints(seg, tEnd, 1.0));
      approachOut.copySignalFrom(seg);
    }
    const platformRev = new TrackSegment(exit, entry, platformWps.slice().reverse());
    platformSeg.reverse = platformRev;
    platformRev.reverse = platformSeg;
    this.network.addSegment(platformSeg);
    this.network.addSegment(platformRev);

    // Draw the platform on the side of the track facing the town.
    const mid = platformSeg.positionAt(0.5);
    const perp = Vec2.fromAngle(platformSeg.angleAt(0.5)).orthogonal();
    const side = perp.dot(town.position.sub(mid)) >= 0 ? 1.0 : -1.0;

    const station = new Station(town);
    const platform = new Platform(platformSeg, platformRev, side);
    platform.station = station;
    station.platforms.push(platform);
    platformSeg.platform = platform;
    platformRev.platform = platform;
    town.station = station;
    this.lastError = '';
    return station;
  }

  // --- Signals ---

  // Place a path signal on the track at a position, or cycle the signal
  // whose junction is clicked. A new placement splits the track and flags
  // both directions (a two-way signal). Returns true if anything changed;
  // lastError explains a false.
  placeOrCycleSignal(pos) {
    const junction = this.findJunctionAt(pos);
    if (junction !== null) return this._cycleSignalAt(junction);
    const hit = this.findTrackAt(pos);
    if (hit.length === 0) {
      this.lastError = 'Click on a track to place a signal';
      return false;
    }
    if (hit[0].isPlatformSegment()) {
      this.lastError = 'Platforms are their own waiting points — no signals there';
      return false;
    }
    const node = this.splitTrackAtHit(hit);
    if (node === null) return false;
    for (const arriving of this.network.getIncoming(node)) arriving.exitSignal = true;
    this.lastError = '';
    return true;
  }

  // Cycle the signal at a junction. Only plain through-nodes qualify —
  // exactly two directed segments arriving, one per direction of the same
  // physical track.
  _cycleSignalAt(junction) {
    const arriving = this.network.getIncoming(junction).filter((seg) => !seg.isPlatformSegment());
    if (arriving.length !== 2) {
      this.lastError = 'Signals only fit on plain track, not junctions';
      return false;
    }
    this.lastError = '';
    const [a, b] = arriving;
    const next = (TrackEditor._signalState(a, b) + 1) % SIGNAL_STATE_COUNT;
    TrackEditor._applySignalState(a, b, next);
    return true;
  }

  // The state the two arriving directions currently encode.
  static _signalState(a, b) {
    if (a.exitSignal && b.exitSignal) return SignalState.TWO_WAY;
    if (a.exitSignal) return a.looseOneWay ? SignalState.LOOSE_A : SignalState.STRICT_A;
    if (b.exitSignal) return b.looseOneWay ? SignalState.LOOSE_B : SignalState.STRICT_B;
    return SignalState.NONE;
  }

  // Write a state onto the two arriving directions. looseOneWay is cleared
  // wherever it is meaningless, so equal states always compare equal.
  static _applySignalState(a, b, state) {
    a.exitSignal = [SignalState.TWO_WAY, SignalState.LOOSE_A, SignalState.STRICT_A].includes(state);
    b.exitSignal = [SignalState.TWO_WAY, SignalState.LOOSE_B, SignalState.STRICT_B].includes(state);
    a.looseOneWay = state === SignalState.LOOSE_A;
    b.looseOneWay = state === SignalState.LOOSE_B;
  }

  // --- Hit testing ---

  // Returns the junction node at a position, if there is one.
  findJunctionAt(pos) {
    for (const node of this.network.nodes) {
      if (pos.distanceTo(node.position) < TrackEditor.HIT_RADIUS) return node;
    }
    return null;
  }

  // Find the closest track segment to a position. Returns [segment, t] or [].
  findTrackAt(pos) {
    let bestSeg = null;
    let bestDist = TrackEditor.HIT_RADIUS;
    let bestT = 0;
    // Hit-test each physical track once: skip a segment whose reverse twin
    // was already visited. Keying on endpoints would wrongly hide parallel
    // tracks between the same two junctions (e.g. a passing loop).
    const seen = new Set();
    for (const seg of this.network.segments) {
      if (seen.has(seg)) continue;
      seen.add(seg);
      if (seg.reverse !== null) seen.add(seg.reverse);
      const points = seg.getBakedPoints();
      const totalLen = seg.length();
      if (totalLen <= 0) continue;
      let accumulated = 0;
      for (let i = 0; i < points.length; i++) {
        if (i > 0) accumulated += points[i].distanceTo(points[i - 1]);
        const d = pos.distanceTo(points[i]);
        if (d < bestDist) {
          bestDist = d;
          bestSeg = seg;
          bestT = accumulated / totalLen;
        }
      }
    }
    return bestSeg !== null ? [bestSeg, bestT] : [];
  }

  // --- Internal helpers ---

  // Largest distance from any point of `candidate`'s curve to `track`'s path.
  static _maxOffsetFrom(candidate, track) {
    let worst = 0;
    for (const p of candidate.getBakedPoints()) {
      worst = Math.max(worst, track.curve.getClosestPoint(p).distanceTo(p));
    }
    return worst;
  }

  // Whether any flat crossing on a segment falls within a span of it.
  _spanContainsCrossing(seg, tStart, tEnd) {
    const total = seg.length();
    if (total <= 0) return false;
    for (const crossing of seg.crossings) {
      const offset = seg.curve.getClosestOffset(crossing.position);
      if (offset >= tStart * total && offset <= tEnd * total) return true;
    }
    return false;
  }

  // Sample interior waypoints from a segment's curve between tStart and tEnd.
  _sampleCurveWaypoints(seg, tStart, tEnd) {
    const wps = [];
    const numSamples = 6;
    for (let i = 1; i < numSamples; i++) {
      wps.push(seg.positionAt(tStart + (tEnd - tStart) * i / numSamples));
    }
    return wps;
  }
}
