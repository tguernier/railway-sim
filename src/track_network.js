import { angleDifference, erase } from './vec2.js';
import { TrackSegment } from './track_segment.js';
import { TrackCrossing, CrossingKind } from './track_crossing.js';

// How a one-way signal facing the other way affects entry into a directed
// segment. See oneWayAgainst.
export const OneWay = Object.freeze({
  NONE: 0,    // no one-way signal against this direction
  LOOSE: 1,   // passable from behind, but the pathfinder avoids it
  STRICT: 2,  // routing in this direction is barred outright
});

// Graph of track segments connecting network nodes. Supports pathfinding via Dijkstra.
export class TrackNetwork {
  // Cost added to a segment unavailable to the routing train. Larger than any
  // plausible route length, so one blocked segment always outweighs any free
  // detour, while two equally-blocked routes still compare by real length.
  static BLOCKED_PENALTY = 10000.0;
  // Cost added for entering a segment against a *loose* one-way signal. Well
  // below BLOCKED_PENALTY on purpose: running the wrong way past a loose
  // signal is safe (reservations still keep trains apart), so a train takes
  // the barred direction rather than queue behind occupied track.
  static ONE_WAY_PENALTY = 2000.0;
  // Maximum heading change through a junction (end of the arriving segment vs
  // start of the departing one). Anything past it is a switchback.
  static MAX_THROUGH_ANGLE = Math.PI / 2;

  constructor() {
    // All track segments in the network.
    this.segments = [];
    // All junction nodes in the network.
    this.nodes = [];
    // Every flat crossing in the network. The same objects are registered on
    // the segments involved, which is where exclusion reads them.
    this.crossings = [];
    // Adjacency list mapping each node to its outgoing segments.
    this._outgoing = new Map();
  }

  // Add a network node.
  addNode(node) {
    if (!this.nodes.includes(node)) this.nodes.push(node);
  }

  // Add a track segment to the network (also registers its endpoint nodes).
  // Crossings against existing track are detected here — every structural
  // edit funnels through this call, so the crossing set cannot drift out of
  // step with the geometry. GameSnapshot opts out: it clones a network whose
  // crossings are already known.
  addSegment(segment, detectCrossings = true) {
    this.segments.push(segment);
    this.addNode(segment.nodeStart);
    this.addNode(segment.nodeEnd);
    if (!this._outgoing.has(segment.nodeStart)) this._outgoing.set(segment.nodeStart, []);
    this._outgoing.get(segment.nodeStart).push(segment);
    if (detectCrossings) this._detectCrossings(segment);
  }

  // Remove a track segment from the network, along with any crossings on its
  // physical track.
  removeSegment(segment) {
    erase(this.segments, segment);
    if (this._outgoing.has(segment.nodeStart)) erase(this._outgoing.get(segment.nodeStart), segment);
    this._purgeCrossings(segment);
  }

  // Get outgoing track segments from a node.
  getOutgoing(node) {
    return this._outgoing.get(node) ?? [];
  }

  // Get incoming track segments to a node.
  getIncoming(node) {
    return this.segments.filter((seg) => seg.nodeEnd === node);
  }

  // --- Flat crossings ---

  // Whether two segments meet at a shared endpoint. Such a pair joins at a
  // junction rather than crossing, so it is exempt from crossing detection.
  static sharesNode(a, b) {
    return a.nodeStart === b.nodeStart || a.nodeStart === b.nodeEnd
      || a.nodeEnd === b.nodeStart || a.nodeEnd === b.nodeEnd;
  }

  // Find and register every crossing a newly added segment makes. Skipped
  // when its reverse twin is already in the network: the twin's scan covered
  // this physical track and registered the results on all four segments.
  _detectCrossings(segment) {
    const twin = segment.reverse;
    if (twin !== null && twin !== segment && this.segments.includes(twin)) return;
    const seen = new Set();
    for (const other of this.segments) {
      if (other === segment || other === twin || seen.has(other)) continue;
      seen.add(other);
      if (other.reverse !== null) seen.add(other.reverse);
      if (TrackNetwork.sharesNode(segment, other)) continue;
      for (const point of TrackSegment.crossingPoints(segment, other)) {
        this.registerCrossing(segment, other, point);
      }
    }
  }

