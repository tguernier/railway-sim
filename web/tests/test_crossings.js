import { suite, t, eq, approx, check, isTrue, isFalse, V } from './test_base.js';
import { radToDeg } from '../src/vec2.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackSegment } from '../src/track_segment.js';
import { TrackNetwork } from '../src/track_network.js';
import { TrackEditor } from '../src/track_editor.js';
import { Town } from '../src/town.js';
import { Train } from '../src/train.js';
import { GameSnapshot } from '../src/game_snapshot.js';
import { Game, GameState } from '../src/game.js';

const node = (x, y) => NetworkNode.junction(V(x, y));
const seg = (ax, ay, bx, by) => new TrackSegment(node(ax, ay), node(bx, by));
const editor = () => new TrackEditor(new TrackNetwork());
const track = (ed, ax, ay, bx, by) => ed.createBidirectionalTrack(node(ax, ay), node(bx, by), []);

// Trains holding either side of a crossing. More than one means two trains
// are inside the same diamond, which must never happen.
function diamondHolders(crossing, trains) {
  let count = 0;
  for (const tr of trains) {
    let inside = false;
    for (const tk of [crossing.trackA, crossing.trackB]) {
      if (tk === null) continue;
      if (tr.reserved.includes(tk) || (tk.reverse !== null && tr.reserved.includes(tk.reverse))) inside = true;
    }
    if (inside) count++;
  }
  return count;
}

// Two crossing lines, each with two stationed towns.
function crossedLines(m) {
  const ed = m.editor;
  track(ed, 0, 300, 1200, 300);
  track(ed, 600, -300, 600, 900);
  const a1 = new Town(V(200, 330), '#fff');
  const a2 = new Town(V(1000, 330), '#fff');
  const b1 = new Town(V(630, -100), '#fff');
  const b2 = new Town(V(630, 700), '#fff');
  m.towns.push(a1, a2, b1, b2);
  ed.placeStation(V(200, 300), m.towns);
  ed.placeStation(V(1000, 300), m.towns);
  ed.placeStation(V(600, -100), m.towns);
  ed.placeStation(V(600, 700), m.towns);
  return [[a1, a2], [b1, b2]];
}

// A self-contained island at height y: a straight track with two stationed
// towns on it.
function island(m, y) {
  const ed = m.editor;
  track(ed, 0, y, 1200, y);
  const a = new Town(V(300, y + 30), '#fff');
  const b = new Town(V(900, y + 30), '#fff');
  m.towns.push(a, b);
  ed.placeStation(V(300, y), m.towns);
  ed.placeStation(V(900, y), m.towns);
  return [a, b];
}

