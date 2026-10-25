import { suite, t, eq, approx, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackNetwork } from '../src/track_network.js';
import { TrackEditor } from '../src/track_editor.js';
import { Town } from '../src/town.js';

const node = (x, y) => NetworkNode.junction(V(x, y));
const editor = () => new TrackEditor(new TrackNetwork());
const town = (x, y) => new Town(V(x, y), '#fff');

// An editor with a straight bidirectional track from (0,0) to (300,0).
function editorWithTrack() {
  const ed = editor();
  ed.createBidirectionalTrack(node(0, 0), node(300, 0), []);
  return ed;
}

// The directed segments arriving at the node closest to a position.
function incomingAt(ed, pos) {
  const n = ed.findJunctionAt(pos);
  return n !== null ? ed.network.getIncoming(n) : [];
}

// Count of segments carrying a signal for their direction of travel.
const signalCount = (ed) => ed.network.segments.filter((s) => s.exitSignal).length;
// The single segment carrying a signal (only meaningful for a one-way).
const signalled = (ed) => ed.network.segments.find((s) => s.exitSignal) ?? null;

export function runAll() {
  suite('TestTrackEditor');
  t('start_drawing_sets_state', () => {
    const ed = editor();
    const n = node(0, 0);
    ed.startDrawing(n);
    isTrue(ed.drawing);
    eq(ed.startNode, n);
    eq(ed.waypoints.length, 0);
  });
  t('add_waypoint', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.addWaypoint(V(50, 50));
    ed.addWaypoint(V(100, 100));
    eq(ed.waypoints.length, 2);
  });
  t('undo_waypoint', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.addWaypoint(V(50, 50));
    ed.addWaypoint(V(100, 100));
    ed.undoWaypoint();
    eq(ed.waypoints.length, 1);
  });
  t('undo_waypoint_empty_is_noop', () => {
    const ed = editor();
    ed.undoWaypoint();
    eq(ed.waypoints.length, 0);
  });
  t('cancel_resets_state', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.addWaypoint(V(50, 50));
    ed.cancel();
    isFalse(ed.drawing);
    eq(ed.startNode, null);
    eq(ed.waypoints.length, 0);
  });
  t('cancel_cleans_up_fresh_junction', () => {
    const ed = editor();
    const j = node(10, 10);
    ed.network.addNode(j);
    ed.startDrawing(j);
    ed.cancel();
    isFalse(ed.network.nodes.includes(j));
  });
  t('finish_at_creates_bidirectional_and_resets', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.finishAt(node(200, 0));
    isFalse(ed.drawing);
    eq(ed.network.segments.length, 2);
  });
  t('finish_and_continue_creates_track_and_continues', () => {
    const ed = editor();
    const b = node(200, 0);
    ed.startDrawing(node(0, 0));
    ed.finishAndContinue(b);
    isTrue(ed.drawing);
    eq(ed.startNode, b);
    eq(ed.waypoints.length, 0);
    eq(ed.network.segments.length, 2);
  });
  t('create_bidirectional_track', () => {
    const ed = editor();
    const a = node(0, 0), b = node(200, 0);
    ed.createBidirectionalTrack(a, b, []);
    eq(ed.network.segments.length, 2);
    eq(ed.network.segments[0].nodeStart, a);
    eq(ed.network.segments[0].nodeEnd, b);
    eq(ed.network.segments[1].nodeStart, b);
    eq(ed.network.segments[1].nodeEnd, a);
  });
  t('find_junction_at_found', () => {
    const ed = editor();
    const j = node(100, 100);
    ed.network.addNode(j);
    eq(ed.findJunctionAt(V(105, 100)), j);
  });
  t('find_junction_at_miss', () => {
    const ed = editor();
    ed.network.addNode(node(100, 100));
    eq(ed.findJunctionAt(V(200, 200)), null);
  });
  t('find_track_at_found', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    eq(ed.findTrackAt(V(100, 5)).length, 2);
  });
  t('find_track_at_miss', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    eq(ed.findTrackAt(V(100, 100)).length, 0);
  });
  t('reverse_linked_on_create', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    const [fwd, rev] = ed.network.segments;
    eq(fwd.reverse, rev);
    eq(rev.reverse, fwd);
    eq(rev.nodeStart, fwd.nodeEnd);
    eq(rev.nodeEnd, fwd.nodeStart);
  });
  t('reverse_linked_on_split', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    ed.splitTrackAtHit(ed.findTrackAt(V(100, 0)));
    eq(ed.network.segments.length, 4);
    for (const s of ed.network.segments) {
      isTrue(s.reverse !== null);
      eq(s.reverse.nodeStart, s.nodeEnd);
      eq(s.reverse.nodeEnd, s.nodeStart);
      eq(s.reverse.reverse, s);
    }
  });
  t('reverse_linked_on_place_station', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(400, 0), []);
    const station = ed.placeStation(V(200, 0), [town(200, 30)]);
    isTrue(station !== null);
    const p = station.platforms[0];
    eq(p.segment.reverse, p.reverseSegment);
    eq(p.reverseSegment.reverse, p.segment);
    for (const s of ed.network.segments) {
      isTrue(s.reverse !== null);
      eq(s.reverse.reverse, s);
    }
  });
  t('try_delete_track_at', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    eq(ed.network.segments.length, 2);
    isFalse(ed.tryDeleteTrackAt(V(100, 100)));
    isTrue(ed.tryDeleteTrackAt(V(100, 0)));
    eq(ed.network.segments.length, 0);
  });
  t('split_track_at_hit', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(200, 0), []);
    const junction = ed.splitTrackAtHit(ed.findTrackAt(V(100, 0)));
    isTrue(junction !== null);
    isTrue(ed.network.nodes.includes(junction));
    eq(ed.network.segments.length, 4);
  });
  t('finish_rejects_tight_curve', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.addWaypoint(V(50, 0));
    ed.addWaypoint(V(50, 30));
    isFalse(ed.finishAt(node(0, 60)));
    isTrue(ed.lastFinishRejected);
    isTrue(ed.drawing);
    eq(ed.network.segments.length, 0);
  });
  t('finish_accepts_gentle_curve', () => {
    const ed = editor();
    ed.startDrawing(node(0, 0));
    ed.addWaypoint(V(150, 40));
    isTrue(ed.finishAt(node(300, 0)));
    isFalse(ed.lastFinishRejected);
    eq(ed.network.segments.length, 2);
  });
  t('turnout_shallow_angle_accepted', () => {
    const ed = editor();
    const a = node(0, 0);
    ed.createBidirectionalTrack(a, node(300, 0), []);
    const c = node(300, -53);
    ed.network.addNode(c);
    ed.startDrawing(a);
    isTrue(ed.finishAt(c));
    isFalse(ed.lastFinishRejected);
    eq(ed.network.segments.length, 4);
  });
  t('turnout_steep_angle_rejected', () => {
    const ed = editor();
    const a = node(0, 0);
    ed.createBidirectionalTrack(a, node(300, 0), []);
    const c = node(300, -300);
    ed.network.addNode(c);
    ed.startDrawing(a);
    isFalse(ed.finishAt(c));
    isTrue(ed.lastFinishRejected);
    eq(ed.rejectionReason, 'turnout');
    eq(ed.network.segments.length, 2);
  });
  t('turnout_no_existing_tracks_accepted', () => {
    const ed = editor();
    const a = node(0, 0), b = node(100, 200);
    ed.network.addNode(a);
    ed.network.addNode(b);
    ed.startDrawing(a);
    isTrue(ed.finishAt(b));
    eq(ed.network.segments.length, 2);
  });
  t('finish_on_track_tangential_connects', () => {
    const ed = editorWithTrack();
    const c = node(500, 0);
    ed.network.addNode(c);
    ed.startDrawing(c);
    isTrue(ed.finishOnTrack(ed.findTrackAt(V(150, 0))));
    isFalse(ed.drawing);
    eq(ed.network.segments.length, 6);
  });
  t('finish_on_track_steep_rejected_without_split', () => {
    const ed = editorWithTrack();
    const c = node(150, 300);
    ed.network.addNode(c);
    ed.startDrawing(c);
    const nodesBefore = ed.network.nodes.length;
    isFalse(ed.finishOnTrack(ed.findTrackAt(V(150, 0))));
    isTrue(ed.lastFinishRejected);
    eq(ed.rejectionReason, 'turnout');
    isTrue(ed.drawing);
    eq(ed.network.segments.length, 2);
    eq(ed.network.nodes.length, nodesBefore);
  });
  t('finish_on_track_continue_keeps_drawing', () => {
    const ed = editorWithTrack();
    const c = node(500, 0);
    ed.network.addNode(c);
    ed.startDrawing(c);
    isTrue(ed.finishOnTrack(ed.findTrackAt(V(150, 0)), true));
    isTrue(ed.drawing);
    approx(ed.startNode.position.x, 150, 5);
    eq(ed.waypoints.length, 0);
    eq(ed.network.segments.length, 6);
  });
  t('finish_on_track_platform_rejected', () => {
    const ed = editorWithTrack();
    const station = ed.placeStation(V(150, 0), [town(150, 0)]);
    const p = station.platforms[0];
    const c = node(500, 0);
    ed.network.addNode(c);
    ed.startDrawing(c);
    isFalse(ed.finishOnTrack([p.segment, 0.5]));
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 6);
  });
  t('finish_on_track_rejoins_departure_segment', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(900, 0), []);
    const j1 = ed.splitTrackAtHit(ed.findTrackAt(V(150, 0)));
    ed.startDrawing(j1);
    ed.addWaypoint(V(450, -40));
    const hit = ed.findTrackAt(V(750, 0));
    eq(hit[0].nodeStart === j1 || hit[0].nodeEnd === j1, true);
    isTrue(ed.finishOnTrack(hit));
    isFalse(ed.drawing);
    eq(ed.network.segments.length, 8);
    eq(ed.network.getOutgoing(j1).length, 3);
  });
  t('finish_on_track_coincident_rejoin_rejected', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(900, 0), []);
    const j1 = ed.splitTrackAtHit(ed.findTrackAt(V(150, 0)));
    ed.startDrawing(j1);
    isFalse(ed.finishOnTrack(ed.findTrackAt(V(750, 0))));
    isTrue(ed.drawing);
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 4);
  });
  t('find_track_at_finds_parallel_track', () => {
    const ed = editor();
    const a = node(0, 0), b = node(300, 0);
    ed.createBidirectionalTrack(a, b, []);
    ed.createBidirectionalTrack(a, b, [V(150, -60)]);
    const hit = ed.findTrackAt(V(150, -60));
    isTrue(hit.length > 0);
    approx(hit[0].positionAt(hit[1]).distanceTo(V(150, -60)), 0, 5);
  });
  t('hit_too_close_to_start_by_distance', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(600, 0), []);
    ed.startDrawing(ed.network.nodes[0]);
    isTrue(ed.hitTooCloseToStart(ed.findTrackAt(V(100, 0))));
    isFalse(ed.hitTooCloseToStart(ed.findTrackAt(V(300, 0))));
    ed.cancel();
    const c = node(20, 10);
    ed.network.addNode(c);
    ed.startDrawing(c);
    isTrue(ed.hitTooCloseToStart(ed.findTrackAt(V(25, 0))));
    isFalse(ed.hitTooCloseToStart(ed.findTrackAt(V(100, 0))));
    ed.cancel();
  });
  t('place_station_creates_platform', () => {
    const ed = editorWithTrack();
    const tw = town(150, 0);
    const station = ed.placeStation(V(150, 5), [tw]);
    isTrue(station !== null);
    eq(tw.station, station);
    eq(station.town, tw);
    eq(station.platforms.length, 1);
    const p = station.platforms[0];
    isTrue(p.segment.isPlatformSegment());
    isTrue(p.reverseSegment.isPlatformSegment());
    eq(p.station, station);
    approx(p.segment.length(), TrackEditor.PLATFORM_LENGTH, 15);
    isTrue(ed.network.nodes.includes(p.segment.nodeStart));
    isTrue(ed.network.nodes.includes(p.segment.nodeEnd));
    eq(ed.network.segments.length, 6);
  });
  t('place_station_snaps_to_endpoint', () => {
    const ed = editor();
    const a = node(0, 0);
    ed.createBidirectionalTrack(a, node(300, 0), []);
    const station = ed.placeStation(V(40, 0), [town(40, 0)]);
    isTrue(station !== null);
    eq(station.platforms[0].segment.nodeStart, a);
    eq(ed.network.segments.length, 4);
  });
  t('place_station_rejects_outside_town', () => {
    const ed = editorWithTrack();
    eq(ed.placeStation(V(150, 0), [town(150, 300)]), null);
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 2);
  });
  t('place_station_rejects_second_station', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(300, 0), []);
    ed.createBidirectionalTrack(node(0, 40), node(300, 40), []);
    const tw = town(150, 20);
    const first = ed.placeStation(V(150, 0), [tw]);
    isTrue(first !== null);
    eq(ed.placeStation(V(150, 40), [tw]), null);
    isTrue(ed.lastError !== '');
    eq(tw.station, first);
  });
  t('place_station_rejects_short_track', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(120, 0), []);
    eq(ed.placeStation(V(60, 0), [town(60, 0)]), null);
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 2);
  });
  t('place_station_rejects_platform_overlap', () => {
    const ed = editorWithTrack();
    const tw = town(150, 0);
    const other = town(160, 0);
    isTrue(ed.placeStation(V(150, 0), [tw, other]) !== null);
    eq(ed.placeStation(V(160, 0), [tw, other]), null);
    isTrue(ed.lastError !== '');
    eq(other.station, null);
  });
  t('split_rejected_on_platform', () => {
    const ed = editorWithTrack();
    const station = ed.placeStation(V(150, 0), [town(150, 0)]);
    eq(ed.splitTrackAtHit([station.platforms[0].segment, 0.5]), null);
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 6);
  });
  t('delete_rejected_on_platform', () => {
    const ed = editorWithTrack();
    ed.placeStation(V(150, 0), [town(150, 0)]);
    eq(ed.network.segments.length, 6);
    isFalse(ed.tryDeleteTrackAt(V(150, 0)));
    isTrue(ed.lastError !== '');
    eq(ed.network.segments.length, 6);
  });
  t('remove_town_removes_station', () => {
    const ed = editorWithTrack();
    const tw = town(150, 0);
    const other = town(500, 500);
    const towns = [tw, other];
    const orders = [tw];
    isTrue(ed.placeStation(V(150, 0), towns) !== null);
    ed.removeTown(tw, towns, [orders]);
    eq(tw.station, null);
    isFalse(towns.includes(tw));
    isTrue(towns.includes(other));
    eq(orders.length, 0);
    eq(ed.network.segments.length, 4);
    for (const s of ed.network.segments) isFalse(s.isPlatformSegment());
  });
  t('signal_placed_two_way_on_split', () => {
    const ed = editorWithTrack();
    isTrue(ed.placeOrCycleSignal(V(150, 0)));
    eq(ed.network.segments.length, 4);
    const arriving = incomingAt(ed, V(150, 0));
    eq(arriving.length, 2);
    for (const s of arriving) isTrue(s.exitSignal);
    eq(signalCount(ed), 2);
  });
  t('signal_cycles_loose_then_strict_then_removes', () => {
    const ed = editorWithTrack();
    const p = V(150, 0);
    ed.placeOrCycleSignal(p);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 1);
    const looseFirst = signalled(ed);
    isTrue(looseFirst.looseOneWay);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 1);
    isFalse(looseFirst.exitSignal);
    isTrue(signalled(ed).looseOneWay);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 1);
    const strictFirst = signalled(ed);
    isFalse(strictFirst.looseOneWay);
    eq(strictFirst, looseFirst);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 1);
    isFalse(strictFirst.exitSignal);
    isFalse(signalled(ed).looseOneWay);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 0);
    eq(ed.network.segments.length, 4);
    isTrue(ed.placeOrCycleSignal(p));
    eq(signalCount(ed), 2);
    for (const s of ed.network.segments) isFalse(s.looseOneWay);
  });
  t('signal_rejected_on_platform', () => {
    const ed = editorWithTrack();
    ed.placeStation(V(150, 0), [town(150, 0)]);
    isFalse(ed.placeOrCycleSignal(V(150, 0)));
    isTrue(ed.lastError !== '');
    eq(signalCount(ed), 0);
    eq(ed.network.segments.length, 6);
  });
  t('signal_rejected_on_real_junction', () => {
    const ed = editor();
    const hub = node(0, 0);
    ed.createBidirectionalTrack(hub, node(300, 0), []);
    ed.createBidirectionalTrack(hub, node(-300, 20), []);
    ed.createBidirectionalTrack(hub, node(-300, -20), []);
    isFalse(ed.placeOrCycleSignal(V(0, 0)));
    isTrue(ed.lastError !== '');
    eq(signalCount(ed), 0);
  });
  t('split_preserves_signal_flags', () => {
    const ed = editor();
    ed.createBidirectionalTrack(node(0, 0), node(400, 0), []);
    ed.placeOrCycleSignal(V(200, 0));
    ed.splitTrackAtHit(ed.findTrackAt(V(100, 0)));
    eq(signalCount(ed), 2);
    for (const s of ed.network.segments) {
      if (s.exitSignal) approx(s.nodeEnd.position.x, 200, 1);
    }
  });
}