  // Record a crossing between two tracks, on the network and on all four
  // directed segments involved. `knownAngle` skips the tangent lookup when
  // the caller already has it (cloning a snapshot of identical geometry).
  registerCrossing(a, b, point, knownAngle = -1, kind = CrossingKind.DIAMOND) {
    const crossing = new TrackCrossing(kind);
    crossing.position = point;
    crossing.angle = knownAngle >= 0 ? knownAngle : TrackSegment.crossingAngle(a, b, point);
    crossing.trackA = a;
    crossing.trackB = b;
    this.crossings.push(crossing);
    for (const seg of [a, a.reverse, b, b.reverse]) {
      if (seg !== null && !seg.crossings.includes(crossing)) seg.crossings.push(crossing);
    }
    return crossing;
  }

  // Drop every crossing on a removed segment's physical track, from the
  // network list and from the far track's segments. Idempotent: deletion
  // paths remove both twins, so this runs twice per physical track.
  _purgeCrossings(segment) {
    for (const crossing of segment.crossings.slice()) {
      erase(this.crossings, crossing);
      const other = crossing.otherTrack(segment);
      if (other !== null) {
        erase(other.crossings, crossing);
        if (other.reverse !== null) erase(other.reverse.crossings, crossing);
      }
    }
    segment.crossings.length = 0;
    const twin = segment.reverse;
    if (twin !== null && twin !== segment) twin.crossings.length = 0;
  }

  // Remove a node if it has no connections. Returns true if removed.
  cleanupOrphan(node) {
    if (this.getOutgoing(node).length === 0 && this.getIncoming(node).length === 0) {
      erase(this.nodes, node);
      this._outgoing.delete(node);
      return true;
    }
    return false;
  }

  // How the one-way signal at a directed segment's start (if any) treats
  // entry in that direction. The segment's twin arriving at that junction is
  // what carries the signal; it is only one-way if no other arriving segment
  // (the through continuation) carries one too, which would make it two-way.
  oneWayAgainst(seg) {
    const twin = seg.reverse;
    if (twin === null || !twin.exitSignal) return OneWay.NONE;
    for (const arriving of this.getIncoming(seg.nodeStart)) {
      if (arriving !== twin && arriving.exitSignal) return OneWay.NONE; // two-way
    }
    return twin.looseOneWay ? OneWay.LOOSE : OneWay.STRICT;
  }

  // Whether a train arriving on prev can roll onto next without reversing:
  // the reverse twin never continues, and the departure heading must stay
  // within MAX_THROUGH_ANGLE of the arrival heading. A null prev means no
  // established heading, so anything goes.
  canContinue(prev, next) {
    if (prev === null) return true;
    if (next === prev.reverse) return false;
    return Math.abs(angleDifference(prev.angleAt(1.0), next.angleAt(0.0))) <= TrackNetwork.MAX_THROUGH_ANGLE;
  }

  // Whether next is a legal move for a route currently arriving on prev.
  // `first` marks the route's first hop: with allowReversal (a train standing
  // at a station stop may change direction) the first hop may also be prev's
  // own reverse twin — the train leaves the way it came in.
  _hopAllowed(prev, next, first, allowReversal) {
    if (this.canContinue(prev, next)) return true;
    return first && allowReversal && prev !== null && next === prev.reverse;
  }

  // Get all departure angles (radians) of outgoing segments at a node.
  departureAnglesAt(node) {
    return this.getOutgoing(node).map((seg) => seg.angleAt(0.0));
  }

