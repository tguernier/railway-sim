import { suite, t, eq, gt, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { TrackSegment } from '../src/track_segment.js';
import { TrackNetwork } from '../src/track_network.js';
import { TrackEditor } from '../src/track_editor.js';
import { Town } from '../src/town.js';
import { Station } from '../src/station.js';
import { Platform } from '../src/platform.js';
import { Train } from '../src/train.js';

export function runAll() {
  suite('TestStation');
  t('station_links_town', () => {
    const town = new Town(V(0, 0), '#fff');
    const station = new Station(town);
    eq(station.town, town);
    eq(station.platforms.length, 0);
  });
  t('platform_links_station_and_segments', () => {
    const a = NetworkNode.junction(V(0, 0));
    const b = NetworkNode.junction(V(120, 0));
    const fwd = new TrackSegment(a, b);
    const rev = new TrackSegment(b, a);
    const platform = new Platform(fwd, rev, -1.0);
    const station = new Station(new Town(V(60, 30), '#fff'));
    platform.station = station;
    station.platforms.push(platform);
    eq(platform.segment, fwd);
    eq(platform.reverseSegment, rev);
    eq(platform.side, -1.0);
    eq(platform.width, 20.0);
    eq(platform.station, station);
  });
  t('train_traverses_platform_and_boards', () => {
    const ed = new TrackEditor(new TrackNetwork());
    const a = NetworkNode.junction(V(0, 0));
    ed.createBidirectionalTrack(a, NetworkNode.junction(V(300, 0)), []);
    const town = new Town(V(150, 0), '#fff');
    town.waiting = 12.0;
    const station = ed.placeStation(V(150, 0), [town]);
    isTrue(station !== null);
    const platform = station.platforms[0];
    const train = new Train();
    train.orders = [town];
    train.currentOrderIndex = 0;
    const route = ed.network.findRouteToPlatform(a, platform);
    gt(route.length, 0);
    isTrue(route[route.length - 1].isPlatformSegment());
    train.setRoute(route);
    isFalse(train.boardedThisLeg);
    train.move(100.0);
    isTrue(train.hasCompletedRoute());
    const seg = train.currentSegment();
    isTrue(seg.isPlatformSegment());
    eq(seg.platform.station.town, train.currentOrderTown());
    train.boardFrom(town);
    eq(train.passengersOnBoard, 12);
    eq(Math.trunc(town.waiting), 0);
  });
  t('town_without_station_yields_no_route', () => {
    const town = new Town(V(150, 0), '#fff');
    eq(town.station, null);
    const net = new TrackNetwork();
    net.addNode(NetworkNode.junction(V(0, 0)));
    isTrue(town.station === null || town.station.platforms.length === 0);
  });
}
