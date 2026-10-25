import { clamp, erase } from './vec2.js';

// A train that follows a route of track segments, carrying passengers between
// towns. A train is a consist of cars: the head advances along the route
// while trailing cars are sampled at fixed distances behind it.
export class Train {
  // Length of one car along the track, in pixels.
  static CAR_LENGTH = 26.0;
  // Coupling gap between consecutive cars, in pixels.
  static CAR_GAP = 4.0;
  // Passenger capacity of one car.
  static CAR_CAPACITY = 20;
  // Seconds a blocked train waits between re-path attempts. Reservation
  // retries stay per-frame; only the Dijkstra re-path is throttled.
  static REROUTE_RETRY_INTERVAL = 1.0;
  // Cost improvement a free alternative tail must offer before the train
  // switches to it — hysteresis so near-equal branches don't flip-flop.
  static SWITCH_MARGIN = Train.CAR_LENGTH * 10.0;

  constructor() {
    // Ordered list of track segments forming the current route.
    this.route = [];
    // Index of the segment the train is currently traversing.
    this.routeIndex = 0;
    // Progress along the current segment, from 0.0 (start) to 1.0 (end).
    this.segmentProgress = 0.0;
    // Segments the head has fully traversed, oldest first — kept only as far
    // back as the tail needs so trailing cars can be positioned.
    this.history = [];
    // Number of cars in the consist. The consist must fit within a platform.
    this.carCount = 2;
    // Travel speed in pixels per second.
    this.speed = 150.0;
    // Number of passengers currently aboard.
    this.passengersOnBoard = 0;
    // Set to true after the station stop on the current route leg is done.
    this.boardedThisLeg = false;
    // How long the train waits at each station stop, in seconds.
    this.dwellTime = 2.0;
    // Seconds remaining of the current station stop (0 when moving).
    this.dwellRemaining = 0.0;
    // Progress on the final route segment where the train halts for its
    // station stop (the middle of the platform). -1 when no stop is pending.
    this.stopProgress = -1.0;
    // Segments this train holds movement reservations on.
    this.reserved = [];
    // Highest route index covered by the current reservation; the head may
    // not advance past the end of route[limitIndex]. -1 until the first
    // extension.
    this.limitIndex = -1;
    // True while the train is halted because the path ahead could not be
    // reserved (retried every move).
    this.waitingForTrack = false;
    // Seconds continuously spent waiting for track since the last re-path
    // attempt — throttles the blocked-retry Dijkstra.
    this.blockedTime = 0.0;
    // Whether the previous move() ended waiting for track.
    this._wasWaiting = false;
    // The network the train routes on and the platform its current leg
    // targets, set at dispatch — what tryExtendReservation re-paths against.
    this.network = null;
    this.targetPlatform = null;
    // The train whose reservation blocked this train's last failed reserve
    // attempt — the edge of the wait-for graph used for deadlock detection.
    this.blockedBy = null;
    // Ordered list of town stops the train visits in a loop.
    this.orders = [];
    // Index into orders for the next stop the train is heading toward.
    this.currentOrderIndex = 0;
  }

  // Maximum number of passengers the train can carry (all cars combined).
  get capacity() {
    return this.carCount * Train.CAR_CAPACITY;
  }

  // Total length of the consist along the track, in pixels.
  consistLength() {
    return this.carCount * Train.CAR_LENGTH + (this.carCount - 1) * Train.CAR_GAP;
  }

  // Initialise a route. Clears the path history: routes are set while the
  // whole consist sits on a platform segment (or at simulation start), and
  // resumeFromStop() re-anchors the train on that segment afterwards.
  setRoute(newRoute) {
    this.releaseAll();
    this.route = newRoute;
    this.routeIndex = 0;
    this.segmentProgress = 0.0;
    this.history = [];
    this.boardedThisLeg = false;
    this.stopProgress = -1.0;
    this.limitIndex = -1;
    this.waitingForTrack = false;
    this.blockedTime = 0.0;
    this._wasWaiting = false;
  }

