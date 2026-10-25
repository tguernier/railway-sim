import { suite, t, eq, approx, check, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackEditor } from '../src/track_editor.js';
import { TrackNetwork } from '../src/track_network.js';
import { CrossingKind } from '../src/track_crossing.js';
import { Town } from '../src/town.js';
import { Train } from '../src/train.js';
import { GameSnapshot } from '../src/game_snapshot.js';
import { Game, GameState } from '../src/game.js';

const J = (x, y) => NetworkNode.junction(V(x, y));
const DT = 1 / 60;
// Lateral position of a segment: its midpoint's y (the line runs along y = 0,
// eastbound/right track at +12, westbound/left track at -12).
const midY = (seg) => seg.positionAt(0.5).y;

// A terminus A on single track (x 0..500), a double section X(500)→Y(1300)
// with town B in the middle, and a terminus C on single track (1300..1700).
// Stations are placed by the caller (B's goes on double track).
function line(m, { stationB = true } = {}) {
  const ed = m.editor;
  const x = J(500, 0);
  const y = J(1300, 0);
  ed.createBidirectionalTrack(J(0, 0), x, []);
  const section = ed.createDoubleTrack(x, y, []);
  ed.createBidirectionalTrack(y, J(1700, 0), []);
  const a = new Town(V(200, 40), '#6495ed', 'A');
  const b = new Town(V(900, 50), '#cd5c5c', 'B');
  const c = new Town(V(1500, 40), '#2e8b57', 'C');
  m.towns.push(a, b, c);
  isTrue(ed.placeStation(V(200, 0), m.towns) !== null);
  if (stationB) isTrue(ed.placeStation(V(900, 12), m.towns) !== null);
  isTrue(ed.placeStation(V(1500, 0), m.towns) !== null);
  return { a, b, c, x, y, section };
}

// No two trains may hold the same physical track.
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

