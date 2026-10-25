import { suite, t, eq, approx, gt, check, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackSegment } from '../src/track_segment.js';
import { TrackEditor } from '../src/track_editor.js';
import { Platform } from '../src/platform.js';

const node = (x, y) => NetworkNode.junction(V(x, y));
const seg = (ax, ay, bx, by, wps = []) => new TrackSegment(node(ax, ay), node(bx, by), wps);

export function runAll() {
  suite('TestTrackSegment');
  t('stores_nodes', () => {
    const a = node(0, 0);
    const b = node(100, 0);
    const s = new TrackSegment(a, b);
    eq(s.nodeStart, a);
    eq(s.nodeEnd, b);
  });
  t('not_platform_segment_by_default', () => {
    const s = seg(0, 0, 200, 0);
    isFalse(s.isPlatformSegment());
    eq(s.platform, null);
  });
  t('platform_marker', () => {
    const fwd = seg(0, 0, 200, 0);
    const rev = seg(200, 0, 0, 0);
    const platform = new Platform(fwd, rev, 1.0);
    fwd.platform = platform;
    rev.platform = platform;
    isTrue(fwd.isPlatformSegment());
    isTrue(rev.isPlatformSegment());
    eq(fwd.platform, platform);
  });
  t('length_positive', () => gt(seg(0, 0, 100, 0).length(), 0));
  t('zero_length_segment_is_safe', () => {
    const s = seg(100, 100, 100, 100);
    eq(s.length(), 0);
    eq(s.positionAt(0.5), V(100, 100));
    eq(s.angleAt(0.5), 0);
  });
  t('position_at_zero_is_start', () => {
    const s = seg(0, 0, 300, 0);
    approx(s.positionAt(0).x, 0, 1);
    approx(s.positionAt(0).y, 0, 1);
  });
  t('position_at_one_is_end', () => {
    const s = seg(0, 0, 300, 0);
    approx(s.positionAt(1).x, 300, 1);
    approx(s.positionAt(1).y, 0, 1);
  });
  t('angle_horizontal_track', () => approx(seg(0, 0, 300, 0).angleAt(0.5), 0, 0.05));
  t('angle_vertical_track', () => approx(seg(0, 0, 0, 300).angleAt(0.5), Math.PI / 2, 0.05));
  t('waypoints_produce_longer_segment', () => {
    gt(seg(0, 0, 200, 0, [V(100, 150)]).length(), seg(0, 0, 200, 0).length());
  });
  t('straight_segment_infinite_radius', () => gt(seg(0, 0, 300, 0).minRadiusOfCurvature(), 10000));
  t('gentle_curve_large_radius', () => {
    gt(seg(0, 0, 300, 0, [V(150, 40)]).minRadiusOfCurvature(), TrackEditor.MIN_CURVE_RADIUS);
  });
  t('tight_uturn_small_radius', () => {
    const r = seg(0, 0, 0, 60, [V(50, 0), V(50, 30)]).minRadiusOfCurvature();
    check(r < TrackEditor.MIN_CURVE_RADIUS, `expected tight U-turn radius ${r} < ${TrackEditor.MIN_CURVE_RADIUS}`);
  });
}