export function runAll() {
  suite('TestCrossings');
  // Geometry
  t('square_tracks_cross_once', () => {
    const a = seg(0, 300, 600, 300);
    const b = seg(300, 0, 300, 600);
    const points = TrackSegment.crossingPoints(a, b);
    eq(points.length, 1);
    approx(points[0].x, 300, 2);
    approx(points[0].y, 300, 2);
    eq(TrackSegment.crossingPoints(b, a).length, 1);
  });
  t('parallel_tracks_never_cross', () => {
    eq(TrackSegment.crossingPoints(seg(0, 0, 600, 0), seg(0, 30, 600, 30)).length, 0);
  });
  t('tracks_sharing_a_node_do_not_cross', () => {
    const shared = node(300, 300);
    const a = new TrackSegment(node(0, 300), shared);
    const b = new TrackSegment(shared, node(600, 100));
    eq(TrackSegment.crossingPoints(a, b).length, 0);
  });
  t('reverse_twins_do_not_cross', () => {
    const fwd = track(editor(), 0, 0, 600, 0);
    eq(TrackSegment.crossingPoints(fwd, fwd.reverse).length, 0);
  });
  t('distant_tracks_rejected_by_bounds', () => {
    eq(TrackSegment.crossingPoints(seg(0, 0, 100, 0), seg(5000, 5000, 5100, 5000)).length, 0);
  });
  t('crossing_angle_square_and_symmetric', () => {
    const a = seg(0, 300, 600, 300);
    const b = seg(300, 0, 300, 600);
    const p = V(300, 300);
    approx(TrackSegment.crossingAngle(a, b, p), Math.PI / 2, 0.05);
    approx(TrackSegment.crossingAngle(b, a, p), Math.PI / 2, 0.05);
    approx(TrackSegment.crossingAngle(a, seg(300, 600, 300, 0), p), Math.PI / 2, 0.05);
  });
  t('crossing_angle_shallow', () => {
    const a = seg(0, 300, 600, 300);
    const b = seg(0, 240, 600, 360);
    const points = TrackSegment.crossingPoints(a, b);
    eq(points.length, 1);
    const ang = TrackSegment.crossingAngle(a, b, points[0]);
    approx(radToDeg(ang), 11.3, 1.5);
    check(ang < TrackEditor.MIN_CROSSING_ANGLE, 'expected shallow crossing to be under the limit');
  });
  // Registration
  t('crossing_registered_on_all_four_segments', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    eq(ed.network.crossings.length, 1);
    const c = ed.network.crossings[0];
    isTrue(a.crossings.includes(c));
    isTrue(a.reverse.crossings.includes(c));
    isTrue(b.crossings.includes(c));
    isTrue(b.reverse.crossings.includes(c));
    approx(c.position.x, 300, 2);
    approx(c.angle, Math.PI / 2, 0.05);
  });
  t('reverse_twin_does_not_duplicate', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    track(ed, 300, 0, 300, 600);
    eq(ed.network.crossings.length, 1);
    for (const s of ed.network.segments) check(s.crossings.length <= 1, `segment carries ${s.crossings.length} crossings`);
  });
  t('other_track_from_either_direction', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const c = ed.network.crossings[0];
    eq(c.otherTrack(a), b);
    eq(c.otherTrack(a.reverse), b);
    eq(c.otherTrack(b), a);
    eq(c.otherTrack(b.reverse), a);
    eq(c.otherTrack(seg(0, 0, 10, 0)), null);
  });
  t('deleting_a_track_purges_the_crossing', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    eq(ed.network.crossings.length, 1);
    isTrue(ed.tryDeleteTrackAt(V(300, 100)));
    eq(ed.network.crossings.length, 0);
    eq(a.crossings.length, 0);
    eq(a.reverse.crossings.length, 0);
    eq(b.crossings.length, 0);
  });
  t('splitting_a_crossed_track_keeps_one_half', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    track(ed, 300, 0, 300, 600);
    ed.splitTrackAtHit(ed.findTrackAt(V(100, 300)));
    eq(ed.network.crossings.length, 1);
    eq(ed.network.segments.filter((s) => s.crossings.length > 0).length, 4);
  });
  // Snapshot
  t('snapshot_clones_crossings_onto_clones', () => {
    const m = new Game();
    track(m.editor, 0, 300, 600, 300);
    track(m.editor, 300, 0, 300, 600);
    eq(m.network.crossings.length, 1);
    const snap = GameSnapshot.capture(m);
    eq(snap.network.crossings.length, 1);
    const original = m.network.crossings[0];
    const clone = snap.network.crossings[0];
    check(clone !== original, 'snapshot must not share the live crossing object');
    approx(clone.position.x, original.position.x, 0.5);
    approx(clone.angle, original.angle, 0.01);
    check(!m.network.segments.includes(clone.trackA), 'cloned crossing still points at a live segment');
    isTrue(snap.network.segments.includes(clone.trackA));
    isTrue(clone.trackA.crossings.includes(clone));
    isTrue(clone.trackB.reverse.crossings.includes(clone));
  });
  t('undo_restores_a_crossing', () => {
    const m = new Game();
    track(m.editor, 0, 300, 600, 300);
    track(m.editor, 300, 0, 300, 600);
    m._pushUndo();
    m.editor.tryDeleteTrackAt(V(300, 100));
    eq(m.network.crossings.length, 0);
    m._undo();
    eq(m.network.crossings.length, 1);
    const c = m.network.crossings[0];
    isTrue(c.trackA !== null && c.trackB !== null);
    isTrue(c.trackA.crossings.includes(c));
  });
  // Exclusion
  t('crossing_track_is_blocked_by_holder', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const t1 = new Train(), t2 = new Train();
    isTrue(t1.tryReserve([a]));
    isTrue(t2.isBlocked(b));
    eq(t2.blockingTrain(b), t1);
    isTrue(t2.isBlocked(b.reverse));
    isFalse(t2.tryReserve([b]));
    eq(t2.blockedBy, t1);
  });
  t('release_frees_the_crossing_track', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const t1 = new Train(), t2 = new Train();
    t1.tryReserve([a]);
    isFalse(t2.tryReserve([b]));
    t1.releaseAll();
    isFalse(t2.isBlocked(b));
    isTrue(t2.tryReserve([b]));
    isTrue(t1.isBlocked(a));
  });
  t('unrelated_track_is_unaffected', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const far = track(ed, 0, 900, 600, 900);
    const t1 = new Train(), t2 = new Train();
    t1.tryReserve([a]);
    isFalse(t2.isBlocked(far));
    isTrue(t2.tryReserve([far]));
    eq(b.crossings.length, 1);
    eq(far.crossings.length, 0);
  });
  t('own_reservation_does_not_block_self', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const t1 = new Train();
    isTrue(t1.tryReserve([a]));
    isFalse(t1.isBlocked(b));
    isTrue(t1.tryReserve([b]));
  });
  t('route_cost_penalises_occupied_crossing', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const t1 = new Train(), t2 = new Train();
    const freeCost = ed.network.routeCost([b], t2);
    t1.tryReserve([a]);
    approx(ed.network.routeCost([b], t2) - freeCost, TrackNetwork.BLOCKED_PENALTY, 1);
  });
  t('reservation_slice_refuses_occupied_diamond', () => {
    const ed = editor();
    const a = track(ed, 0, 300, 600, 300);
    const b = track(ed, 300, 0, 300, 600);
    const far = track(ed, 0, 900, 600, 900);
    const t1 = new Train(), t2 = new Train();
    t1.tryReserve([a]);
    isFalse(t2.tryReserve([far, b]));
    eq(t2.reserved.length, 0);
    eq(far.reservedBy, null);
  });
  // Editor validation
  t('square_crossing_accepted', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    ed.startDrawing(node(300, 0));
    isTrue(ed.finishAt(node(300, 600)));
    eq(ed.network.crossings.length, 1);
  });
  t('shallow_crossing_rejected', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    ed.startDrawing(node(0, 270));
    isFalse(ed.finishAt(node(600, 330)));
    eq(ed.rejectionReason, 'crossing');
    eq(ed.network.crossings.length, 0);
    eq(ed.network.segments.length, 2);
  });
  t('crossing_a_platform_rejected', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    isTrue(ed.placeStation(V(300, 300), [new Town(V(300, 330), '#fff')]) !== null);
    ed.startDrawing(node(300, 0));
    isFalse(ed.finishAt(node(300, 600)));
    eq(ed.rejectionReason, 'crossing_platform');
    eq(ed.network.crossings.length, 0);
  });
  t('station_across_a_crossing_rejected', () => {
    const ed = editor();
    track(ed, 0, 300, 600, 300);
    track(ed, 300, 0, 300, 600);
    const towns = [new Town(V(300, 340), '#fff')];
    eq(ed.placeStation(V(300, 300), towns), null);
    isTrue(ed.lastError.includes('crossing'));
    eq(towns[0].station, null);
  });
  t('crossover_arm_onto_a_track_accepted', () => {
    const ed = editor();
    track(ed, 0, 0, 1200, 0);
    track(ed, 0, 60, 1200, 60);
    ed.startDrawing(ed.splitTrackAtHit(ed.findTrackAt(V(400, 0))));
    isTrue(ed.finishOnTrack(ed.findTrackAt(V(700, 60))));
    eq(ed.network.crossings.length, 0);
  });
  // Simulation
  t('start_rejected_when_first_stops_cross', () => {
    const m = new Game();
    const i1 = island(m, 0);
    const i2 = island(m, 600);
    m.network.registerCrossing(i1[0].station.platforms[0].segment,
      i2[0].station.platforms[0].segment, V(300, 300));
    m.roster[0].orders = i1;
    m._buyTrain();
    m.roster[1].orders = i2;
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    eq(m.money, 1000);
    eq(m.trains.length, 0);
    isTrue(m.statusMessage.includes('cross'));
  });
  t('crossing_lines_never_share_the_diamond', () => {
    const m = new Game();
    const lines = crossedLines(m);
    eq(m.network.crossings.length, 1);
    m.roster[0].orders = lines[0];
    m._buyTrain();
    m.roster[1].orders = lines[1];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    let shared = false;
    const wrapped = [false, false];
    for (let tick = 0; tick < 3600; tick++) {
      m.process(1 / 60);
      for (const c of m.network.crossings) if (diamondHolders(c, m.trains) > 1) shared = true;
      m.trains.forEach((tr, i) => { if (tr.currentOrderIndex === 0) wrapped[i] = true; });
    }
    eq(m.state, GameState.SIMULATING);
    isFalse(shared);
    isTrue(wrapped[0]);
    isTrue(wrapped[1]);
  });
  t('scissors_arms_exclude_each_other', () => {
    const ed = editor();
    track(ed, 0, 0, 1200, 0);
    track(ed, 0, 60, 1200, 60);
    ed.startDrawing(ed.splitTrackAtHit(ed.findTrackAt(V(400, 0))));
    isTrue(ed.finishOnTrack(ed.findTrackAt(V(700, 60))));
    ed.startDrawing(ed.splitTrackAtHit(ed.findTrackAt(V(400, 60))));
    isTrue(ed.finishOnTrack(ed.findTrackAt(V(700, 0))));
    eq(ed.network.crossings.length, 1);
    const c = ed.network.crossings[0];
    approx(c.position.x, 550, 40);
    approx(c.position.y, 30, 10);
    const t1 = new Train(), t2 = new Train();
    isTrue(t1.tryReserve([c.trackA]));
    isFalse(t2.tryReserve([c.trackB]));
    isFalse(t2.isBlocked(ed.findTrackAt(V(1000, 0))[0]));
  });
}