export function runAll() {
  suite('TestDoubleTrack');
  t('plan_offsets_tracks_and_converges_on_the_ends', () => {
    const ed = new TrackEditor(new TrackNetwork());
    const plan = ed.planDoubleTrack(J(0, 0), J(800, 0), []);
    isTrue(plan !== null);
    // Eastbound travel: right is +y (y points down), left is -y.
    approx(plan.right.positionAt(0.5).y, TrackEditor.DOUBLE_SPACING / 2, 0.5);
    approx(plan.left.positionAt(0.5).y, -TrackEditor.DOUBLE_SPACING / 2, 0.5);
    approx(plan.right.positionAt(0).distanceTo(V(0, 0)), 0, 0.01);
    approx(plan.left.positionAt(1).distanceTo(V(800, 0)), 0, 0.01);
    // The tracks leave the junction in line with the centreline.
    check(Math.abs(plan.right.angleAt(0)) < 0.1, `right departs at ${plan.right.angleAt(0)}`);
    isTrue(plan.right.minRadiusOfCurvature() >= TrackEditor.MIN_CURVE_RADIUS);
    eq(ed.planDoubleTrack(J(0, 0), J(150, 0), []), null);
  });
  t('section_is_one_way_signalled_by_running_line', () => {
    const m = new Game();
    const { x, y, section } = line(m, { stationB: false });
    const signalled = section.right.slice(0, -1);
    isTrue(signalled.every((seg) => seg.exitSignal && !seg.reverse.exitSignal));
    isTrue(section.left.slice(1).every((seg) => seg.reverse.exitSignal && !seg.exitSignal));
    for (const seg of [...section.right, ...section.left]) isFalse(seg.looseOneWay);
    // Routing keeps each direction on its own track.
    const east = m.network.findRoute(x, y);
    isTrue(east.length > 0 && east.every((seg) => midY(seg) > 1));
    const west = m.network.findRoute(y, x);
    isTrue(west.length > 0 && west.every((seg) => midY(seg) < -1));
  });
  t('taper_pairs_exclude_each_other_only_at_the_ends', () => {
    const m = new Game();
    const { section } = line(m, { stationB: false });
    const fouls = m.network.crossings.filter((c) => c.kind === CrossingKind.FOUL);
    eq(fouls.length, 2);
    const t1 = new Train();
    const t2 = new Train();
    isTrue(t1.tryReserve([section.right[0]]));
    isTrue(t2.isBlocked(section.left[0]));
    isTrue(t2.isBlocked(section.left[0].reverse));
    isFalse(t2.isBlocked(section.left[1]));
    isFalse(t2.isBlocked(section.left[section.left.length - 1]));
    isTrue(section.right[0].taper && section.left[0].reverse.taper);
    isFalse(section.right[1].taper);
  });
  t('taper_pieces_are_protected', () => {
    const m = new Game();
    const { section } = line(m, { stationB: false });
    const ed = m.editor;
    const before = m.network.segments.length;
    eq(ed.splitTrackAtHit([section.right[0], 0.5]), null);
    isTrue(ed.lastError.includes('double track converges'));
    const tapered = section.left[0].positionAt(0.6);
    isFalse(ed.placeOrCycleSignal(tapered));
    m.towns.push(new Town(tapered, '#fff', 'T'));
    eq(ed.placeStation(tapered, m.towns), null);
    ed.startDrawing(J(560, -300));
    isFalse(ed.finishOnTrack([section.right[0], 0.5]));
    eq(m.network.segments.length, before);
    eq(m.network.crossings.length, 2);
  });
  t('drawing_in_double_mode_lays_a_section_and_undoes', () => {
    const m = new Game();
    m.handleInput({ type: 'key', code: 'KeyD' });
    isTrue(m.editor.doubleTrack);
    isTrue(m.hintText().includes('double'));
    m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: V(0, 0) });
    m.handleInput({ type: 'mouse', button: 'left', shift: true, pos: V(700, 0) });
    isTrue(m.editor.drawing);  // shift: finished and continuing
    isTrue(m.hintText().startsWith('Drawing double track'));
    isTrue(m.network.segments.length >= 12);
    eq(m.network.crossings.length, 2);
    // Too short to split and merge: refused with a reason, nothing built.
    const segs = m.network.segments.length;
    m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: V(850, 0) });  // waypoint
    m.handleInput({ type: 'mouse', button: 'left', shift: true, pos: V(860, 0) });
    eq(m.network.segments.length, segs);
    eq(m.editor.rejectionReason, 'double_short');
    isTrue(m.statusMessage.includes('Double track needs a longer run'));
    m.handleInput({ type: 'key', code: 'Escape' });
    m.handleInput({ type: 'key', code: 'KeyU' });
    eq(m.network.segments.length, 0);
    eq(m.network.crossings.length, 0);
    eq(m.network.nodes.length, 0);
  });
  t('station_on_double_track_gets_a_platform_per_track', () => {
    const m = new Game();
    const signalsBefore = (() => {
      const probe = new Game();
      line(probe, { stationB: false });
      return probe.network.segments.filter((s) => s.exitSignal).length;
    })();
    const { b } = line(m);
    eq(b.station.platforms.length, 2);
    const ys = b.station.platforms.map((p) => midY(p.segment)).sort((p, q) => p - q);
    approx(ys[0], -12, 1);
    approx(ys[1], 12, 1);
    // Side platforms face outward, away from the other track.
    for (const p of b.station.platforms) {
      const mid = p.segment.positionAt(0.5);
      const toward = mid.add(V(0, 0).add(
        // the platform side's lateral direction
        (() => { const a = p.segment.angleAt(0.5); return V(Math.sin(a), -Math.cos(a)).mul(p.side); })()));
      check(Math.sign(toward.y - mid.y) === Math.sign(mid.y), `platform at y=${mid.y.toFixed(1)} faces ${toward.y - mid.y}`);
    }
    // The splits kept every one-way signal in place.
    eq(m.network.segments.filter((s) => s.exitSignal).length, signalsBefore);
  });
  t('station_on_a_lone_parallel_track_needs_both_platforms_valid', () => {
    // A taper piece is no place for the partner platform: the whole station
    // is refused, not half built.
    const m = new Game();
    const { section } = line(m, { stationB: false });
    const ed = m.editor;
    const near = section.right[1].positionAt(0.05);
    const town = new Town(near, '#fff', 'N');
    m.towns.push(town);
    const before = m.network.segments.length;
    const station = ed.placeStation(near, m.towns);
    if (station === null) {
      eq(m.network.segments.length, before);
      eq(town.station, null);
    } else {
      eq(station.platforms.length, 2);  // both fitted after all
    }
  });
  t('loop_plan_picks_the_start_platform_on_the_right_line', () => {
    const m = new Game();
    const { a, b, c } = line(m);
    const plan = m.network.planLoop([b, c, b, a].map((tw) => tw.station.platforms));
    eq(plan.unroutable, -1);
    isTrue(midY(plan.start.segment) > 0);  // eastbound track, toward C
    const back = m.network.planLoop([b, a, b, c].map((tw) => tw.station.platforms));
    eq(back.unroutable, -1);
    isTrue(midY(back.start.segment) < 0);  // westbound track, toward A
    eq(m.network.firstUnroutableStop([a, b, c, b].map((tw) => tw.station.platforms)), -1);
    m.roster[0].orders = [b, c, b, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isTrue(midY(m.trains[0].currentSegment()) > 0);
  });
  t('opposing_trains_pass_on_double_track', () => {
    const m = new Game();
    const { a, c } = line(m, { stationB: false });
    m.roster[0].orders = [a, c];
    m._buyTrain();
    m.roster[1].orders = [c, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true, flagged = false, sawPass = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 60 * 60; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      const [p0, p1] = m.trains.map((tr) => tr.currentPosition());
      if (Math.abs(p0.x - p1.x) < 100 && Math.abs(p0.y - p1.y) > 20) sawPass = true;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    eq(m.state, GameState.SIMULATING);
    isTrue(disjoint);
    isFalse(flagged);
    isTrue(sawPass);  // side by side on the two tracks
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('through_station_uses_the_platform_on_each_running_line', () => {
    const m = new Game();
    const { a, b, c } = line(m);
    m.roster[0].orders = [a, b, c, b];
    const arrivals = recordArrivals(m);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    for (let tick = 0; tick < 60 * 45; tick++) m.process(DT);
    eq(m.state, GameState.SIMULATING);
    const names = arrivals.map(([n]) => n).join('');
    isTrue(names.startsWith('BCBA'));
    isTrue(arrivals[0][1] > 0);  // B eastbound: right-hand platform
    isTrue(arrivals[2][1] < 0);  // B westbound: the other platform
  });
  t('turning_back_on_one_way_double_track_is_refused_at_start', () => {
    // B sits mid-way along the double section: a train shuttling B ↔ C would
    // return to B on the westbound platform and could not head east again
    // without a crossover. Caught on the second lap of the loop check, at
    // start, rather than stranding the train mid-run.
    const m = new Game();
    const { b, c } = line(m);
    eq(m.network.firstUnroutableStop([b, c].map((tw) => tw.station.platforms)), 0);
    m.roster[0].orders = [b, c];
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    isTrue(m.statusMessage.includes('turn back'));
  });
  t('trains_follow_each_other_on_one_running_line', () => {
    // Two eastbound-first trains a station apart: the follower runs behind
    // the leader on the same track, held only by the signals between them.
    // B → C → B → A turns back only at the single-track termini.
    const m = new Game();
    const { a, b, c } = line(m);
    m.roster[0].orders = [b, c, b, a];
    m._buyTrain();
    m.roster[1].orders = [a, c];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true, flagged = false, sameLine = false, heldOnLine = false;
    for (let tick = 0; tick < 60 * 20; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      const [p0, p1] = m.trains.map((tr) => tr.currentPosition());
      if (Math.abs(p0.y) > 3 && Math.abs(p1.y) > 3 && Math.sign(p0.y) === Math.sign(p1.y)) sameLine = true;
      // The follower held at a signal out on the double track, not back at
      // its platform.
      if (m.trains[1].waitingForTrack && Math.abs(p1.y) > 6) heldOnLine = true;
    }
    isTrue(disjoint);
    isFalse(flagged);
    isTrue(sameLine);
    isTrue(heldOnLine);
  });
  t('chained_sections_exclude_crossing_movements_at_the_pinch', () => {
    // Two sections meeting at one junction P (what shift+click chaining in
    // double mode builds). Eastbound and westbound movements both pass
    // through P; the taper pairs on either side keep them apart there.
    const m = new Game();
    const ed = m.editor;
    const x = J(500, 0), p = J(1000, 0), y = J(1500, 0);
    ed.createBidirectionalTrack(J(0, 0), x, []);
    const s1 = ed.createDoubleTrack(x, p, []);
    const s2 = ed.createDoubleTrack(p, y, []);
    ed.createBidirectionalTrack(y, J(1900, 0), []);
    eq(m.network.crossings.length, 4);
    const east = new Train();
    const west = new Train();
    isTrue(east.tryReserve([s1.right[s1.right.length - 1], s2.right[0]]));
    isFalse(west.tryReserve([s2.left[0].reverse, s1.left[s1.left.length - 1].reverse]));
    east.releaseAll();
    const a = new Town(V(200, 40), '#fff', 'A');
    const c = new Town(V(1700, 40), '#fff', 'C');
    m.towns.push(a, c);
    isTrue(ed.placeStation(V(200, 0), m.towns) !== null);
    isTrue(ed.placeStation(V(1700, 0), m.towns) !== null);
    m.roster[0].orders = [a, c];
    m._buyTrain();
    m.roster[1].orders = [c, a];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let disjoint = true, flagged = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 60 * 60; tick++) {
      m.process(DT);
      if (!reservationsDisjoint(m.trains)) disjoint = false;
      if (m.deadlockedTrains.length > 0) flagged = true;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    isTrue(disjoint);
    isFalse(flagged);
    isTrue(wrapped[0] && wrapped[1]);
  });
  t('snapshot_keeps_tapers_and_foul_pairs', () => {
    const m = new Game();
    line(m);
    const snap = GameSnapshot.capture(m);
    const fouls = snap.network.crossings.filter((c) => c.kind === CrossingKind.FOUL);
    eq(fouls.length, 2);
    isTrue(fouls.every((c) => c.trackA.taper && c.trackB.taper && snap.network.segments.includes(c.trackA)));
    eq(snap.network.segments.filter((s) => s.taper).length, m.network.segments.filter((s) => s.taper).length);
    // Undoing a station on double track removes both platforms.
    const m2 = new Game();
    const { b } = line(m2, { stationB: false });
    m2.placingStation = true;
    m2._tryPlaceStation(V(900, 12));
    eq(m2.towns[1].station.platforms.length, 2);
    m2._undo();
    eq(m2.towns[1].station, null);
    eq(m2.network.segments.filter((s) => s.isPlatformSegment()).length, 4);  // A and C only
    eq(b.name, 'B');
  });
}