  // Find the shortest route from a node to a station platform. The route
  // always ends with a traversal of the platform segment (entering at
  // whichever end gives the shorter path). With forTrain given, both
  // candidate entry ends are costed with reservation penalties.
  findRouteToPlatform(from, platform, forTrain = null, arriving = null, allowReversal = false) {
    const entry = platform.segment.nodeStart;
    const exit = platform.segment.nodeEnd;
    if (from === entry && this._hopAllowed(arriving, platform.segment, true, allowReversal)) {
      return [platform.segment];
    }
    if (from === exit && this._hopAllowed(arriving, platform.reverseSegment, true, allowReversal)) {
      return [platform.reverseSegment];
    }
    const routeA = this.findRoute(from, entry, forTrain, arriving, platform.segment, allowReversal);
    const routeB = this.findRoute(from, exit, forTrain, arriving, platform.reverseSegment, allowReversal);
    const lenA = routeA.length > 0 ? this.routeCost(routeA, forTrain) : Infinity;
    const lenB = routeB.length > 0 ? this.routeCost(routeB, forTrain) : Infinity;
    if (lenA === Infinity && lenB === Infinity) return [];
    if (lenA <= lenB) {
      routeA.push(platform.segment);
      return routeA;
    }
    routeB.push(platform.reverseSegment);
    return routeB;
  }

  // The cheapest route to any of a station's platforms (a station on double
  // track has one per track), or null when none is reachable. Each candidate
  // is found by findRouteToPlatform and compared by routeCost, so with
  // forTrain the platform choice is traffic-aware; ties go to the earlier
  // platform. Returns { route, platform }.
  findRouteToStation(from, platforms, forTrain = null, arriving = null, allowReversal = false) {
    let best = null;
    let bestCost = Infinity;
    for (const platform of platforms) {
      const route = this.findRouteToPlatform(from, platform, forTrain, arriving, allowReversal);
      if (route.length === 0) continue;
      const cost = this.routeCost(route, forTrain);
      if (cost < bestCost) {
        best = { route, platform };
        bestCost = cost;
      }
    }
    return best;
  }

  // The platforms of a station worth stopping at given where the train goes
  // next: those from which some platform of the next stop is reachable
  // (standing at a stop, a train may leave either way). With crossovers a
  // train can often reach a platform it could not leave in the right
  // direction — on double track, the other line's platform — and picking
  // it for being cheapest would strand the train at its next dispatch.
  // Reservation-blind. Falls back to all platforms when none qualifies, so
  // loop validation still reports the leg that fails.
  viablePlatforms(platforms, nextPlatforms) {
    if (platforms.length < 2) return platforms;
    const viable = platforms.filter((p) => p.segment.length() > 0
      && this.findRouteToStation(p.segment.nodeEnd, nextPlatforms, null, p.segment, true) !== null);
    return viable.length > 0 ? viable : platforms;
  }

  // Plan a loop of stops the way dispatch will run it: start standing on a
  // platform of the first stop, route to each subsequent stop's cheapest
  // reachable platform in turn, and finish back at the first stop. Each stop
  // is a Platform or an array of them (a station's platforms). The start
  // platform matters on double track — a train can only leave along its own
  // running line — so each of the first stop's platforms is tried in turn.
  // Returns { unroutable, start }: unroutable is -1 when the whole loop works
  // (start is then the platform to spawn on), else the index of the first
  // stop that cannot be reached (from the first start platform's attempt).
  // Reservation-blind, so layouts are never rejected because of where trains
  // happen to stand.
  planLoop(stops) {
    const stations = stops.map((s) => (Array.isArray(s) ? s : [s]));
    if (stations.length === 0) return { unroutable: -1, start: null };
    let firstFailure = -1;
    for (const start of stations[0]) {
      const failed = this._loopFailure(stations, start);
      if (failed === -1) return { unroutable: -1, start };
      if (firstFailure === -1) firstFailure = failed;
    }
    return { unroutable: firstFailure, start: null };
  }