  // Check if the train has a route.
  hasRoute() {
    return this.route.length > 0;
  }

  // Get current track segment.
  currentSegment() {
    return this.routeIndex < this.route.length ? this.route[this.routeIndex] : null;
  }

  // Move train along a track segment. While dwelling at a station the train
  // stays put and the dwell timer counts down instead. The head only
  // advances onto the next route segment once its reservation is taken; a
  // segment held by another train halts the head at the boundary, retried on
  // every move.
  move(delta) {
    if (this.dwellRemaining > 0) {
      this.dwellRemaining = Math.max(this.dwellRemaining - delta, 0);
      return;
    }
    if (!this.hasRoute()) return;
    this._wasWaiting = this.waitingForTrack;
    this.blockedTime = this._wasWaiting ? this.blockedTime + delta : 0.0;
    this.waitingForTrack = false;
    let distance = this.speed * delta;
    while (distance > 0 && !this.hasCompletedRoute()) {
      const seg = this.currentSegment();
      if (seg.length() <= 0) {
        if (this.routeIndex < this.route.length - 1) {
          if (!this._advanceToNextSegment(seg)) {
            this.segmentProgress = 1.0;
            break;
          }
        } else {
          this.segmentProgress = 1.0;
          break;
        }
        continue;
      }
      // Halt short of the segment end when a station stop is pending on the
      // final segment.
      let target = 1.0;
      let isStop = false;
      if (this.routeIndex === this.route.length - 1 && this.stopProgress >= 0
          && this.segmentProgress < this.stopProgress) {
        target = this.stopProgress;
        isStop = true;
      }
      const remaining = (target - this.segmentProgress) * seg.length();
      if (distance >= remaining) {
        distance -= remaining;
        this.segmentProgress = target;
        if (isStop) break; // arrived at the platform stop
        if (this.routeIndex < this.route.length - 1) {
          if (!this._advanceToNextSegment(seg)) break;
        } else {
          break;
        }
      } else {
        this.segmentProgress += distance / seg.length();
        distance = 0;
      }
    }
    this._trimHistory();
  }

  // Advance the head onto the next route segment. Crossing past the reserved
  // limit first requires extending the reservation to the next safe waiting
  // point; on failure the train halts at the boundary. The traversed segment
  // moves into the history so trailing cars can still be positioned on it.
  _advanceToNextSegment(seg) {
    // Loop: the first extension after dispatch may stop at a signal on the
    // current segment itself, still short of the boundary being crossed.
    while (this.routeIndex + 1 > this.limitIndex) {
      if (!this.tryExtendReservation()) {
        this.waitingForTrack = true;
        return false;
      }
    }
    this.history.push(seg);
    this.routeIndex += 1;
    this.segmentProgress = 0.0;
    return true;
  }

  // Check if train has fully progressed along a track segment.
  hasCompletedRoute() {
    return this.route.length > 0 && this.routeIndex >= this.route.length - 1 && this.segmentProgress >= 1.0;
  }

  // Whether the train is at (or past) its pending station stop point.
  atPendingStop() {
    return this.stopProgress >= 0 && this.route.length > 0
      && this.routeIndex === this.route.length - 1 && this.segmentProgress >= this.stopProgress;
  }

  // Resume a freshly set route from a station stop. prevSeg / prevProgress
  // describe where the train's head was stopped; reverseSeg is the
  // opposite-direction twin of prevSeg. If the new route leaves along
  // reverseSeg (a dead-end station) the train turns around in place.
  // Otherwise prevSeg is prepended so the train first rolls forward through
  // its remainder before joining the new route.
  resumeFromStop(prevSeg, prevProgress, reverseSeg) {
    if (this.route.length === 0) return;
    if (this.route[0] === reverseSeg) {
      const back = prevSeg.length() > 0 ? this.consistLength() / prevSeg.length() : 0;
      this.segmentProgress = clamp(1.0 - (prevProgress - back), 0, 1);
    } else {
      this.route.unshift(prevSeg);
      this.segmentProgress = prevProgress;
      if (this.limitIndex >= 0) this.limitIndex += 1; // keep the limit on the same segment
    }
  }

