import { suite, t, eq, approx, gt, isFalse, V } from './test_base.js';
import { Town } from '../src/town.js';

export function runAll() {
  suite('TestTown');
  t('init', () => {
    const pos = V(100, 200);
    const town = new Town(pos, '#ff0000');
    eq(town.position, pos);
    eq(town.color, '#ff0000');
    eq(town.waiting, 0.0);
    eq(town.station, null);
    eq(town.radius, 60.0);
  });
  t('town_has_no_network_node', () => {
    isFalse('node' in new Town(V(0, 0), '#fff'));
  });
  t('generate_passengers_increases_waiting', () => {
    const town = new Town(V(0, 0), '#fff');
    for (let i = 0; i < 1000; i++) town.generatePassengers();
    gt(town.waiting, 0.0);
  });
  t('pickup_returns_floored_count', () => {
    const town = new Town(V(0, 0), '#fff');
    town.waiting = 5.7;
    eq(town.pickupPassengers(40), 5);
    approx(town.waiting, 0.7, 0.01);
  });
  t('pickup_limited_by_capacity', () => {
    const town = new Town(V(0, 0), '#fff');
    town.waiting = 20.0;
    eq(town.pickupPassengers(10), 10);
    approx(town.waiting, 10.0, 0.01);
  });
  t('pickup_zero_when_waiting_below_one', () => {
    const town = new Town(V(0, 0), '#fff');
    town.waiting = 0.8;
    eq(town.pickupPassengers(40), 0);
    approx(town.waiting, 0.8, 0.01);
  });
}
