import { suite, t, eq, approx, gt, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { TrainPlan } from '../src/train_plan.js';
import { GameSnapshot } from '../src/game_snapshot.js';
import { Game } from '../src/game.js';

// A world with a curved pair, a split junction, and a stationed town.
// 10 segments, 6 junctions.
function buildWorld(m) {
  const ed = m.editor;
  const a = NetworkNode.junction(V(0, 0));
  const b = NetworkNode.junction(V(600, 0));
  const c = NetworkNode.junction(V(1200, 0));
  ed.createBidirectionalTrack(a, b, [V(300, 60)]);
  ed.createBidirectionalTrack(b, c, []);
  ed.splitTrackAtHit(ed.findTrackAt(V(900, 0)));
  const town = new Town(V(750, 30), '#2e8b57');
  town.waiting = 7.0;
  m.towns.push(town);
  ed.placeStation(V(750, 0), m.towns);
  m.trainOrders.push(town);
  m.nextColorIndex = 3;
  return town;
}

const nodeAt = (net, pos) => net.nodes.find((n) => n.position.distanceTo(pos) < 1) ?? null;
const segBetween = (net, p0, p1) => net.segments.find((s) =>
  s.nodeStart.position.distanceTo(p0) < 1 && s.nodeEnd.position.distanceTo(p1) < 1) ?? null;

export function runAll() {
  suite('TestGameSnapshot');
  t('clone_counts_match', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    eq(snap.network.segments.length, m.network.segments.length);
    eq(snap.network.segments.length, 10);
    eq(snap.network.nodes.length, 6);
    eq(snap.towns.length, 1);
    eq(snap.trainOrders.length, 1);
    eq(snap.nextColorIndex, 3);
  });
  t('clone_twins_are_mutual', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    for (const s of snap.network.segments) {
      isTrue(s.reverse !== null);
      eq(s.reverse.reverse, s);
      eq(s.reverse.nodeStart, s.nodeEnd);
      eq(s.reverse.nodeEnd, s.nodeStart);
      isFalse(m.network.segments.includes(s));
    }
  });
  t('clone_curves_preserved', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    const original = segBetween(m.network, V(0, 0), V(600, 0));
    const clone = segBetween(snap.network, V(0, 0), V(600, 0));
    isTrue(clone !== null);
    approx(clone.length(), original.length(), 1);
    approx(clone.positionAt(0.5).y, original.positionAt(0.5).y, 1);
    gt(clone.positionAt(0.5).y, 20);
  });
  t('clone_station_wiring_survives', () => {
    const m = new Game();
    const town = buildWorld(m);
    const snap = GameSnapshot.capture(m);
    const cloneTown = snap.towns[0];
    isTrue(cloneTown !== town);
    isTrue(cloneTown.station !== null);
    isTrue(cloneTown.station !== town.station);
    eq(cloneTown.waiting, 7.0);
    const p = cloneTown.station.platforms[0];
    isTrue(p.segment.isPlatformSegment());
    eq(p.segment.platform, p);
    eq(p.reverseSegment.platform, p);
    eq(p.station.town, cloneTown);
    eq(p.segment.reverse, p.reverseSegment);
    eq(p.side, town.station.platforms[0].side);
    isTrue(snap.network.segments.includes(p.segment));
    isTrue(snap.network.segments.includes(p.reverseSegment));
  });
  t('clone_orders_identity_mapped', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    eq(snap.trainOrders[0], snap.towns[0]);
  });
  t('clone_roster_plans_mapped', () => {
    const m = new Game();
    const town = buildWorld(m);
    m.roster.push(new TrainPlan());
    m.roster[1].carCount = 3;
    m.roster[1].orders.push(town);
    m.selectedTrain = 1;
    const snap = GameSnapshot.capture(m);
    eq(snap.roster.length, 2);
    eq(snap.selectedTrain, 1);
    isTrue(snap.roster[1] !== m.roster[1]);
    eq(snap.roster[1].carCount, 3);
    eq(snap.roster[1].orders[0], snap.towns[0]);
  });
  t('clone_routes_across_adjacency', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    const from = nodeAt(snap.network, V(0, 0));
    const to = nodeAt(snap.network, V(1200, 0));
    isTrue(from !== null);
    isTrue(to !== null);
    const route = snap.network.findRoute(from, to);
    gt(route.length, 0);
    eq(route[route.length - 1].nodeEnd, to);
  });
  t('clone_isolated_junction_survives', () => {
    const m = new Game();
    buildWorld(m);
    m.network.addNode(NetworkNode.junction(V(50, 500)));
    isTrue(nodeAt(GameSnapshot.capture(m).network, V(50, 500)) !== null);
  });
  t('clone_signal_flags_preserved', () => {
    const m = new Game();
    buildWorld(m);
    segBetween(m.network, V(0, 0), V(600, 0)).exitSignal = true;
    const clone = segBetween(GameSnapshot.capture(m).network, V(0, 0), V(600, 0));
    isTrue(clone.exitSignal);
    isFalse(clone.reverse.exitSignal);
    isFalse(clone.looseOneWay);
    segBetween(m.network, V(0, 0), V(600, 0)).looseOneWay = true;
    const loose = segBetween(GameSnapshot.capture(m).network, V(0, 0), V(600, 0));
    isTrue(loose.exitSignal);
    isTrue(loose.looseOneWay);
  });
  t('mutating_original_leaves_clone_untouched', () => {
    const m = new Game();
    const town = buildWorld(m);
    const snap = GameSnapshot.capture(m);
    m.editor.tryDeleteTrackAt(V(1050, 0));
    town.waiting = 99.0;
    m.towns.length = 0;
    eq(m.network.segments.length, 8);
    eq(snap.network.segments.length, 10);
    eq(snap.towns.length, 1);
    eq(snap.towns[0].waiting, 7.0);
  });
  t('restore_swaps_state_into_main', () => {
    const m = new Game();
    buildWorld(m);
    const snap = GameSnapshot.capture(m);
    m.hoveredTown = m.towns[0];
    m.nextColorIndex = 8;
    snap.restore(m);
    eq(m.network, snap.network);
    eq(m.editor.network, snap.network);
    eq(m.towns[0], snap.towns[0]);
    eq(m.trainOrders[0], snap.towns[0]);
    eq(m.nextColorIndex, 3);
    eq(m.hoveredTown, null);
    eq(m.hoveredJunction, null);
  });
}