  // Position and heading at a point backOffset px behind the head, walking
  // back through the current segment and then the history. Clamps at the
  // oldest known point, so cars compress there rather than leaving the track.
  // Returns { position, angle }.
  pointBehind(backOffset) {
    let seg = this.currentSegment();
    if (seg === null) return { position: null, angle: 0 };
    let remaining = backOffset;
    // Distance of the head into the current segment.
    let available = this.segmentProgress * seg.length();
    let idx = this.history.length;
    while (remaining > available && idx > 0) {
      remaining -= available;
      idx -= 1;
      seg = this.history[idx];
      available = seg.length();
    }
    const dist = available - Math.min(remaining, available);
    const t = seg.length() > 0 ? dist / seg.length() : 0;
    return { position: seg.positionAt(t), angle: seg.angleAt(t) };
  }

  // Drop history segments the tail can no longer reach, releasing their
  // track reservations — the tail clearing a segment is exactly when it
  // frees up.
  _trimHistory() {
    const seg = this.currentSegment();
    let behind = seg !== null ? this.segmentProgress * seg.length() : 0;
    let keepFrom = this.history.length;
    while (keepFrom > 0 && behind < this.consistLength()) {
      keepFrom -= 1;
      behind += this.history[keepFrom].length();
    }
    if (keepFrom > 0) {
      const dropped = this.history.slice(0, keepFrom);
      this.history = this.history.slice(keepFrom);
      for (const cleared of dropped) {
        if (!this._stillOccupies(cleared)) this.release(cleared);
      }
    }
  }

  // Whether a segment is still under or ahead of the train — a looping route
  // can revisit a segment, so a copy dropped from history must not release it.
  _stillOccupies(seg) {
    if (this.history.includes(seg)) return true;
    for (let i = this.routeIndex; i < this.route.length; i++) {
      if (this.route[i] === seg) return true;
    }
    return false;
  }

  // Get current train position.
  currentPosition() {
    const seg = this.currentSegment();
    return seg === null ? null : seg.positionAt(this.segmentProgress);
  }

  // Get current train angle.
  currentAngle() {
    const seg = this.currentSegment();
    return seg === null ? 0 : seg.angleAt(this.segmentProgress);
  }

  // Get the town the train is currently heading toward per its orders.
  currentOrderTown() {
    return this.orders.length === 0 ? null : this.orders[this.currentOrderIndex];
  }

  // Advance to the next stop in the order list (wraps around).
  advanceOrder() {
    if (this.orders.length === 0) return;
    this.currentOrderIndex = (this.currentOrderIndex + 1) % this.orders.length;
  }

  // Unload passengers from train.
  unload() {
    const fare = this.passengersOnBoard;
    this.passengersOnBoard = 0;
    return fare;
  }

  // Pickup passengers onto train.
  boardFrom(town) {
    this.passengersOnBoard = town.pickupPassengers(this.capacity);
  }

  // --- Track reservations ---

  // Extend the reservation from just past limitIndex through the next safe
  // waiting point on the route: the first segment whose exit carries a
  // signal for this direction of travel, or the end of the route (the
  // platform stop). Before reserving, the provisional tail beyond limitIndex
  // is re-pathed with other trains' reservations penalized and a
  // sufficiently better tail is spliced in. The whole slice is reserved
  // atomically; on failure limitIndex and the held reservations are
  // unchanged. Returns true if the path ahead is covered.
  tryExtendReservation() {
    if (this.limitIndex >= this.route.length - 1) return true;
    this._repathProvisionalTail();
    const slice = [];
    let end = this.limitIndex;
    for (let i = this.limitIndex + 1; i < this.route.length; i++) {
      slice.push(this.route[i]);
      end = i;
      if (this.route[i].exitSignal) break;
    }
    if (!this.tryReserve(slice)) return false;
    this.limitIndex = end;
    return true;
  }

