import { NetworkNode } from './network_node.js';
import { TrackSegment } from './track_segment.js';
import { TrackNetwork } from './track_network.js';
import { Town } from './town.js';
import { Station } from './station.js';
import { Platform } from './platform.js';
import { TrainPlan } from './train_plan.js';

// A deep copy of the editable world state (towns, network, train roster),
// used as an entry on the undo stack. Capture before a build action; restore
// swaps the cloned objects in as the live state. Money, game state, and the
// running trains are deliberately not snapshotted — undo is an editing-mode
// tool.
export class GameSnapshot {
  constructor() {
    // Cloned towns (stations/platforms rewired onto the cloned network).
    this.towns = [];
    // Cloned track network.
    this.network = null;
    // Cloned per-train plans (orders point into the cloned towns).
    this.roster = [];
    // Index of the roster train that was selected for editing.
    this.selectedTrain = 0;
    // Palette index for the next town placed.
    this.nextColorIndex = 0;
  }

  // Orders of the selected plan — mirrors Game.trainOrders.
  get trainOrders() {
    return this.roster[this.selectedTrain].orders;
  }

  // Deep-copy the editable state of the game. Old→new identity maps keep the
  // clone internally consistent: reverse twins, adjacency, and
  // platform/station wiring all point at cloned objects.
  static capture(game) {
    const snap = new GameSnapshot();
    const nodeMap = new Map();
    const segmentMap = new Map();
    const net = game.network;

    // Nodes first, so segments can be built with their mapped endpoints.
    for (const node of net.nodes) nodeMap.set(node, NetworkNode.junction(node.position));

    // Bare segment clones. The curve is duplicated directly — a segment does
    // not retain its waypoint list, so the curve is the source of truth.
    for (const seg of net.segments) {
      const clone = TrackSegment.fromCurve(nodeMap.get(seg.nodeStart), nodeMap.get(seg.nodeEnd), seg.curve);
      clone.copySignalFrom(seg);
      segmentMap.set(seg, clone);
    }
    for (const seg of net.segments) {
      if (seg.reverse !== null && segmentMap.has(seg.reverse)) {
        segmentMap.get(seg).reverse = segmentMap.get(seg.reverse);
      }
    }

    // Rebuild the network with crossing detection off — the geometry is
    // unchanged, so the known set is cloned below instead.
    snap.network = new TrackNetwork();
    for (const seg of net.segments) snap.network.addSegment(segmentMap.get(seg), false);
    for (const node of net.nodes) snap.network.addNode(nodeMap.get(node));

    for (const crossing of net.crossings) {
      const a = crossing.trackA;
      const b = crossing.trackB;
      if (a === null || b === null || !segmentMap.has(a) || !segmentMap.has(b)) continue;
      snap.network.registerCrossing(segmentMap.get(a), segmentMap.get(b), crossing.position, crossing.angle);
    }

    // Towns, with stations/platforms rewired onto the cloned segments.
    const townMap = new Map();
    for (const town of game.towns) {
      const townClone = new Town(town.position, town.color);
      townClone.radius = town.radius;
      townClone.waiting = town.waiting;
      if (town.station !== null) {
        const stationClone = new Station(townClone);
        for (const platform of town.station.platforms) {
          const revClone = platform.reverseSegment !== null ? segmentMap.get(platform.reverseSegment) : null;
          const platformClone = new Platform(segmentMap.get(platform.segment), revClone, platform.side);
          platformClone.width = platform.width;
          platformClone.station = stationClone;
          platformClone.segment.platform = platformClone;
          if (platformClone.reverseSegment !== null) platformClone.reverseSegment.platform = platformClone;
          stationClone.platforms.push(platformClone);
        }
        townClone.station = stationClone;
      }
      townMap.set(town, townClone);
      snap.towns.push(townClone);
    }

    for (const plan of game.roster) {
      const planClone = new TrainPlan();
      planClone.carCount = plan.carCount;
      for (const town of plan.orders) planClone.orders.push(townMap.get(town));
      snap.roster.push(planClone);
    }
    snap.selectedTrain = game.selectedTrain;
    snap.nextColorIndex = game.nextColorIndex;
    return snap;
  }

  // Swap this snapshot's objects in as the live state. An undo stack entry
  // is popped when restored, so it is never restored twice and needs no
  // re-cloning.
  restore(game) {
    game.towns = this.towns;
    game.network = this.network;
    game.roster = this.roster;
    game.selectedTrain = this.selectedTrain;
    game.nextColorIndex = this.nextColorIndex;
    game.editor.network = this.network;
    // Hover references point into the discarded world; the next mouse
    // motion re-derives them.
    game.hoveredTown = null;
    game.hoveredJunction = null;
    game.worldVersion++;
  }
}
