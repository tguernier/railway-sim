import { Vec2, clamp, degToRad, angleDifference, erase } from './vec2.js';
import { NetworkNode } from './network_node.js';
import { TrackSegment } from './track_segment.js';
import { TrackNetwork } from './track_network.js';
import { CrossingKind } from './track_crossing.js';
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

  // --- Double track ---
  // Distance between the centres of a double section's two tracks: clear of
  // each other's ballast and platforms, and of the 12 px-wide trains.
  static DOUBLE_SPACING = 24.0;
  // Length of the taper where the two tracks converge on a section's end
  // junction: a third of the section, within these bounds. The lower bound
  // keeps the S-bend of the taper gentler than MIN_CURVE_RADIUS.
  static DOUBLE_TAPER_MIN = 80.0;
  static DOUBLE_TAPER_MAX = 120.0;
  // Shortest centreline that fits both tapers with some parallel track.
  static DOUBLE_MIN_LENGTH = 2 * TrackEditor.DOUBLE_TAPER_MIN + 40.0;
  // Target spacing of the one-way signals along the parallel run. Pieces stay
  // longer than MIN_STATION_SEGMENT_LENGTH so a station fits on one.
  static DOUBLE_SIGNAL_SPACING = 200.0;
  // Spacing of the samples each track is drawn through.
  static DOUBLE_SAMPLE_STEP = 20.0;
  // How far from the expected offset, and how far off parallel, a track may
  // be and still count as the other track of a double line (station
  // placement pairs platforms by geometry).
  static PARALLEL_TOLERANCE = 5.0;
  static PARALLEL_ANGLE = degToRad(10.0);

  // --- Crossovers ---
  // Distance along the line between a crossover's two junctions; the
  // diagonal's S-bend over it keeps its radius well above MIN_CURVE_RADIUS.
  static CROSSOVER_LENGTH = 140.0;
  // Planned splits must keep this far from existing junctions and signals.
  static NODE_CLEARANCE = 12.0;
  // How far turnback walks follow a line looking for a platform/crossover.
  static TURNBACK_SEARCH = 1200.0;
  // Clear running line a scissors crossover needs beyond each end: room for
  // the longest train (consists fit a platform) and a margin. A train
  // waiting on either side of the scissors then never stands in it or in a
  // neighbouring interlocked area (a double section's end, another
  // crossover) — waiting in one for the other is how two trains deadlock.
  static CROSSOVER_CLEARANCE = TrackEditor.PLATFORM_LENGTH + 10.0;
  // How far a crossover may slide from the click to find a spot that fits.
  static CROSSOVER_NUDGE = 60.0;

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
    // Whether drawing lays a double-track section (D toggles) instead of a
    // single track.
    this.doubleTrack = false;
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
    this._layTrack(this.startNode, node, this.waypoints);
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
    this._layTrack(this.startNode, node, this.waypoints);
    this.startNode = node;
    this.waypoints = [];
    return true;
  }

  // Validate the track a drawing would lay between two nodes. Returns "" if
  // valid, or a reason string.
  _validateTrack(from, to, wps) {
    return this._validateCandidates(from, to, wps, null);
  }

  // The track(s) a drawing from `from` to `to` would lay: one segment, or in
  // double-track mode both tracks of the section. { tracks } or { reason }.
  candidateTracks(from, to, wps) {
    if (!this.doubleTrack) return { tracks: [new TrackSegment(from, to, wps)] };
    const plan = this.planDoubleTrack(from, to, wps);
    return plan === null ? { reason: 'double_short' } : { tracks: [plan.right, plan.left] };
  }

  // Validate every candidate track for curve radius, turnout angle at both
  // ends, and crossings. `endTangent` is given when finishing onto an
  // existing track: the track's tangent at the split point, which is what
  // the new junction's departure angles will be.
  _validateCandidates(from, to, wps, endTangent) {
    const candidates = this.candidateTracks(from, to, wps);
    if (candidates.reason) return candidates.reason;
    for (const c of candidates.tracks) {
      if (c.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) return 'curve';
      if (!this._validateTurnoutAngle(from, c, true)) return 'turnout';
      const endOk = endTangent === null
        ? this._validateTurnoutAngle(to, c, false)
        : TrackEditor.minDivergence([endTangent], c.angleAt(1.0) + Math.PI) <= TrackEditor.MAX_TURNOUT_ANGLE;
      if (!endOk) return 'turnout';
    }
    for (const c of candidates.tracks) {
      const reason = this.validateCrossings(c);
      if (reason !== '') return reason;
    }
    return '';
  }

  // Lay the drawn track between two nodes: single or double per the mode.
  _layTrack(from, to, wps) {
    if (this.doubleTrack) this.createDoubleTrack(from, to, wps);
    else this.createBidirectionalTrack(from, to, wps);
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
    const blocked = TrackEditor._splitBlocker(seg);
    if (blocked !== '') {
      this.lastError = blocked;
      return false;
    }
    this.lastError = '';
    const splitPos = seg.positionAt(t);
    const end = NetworkNode.junction(splitPos);
    const candidate = new TrackSegment(this.startNode, end, this.waypoints);
    // After the split, the junction's departure angles are the track's
    // tangent at the split point (both directions). The candidate's own end
    // node is fresh, so it shares no node with the segment it lands on; the
    // endpoint clearance in crossingPoints keeps the join out of the
    // crossing test.
    const reason = this._validateCandidates(this.startNode, end, this.waypoints, seg.angleAt(t));
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
    this._layTrack(this.startNode, junction, this.waypoints);
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
    const blocked = TrackEditor._splitBlocker(seg);
    if (blocked !== '') {
      this.lastError = blocked;
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

  // Why a segment may not be split, or '' when it may: platforms (the station
  // owns them) and double-track tapers (splitting would drop their FOUL
  // exclusion).
  static _splitBlocker(seg) {
    if (seg.isPlatformSegment()) return 'Cannot create junctions inside a station';
    if (seg.taper) return 'Cannot build where double track converges — choose a spot along the parallel tracks';
    return '';
  }

  // --- Double track ---

  // Geometry of a double-track section between two nodes along the drawn
  // centreline, or null when the centreline is too short to taper in and
  // out. The two tracks run DOUBLE_SPACING apart and converge onto `from`
  // and `to` over smoothstep tapers, so the section joins the network at
  // ordinary junctions. `right` carries from→to traffic (right-hand running
  // relative to that direction), `left` carries to→from. Returns
  // { centre, taper, right, left, rightPoints, leftPoints, samples } where
  // the point arrays are the sampled track waypoints and `samples` their
  // centreline distances.
  planDoubleTrack(from, to, wps) {
    const centre = new TrackSegment(from, to, wps);
    const length = centre.length();
    if (length < TrackEditor.DOUBLE_MIN_LENGTH) return null;
    const taper = clamp(length / 3, TrackEditor.DOUBLE_TAPER_MIN, TrackEditor.DOUBLE_TAPER_MAX);
    const n = Math.max(2, Math.ceil(length / TrackEditor.DOUBLE_SAMPLE_STEP));
    const rightPoints = [];
    const leftPoints = [];
    const samples = [];
    for (let k = 1; k < n; k++) {
      const s = (length * k) / n;
      const off = TrackEditor.doubleOffset(s, length, taper);
      const p = centre.positionAt(s / length);
      // orthogonal() is the left of the direction of travel (y points down).
      const leftward = Vec2.fromAngle(centre.angleAt(s / length)).orthogonal();
      rightPoints.push(p.sub(leftward.mul(off)));
      leftPoints.push(p.add(leftward.mul(off)));
      samples.push(s);
    }
    return {
      centre,
      taper,
      right: new TrackSegment(from, to, rightPoints),
      left: new TrackSegment(from, to, leftPoints),
      rightPoints,
      leftPoints,
      samples,
    };
  }

  // Lateral offset of each track from the centreline at distance s along a
  // section of the given length: half the spacing along the parallel run,
  // easing to zero at both ends with a smoothstep (zero slope at the
  // junction, so the tracks leave it in line with the centreline).
  static doubleOffset(s, length, taper) {
    const x = Math.min(s, length - s) / taper;
    const ease = x >= 1 ? 1 : x * x * (3 - 2 * x);
    return (TrackEditor.DOUBLE_SPACING / 2) * ease;
  }

  // Lay a double-track section between two nodes (validate first: see
  // _validateCandidates). Each track is built as a chain of pieces split at
  // the taper ends and every ~DOUBLE_SIGNAL_SPACING along the parallel run;
  // each split carries a strict one-way signal serving that track's
  // direction, so routing keeps trains on their own running line and
  // following trains can close up. The taper pieces at each end are marked
  // `taper` and paired with a FOUL crossing — where the tracks converge,
  // trains on both would overlap, so only one may hold either taper.
  // Returns { right, left }: each track's pieces in from→to order.
  createDoubleTrack(from, to, wps) {
    const plan = this.planDoubleTrack(from, to, wps);
    const length = plan.centre.length();
    const inner = length - 2 * plan.taper;
    const runs = Math.max(1, Math.round(inner / TrackEditor.DOUBLE_SIGNAL_SPACING));
    // Split at the samples nearest the taper ends and the evenly spaced
    // points between them.
    const cuts = [];
    for (let i = 0; i <= runs; i++) {
      const target = plan.taper + (inner * i) / runs;
      let best = 0;
      for (let k = 1; k < plan.samples.length; k++) {
        if (Math.abs(plan.samples[k] - target) < Math.abs(plan.samples[best] - target)) best = k;
      }
      if (cuts.length === 0 || best > cuts[cuts.length - 1]) cuts.push(best);
    }
    const build = (points) => {
      const pieces = [];
      let node = from;
      let first = 0;
      for (const cut of cuts) {
        const junction = NetworkNode.junction(points[cut]);
        pieces.push(this.createBidirectionalTrack(node, junction, points.slice(first, cut)));
        node = junction;
        first = cut + 1;
      }
      pieces.push(this.createBidirectionalTrack(node, to, points.slice(first)));
      return pieces;
    };
    const right = build(plan.rightPoints);
    const left = build(plan.leftPoints);
    // One-way signals: the right track serves from→to, so the piece arriving
    // at each split in that direction carries the signal; the left track
    // serves to→from, so the reverse of the piece leaving each split does.
    for (let i = 0; i < cuts.length; i++) {
      right[i].exitSignal = true;
      left[i + 1].reverse.exitSignal = true;
    }
    for (const pieces of [right, left]) {
      for (const piece of [pieces[0], pieces[pieces.length - 1]]) {
        piece.taper = true;
        piece.reverse.taper = true;
      }
    }
    this.network.registerCrossing(right[0], left[0], from.position, 0, CrossingKind.FOUL);
    this.network.registerCrossing(right[right.length - 1], left[left.length - 1], to.position, 0, CrossingKind.FOUL);
    return { right, left };
  }

  // The other track of a double line at a point on `seg`: a different
  // physical track running parallel DOUBLE_SPACING to either side. Returns
  // [segment, t] or null.
  findParallelTrack(seg, t) {
    const point = seg.positionAt(t);
    const heading = seg.angleAt(t);
    const lateral = Vec2.fromAngle(heading).orthogonal();
    let best = null;
    let bestDist = TrackEditor.PARALLEL_TOLERANCE;
    for (const side of [1, -1]) {
      const probe = point.add(lateral.mul(side * TrackEditor.DOUBLE_SPACING));
      const seen = new Set([seg, seg.reverse]);
      for (const other of this.network.segments) {
        if (seen.has(other)) continue;
        seen.add(other);
        if (other.reverse !== null) seen.add(other.reverse);
        const total = other.length();
        if (total <= 0) continue;
        const closest = other.curve.getClosestPoint(probe);
        const d = closest.distanceTo(probe);
        if (d >= bestDist) continue;
        const otherT = other.curve.getClosestOffset(probe) / total;
        // Parallel in either direction of travel.
        const diff = Math.abs(angleDifference(heading, other.angleAt(otherT)));
        if (Math.min(diff, Math.PI - diff) > TrackEditor.PARALLEL_ANGLE) continue;
        best = [other, otherT];
        bestDist = d;
      }
    }
    return best;
  }

  // The directed segment of a double-track line in its running direction,
  // given a point (seg, t) on it and the other track (partner, [seg, t]):
  // right-hand running puts the other track on the left of travel.
  static _runningDirection(seg, t, partner) {
    const point = seg.positionAt(t);
    const other = partner[0].positionAt(partner[1]);
    const left = Vec2.fromAngle(seg.angleAt(t)).orthogonal();
    return left.dot(other.sub(point)) > 0 ? seg : seg.reverse;
  }

  // The next segment along the same line after `seg`: the outgoing segment
  // at its end that continues straight on (never the reverse twin, never a
  // crossover diagonal). Null at a dead end or a sharp turn.
  _continueStraight(seg) {
    let best = null;
    let bestDiff = TrackEditor.PARALLEL_ANGLE;
    for (const next of this.network.getOutgoing(seg.nodeEnd)) {
      if (next === seg.reverse || next.crossover) continue;
      const diff = Math.abs(angleDifference(seg.angleAt(1.0), next.angleAt(0.0)));
      if (diff < bestDiff) {
        best = next;
        bestDiff = diff;
      }
    }
    return best;
  }

  // Walk a line from `first` until the first platform and clear the
  // running-direction signals passed, so trains can run against the line
  // between a scissors crossover and that platform. Downstream walks (`first`
  // in the running direction, from a scissors' exit junction) serve trains
  // that reversed at the platform and run back to the crossover; upstream
  // walks (`first` against it, from a scissors' entry junction) serve trains
  // that crossed over and run forward, wrong-way, to the platform. Either
  // way strict one-way signals on the stretch would bar the move, and a train
  // waiting at one would deadlock against the wrong-way train (each needing
  // what the other holds). An upstream walk keeps the signal at its start —
  // the scissors' protecting signal. Stops at a taper (section end, another
  // crossover) or after TURNBACK_SEARCH without a platform, clearing
  // nothing. Returns whether a platform was found.
  _clearTurnbackSignals(first, upstream = false) {
    const passed = [];
    let seg = first;
    let dist = 0;
    while (seg !== null && dist < TrackEditor.TURNBACK_SEARCH) {
      if (seg.isPlatformSegment()) {
        // Upstream, the running-direction signal at each passed node sits on
        // the reverse of the segment that left it.
        const signals = upstream ? passed.slice(1).map((s) => s.reverse) : passed;
        for (const sig of signals) {
          sig.exitSignal = false;
          sig.looseOneWay = false;
        }
        return true;
      }
      if (seg.taper) return false;
      passed.push(seg);
      dist += seg.length();
      seg = this._continueStraight(seg);
    }
    return false;
  }

  // For a new platform on double track: find the nearest scissors crossover
  // on its line in each direction (within the section) and clear the
  // signals between — upstream it is the crossover's exit side (trains
  // reverse here and run back to it), downstream its entry side (trains
  // cross over there and run forward to here).
  _linkTurnbacks(platform) {
    const partner = this.findParallelTrack(platform.segment, 0.5);
    if (partner === null) return;
    const running = TrackEditor._runningDirection(platform.segment, 0.5, partner);
    for (const upstreamOfPlatform of [true, false]) {
      let seg = upstreamOfPlatform ? running.reverse : running;
      let dist = 0;
      while (seg !== null && dist < TrackEditor.TURNBACK_SEARCH) {
        const junction = seg.nodeEnd;
        if (this.network.getOutgoing(junction).some((s) => s.crossover)) {
          // Re-walk from the crossover towards this platform.
          this._clearTurnbackSignals(seg.reverse, !upstreamOfPlatform);
          break;
        }
        if (seg.taper) break;
        dist += seg.length();
        seg = this._continueStraight(seg);
      }
    }
  }

  // Work out a scissors crossover centred on a click on double track,
  // without changing anything. Two diagonals cross at a diamond between
  // junctions CROSSOVER_LENGTH apart on each line:
  //   trailing — from the left-hand line upstream to the right-hand line
  //     downstream (relative to the clicked line's running direction f).
  //     Through traffic cannot take it (it bends backwards through the
  //     junction); it carries trains that reversed at a stop beyond the
  //     scissors and run back to it, onto the other line in its direction.
  //   facing — from the right-hand line upstream to the left-hand line
  //     downstream. It carries trains forward onto the other line, wrong-way,
  //     to a platform just beyond, where they reverse and leave correctly —
  //     so a terminating train can use either platform.
  // Returns a plan for placeCrossover, or { error }.
  planCrossover(pos) {
    const hit = this.findTrackAt(pos);
    if (hit.length === 0) return { error: 'Click on a double-track section to place a crossover' };
    const [seg, t] = hit;
    if (seg.isPlatformSegment()) return { error: 'Crossovers cannot go on a platform' };
    if (seg.taper) return { error: 'Crossovers need the parallel part of a double-track section' };
    const partner = this.findParallelTrack(seg, t);
    if (partner === null) return { error: 'Crossovers go on double track — click one of its two tracks' };
    const running = TrackEditor._runningDirection(seg, t, partner);
    const clicked = seg.positionAt(t);
    const other = partner[0].positionAt(partner[1]);
    // Frame: f along the clicked line's running direction, n from the other
    // line (the left-hand one relative to f) towards the clicked one.
    const f = Vec2.fromAngle(running === seg ? seg.angleAt(t) : seg.angleAt(t) + Math.PI);
    const n = clicked.sub(other).normalized();
    const clickCentre = clicked.add(other).mul(0.5);
    // One click should just work: signals sit every ~200 px, so slide the
    // crossover up to CROSSOVER_NUDGE along the line to the nearest spot
    // where it fits, reporting the reason at the click itself if none does.
    let firstError = null;
    for (let i = 0; i <= 2 * TrackEditor.CROSSOVER_NUDGE / 10; i++) {
      const shift = (i % 2 === 1 ? 1 : -1) * Math.ceil(i / 2) * 10;
      const plan = this._planCrossoverAt(clickCentre.add(f.mul(shift)), f, n);
      if (plan.error === undefined) return plan;
      if (firstError === null) firstError = plan;
    }
    return firstError;
  }

  // planCrossover for a given centre point and frame.
  _planCrossoverAt(centre, f, n) {
    const half = TrackEditor.CROSSOVER_LENGTH / 2;
    const offset = TrackEditor.DOUBLE_SPACING / 2;
    const at = (along, side) => centre.add(f.mul(along)).add(n.mul(side * offset));
    // R = the right-hand line (runs along f), L = the left-hand one.
    const points = { rIn: at(-half, 1), rOut: at(half, 1), lIn: at(half, -1), lOut: at(-half, -1) };
    const snapped = {};
    for (const [key, target] of Object.entries(points)) {
      const found = this._snapToLine(target, f);
      if (found.error) return found;
      snapped[key] = found;
    }
    // Both junctions on a line must split the same piece: no junction or
    // signal between them.
    if (snapped.rIn.seg !== snapped.rOut.seg || snapped.lIn.seg !== snapped.lOut.seg) {
      return { error: 'Too close to a junction or signal — place the crossover a little further along' };
    }
    for (const [a, b] of [[snapped.rIn, snapped.rOut], [snapped.lIn, snapped.lOut]]) {
      if (!this._clearAround(a.seg, Math.min(a.t, b.t), Math.max(a.t, b.t), TrackEditor.CROSSOVER_CLEARANCE)) {
        return { error: 'Too close to where the double track ends or another crossover — a train must fit between them' };
      }
    }
    // Each diagonal is a smoothstep S-bend from one line to the other.
    const bend = (fromSide) => {
      const wps = [];
      const steps = 7;
      for (let k = 1; k < steps; k++) {
        const u = k / steps;
        const ease = u * u * (3 - 2 * u);
        wps.push(centre.add(f.mul(-half + 2 * half * u)).add(n.mul(fromSide * offset * (1 - 2 * ease))));
      }
      return wps;
    };
    const diagonals = [
      { from: snapped.lOut, to: snapped.rOut, wps: bend(-1) },  // trailing
      { from: snapped.rIn, to: snapped.lIn, wps: bend(1) },     // facing
    ];
    for (const d of diagonals) {
      d.segment = new TrackSegment(NetworkNode.junction(d.from.point), NetworkNode.junction(d.to.point), d.wps);
      if (d.segment.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) {
        return { error: 'Track too curved for a crossover here' };
      }
      for (const [track, angle] of [[d.from, d.segment.angleAt(0.0)], [d.to, d.segment.angleAt(1.0) + Math.PI]]) {
        if (TrackEditor.minDivergence([track.seg.angleAt(track.t)], angle) > TrackEditor.MAX_TURNOUT_ANGLE) {
          return { error: 'Track too curved for a crossover here' };
        }
      }
      if (this.validateCrossings(d.segment) !== '') return { error: 'A crossover cannot cross other track' };
    }
    return { snapped, diagonals };
  }

  // Whether the line through `seg` runs at least `dist` beyond the span
  // [t0, t1] on it, both ways, without meeting a taper (an interlocked
  // area). A dead end is fine.
  _clearAround(seg, t0, t1, dist) {
    const total = seg.length();
    for (const [start, covered] of [[seg, (1 - t1) * total], [seg.reverse, t0 * total]]) {
      let current = start;
      let reach = covered;
      while (reach < dist) {
        const next = this._continueStraight(current);
        if (next === null) break;
        if (next.taper) return false;
        reach += next.length();
        current = next;
      }
    }
    return true;
  }

  // The point on a running line nearest `target`, checked usable for a
  // crossover split: on parallel (to f), plain track — not a platform or
  // taper — and clear of existing nodes. Returns { seg, t, point } or
  // { error }.
  _snapToLine(target, f) {
    const hit = this.findTrackAt(target);
    if (hit.length === 0) return { error: 'Track too curved for a crossover here' };
    const [seg] = hit;
    const total = seg.length();
    const t = seg.curve.getClosestOffset(target) / total;
    const point = seg.positionAt(t);
    if (point.distanceTo(target) > TrackEditor.PARALLEL_TOLERANCE) return { error: 'Track too curved for a crossover here' };
    const diff = Math.abs(angleDifference(seg.angleAt(t), f.angle()));
    if (Math.min(diff, Math.PI - diff) > TrackEditor.PARALLEL_ANGLE) return { error: 'Track too curved for a crossover here' };
    if (seg.isPlatformSegment()) return { error: 'Crossovers cannot overlap a platform' };
    if (seg.taper) return { error: 'Too close to where the double track ends or another crossover' };
    if (point.distanceTo(seg.nodeStart.position) < TrackEditor.NODE_CLEARANCE
        || point.distanceTo(seg.nodeEnd.position) < TrackEditor.NODE_CLEARANCE) {
      return { error: 'Too close to a junction or signal — place the crossover a little further along' };
    }
    return { seg, t, point };
  }

  // Place a scissors crossover centred on a click on double track (see
  // planCrossover). Splits each line at its entry and exit junctions and
  // lays both diagonals; they cross at a diamond, which TrackNetwork detects
  // like any flat crossing. Interlocking:
  //   - each line's middle piece (entry → exit junction) is a taper paired
  //     by FOUL crossings with both diagonals, which run alongside it where
  //     they leave the line — so straight-through trains on the two lines
  //     can pass each other, but no diagonal move overlaps either;
  //   - a protecting signal (loose one-way, the line's direction) on the
  //     piece arriving at each line's entry junction: the last waiting point
  //     before the scissors, clear of everything a diagonal touches.
  // Then clears the wrong-way stretches to the nearest platform beyond each
  // end (_clearTurnbackSignals). Returns true; lastError explains a false.
  placeCrossover(pos) {
    const plan = this.planCrossover(pos);
    if (plan.error !== undefined) {
      this.lastError = plan.error;
      return false;
    }
    const split = (point) => {
      const [seg] = this.findTrackAt(point);
      return this.splitTrackAtHit([seg, seg.curve.getClosestOffset(point) / seg.length()]);
    };
    const { snapped } = plan;
    const node = {};
    for (const key of ['rIn', 'rOut', 'lIn', 'lOut']) node[key] = split(snapped[key].point);
    const diagonals = [
      this.createBidirectionalTrack(node.lOut, node.rOut, plan.diagonals[0].wps),
      this.createBidirectionalTrack(node.rIn, node.lIn, plan.diagonals[1].wps),
    ];
    // Each line's middle piece, in its running direction (entry → exit).
    const middles = [];
    for (const [entry, exit] of [[node.rIn, node.rOut], [node.lIn, node.lOut]]) {
      const middle = this.network.getOutgoing(entry).find((s) => s.nodeEnd === exit && !s.crossover);
      const approach = this.network.getIncoming(entry).find((s) => s !== middle.reverse && !s.crossover);
      // The protecting signal: a loose one-way. It is the line's waiting
      // point, but must not bar the wrong-way move out of the entry junction
      // that a train makes after crossing the facing diagonal (a strict
      // one-way bars routing at its junction); loose only prices it, so a
      // train crosses over only when the platform straight ahead is worse.
      approach.exitSignal = true;
      approach.looseOneWay = true;
      middles.push(middle);
    }
    for (const piece of [...diagonals, ...middles]) {
      piece.taper = true;
      piece.reverse.taper = true;
    }
    for (const diagonal of diagonals) {
      diagonal.crossover = true;
      diagonal.reverse.crossover = true;
      for (const middle of middles) {
        this.network.registerCrossing(middle, diagonal, diagonal.positionAt(0.5), 0, CrossingKind.FOUL);
      }
    }
    // No waiting point within CROSSOVER_CLEARANCE past either exit: a train
    // that has crossed stops only with its tail clear of the scissors.
    for (const [exitNode, middle] of [[node.rOut, middles[0]], [node.lOut, middles[1]]]) {
      let seg = this.network.getOutgoing(exitNode).find((s) => s !== middle.reverse && !s.crossover);
      let reach = 0;
      while (seg !== null && seg !== undefined && !seg.taper) {
        reach += seg.length();
        if (reach >= TrackEditor.CROSSOVER_CLEARANCE) break;
        seg.exitSignal = false;
        seg.looseOneWay = false;
        seg = this._continueStraight(seg);
      }
    }
    // Wrong-way stretches: from each exit junction downstream (reversing
    // trains run back), and from each entry junction upstream (crossing
    // trains run forward) — keeping the protecting signal.
    for (const [exitNode, middle] of [[node.rOut, middles[0]], [node.lOut, middles[1]]]) {
      const downstream = this.network.getOutgoing(exitNode).find((s) => s !== middle.reverse && !s.crossover);
      if (downstream !== undefined) this._clearTurnbackSignals(downstream);
    }
    for (const [entryNode, middle] of [[node.rIn, middles[0]], [node.lIn, middles[1]]]) {
      const upstream = this.network.getOutgoing(entryNode).find((s) => s !== middle && !s.crossover);
      if (upstream !== undefined) this._clearTurnbackSignals(upstream, true);
    }
    this.lastError = '';
    return true;
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
  // entry/exit junctions. On double track — another track running parallel
  // DOUBLE_SPACING away — the station gets a platform on each track, side
  // platforms facing outward, so trains in both directions can call; both
  // are validated before either is built. Returns the new Station, or null
  // (with lastError set) if placement is invalid.
  placeStation(pos, towns) {
    const hit = this.findTrackAt(pos);
    if (hit.length === 0) {
      this.lastError = 'Click on a track to place a station';
      return null;
    }
    const [seg, t] = hit;
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
    if (seg.isPlatformSegment()) {
      this.lastError = 'There is already a platform here';
      return null;
    }
    if (town === null) {
      this.lastError = "Stations must be placed inside a town's circle";
      return null;
    }
    if (town.station !== null) {
      this.lastError = 'This town already has a station';
      return null;
    }

    const plans = [this._planPlatform(seg, t)];
    const partner = this.findParallelTrack(seg, t);
    if (partner !== null) plans.push(this._planPlatform(partner[0], partner[1]));
    const failed = plans.find((plan) => plan.error !== undefined);
    if (failed !== undefined) {
      this.lastError = plans.length > 1 && failed === plans[1]
        ? `The other track of the double line can't take a platform here: ${failed.error.toLowerCase()}`
        : failed.error;
      return null;
    }

    const station = new Station(town);
    // A lone platform faces the town; a pair faces outward, away from each
    // other's track.
    const facing = plans.map((plan, i) => (plans.length === 1
      ? town.position
      : plan.mid.mul(2).sub(plans[1 - i].mid)));
    plans.forEach((plan, i) => {
      const platform = this._buildPlatform(plan, facing[i]);
      platform.station = station;
      station.platforms.push(platform);
    });
    // A scissors crossover already on either line, either side, now has a
    // platform to serve: clear the wrong-way stretch between them.
    if (station.platforms.length === 2) {
      for (const platform of station.platforms) this._linkTurnbacks(platform);
    }
    town.station = station;
    this.lastError = '';
    return station;
  }

  // Work out a platform span on a segment centred on t, without changing
  // anything. Returns a plan for _buildPlatform, or { error }.
  _planPlatform(seg, t) {
    if (seg.isPlatformSegment()) return { error: 'There is already a platform here' };
    if (seg.taper) return { error: 'Stations cannot go where double track converges' };
    const total = seg.length();
    if (total < TrackEditor.MIN_STATION_SEGMENT_LENGTH) return { error: 'Track too short for a platform' };

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
    if (platformSeg.minRadiusOfCurvature() < TrackEditor.MIN_CURVE_RADIUS) return { error: 'Track too curved for a platform' };
    // The mirror of the "no crossings over a platform" drawing rule.
    if (this._spanContainsCrossing(seg, tStart, tEnd)) return { error: 'Cannot build a platform across a track crossing' };
    return { seg, tStart, tEnd, snapStart, snapEnd, entry, exit, platformWps, platformSeg, mid: platformSeg.positionAt(0.5) };
  }

  // Replace a planned segment with approach tracks + the platform pair, the
  // platform drawn on the side facing `toward`. Returns the Platform.
  _buildPlatform(plan, toward) {
    const { seg, tStart, tEnd, snapStart, snapEnd, entry, exit, platformWps, platformSeg } = plan;
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

    const perp = Vec2.fromAngle(platformSeg.angleAt(0.5)).orthogonal();
    const side = perp.dot(toward.sub(plan.mid)) >= 0 ? 1.0 : -1.0;
    const platform = new Platform(platformSeg, platformRev, side);
    platformSeg.platform = platform;
    platformRev.platform = platform;
    return platform;
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