  // Re-path the provisional tail (route[limitIndex + 1:]) to targetPlatform
  // with other trains' reservations penalized, and splice a better tail onto
  // the kept prefix — history, indices, and held reservations stay intact.
  // Hysteresis: a free tail is only abandoned for one cheaper by
  // SWITCH_MARGIN; a blocked tail for any cheaper one. Skipped while the
  // train is still anchored at its departure platform. Blocked retries are
  // throttled to one attempt per REROUTE_RETRY_INTERVAL.
  _repathProvisionalTail() {
    if (this.network === null || this.targetPlatform === null) return;
    if (this.limitIndex < this.routeIndex) return; // anchored at the departure platform
    if (this._wasWaiting && this.blockedTime < Train.REROUTE_RETRY_INTERVAL) return;
    this.blockedTime = 0.0;
    const node = this.route[this.limitIndex].nodeEnd;
    const oldTail = this.route.slice(this.limitIndex + 1);
    // The tail must continue the rolling train's heading (no reversal: only
    // a train standing at a stop may change direction).
    const newTail = this.network.findRouteToPlatform(node, this.targetPlatform, this, this.route[this.limitIndex]);
    if (newTail.length === 0) return;
    const oldCost = this.network.routeCost(oldTail, this);
    const newCost = this.network.routeCost(newTail, this);
    const oldBlocked = oldTail.some((seg) => this.isBlocked(seg));
    const margin = oldBlocked ? 0.0 : Train.SWITCH_MARGIN;
    if (newCost >= oldCost - margin) return; // keep the current plan
    this.route = this.route.slice(0, this.limitIndex + 1).concat(newTail);
    // The new tail may enter the destination platform from the other end.
    this.stopProgress = this.stopPointOn(this.route[this.route.length - 1]);
  }

  // Head halt point (progress) on a platform segment that centers the
  // consist on the platform.
  stopPointOn(platformSeg) {
    const total = platformSeg.length();
    if (total <= 0) return 1.0;
    return clamp(0.5 + this.consistLength() / (2.0 * total), 0, 1);
  }

  // Reserve every segment for this train, all-or-nothing: if any segment (or
  // its reverse twin) is held by another train, nothing is reserved and
  // blockedBy records the holder.
  tryReserve(segs) {
    for (const seg of segs) {
      const blocker = this.blockingTrain(seg);
      if (blocker !== null) {
        this.blockedBy = blocker;
        return false;
      }
    }
    for (const seg of segs) {
      if (seg.reservedBy !== this) {
        seg.reservedBy = this;
        this.reserved.push(seg);
      }
    }
    this.blockedBy = null;
    return true;
  }

  // The other train making a segment unavailable to this one: the holder of
  // the segment, of its reverse twin, or of a track it meets at a flat
  // crossing. Null when the segment is free.
  blockingTrain(seg) {
    let holder = this._holderOf(seg);
    if (holder !== null) return holder;
    for (const crossing of seg.crossings) {
      const other = crossing.otherTrack(seg);
      if (other === null) continue;
      holder = this._holderOf(other);
      if (holder !== null) return holder;
    }
    return null;
  }

  // The train holding either direction of a physical track, unless that
  // train is this one. Null when the track is free.
  _holderOf(seg) {
    if (seg.reservedBy !== null && seg.reservedBy !== this) return seg.reservedBy;
    const rev = seg.reverse;
    if (rev !== null && rev.reservedBy !== null && rev.reservedBy !== this) return rev.reservedBy;
    return null;
  }

  // Whether a segment is unavailable to this train.
  isBlocked(seg) {
    return this.blockingTrain(seg) !== null;
  }

  // Release one held segment (no-op unless this train is the holder).
  release(seg) {
    if (seg.reservedBy === this) seg.reservedBy = null;
    erase(this.reserved, seg);
  }

  // Release every reservation this train holds.
  releaseAll() {
    for (const seg of this.reserved) {
      if (seg.reservedBy === this) seg.reservedBy = null;
    }
    this.reserved = [];
  }
}
