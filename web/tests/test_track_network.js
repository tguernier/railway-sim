import { suite, t, eq, approx, gt, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackSegment } from '../src/track_segment.js';
import { TrackNetwork } from '../src/track_network.js';
import { Platform } from '../src/platform.js';
import { Train } from '../src/train.js';

const node = (x, y) => NetworkNode.junction(V(x, y));
const seg = (a, b) => new TrackSegment(a, b);
const last = (arr) => arr[arr.length - 1];

// Build a platform pair between two nodes and register it on a network,
// linked as reverse twins as placeStation does.
function platform(net, a, b) {
  const fwd = new TrackSegment(a, b);
  const rev = new TrackSegment(b, a);
  fwd.reverse = rev;
  rev.reverse = fwd;
  net.addSegment(fwd);
  net.addSegment(rev);
  const p = new Platform(fwd, rev, 1.0);
  fwd.platform = p;
  rev.platform = p;
  return p;
}

// A linked twin pair added to the network. Returns the forward segment.
function twin(net, a, b) {
  const fwd = new TrackSegment(a, b);
  const rev = new TrackSegment(b, a);
  fwd.reverse = rev;
  rev.reverse = fwd;
  net.addSegment(fwd);
  net.addSegment(rev);
  return fwd;
}

// A short and a long branch between the same two nodes, the short one held
// by another train.
function blockedBranchPair() {
  const net = new TrackNetwork();
  const a = node(0, 0);
  const b = node(200, 0);
  const shortSeg = twin(net, a, b);
  const longSeg = new TrackSegment(a, b, [V(100, 300)]);
  net.addSegment(longSeg);
  const holder = new Train();
  holder.tryReserve([shortSeg]);
  return { net, a, b, shortSeg, longSeg, holder };
}