  // Index of the first stop the loop cannot reach starting on `start`, or -1.
  // Dispatch picks each stop's platform greedily, so a lap can end on a
  // different platform of the first stop than it began on — on double track,
  // a train sets out eastbound and returns on the westbound platform — and
  // the next lap must work from there too. Laps are walked until one starts
  // from a platform already started from; each lap is deterministic given
  // its start, so the walk then repeats forever.
  _loopFailure(stations, start) {
    const startedFrom = new Set();
    let arriving = start.segment;
    while (!startedFrom.has(arriving.platform)) {
      startedFrom.add(arriving.platform);
      for (let i = 1; i < stations.length + 1; i++) {
        const idx = i % stations.length;
        const targets = this.viablePlatforms(stations[idx], stations[(idx + 1) % stations.length]);
        const found = this.findRouteToStation(arriving.nodeEnd, targets, null, arriving, true);
        if (found === null) return idx;
        arriving = found.route[found.route.length - 1];
      }
    }
    return -1;
  }

  // Index of the first stop a loop cannot reach, or -1 (see planLoop).
  firstUnroutableStop(stops) {
    return this.planLoop(stops).unroutable;
  }

  // Cost of a route for a train: total length, plus BLOCKED_PENALTY for each
  // segment unavailable to it and ONE_WAY_PENALTY for each entered against a
  // loose one-way signal (mirrors findRoute's relaxation — the lookahead
  // compares the two, so they must agree).
  routeCost(route, forTrain) {
    let total = 0;
    for (const seg of route) {
      total += seg.length();
      if (forTrain !== null && forTrain.isBlocked(seg)) total += TrackNetwork.BLOCKED_PENALTY;
      if (this.oneWayAgainst(seg) === OneWay.LOOSE) total += TrackNetwork.ONE_WAY_PENALTY;
    }
    return total;
  }

  // Find the shortest route between two nodes using Dijkstra (weighted by
  // segment length). The search is direction-aware: its state is the
  // directed segment a path arrives on (not the node), and every junction
  // transition must satisfy canContinue — trains never switchback mid-route.
  // `arriving` seeds the heading at `from`; with allowReversal the first hop
  // may be arriving's reverse twin. With exitSeg the goal only counts when
  // the path can continue onto it.
  findRoute(from, to, forTrain = null, arriving = null, exitSeg = null, allowReversal = false) {
    if (from === to && exitSeg === null) return [];

    // Each entry: [cost, node, path]; the arriving segment is path's last,
    // or `arriving` while the path is still empty.
    const queue = [[0.0, from, []]];
    const visited = new Set();

    while (queue.length > 0) {
      // Find the lowest-cost entry (the first one wins ties).
      let bestIdx = 0;
      for (let i = 1; i < queue.length; i++) {
        if (queue[i][0] < queue[bestIdx][0]) bestIdx = i;
      }
      const [cost, node, path] = queue[bestIdx];
      queue.splice(bestIdx, 1);
      const prev = path.length > 0 ? path[path.length - 1] : arriving;

      // Visited is keyed by the arriving segment: reachability onward depends
      // on the heading a node is reached with.
      if (path.length > 0) {
        if (visited.has(prev)) continue;
        visited.add(prev);
      }

      // Check at dequeue time — this is the shortest path to this state.
      if (node === to && (exitSeg === null || this.canContinue(prev, exitSeg))) return path;

      for (const seg of this.getOutgoing(node)) {
        const against = this.oneWayAgainst(seg);
        if (against === OneWay.STRICT) continue; // a strict one-way bars entry
        if (!this._hopAllowed(prev, seg, path.length === 0, allowReversal)) continue;
        if (visited.has(seg)) continue;
        let newCost = cost + seg.length();
        if (forTrain !== null && forTrain.isBlocked(seg)) newCost += TrackNetwork.BLOCKED_PENALTY;
        if (against === OneWay.LOOSE) newCost += TrackNetwork.ONE_WAY_PENALTY;
        queue.push([newCost, seg.nodeEnd, [...path, seg]]);
      }
    }
    return [];
  }
}
