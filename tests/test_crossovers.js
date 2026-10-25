import { suite, t, eq, approx, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { CrossingKind } from '../src/track_crossing.js';
import { TrackEditor } from '../src/track_editor.js';
import { Town } from '../src/town.js';
import { Train } from '../src/train.js';
import { Game, GameState } from '../src/game.js';

const J = (x, y) => NetworkNode.junction(V(x, y));
const DT = 1 / 60;
const midY = (seg) => seg.positionAt(0.5).y;

// Terminus A on single track (x 0..400), a double section X(400)→Y(1600)
// with B mid-way at x=1000 (station optional), terminus C on single track
// beyond. The eastbound (right-hand) line runs at y = +12, westbound at
// y = -12; signal nodes sit at x = 520, 720, 900, 1100, 1280, 1480, and B's
// platforms span 940..1060. Scissors fit at x≈760..850 (west of B) and
// x≈1150..1250 (east of B).
function line(m, { stationB = true } = {}) {
  const ed = m.editor;
  const x = J(400, 0);
  const y = J(1600, 0);
  ed.createBidirectionalTrack(J(0, 0), x, []);
  ed.createDoubleTrack(x, y, []);
  ed.createBidirectionalTrack(y, J(2000, 0), []);
  const a = new Town(V(200, 40), '#6495ed', 'A');
  const b = new Town(V(1000, 50), '#cd5c5c', 'B');
  const c = new Town(V(1800, 40), '#2e8b57', 'C');
  m.towns.push(a, b, c);
  isTrue(ed.placeStation(V(200, 0), m.towns) !== null);
  if (stationB) isTrue(ed.placeStation(V(1000, 12), m.towns) !== null);
  isTrue(ed.placeStation(V(1800, 0), m.towns) !== null);
  return { a, b, c, x, y };
}

const platforms = (...towns) => towns.map((tw) => tw.station.platforms);
const crossovers = (m) => m.network.segments.filter((s) => s.crossover);
// Running-direction signals carried into the node at (px, py).
function signalsNear(m, px, py) {
  return m.network.segments.filter((s) => s.exitSignal && s.nodeEnd.position.distanceTo(V(px, py)) < 4);
}
const eastbound = (seg) => Math.abs(seg.angleAt(1)) < 0.3;
const westbound = (seg) => Math.abs(Math.abs(seg.angleAt(1)) - Math.PI) < 0.3;

function reservationsDisjoint(trains) {
  for (let i = 0; i < trains.length; i++) {
    for (const seg of trains[i].reserved) {
      for (let j = 0; j < trains.length; j++) {
        if (j === i) continue;
        if (trains[j].reserved.includes(seg) || (seg.reverse !== null && trains[j].reserved.includes(seg.reverse))) return false;
      }
    }
  }
  return true;
}

// Record [town name, platform y] at every platform arrival.
function recordArrivals(m) {
  const arrivals = [];
  const original = m._arriveAtPlatform.bind(m);
  m._arriveAtPlatform = (tr) => {
    const seg = tr.currentSegment();
    arrivals.push([seg.platform.station.town.name, midY(seg)]);
    original(tr);
  };
  return arrivals;
}

// Run a started game; report what happened.
function run(m, seconds) {
  let disjoint = true, flagged = false, usedCrossover = false;
  const wraps = m.trains.map(() => 0);
  const lastIdx = m.trains.map((tr) => tr.currentOrderIndex);
  for (let tick = 0; tick < seconds * 60; tick++) {
    m.process(DT);
    if (m.state !== GameState.SIMULATING) break;
    if (!reservationsDisjoint(m.trains)) disjoint = false;
    if (m.deadlockedTrains.length > 0) flagged = true;
    m.trains.forEach((tr, i) => {
      if (tr.currentSegment()?.crossover) usedCrossover = true;
      if (tr.currentOrderIndex !== lastIdx[i] && tr.currentOrderIndex === 0) wraps[i]++;
      lastIdx[i] = tr.currentOrderIndex;
    });
  }
  return { disjoint, flagged, wraps, usedCrossover, running: m.state === GameState.SIMULATING };
}

export function runAll() {
  suite('TestCrossovers');
  t('one_click_lays_a_scissors_crossover', () => {
    const m = new Game();
    line(m);
    const before = m.network.segments.length;
    const diamondsBefore = m.network.crossings.filter((c) => c.kind === CrossingKind.DIAMOND).length;
    isTrue(m.editor.placeCrossover(V(1190, 12)));
    // Two splits per line (+8 segments) and two diagonal pairs (+4).
    eq(m.network.segments.length, before + 12);
    const diag = crossovers(m);
    eq(diag.length, 4);
    isTrue(diag.every((s) => s.taper));
    // The diagonals cross at a diamond in the middle.
    const diamonds = m.network.crossings.filter((c) => c.kind === CrossingKind.DIAMOND);
    eq(diamonds.length, diamondsBefore + 1);
    approx(diamonds[diamonds.length - 1].position.y, 0, 2);
    // Each diagonal and each line's middle piece exclude one another.
    eq(m.network.crossings.filter((c) => c.kind === CrossingKind.FOUL).length, 2 + 4);
    // Both diagonals span the same stretch, line to line.
    const xs = diag.map((s) => s.nodeStart.position.x);
    const west = Math.min(...xs);
    const east = Math.max(...xs);
    approx(east - west, TrackEditor.CROSSOVER_LENGTH, 3);
    isTrue(Math.abs((west + east) / 2 - 1190) <= 60);
    // Protecting signals before each line's entry: west end eastbound, east
    // end westbound.
    const guardR = signalsNear(m, west, 12);
    isTrue(guardR.length === 1 && eastbound(guardR[0]) && guardR[0].looseOneWay);
    const guardL = signalsNear(m, east, -12);
    isTrue(guardL.length === 1 && westbound(guardL[0]) && guardL[0].looseOneWay);
  });
  t('through_traffic_never_takes_a_diagonal', () => {
    const m = new Game();
    const { x, y } = line(m);
    m.editor.placeCrossover(V(1190, 12));
    m.editor.placeCrossover(V(810, 12));
    for (const route of [m.network.findRoute(x, y), m.network.findRoute(y, x)]) {
      isTrue(route.length > 0);
      isFalse(route.some((s) => s.crossover));
    }
  });
  t('wrong_way_stretches_to_the_station_are_cleared', () => {
    const m = new Game();
    line(m);
    isTrue(signalsNear(m, 1100, -12).length === 1);
    isTrue(signalsNear(m, 1100, 12).length === 1);
    isTrue(signalsNear(m, 1280, 12).length === 1);
    m.editor.placeCrossover(V(1190, 12));
    // Trailing: B's westbound platform → back east to the scissors.
    eq(signalsNear(m, 1100, -12).length, 0);
    // Facing: from the scissors' entry (west end) wrong-way back to B's
    // eastbound platform...
    eq(signalsNear(m, 1100, 12).length, 0);
    // ...and no waiting point within a train length past either exit.
    eq(signalsNear(m, 1280, 12).length, 0);
    // The section-end signals stay strict.
    isTrue(signalsNear(m, 1480, 12).length === 1);
    isTrue(signalsNear(m, 520, -12).length === 1);
  });
  t('trailing_diagonal_turns_trains_back_b_and_c', () => {
    const m = new Game();
    const { b, c } = line(m);
    eq(m.network.firstUnroutableStop(platforms(b, c)), 0);
    isTrue(m.editor.placeCrossover(V(1190, 12)));
    eq(m.network.firstUnroutableStop(platforms(b, c)), -1);
    m.roster[0].orders = [b, c];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    const r = run(m, 60);
    isTrue(r.running);
    isTrue(r.usedCrossover);
    isTrue(r.wraps[0] >= 2);
  });
  t('facing_diagonal_reaches_the_other_platform', () => {
    const m = new Game();
    const { b, x } = line(m);
    const [east, west] = b.station.platforms.slice().sort((p, q) => midY(q.segment) - midY(p.segment));
    // From the west, B's westbound-line platform is out of reach...
    const arriving = m.network.getIncoming(x).find((s) => s.nodeStart.position.x < 400);
    eq(m.network.findRouteToPlatform(x, west, null, arriving).length, 0);
    // ...until a scissors west of B lets a train cross over to it.
    m.editor.placeCrossover(V(810, 12));
    const route = m.network.findRouteToPlatform(x, west, null, arriving);
    isTrue(route.length > 0 && route.some((s) => s.crossover));
    isTrue(m.network.findRouteToPlatform(x, east, null, arriving).length > 0);
  });
  t('terminating_trains_use_either_platform', () => {
    // A ⇄ B with a scissors west of B. Arriving from the west a train takes
    // B's eastbound platform straight ahead — unless it is occupied, when
    // dispatch prices it out and the facing diagonal takes the train to the
    // westbound line's platform instead, from which it leaves correctly.
    const m = new Game();
    const { a, b, x } = line(m);
    m.editor.placeCrossover(V(810, 12));
    const [eastP, westP] = b.station.platforms.slice().sort((p, q) => midY(q.segment) - midY(p.segment));
    const viable = m.network.viablePlatforms(b.station.platforms, a.station.platforms);
    eq(viable.length, 2);  // both can be left towards A
    const arriving = m.network.getIncoming(x).find((s) => s.nodeStart.position.x < 400);
    const free = m.network.findRouteToStation(x, viable, new Train(), arriving);
    eq(free.platform, eastP);
    const holder = new Train();
    isTrue(holder.tryReserve([eastP.segment]));
    const busy = m.network.findRouteToStation(x, viable, new Train(), arriving);
    eq(busy.platform, westP);
    isTrue(busy.route.some((s) => s.crossover));
    // And it runs: with the eastbound platform held throughout, a shuttle
    // keeps calling at B on the other one.
    m.roster[0].orders = [a, b];
    const arrivals = recordArrivals(m);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    const r = run(m, 60);
    isTrue(r.running);
    isFalse(r.flagged);
    isTrue(r.wraps[0] >= 2);
    const atB = arrivals.filter(([name]) => name === 'B');
    isTrue(atB.length >= 2 && atB.every(([, py]) => py < 0));
  });
  t('turnback_trains_share_the_line_with_through_traffic', () => {
    const m = new Game();
    const { a, b, c } = line(m);
    m.editor.placeCrossover(V(1190, 12));
    m.editor.placeCrossover(V(810, 12));
    m.roster[0].orders = [b, c];
    m._buyTrain();
    m.roster[1].orders = [a, c];
    m._buyTrain();
    m.roster[2].orders = [c, b, a, b];
    m.money = 5000;
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    const r = run(m, 150);
    isTrue(r.running);
    isTrue(r.disjoint);
    isFalse(r.flagged);
    isTrue(r.wraps.every((n) => n >= 2));
  });
  t('crossover_refused_off_the_parallel_run', () => {
    const m = new Game();
    line(m);
    const ed = m.editor;
    const before = m.network.segments.length;
    isFalse(ed.placeCrossover(V(300, 0)));      // single track
    isTrue(ed.lastError.includes('double track'));
    isFalse(ed.placeCrossover(V(450, 6)));      // the section's taper
    isFalse(ed.placeCrossover(V(1000, 12)));    // across B's platforms
    isFalse(ed.placeCrossover(V(1430, 12)));    // no room before the section end
    isFalse(ed.placeCrossover(V(1000, 300)));   // nothing there
    eq(m.network.segments.length, before);
    eq(crossovers(m).length, 0);
    // A second scissors too close to the first is refused too.
    isTrue(ed.placeCrossover(V(810, 12)));
    isFalse(ed.placeCrossover(V(640, -12)));
    isTrue(ed.lastError.length > 0);
  });
  t('undo_removes_the_scissors_and_restores_signals', () => {
    const m = new Game();
    line(m);
    const segs = m.network.segments.length;
    const signals = m.network.segments.filter((s) => s.exitSignal).length;
    const crossings = m.network.crossings.length;
    m.setTool('crossover');
    m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: V(1190, 12) });
    eq(crossovers(m).length, 4);
    eq(m.tool, 'crossover');
    m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: V(300, 0) });  // refused
    eq(m.undoStack.length, 1);
    isTrue(m.statusMessage.includes('double track'));
    m.handleInput({ type: 'key', code: 'KeyU' });
    eq(m.network.segments.length, segs);
    eq(m.network.segments.filter((s) => s.exitSignal).length, signals);
    eq(m.network.crossings.length, crossings);
    eq(crossovers(m).length, 0);
  });
  t('station_built_after_the_scissors_gets_its_turnbacks', () => {
    const m = new Game();
    const { b, c } = line(m, { stationB: false });
    m.editor.placeCrossover(V(1190, 12));
    isTrue(signalsNear(m, 1100, 12).length === 1);  // no platform beyond yet
    isTrue(m.editor.placeStation(V(1000, 12), m.towns) !== null);
    eq(signalsNear(m, 1100, -12).length, 0);        // trailing side
    eq(signalsNear(m, 1100, 12).length, 0);         // facing side
    eq(m.network.firstUnroutableStop(platforms(b, c)), -1);
  });
  t('c_key_and_toolbar_tool', () => {
    const m = new Game();
    line(m);
    m.handleInput({ type: 'key', code: 'KeyC' });
    eq(m.tool, 'crossover');
    isTrue(m.hintText().includes('crossover'));
    m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: V(1190, -12) });  // either line works
    eq(crossovers(m).length, 4);
    m.handleInput({ type: 'key', code: 'KeyC' });
    eq(m.tool, 'track');
  });
}
