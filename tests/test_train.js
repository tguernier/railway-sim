import { suite, t, eq, approx, gt, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackSegment } from '../src/track_segment.js';
import { Town } from '../src/town.js';
import { Train } from '../src/train.js';

const town = (x, y) => new Town(V(x, y), '#fff');
const node = (x, y) => NetworkNode.junction(V(x, y));
const seg = (a, b) => new TrackSegment(a, b);
const line = (ax, bx) => seg(node(ax, 0), node(bx, 0));

// Three 100 px segments in a line; a 2-car consist is 56 px long.
function routeOfThree(tr) {
  const segs = [line(0, 100), line(100, 200), line(200, 300)];
  tr.carCount = 2;
  tr.setRoute(segs);
  return segs;
}

// A linked forward/reverse segment pair between two nodes.
function twinPair(a, b) {
  const fwd = seg(a, b);
  const rev = seg(b, a);
  fwd.reverse = rev;
  rev.reverse = fwd;
  return [fwd, rev];
}

export function runAll() {
  suite('TestTrain');
  t('has_route_false_initially', () => isFalse(new Train().hasRoute()));
  t('set_route_stores_and_resets', () => {
    const tr = new Train();
    tr.setRoute([line(0, 200)]);
    eq(tr.routeIndex, 0);
    eq(tr.segmentProgress, 0);
  });
  t('set_route_resets_boarded_flag', () => {
    const tr = new Train();
    tr.boardedThisLeg = true;
    tr.setRoute([line(0, 200)]);
    isFalse(tr.boardedThisLeg);
  });
  t('has_route_true_after_set', () => {
    const tr = new Train();
    tr.setRoute([line(0, 200)]);
    isTrue(tr.hasRoute());
  });
  t('halts_at_pending_stop_point', () => {
    const tr = new Train();
    tr.setRoute([line(0, 500)]);
    tr.stopProgress = 0.5;
    tr.move(100);
    eq(tr.segmentProgress, 0.5);
    isTrue(tr.atPendingStop());
    isFalse(tr.hasCompletedRoute());
  });
  t('resumes_past_stop_once_cleared', () => {
    const tr = new Train();
    tr.setRoute([line(0, 500)]);
    tr.stopProgress = 0.5;
    tr.move(100);
    tr.stopProgress = -1;
    tr.move(100);
    isTrue(tr.hasCompletedRoute());
  });
  t('set_route_clears_stop_point', () => {
    const tr = new Train();
    tr.stopProgress = 0.5;
    tr.setRoute([line(0, 500)]);
    eq(tr.stopProgress, -1);
  });
  t('dwell_blocks_movement_and_counts_down', () => {
    const tr = new Train();
    tr.setRoute([line(0, 500)]);
    tr.dwellRemaining = 1.0;
    tr.move(0.4);
    eq(tr.segmentProgress, 0);
    approx(tr.dwellRemaining, 0.6, 0.01);
  });
  t('moves_again_after_dwell_expires', () => {
    const tr = new Train();
    tr.setRoute([line(0, 500)]);
    tr.dwellRemaining = 0.3;
    tr.move(0.5);
    eq(tr.dwellRemaining, 0);
    eq(tr.segmentProgress, 0);
    tr.move(0.1);
    gt(tr.segmentProgress, 0);
  });
  t('move_advances_segment_progress', () => {
    const tr = new Train();
    tr.setRoute([line(0, 500)]);
    tr.move(0.1);
    gt(tr.segmentProgress, 0);
  });
  t('resume_from_stop_turns_around_on_reverse', () => {
    const a = node(0, 0), b = node(500, 0);
    const fwd = seg(a, b), rev = seg(b, a);
    const out = seg(a, node(-500, 0));
    const tr = new Train();
    tr.carCount = 2;
    tr.setRoute([rev, out]);
    tr.resumeFromStop(fwd, 0.3, rev);
    eq(tr.route.length, 2);
    eq(tr.currentSegment(), rev);
    approx(tr.segmentProgress, 1.0 - (0.3 - tr.consistLength() / 500), 0.0001);
    approx(tr.currentPosition().x, 150 - tr.consistLength(), 1);
    approx(tr.pointBehind(tr.consistLength()).position.x, 150, 1);
  });
  t('resume_from_stop_prepends_forward_segment', () => {
    const a = node(0, 0), b = node(500, 0);
    const platformSeg = seg(a, b), rev = seg(b, a);
    const onward = seg(b, node(1000, 0));
    const tr = new Train();
    tr.setRoute([onward]);
    tr.resumeFromStop(platformSeg, 0.5, rev);
    eq(tr.route.length, 2);
    eq(tr.currentSegment(), platformSeg);
    eq(tr.segmentProgress, 0.5);
    tr.move(100);
    isTrue(tr.hasCompletedRoute());
  });
  t('has_completed_route_false_at_start', () => {
    const tr = new Train();
    tr.setRoute([line(0, 200)]);
    isFalse(tr.hasCompletedRoute());
  });
  t('has_completed_route_true_after_full_move', () => {
    const tr = new Train();
    tr.setRoute([line(0, 200)]);
    tr.move(100);
    isTrue(tr.hasCompletedRoute());
  });
  t('unload_returns_count_and_clears', () => {
    const tr = new Train();
    tr.passengersOnBoard = 7;
    eq(tr.unload(), 7);
    eq(tr.passengersOnBoard, 0);
  });
  t('board_from_picks_up_passengers', () => {
    const tw = town(0, 0);
    tw.waiting = 10;
    const tr = new Train();
    tr.boardFrom(tw);
    eq(tr.passengersOnBoard, 10);
  });
  t('board_from_respects_capacity', () => {
    const tw = town(0, 0);
    tw.waiting = 100;
    const tr = new Train();
    tr.boardFrom(tw);
    eq(tr.passengersOnBoard, tr.capacity);
  });
  t('orders_empty_initially', () => {
    const tr = new Train();
    eq(tr.orders.length, 0);
    eq(tr.currentOrderTown(), null);
  });
  t('current_order_town_returns_correct_stop', () => {
    const tr = new Train();
    const a = town(0, 0), b = town(100, 0);
    tr.orders = [a, b];
    tr.currentOrderIndex = 0;
    eq(tr.currentOrderTown(), a);
    tr.currentOrderIndex = 1;
    eq(tr.currentOrderTown(), b);
  });
  t('advance_order_cycles', () => {
    const tr = new Train();
    const a = town(0, 0), b = town(100, 0), c = town(200, 0);
    tr.orders = [a, b, c];
    tr.advanceOrder();
    eq(tr.currentOrderIndex, 1);
    eq(tr.currentOrderTown(), b);
    tr.advanceOrder();
    eq(tr.currentOrderIndex, 2);
    eq(tr.currentOrderTown(), c);
  });
  t('advance_order_wraps_around', () => {
    const tr = new Train();
    const a = town(0, 0), b = town(100, 0);
    tr.orders = [a, b];
    tr.currentOrderIndex = 1;
    tr.advanceOrder();
    eq(tr.currentOrderIndex, 0);
    eq(tr.currentOrderTown(), a);
  });
  t('consist_length_and_capacity_scale_with_cars', () => {
    const tr = new Train();
    tr.carCount = 1;
    approx(tr.consistLength(), Train.CAR_LENGTH, 0.001);
    eq(tr.capacity, Train.CAR_CAPACITY);
    tr.carCount = 2;
    approx(tr.consistLength(), 2 * Train.CAR_LENGTH + Train.CAR_GAP, 0.001);
    eq(tr.capacity, 2 * Train.CAR_CAPACITY);
    tr.carCount = 4;
    approx(tr.consistLength(), 4 * Train.CAR_LENGTH + 3 * Train.CAR_GAP, 0.001);
    eq(tr.capacity, 4 * Train.CAR_CAPACITY);
  });
  t('history_keeps_segments_the_tail_needs', () => {
    const tr = new Train();
    const segs = routeOfThree(tr);
    tr.move(1);
    eq(tr.routeIndex, 1);
    eq(tr.history.length, 1);
    eq(tr.history[0], segs[0]);
    tr.move(1);
    isTrue(tr.hasCompletedRoute());
    eq(tr.history.length, 0);
  });
  t('point_behind_spans_segment_boundary', () => {
    const tr = new Train();
    routeOfThree(tr);
    tr.move(1);
    approx(tr.pointBehind(0).position.x, 150, 1);
    approx(tr.pointBehind(13).position.x, 137, 1);
    approx(tr.pointBehind(100).position.x, 50, 1);
  });
  t('point_behind_clamps_at_oldest_point', () => {
    const tr = new Train();
    tr.setRoute([line(0, 100)]);
    approx(tr.pointBehind(50).position.x, 0, 0.001);
  });
  t('set_route_clears_history', () => {
    const tr = new Train();
    routeOfThree(tr);
    tr.move(1);
    eq(tr.history.length, 1);
    tr.setRoute([line(0, 100)]);
    eq(tr.history.length, 0);
  });
  t('resume_forward_keeps_tail_continuous', () => {
    const a = node(0, 0), b = node(500, 0);
    const platformSeg = seg(a, b), rev = seg(b, a);
    const onward = seg(b, node(1000, 0));
    const tr = new Train();
    tr.carCount = 2;
    tr.setRoute([onward]);
    tr.resumeFromStop(platformSeg, 0.5, rev);
    approx(tr.currentPosition().x, 250, 1);
    approx(tr.pointBehind(tr.consistLength()).position.x, 250 - tr.consistLength(), 1);
  });
  t('try_reserve_marks_segments', () => {
    const tr = new Train();
    const s1 = line(0, 100), s2 = line(100, 200);
    isTrue(tr.tryReserve([s1, s2]));
    eq(s1.reservedBy, tr);
    eq(s2.reservedBy, tr);
    eq(tr.reserved.length, 2);
  });
  t('try_reserve_atomic_all_or_nothing', () => {
    const tr = new Train(), other = new Train();
    const s1 = line(0, 100), s2 = line(100, 200);
    isTrue(other.tryReserve([s2]));
    isFalse(tr.tryReserve([s1, s2]));
    eq(s1.reservedBy, null);
    eq(tr.reserved.length, 0);
  });
  t('reserve_blocks_reverse_twin', () => {
    const other = new Train();
    const pair = twinPair(node(0, 0), node(100, 0));
    isTrue(other.tryReserve([pair[0]]));
    isFalse(new Train().tryReserve([pair[1]]));
  });
  t('own_twin_is_not_blocked', () => {
    const tr = new Train();
    const pair = twinPair(node(0, 0), node(100, 0));
    isTrue(tr.tryReserve([pair[0]]));
    isTrue(tr.tryReserve([pair[1]]));
  });
  t('re_reserve_is_idempotent', () => {
    const tr = new Train();
    const s = line(0, 100);
    isTrue(tr.tryReserve([s]));
    isTrue(tr.tryReserve([s]));
    eq(tr.reserved.length, 1);
  });
  t('release_all_frees_segments', () => {
    const tr = new Train();
    const s1 = line(0, 100), s2 = line(100, 200);
    tr.tryReserve([s1, s2]);
    tr.releaseAll();
    eq(s1.reservedBy, null);
    eq(tr.reserved.length, 0);
    isTrue(new Train().tryReserve([s1]));
  });
  t('set_route_releases_reservations', () => {
    const tr = new Train();
    const s = line(0, 100);
    tr.tryReserve([s]);
    tr.setRoute([line(0, 200)]);
    eq(s.reservedBy, null);
    eq(tr.reserved.length, 0);
  });
  t('tail_clear_releases_segments', () => {
    const tr = new Train();
    const segs = routeOfThree(tr);
    tr.tryReserve([segs[0]]);
    tr.move(1);
    eq(segs[0].reservedBy, tr);
    eq(segs[1].reservedBy, tr);
    tr.move(1);
    eq(segs[0].reservedBy, null);
    eq(segs[1].reservedBy, null);
    eq(segs[2].reservedBy, tr);
    eq(tr.reserved.length, 1);
    eq(tr.reserved[0], segs[2]);
  });
  t('blocked_entry_halts_at_boundary', () => {
    const tr = new Train(), other = new Train();
    const s1 = line(0, 100), s2 = line(100, 200);
    other.tryReserve([s2]);
    tr.setRoute([s1, s2]);
    tr.tryReserve([s1]);
    tr.move(1);
    eq(tr.routeIndex, 0);
    eq(tr.segmentProgress, 1);
    isTrue(tr.waitingForTrack);
    isFalse(tr.hasCompletedRoute());
  });
  t('blocked_entry_proceeds_after_release', () => {
    const tr = new Train(), other = new Train();
    const s1 = line(0, 100), s2 = line(100, 200);
    other.tryReserve([s2]);
    tr.setRoute([s1, s2]);
    tr.tryReserve([s1]);
    tr.move(1);
    other.releaseAll();
    tr.move(1);
    isFalse(tr.waitingForTrack);
    isTrue(tr.hasCompletedRoute());
    eq(s2.reservedBy, tr);
  });
  t('turnaround_keeps_span_held', () => {
    const a = node(0, 0), b = node(500, 0);
    const pair = twinPair(a, b);
    const out = seg(a, node(-500, 0));
    const tr = new Train();
    tr.carCount = 2;
    tr.tryReserve([pair[0]]);
    tr.setRoute([pair[1], out]);
    tr.resumeFromStop(pair[0], 0.3, pair[1]);
    isTrue(tr.tryReserve([tr.currentSegment()]));
    eq(pair[1].reservedBy, tr);
    isFalse(new Train().tryReserve([pair[0]]));
  });
  t('extension_stops_at_first_signal', () => {
    const tr = new Train();
    const segs = routeOfThree(tr);
    segs[1].exitSignal = true;
    isTrue(tr.tryExtendReservation());
    eq(tr.limitIndex, 1);
    eq(segs[0].reservedBy, tr);
    eq(segs[1].reservedBy, tr);
    eq(segs[2].reservedBy, null);
    isTrue(tr.tryExtendReservation());
    eq(tr.limitIndex, 2);
    eq(segs[2].reservedBy, tr);
  });
  t('extension_failure_keeps_limit_and_records_blocker', () => {
    const tr = new Train(), other = new Train();
    const segs = routeOfThree(tr);
    segs[1].exitSignal = true;
    other.tryReserve([segs[2]]);
    isTrue(tr.tryExtendReservation());
    eq(tr.limitIndex, 1);
    isFalse(tr.tryExtendReservation());
    eq(tr.limitIndex, 1);
    eq(segs[2].reservedBy, other);
    eq(tr.blockedBy, other);
  });
  t('opposite_direction_signal_ignored', () => {
    const tr = new Train();
    const segs = routeOfThree(tr);
    const rev = seg(segs[1].nodeEnd, segs[1].nodeStart);
    segs[1].reverse = rev;
    rev.reverse = segs[1];
    rev.exitSignal = true;
    isTrue(tr.tryExtendReservation());
    eq(tr.limitIndex, 2);
  });
  t('halts_at_signal_until_path_frees', () => {
    const tr = new Train(), other = new Train();
    const segs = routeOfThree(tr);
    segs[0].exitSignal = true;
    other.tryReserve([segs[2]]);
    tr.move(1);
    eq(tr.routeIndex, 0);
    eq(tr.segmentProgress, 1);
    isTrue(tr.waitingForTrack);
    other.releaseAll();
    tr.move(2);
    isFalse(tr.waitingForTrack);
    isTrue(tr.hasCompletedRoute());
    eq(segs[2].reservedBy, tr);
  });
}
