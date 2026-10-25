import { suite, t, eq, approx, check, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { Train } from '../src/train.js';
import { Game, GameState } from '../src/game.js';

const J = (x, y) => NetworkNode.junction(V(x, y));
const town = (x, y) => new Town(V(x, y), '#fff');
const last = (arr) => arr[arr.length - 1];
const DT = 1 / 60;

function sameArray(a, b) {
  check(a.length === b.length && a.every((x, i) => x === b[i]), 'expected arrays to match');
}

// A self-contained island at height y: a straight track with two stationed
// towns on it.
function island(m, y) {
  const ed = m.editor;
  ed.createBidirectionalTrack(J(0, y), J(1200, y), []);
  const a = town(300, y + 30);
  const b = town(900, y + 30);
  m.towns.push(a, b);
  ed.placeStation(V(300, y), m.towns);
  ed.placeStation(V(900, y), m.towns);
  return [a, b];
}

// No two trains may hold the same physical track.
function reservationsDisjoint(trains) {
  for (let i = 0; i < trains.length; i++) {
    for (const seg of trains[i].reserved) {
      for (let j = 0; j < trains.length; j++) {
        if (j === i) continue;
        if (trains[j].reserved.includes(seg)) return false;
        if (seg.reverse !== null && trains[j].reserved.includes(seg.reverse)) return false;
      }
    }
  }
  return true;
}

// Three towns on a main line with one branch; X, Y and Z are signal nodes on
// the three approaches to the junction.
function branchJunction(m) {
  const ed = m.editor;
  const x = J(700, 300), j = J(800, 300), z = J(900, 300), y = J(900, 240);
  ed.createBidirectionalTrack(J(100, 300), x, []);
  ed.createBidirectionalTrack(x, j, []);
  ed.createBidirectionalTrack(j, z, []);
  ed.createBidirectionalTrack(z, J(1600, 300), []);
  ed.createBidirectionalTrack(j, y, []);
  ed.createBidirectionalTrack(y, J(1500, 60), []);
  const t1 = town(300, 340), t2 = town(1250, 340), t3 = town(1200, 110);
  m.towns.push(t1, t2, t3);
  ed.placeStation(V(300, 300), m.towns);
  ed.placeStation(V(1250, 300), m.towns);
  ed.placeStation(V(1200, 150), m.towns);
  m.roster[0].orders = [t1, t2];
  m._buyTrain();
  m.roster[1].orders = [t3, t1];
  return { x, j, z, y };
}

// Put a two-way signal on every direction arriving at a node.
function twoWaySignal(net, n) {
  for (const seg of net.getIncoming(n)) seg.exitSignal = true;
}

// A one-way signal at a node serving only the eastbound direction.
function oneWaySignalEast(net, n, loose) {
  for (const seg of net.getIncoming(n)) {
    const eastbound = seg.nodeStart.position.x < n.position.x;
    seg.exitSignal = eastbound;
    seg.looseOneWay = eastbound && loose;
  }
}

// Loop layout for the lookahead unit tests: from s, a short path (via x) to
// the platform's entry end and a long free path (via y) to its exit end.
function rerouteWorld() {
  const m = new Game();
  const ed = m.editor;
  const q = J(-100, 0), s = J(0, 0), x = J(100, 0), entry = J(200, 0), exit = J(400, 0), y = J(500, 0);
  const qs = ed.createBidirectionalTrack(q, s, []);
  const sx = ed.createBidirectionalTrack(s, x, []);
  ed.createBidirectionalTrack(x, entry, []);
  ed.createBidirectionalTrack(entry, exit, []);
  ed.createBidirectionalTrack(exit, y, []);
  const sy = ed.createBidirectionalTrack(y, s, [V(620, 200), V(200, 250)]);
  const tw = town(300, 50);
  m.towns.push(tw);
  isTrue(ed.placeStation(V(300, 0), m.towns) !== null);
  const plat = tw.station.platforms[0];
  const tr = new Train();
  tr.orders = [tw];
  tr.currentOrderIndex = 0;
  tr.network = m.network;
  tr.targetPlatform = plat;
  tr.route = [qs, ...m.network.findRouteToPlatform(s, plat)];
  tr.routeIndex = 0;
  tr.segmentProgress = 1.0;
  tr.stopProgress = tr.stopPointOn(last(tr.route));
  isTrue(tr.tryReserve([qs]));
  tr.limitIndex = 0;
  return { m, town: tw, qs, sx, sy, tr };
}

export function runAll() {
  suite('TestMultiTrain');
  t('fleet_cost_charged_at_start', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[1], tw[0]];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    eq(m.money, 1000 - 500 - 2 * 150);
    eq(m.trains.length, 2);
  });
  t('start_rejected_when_broke', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[1], tw[0]];
    m.money = 700;
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    eq(m.money, 700);
    isTrue(m.statusMessage.includes('Not enough money'));
  });
  t('start_rejected_same_first_stop', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[0], tw[1]];
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    eq(m.money, 1000);
    isTrue(m.statusMessage.includes('same station'));
  });
  t('start_rejected_train_missing_stops', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    isTrue(m.statusMessage.includes('Train 2'));
  });
  t('two_islands_both_trains_deliver', () => {
    const m = new Game();
    const i1 = island(m, 0);
    const i2 = island(m, 600);
    m.roster[0].orders = [i1[0], i1[1]];
    m._buyTrain();
    m.roster[1].orders = [i2[0], i2[1]];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true;
    const wrapped = [false, false];
    for (let tick = 0; tick < 2400; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('head_on_single_track_never_overlaps', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[1], tw[0]];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true;
    for (let tick = 0; tick < 900; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
    }
    isTrue(disjoint);
    isTrue(m.trains[0].waitingForTrack);
    isTrue(m.trains[1].waitingForTrack);
  });
  t('signals_let_opposing_trains_pass', () => {
    const m = new Game();
    const ed = m.editor;
    const p = J(700, 300), q = J(1100, 300);
    const aEnd = J(500, 100), cEnd = J(500, 500), bEnd = J(1300, 100), dEnd = J(1300, 500);
    ed.createBidirectionalTrack(J(0, 100), aEnd, []);
    ed.createBidirectionalTrack(aEnd, p, []);
    ed.createBidirectionalTrack(J(0, 500), cEnd, []);
    ed.createBidirectionalTrack(cEnd, p, []);
    ed.createBidirectionalTrack(p, q, []);
    ed.createBidirectionalTrack(q, bEnd, []);
    ed.createBidirectionalTrack(bEnd, J(1800, 100), []);
    ed.createBidirectionalTrack(q, dEnd, []);
    ed.createBidirectionalTrack(dEnd, J(1800, 500), []);
    const a = town(200, 140), b = town(1550, 140), c = town(200, 540), d = town(1550, 540);
    m.towns.push(a, b, c, d);
    isTrue(ed.placeStation(V(200, 100), m.towns) !== null);
    isTrue(ed.placeStation(V(1550, 100), m.towns) !== null);
    isTrue(ed.placeStation(V(200, 500), m.towns) !== null);
    isTrue(ed.placeStation(V(1550, 500), m.towns) !== null);
    for (const pos of [V(450, 100), V(1350, 100), V(450, 500), V(1350, 500)]) {
      isTrue(ed.placeOrCycleSignal(pos));
    }
    m.roster[0].orders = [a, b];
    m._buyTrain();
    m.roster[1].orders = [d, c];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true, sawWait = false, flagged = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 3600; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      m.trains.forEach((tr, i) => {
        if (tr.waitingForTrack) sawWait = true;
        if (tr.currentOrderIndex === 0) wrapped[i] = true;
      });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isTrue(sawWait);
    isFalse(flagged);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('one_way_passing_loop_lets_head_on_trains_pass', () => {
    const m = new Game();
    const ed = m.editor;
    const lw = J(500, 300), le = J(900, 300);
    ed.createBidirectionalTrack(J(0, 300), lw, []);
    ed.createBidirectionalTrack(le, J(1400, 300), []);
    const branch1 = ed.createBidirectionalTrack(lw, le, [V(700, 220)]);
    const branch2 = ed.createBidirectionalTrack(lw, le, [V(700, 380)]);
    branch1.exitSignal = true;
    branch2.reverse.exitSignal = true;
    const a = town(200, 350), b = town(1150, 350);
    m.towns.push(a, b);
    isTrue(ed.placeStation(V(200, 300), m.towns) !== null);
    isTrue(ed.placeStation(V(1150, 300), m.towns) !== null);
    m.roster[0].orders = [a, b];
    m._buyTrain();
    m.roster[1].orders = [b, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isTrue(m.trains[0].route.includes(branch1));
    isFalse(m.trains[0].route.includes(branch2));
    isTrue(m.trains[1].route.includes(branch2.reverse));
    isFalse(m.trains[1].route.includes(branch1.reverse));
    let disjoint = true, sawPass = false, flagged = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 3600; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      const s0 = m.trains[0].currentSegment(), s1 = m.trains[1].currentSegment();
      if ((s0 === branch1 || s0 === branch2.reverse) && (s1 === branch1 || s1 === branch2.reverse)) sawPass = true;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isTrue(sawPass);
    isFalse(flagged);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('dispatch_routes_around_parked_train', () => {
    const m = new Game();
    const ed = m.editor;
    const j1 = J(600, 0), j2 = J(1400, 0);
    ed.createBidirectionalTrack(J(0, 0), j1, []);
    ed.createBidirectionalTrack(j1, j2, []);
    ed.createBidirectionalTrack(j2, J(2000, 0), []);
    const bypass = ed.createBidirectionalTrack(j1, j2, [V(1000, 250)]);
    const b = town(200, 50), a = town(1000, 50), c = town(1800, 50);
    m.towns.push(b, a, c);
    isTrue(ed.placeStation(V(200, 0), m.towns) !== null);
    isTrue(ed.placeStation(V(1000, 0), m.towns) !== null);
    isTrue(ed.placeStation(V(1800, 0), m.towns) !== null);
    m.roster[0].orders = [a, b];
    m._buyTrain();
    m.roster[1].orders = [b, c];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    const t2 = m.trains[1];
    isTrue(t2.route.includes(bypass) || t2.route.includes(bypass.reverse));
    const aPlat = a.station.platforms[0];
    isFalse(t2.route.includes(aPlat.segment));
    isFalse(t2.route.includes(aPlat.reverseSegment));
  });
  t('dispatch_with_no_free_alternative_still_routes', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[1], tw[0]];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isTrue(m.trains[0].hasRoute());
    isTrue(m.trains[1].hasRoute());
  });
  t('two_way_passing_loop_diverts_at_speed', () => {
    const m = new Game();
    const ed = m.editor;
    const sa = J(380, 300), sb = J(1020, 300), lw = J(500, 300), le = J(900, 300);
    ed.createBidirectionalTrack(J(0, 300), sa, []);
    ed.createBidirectionalTrack(sa, lw, []);
    const branch1 = ed.createBidirectionalTrack(lw, le, [V(700, 240)]);
    const branch2 = ed.createBidirectionalTrack(lw, le, [V(700, 430)]);
    ed.createBidirectionalTrack(le, sb, []);
    ed.createBidirectionalTrack(sb, J(1400, 300), []);
    const a = town(200, 350), b = town(1150, 350);
    m.towns.push(a, b);
    isTrue(ed.placeStation(V(200, 300), m.towns) !== null);
    isTrue(ed.placeStation(V(1150, 300), m.towns) !== null);
    for (const s of [branch1, branch1.reverse, branch2, branch2.reverse]) s.exitSignal = true;
    for (const s of [...m.network.getIncoming(sa), ...m.network.getIncoming(sb)]) s.exitSignal = true;
    m.roster[0].orders = [a, b];
    m._buyTrain();
    m.roster[1].orders = [b, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isTrue(m.trains[0].route.includes(branch1));
    isTrue(m.trains[1].route.includes(branch1.reverse));
    const loopSegs = [branch1, branch1.reverse, branch2, branch2.reverse];
    let disjoint = true, sawPass = false, waitedBeforePass = false, flagged = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 3600; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      if (loopSegs.includes(m.trains[0].currentSegment()) && loopSegs.includes(m.trains[1].currentSegment())) sawPass = true;
      m.trains.forEach((tr, i) => {
        if (!sawPass && tr.waitingForTrack) waitedBeforePass = true;
        if (tr.currentOrderIndex === 0) wrapped[i] = true;
      });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isTrue(sawPass);
    isFalse(waitedBeforePass);
    isFalse(flagged);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('convoy_spreads_across_branches', () => {
    const m = new Game();
    const ed = m.editor;
    const m1 = J(150, 300), sa = J(300, 300), lw = J(420, 300), le = J(1220, 300), sb = J(1340, 300);
    const f1 = J(1550, 180), f2 = J(1550, 420);
    ed.createBidirectionalTrack(J(-800, 300), m1, []);
    ed.createBidirectionalTrack(m1, sa, []);
    ed.createBidirectionalTrack(sa, lw, []);
    const branch1 = ed.createBidirectionalTrack(lw, le, [V(820, 240)]);
    const branch2 = ed.createBidirectionalTrack(lw, le, [V(820, 450)]);
    ed.createBidirectionalTrack(le, sb, []);
    ed.createBidirectionalTrack(sb, f1, []);
    ed.createBidirectionalTrack(f1, J(1900, 180), []);
    ed.createBidirectionalTrack(sb, f2, []);
    ed.createBidirectionalTrack(f2, J(1900, 420), []);
    const w2 = town(-500, 350), w1 = town(-100, 350), e1 = town(1750, 230), e2 = town(1750, 470);
    m.towns.push(w2, w1, e1, e2);
    isTrue(ed.placeStation(V(-500, 300), m.towns) !== null);
    isTrue(ed.placeStation(V(-100, 300), m.towns) !== null);
    isTrue(ed.placeStation(V(1750, 180), m.towns) !== null);
    isTrue(ed.placeStation(V(1750, 420), m.towns) !== null);
    isTrue(branch1.length() < branch2.length());
    for (const s of [branch1, branch1.reverse, branch2, branch2.reverse]) s.exitSignal = true;
    for (const n of [m1, sa, sb]) for (const s of m.network.getIncoming(n)) s.exitSignal = true;
    m.roster[0].orders = [w1, e1];
    m._buyTrain();
    m.roster[1].orders = [w2, e2];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isTrue(m.trains[0].route.includes(branch1));
    isTrue(m.trains[1].route.includes(branch1));
    let disjoint = true, sawSpread = false, flagged = false;
    for (let tick = 0; tick < 900; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      if (m.trains[0].currentSegment() === branch1 && m.trains[1].currentSegment() === branch2) sawSpread = true;
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isTrue(sawSpread);
    isFalse(flagged);
    isTrue(m.trains[1].route.includes(branch2));
  });
  t('lookahead_splices_tail_and_switches_platform_end', () => {
    const w = rerouteWorld();
    const tr = w.tr;
    const plat = w.town.station.platforms[0];
    isTrue(tr.route.includes(w.sx));
    eq(last(tr.route), plat.segment);
    const blocker = new Train();
    isTrue(blocker.tryReserve([w.sx]));
    isTrue(tr.tryExtendReservation());
    isFalse(tr.waitingForTrack);
    eq(tr.route[0], w.qs);
    isTrue(tr.route.includes(w.sy.reverse));
    eq(last(tr.route), plat.reverseSegment);
    approx(tr.stopProgress, tr.stopPointOn(plat.reverseSegment), 0.001);
    eq(tr.limitIndex, tr.route.length - 1);
    for (const s of tr.reserved) isTrue(tr.route.includes(s));
  });
  t('lookahead_unchanged_choice_is_noop', () => {
    const { tr } = rerouteWorld();
    const before = tr.route.slice();
    tr._repathProvisionalTail();
    sameArray(tr.route, before);
    eq(tr.limitIndex, 0);
    eq(tr.reserved.length, 1);
  });
  t('lookahead_skipped_at_anchored_platform', () => {
    const w = rerouteWorld();
    const { m, tr } = w;
    const plat = w.town.station.platforms[0];
    tr.releaseAll();
    tr.route = [plat.segment, ...m.network.findRoute(plat.segment.nodeEnd, w.qs.nodeStart)];
    tr.routeIndex = 0;
    tr.segmentProgress = 1.0;
    tr.limitIndex = -1;
    tr.orders = [w.town];
    const blocker = new Train();
    isTrue(blocker.tryReserve([tr.route[1]]));
    const before = tr.route.slice();
    isFalse(tr.tryExtendReservation());
    sameArray(tr.route, before);
    eq(tr.reserved.length, 0);
    eq(tr.limitIndex, -1);
  });
  t('lookahead_keeps_near_equal_free_tail', () => {
    const m = new Game();
    const ed = m.editor;
    const q = J(-100, 0), s = J(0, 0), x = J(300, 0), entry = J(400, 0), exit = J(600, 0);
    const qs = ed.createBidirectionalTrack(q, s, []);
    const direct = ed.createBidirectionalTrack(s, x, []);
    const curved = ed.createBidirectionalTrack(s, x, [V(150, 70)]);
    const xe = ed.createBidirectionalTrack(x, entry, []);
    ed.createBidirectionalTrack(entry, exit, []);
    const tw = town(500, 50);
    m.towns.push(tw);
    isTrue(ed.placeStation(V(500, 0), m.towns) !== null);
    const plat = tw.station.platforms[0];
    isTrue(curved.length() > direct.length());
    isTrue(curved.length() - direct.length() < Train.SWITCH_MARGIN);
    const tr = new Train();
    tr.network = m.network;
    tr.targetPlatform = plat;
    tr.route = [qs, curved, xe, plat.segment];
    tr.routeIndex = 0;
    tr.segmentProgress = 1.0;
    tr.stopProgress = tr.stopPointOn(plat.segment);
    isTrue(tr.tryReserve([qs]));
    tr.limitIndex = 0;
    const before = tr.route.slice();
    tr._repathProvisionalTail();
    sameArray(tr.route, before);
  });
  t('lookahead_adopts_much_shorter_free_tail', () => {
    const w = rerouteWorld();
    const { m, tr } = w;
    const plat = w.town.station.platforms[0];
    const blocker = new Train();
    isTrue(blocker.tryReserve([w.sx]));
    const longTail = m.network.findRouteToPlatform(w.qs.nodeEnd, plat, tr);
    blocker.releaseAll();
    isTrue(longTail.includes(w.sy.reverse));
    tr.route = [w.qs, ...longTail];
    tr.stopProgress = tr.stopPointOn(last(tr.route));
    tr._repathProvisionalTail();
    isTrue(tr.route.includes(w.sx));
    eq(last(tr.route), plat.segment);
    approx(tr.stopProgress, tr.stopPointOn(plat.segment), 0.001);
  });
  t('branch_junction_deadlocks_on_two_way_signals', () => {
    const m = new Game();
    const n = branchJunction(m);
    twoWaySignal(m.network, n.x);
    twoWaySignal(m.network, n.y);
    twoWaySignal(m.network, n.z);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let flagged = false;
    for (let tick = 0; tick < 3600; tick++) {
      m.process(DT);
      if (m.deadlockedTrains.length > 0) {
        flagged = true;
        break;
      }
    }
    isTrue(flagged);
    for (const tr of m.trains) approx(tr.currentPosition().y, 300, 1);
  });
  t('branch_junction_strict_one_way_is_unroutable', () => {
    const m = new Game();
    const n = branchJunction(m);
    oneWaySignalEast(m.network, n.x, false);
    twoWaySignal(m.network, n.y);
    twoWaySignal(m.network, n.z);
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    isTrue(m.statusMessage.includes('no track route'));
  });
  t('branch_junction_loose_one_way_holds_train_on_branch', () => {
    const m = new Game();
    const n = branchJunction(m);
    oneWaySignalEast(m.network, n.x, true);
    twoWaySignal(m.network, n.y);
    twoWaySignal(m.network, n.z);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true, flagged = false, waitedOnBranch = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 3600; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      if (m.trains[1].waitingForTrack && m.trains[1].currentPosition().y < 290) waitedOnBranch = true;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isFalse(flagged);
    isTrue(waitedOnBranch);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('nose_to_nose_deadlock_detected', () => {
    const m = new Game();
    const tw = island(m, 0);
    m.roster[0].orders = [tw[0], tw[1]];
    m._buyTrain();
    m.roster[1].orders = [tw[1], tw[0]];
    m._startSimulation();
    for (let tick = 0; tick < 150; tick++) m.process(DT);
    eq(m.state, GameState.SIMULATING);
    eq(m.deadlockedTrains.length, 2);
    isTrue(m.statusMessage.includes('Deadlock'));
  });
  t('queue_behind_moving_leader_not_deadlocked', () => {
    const m = new Game();
    const ed = m.editor;
    const pts = [V(300, 0), V(900, 0), V(1200, 300), V(1200, 900), V(900, 1200), V(300, 1200), V(0, 900), V(0, 300)];
    const ring = pts.map((p) => NetworkNode.junction(p));
    for (let i = 0; i < ring.length; i++) ed.createBidirectionalTrack(ring[i], ring[(i + 1) % ring.length], []);
    const a = town(400, 50), b = town(1150, 600), c = town(600, 1150);
    m.towns.push(a, b, c);
    isTrue(ed.placeStation(V(400, 0), m.towns) !== null);
    isTrue(ed.placeStation(V(1200, 600), m.towns) !== null);
    isTrue(ed.placeStation(V(600, 1200), m.towns) !== null);
    m.roster[0].orders = [a, b, c];
    m._buyTrain();
    m.roster[1].orders = [b, c, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    for (const tr of m.trains) tr.speed = 450;
    let flagged = false, sawWait = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 2700; tick++) {
      m.process(DT);
      if (m.deadlockedTrains.length > 0) flagged = true;
      m.trains.forEach((tr, i) => {
        if (tr.waitingForTrack) sawWait = true;
        if (tr.currentOrderIndex === 0) wrapped[i] = true;
      });
    }
    eq(m.state, GameState.SIMULATING);
    isFalse(flagged);
    isTrue(sawWait);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('all_blocked_timeout_flags_deadlock', () => {
    const m = new Game();
    m.state = GameState.SIMULATING;
    const a = new Train(), b = new Train();
    a.waitingForTrack = true;
    b.waitingForTrack = true;
    m.trains = [a, b];
    for (let tick = 0; tick < 660; tick++) m.process(DT);
    eq(m.deadlockedTrains.length, 2);
    isTrue(m.statusMessage.includes('Deadlock'));
  });
}