export function runAll() {
  suite('TestTrackNetwork');
  t('add_segment_stored', () => {
    const net = new TrackNetwork();
    const s = seg(node(0, 0), node(100, 0));
    net.addSegment(s);
    eq(net.segments.length, 1);
    eq(net.segments[0], s);
  });
  t('add_segment_registers_nodes', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(100, 0);
    net.addSegment(seg(a, b));
    isTrue(net.nodes.includes(a));
    isTrue(net.nodes.includes(b));
  });
  t('get_outgoing_returns_segment', () => {
    const net = new TrackNetwork();
    const a = node(0, 0);
    const s = seg(a, node(100, 0));
    net.addSegment(s);
    eq(net.getOutgoing(a).length, 1);
    eq(net.getOutgoing(a)[0], s);
  });
  t('get_outgoing_unknown_node_empty', () => {
    eq(new TrackNetwork().getOutgoing(node(0, 0)).length, 0);
  });
  t('find_route_direct', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(100, 0);
    const s = seg(a, b);
    net.addSegment(s);
    const route = net.findRoute(a, b);
    eq(route.length, 1);
    eq(route[0], s);
  });
  t('find_route_two_hops', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(100, 0), c = node(200, 0);
    const ab = seg(a, b), bc = seg(b, c);
    net.addSegment(ab);
    net.addSegment(bc);
    const route = net.findRoute(a, c);
    eq(route.length, 2);
    eq(route[0], ab);
    eq(route[1], bc);
  });
  t('find_route_no_path', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(100, 0), c = node(200, 0);
    net.addSegment(seg(a, b));
    eq(net.findRoute(a, c).length, 0);
  });
  t('find_route_same_node_no_loop', () => {
    const net = new TrackNetwork();
    const a = node(0, 0);
    net.addSegment(seg(a, node(100, 0)));
    eq(net.findRoute(a, a).length, 0);
  });
  t('dijkstra_prefers_shorter_distance', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(0, 200), m = node(0, 100);
    const longDirect = new TrackSegment(a, b, [V(2000, 100)]);
    const am = new TrackSegment(a, m), mb = new TrackSegment(m, b);
    net.addSegment(longDirect);
    net.addSegment(am);
    net.addSegment(mb);
    gt(longDirect.length(), am.length() + mb.length());
    const route = net.findRoute(a, b);
    eq(route.length, 2);
    eq(route[0], am);
    eq(route[1], mb);
  });
  t('remove_segment', () => {
    const net = new TrackNetwork();
    const a = node(0, 0);
    const s = seg(a, node(100, 0));
    net.addSegment(s);
    net.removeSegment(s);
    eq(net.segments.length, 0);
    eq(net.getOutgoing(a).length, 0);
  });
  t('remove_segment_nonexistent_is_noop', () => {
    const net = new TrackNetwork();
    net.removeSegment(seg(node(0, 0), node(100, 0)));
    eq(net.segments.length, 0);
  });
  t('cleanup_orphan_junction', () => {
    const net = new TrackNetwork();
    const j = node(50, 50);
    net.addNode(j);
    isTrue(net.nodes.includes(j));
    isTrue(net.cleanupOrphan(j));
    isFalse(net.nodes.includes(j));
  });
  t('cleanup_orphan_keeps_connected', () => {
    const net = new TrackNetwork();
    const a = node(0, 0);
    net.addSegment(seg(a, node(100, 0)));
    isFalse(net.cleanupOrphan(a));
    isTrue(net.nodes.includes(a));
  });
  t('route_through_junction', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const aj = seg(a, j), jb = seg(j, b);
    net.addSegment(aj);
    net.addSegment(jb);
    const route = net.findRoute(a, b);
    eq(route.length, 2);
    eq(route[0], aj);
    eq(route[1], jb);
  });
  t('route_to_platform_traverses_platform', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), entry = node(100, 0), exit = node(220, 0);
    const approach = seg(a, entry);
    net.addSegment(approach);
    net.addSegment(seg(entry, a));
    const p = platform(net, entry, exit);
    const route = net.findRouteToPlatform(a, p);
    eq(route.length, 2);
    eq(route[0], approach);
    eq(route[1], p.segment);
  });
  t('route_to_platform_from_entry_node', () => {
    const net = new TrackNetwork();
    const entry = node(0, 0);
    const p = platform(net, entry, node(120, 0));
    const route = net.findRouteToPlatform(entry, p);
    eq(route.length, 1);
    eq(route[0], p.segment);
  });
  t('route_to_platform_from_exit_node', () => {
    const net = new TrackNetwork();
    const exit = node(120, 0);
    const p = platform(net, node(0, 0), exit);
    const route = net.findRouteToPlatform(exit, p);
    eq(route.length, 1);
    eq(route[0], p.reverseSegment);
  });
  t('route_to_platform_no_path', () => {
    const net = new TrackNetwork();
    const lonely = node(-500, -500);
    net.addNode(lonely);
    const p = platform(net, node(0, 0), node(120, 0));
    eq(net.findRouteToPlatform(lonely, p).length, 0);
  });
  t('unroutable_stop_connected_loop', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(120, 0), c = node(240, 0), d = node(360, 0);
    const p1 = platform(net, a, b);
    const p2 = platform(net, c, d);
    net.addSegment(seg(b, c));
    net.addSegment(seg(c, b));
    net.addSegment(seg(d, a));
    net.addSegment(seg(a, d));
    eq(net.firstUnroutableStop([p1, p2]), -1);
  });
  t('unroutable_stop_disconnected', () => {
    const net = new TrackNetwork();
    const p1 = platform(net, node(0, 0), node(120, 0));
    const p2 = platform(net, node(500, 0), node(620, 0));
    eq(net.firstUnroutableStop([p1, p2]), 1);
  });
  t('unroutable_stop_on_wrap_leg', () => {
    const net = new TrackNetwork();
    const b = node(120, 0), c = node(240, 0);
    const p1 = platform(net, node(0, 0), b);
    const p2 = platform(net, c, node(360, 0));
    net.addSegment(seg(b, c));
    eq(net.firstUnroutableStop([p1, p2]), 0);
  });
  t('two_way_signal_passable_both_directions', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const aj = twin(net, a, j);
    const jb = twin(net, j, b);
    aj.exitSignal = true;
    jb.reverse.exitSignal = true;
    eq(net.findRoute(a, b).length, 2);
    eq(net.findRoute(b, a).length, 2);
  });
  t('one_way_signal_bars_reverse_direction', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const aj = twin(net, a, j);
    twin(net, j, b);
    aj.exitSignal = true;
    eq(net.findRoute(a, b).length, 2);
    eq(net.findRoute(b, a).length, 0);
  });
  t('one_way_signal_forces_other_branch', () => {
    const net = new TrackNetwork();
    const w = node(0, 0), lw = node(100, 0), le = node(300, 0), e = node(400, 0);
    twin(net, w, lw);
    const branch1 = twin(net, lw, le);
    const branch2 = twin(net, lw, le);
    twin(net, le, e);
    branch1.exitSignal = true;
    branch2.reverse.exitSignal = true;
    const east = net.findRoute(w, e);
    eq(east.length, 3);
    isTrue(east.includes(branch1));
    isFalse(east.includes(branch2));
    const west = net.findRoute(e, w);
    eq(west.length, 3);
    isTrue(west.includes(branch2.reverse));
    isFalse(west.includes(branch1.reverse));
  });
  t('unroutable_when_only_path_is_one_way_against', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(120, 0), c = node(240, 0), d = node(360, 0);
    const p1 = platform(net, a, b);
    const p2 = platform(net, c, d);
    const link = twin(net, b, c);
    eq(net.firstUnroutableStop([p1, p2]), -1);
    link.exitSignal = true;
    eq(net.firstUnroutableStop([p1, p2]), 0);
  });
  t('loose_one_way_passable_against_for_a_penalty', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const aj = twin(net, a, j);
    twin(net, j, b);
    aj.exitSignal = true;
    aj.looseOneWay = true;
    eq(net.findRoute(a, b).length, 2);
    const west = net.findRoute(b, a);
    eq(west.length, 2);
    approx(net.routeCost(west, null), 200 + TrackNetwork.ONE_WAY_PENALTY);
    aj.looseOneWay = false;
    eq(net.findRoute(b, a).length, 0);
  });
  t('loose_one_way_prefers_the_way_round', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const m1 = node(60, 100), m2 = node(140, 100);
    const aj = twin(net, a, j);
    twin(net, j, b);
    twin(net, a, m1);
    twin(net, m1, m2);
    twin(net, m2, b);
    eq(net.findRoute(b, a).length, 2);
    aj.exitSignal = true;
    aj.looseOneWay = true;
    eq(net.findRoute(b, a).length, 3);
    eq(net.findRoute(a, b).length, 2);
  });
  t('loose_one_way_keeps_order_loop_routable', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(120, 0), c = node(240, 0), d = node(360, 0);
    const p1 = platform(net, a, b);
    const p2 = platform(net, c, d);
    const link = twin(net, b, c);
    link.exitSignal = true;
    link.looseOneWay = true;
    eq(net.firstUnroutableStop([p1, p2]), -1);
    link.looseOneWay = false;
    eq(net.firstUnroutableStop([p1, p2]), 0);
  });
  t('penalty_prefers_free_branch', () => {
    const w = blockedBranchPair();
    const route = w.net.findRoute(w.a, w.b, new Train());
    eq(route.length, 1);
    eq(route[0], w.longSeg);
    eq(w.net.findRoute(w.a, w.b)[0], w.shortSeg);
    eq(w.net.findRoute(w.a, w.b, w.holder)[0], w.shortSeg);
  });
  t('penalty_all_blocked_returns_shortest', () => {
    const w = blockedBranchPair();
    w.holder.tryReserve([w.longSeg]);
    const route = w.net.findRoute(w.a, w.b, new Train());
    eq(route.length, 1);
    eq(route[0], w.shortSeg);
  });
  t('reverse_twin_reservation_penalizes', () => {
    const w = blockedBranchPair();
    w.holder.releaseAll();
    w.holder.tryReserve([w.shortSeg.reverse]);
    eq(w.net.findRoute(w.a, w.b, new Train())[0], w.longSeg);
  });
  t('one_way_still_bars_with_for_train', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(100, 0), b = node(200, 0);
    const aj = twin(net, a, j);
    twin(net, j, b);
    aj.exitSignal = true;
    eq(net.findRoute(b, a, new Train()).length, 0);
  });
  t('platform_entry_end_avoids_traffic', () => {
    const net = new TrackNetwork();
    const s = node(0, 0), x = node(100, 0), entry = node(200, 0), exit = node(320, 0), y = node(420, 0);
    const p = platform(net, entry, exit);
    const sx = twin(net, s, x);
    twin(net, x, entry);
    const sy = new TrackSegment(s, y, [V(210, 300), V(520, 150)]);
    net.addSegment(sy);
    net.addSegment(seg(y, exit));
    const tr = new Train();
    eq(last(net.findRouteToPlatform(s, p, tr)), p.segment);
    const holder = new Train();
    holder.tryReserve([sx]);
    const route = net.findRouteToPlatform(s, p, tr);
    eq(last(route), p.reverseSegment);
    isTrue(route.includes(sy));
  });
  t('unroutable_stop_ignores_reservations', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(120, 0), c = node(240, 0), d = node(360, 0);
    const p1 = platform(net, a, b);
    const p2 = platform(net, c, d);
    const bc = twin(net, b, c);
    const da = twin(net, d, a);
    const holder = new Train();
    holder.tryReserve([bc, da, p1.segment, p2.segment]);
    eq(net.firstUnroutableStop([p1, p2]), -1);
  });
  t('switchback_through_junction_rejected', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(300, 0), c = node(600, 0), d = node(600, 80);
    twin(net, a, j);
    twin(net, j, c);
    twin(net, j, d);
    eq(net.findRoute(a, c).length, 2);
    eq(net.findRoute(a, d).length, 2);
    eq(net.findRoute(d, c).length, 0);
    eq(net.findRoute(c, d).length, 0);
  });
  t('reversal_only_first_hop_at_stop', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), b = node(300, 0), c = node(600, 0);
    const ab = twin(net, a, b);
    twin(net, b, c);
    const standing = ab.reverse;
    eq(net.findRoute(a, c, null, standing).length, 0);
    const route = net.findRoute(a, c, null, standing, null, true);
    eq(route.length, 2);
    eq(route[0], ab);
  });
  t('v_junction_stops_unroutable', () => {
    const net = new TrackNetwork();
    const a = node(0, 0), j = node(300, 0), b1 = node(500, 50), b2 = node(500, -50);
    twin(net, a, j);
    twin(net, j, b1);
    twin(net, j, b2);
    const p1 = platform(net, b1, node(620, 80));
    const p2 = platform(net, b2, node(620, -80));
    eq(net.firstUnroutableStop([p1, p2]), 1);
  });
}
