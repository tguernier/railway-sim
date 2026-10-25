import { suite, t, eq, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { GameSnapshot } from '../src/game_snapshot.js';
import { Game, GameState, townName, TOWN_NAMES } from '../src/game.js';

const J = (x, y) => NetworkNode.junction(V(x, y));

// One straight line with stationed towns A, B, C at x = 200, 600, 1000.
function lineOfThree(m) {
  m.editor.createBidirectionalTrack(J(0, 0), J(1200, 0), []);
  const towns = [200, 600, 1000].map((x, i) => new Town(V(x, 30), '#fff', townName(i)));
  m.towns.push(...towns);
  for (const tw of towns) m.editor.placeStation(V(tw.position.x, 0), m.towns);
  return towns;
}

// Record the town of every platform arrival, in order.
function recordArrivals(m) {
  const arrivals = [];
  const original = m._arriveAtPlatform.bind(m);
  m._arriveAtPlatform = (tr) => {
    arrivals.push(tr.currentSegment().platform.station.town);
    original(tr);
  };
  return arrivals;
}

export function runAll() {
  suite('TestOrders');
  t('clicking_an_existing_stop_appends_it_again', () => {
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.editingOrders = true;
    for (const tw of [a, b, c, b]) m.handleInput({ type: 'mouse', button: 'left', shift: false, pos: tw.position });
    eq(m.trainOrders.length, 4);
    isTrue(m.trainOrders[1] === b && m.trainOrders[3] === b);
    eq(m.undoStack.length, 4);
  });
  t('back_to_back_repeat_rejected_without_undo', () => {
    const m = new Game();
    const [a] = lineOfThree(m);
    isTrue(m.addOrder(0, a));
    isFalse(m.addOrder(0, a));
    eq(m.trainOrders.length, 1);
    eq(m.undoStack.length, 1);
    isTrue(m.statusMessage.includes('previous stop'));
  });
  t('order_problem_catches_wraparound_repeat', () => {
    const m = new Game();
    const [a, b] = lineOfThree(m);
    m.roster[0].orders = [a];
    eq(Game.orderProblem(m.roster[0]), 'needs at least 2 stops');
    m.roster[0].orders = [a, b, a];
    isTrue(Game.orderProblem(m.roster[0]).includes('stops 3 and 1'));
    m._startSimulation();
    eq(m.state, GameState.EDITING);
    isTrue(m.statusMessage.includes('Train 1 stops 3 and 1'));
    m.roster[0].orders = [a, b];
    eq(Game.orderProblem(m.roster[0]), '');
  });
  t('train_visits_a_repeated_stop_in_order', () => {
    // A → B → C → B on one line: the train reverses at C and at A, and
    // calls at B on the way out and on the way back.
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.roster[0].orders = [a, b, c, b];
    const arrivals = recordArrivals(m);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    for (let tick = 0; tick < 60 * 40; tick++) m.process(1 / 60);
    eq(m.state, GameState.SIMULATING);
    const expected = [b, c, b, a, b, c];
    isTrue(arrivals.length >= expected.length);
    isTrue(expected.every((tw, i) => arrivals[i] === tw));
    isTrue(m.money > 1000 - 150);  // fares from the repeated stop count too
  });
  t('remove_move_clear_are_undoable', () => {
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.roster[0].orders = [a, b, c];
    isTrue(m.moveOrder(0, 2, -1));
    isTrue(m.trainOrders[1] === c && m.trainOrders[2] === b);
    isFalse(m.moveOrder(0, 0, -1));  // already first
    isFalse(m.moveOrder(0, 2, 1));   // already last
    isTrue(m.removeOrder(0, 0));
    eq(m.trainOrders.length, 2);
    isTrue(m.clearOrders(0));
    eq(m.trainOrders.length, 0);
    isFalse(m.clearOrders(0));
    eq(m.undoStack.length, 3);
    m._undo();
    eq(m.trainOrders.length, 2);
    m._undo();
    eq(m.trainOrders.length, 3);
    m._undo();
    // Undo restores clones, so compare by position.
    eq(m.trainOrders[1].position, b.position);
    eq(m.trainOrders[2].position, c.position);
  });
  t('removing_a_town_drops_every_visit_and_collapses_repeats', () => {
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.roster[0].orders = [a, b, c, b];
    m._buyTrain();
    m.roster[1].orders = [a, b, a, c];
    m._rightClickAt(b.position.add(V(0, 20)));
    isFalse(m.towns.includes(b));
    isTrue(m.roster[0].orders.length === 2 && m.roster[0].orders[0] === a && m.roster[0].orders[1] === c);
    isTrue(m.roster[1].orders.length === 2 && m.roster[1].orders[0] === a && m.roster[1].orders[1] === c);
  });
  t('snapshot_keeps_repeated_stops_identical', () => {
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.roster[0].orders = [a, b, c, b];
    const snap = GameSnapshot.capture(m);
    const o = snap.roster[0].orders;
    isTrue(o[1] === o[3]);
    isTrue(o[1] !== b);
    eq(o[1].name, b.name);
  });
  t('sell_by_index_keeps_selection_on_the_same_train', () => {
    const m = new Game();
    m._buyTrain();
    m._buyTrain();
    m.roster[2].carCount = 3;
    m.selectTrain(2);
    m._sellTrain(0);
    eq(m.roster.length, 2);
    eq(m.selectedTrain, 1);
    eq(m.roster[m.selectedTrain].carCount, 3);
  });
  t('car_count_clamped_and_fleet_cost', () => {
    const m = new Game();
    m.setCarCount(0, 99);
    eq(m.roster[0].carCount, m.maxCarCount());
    m.setCarCount(0, 0);
    eq(m.roster[0].carCount, 1);
    m._buyTrain();
    m.setCarCount(1, 3);
    eq(m.fleetCost(), Game.TRAIN_COST + 2 * Game.COST_PER_CAR);
  });
  t('towns_are_named_in_placement_order', () => {
    const m = new Game();
    m._placeTown(V(0, 0));
    m._placeTown(V(500, 0));
    eq(m.towns[0].name, TOWN_NAMES[0]);
    eq(m.towns[1].name, TOWN_NAMES[1]);
    m._undo();
    m._placeTown(V(900, 0));
    eq(m.towns[1].name, TOWN_NAMES[1]);  // the undone name is reused
    eq(townName(TOWN_NAMES.length), `${TOWN_NAMES[0]} 2`);
  });
  t('order_edits_refused_while_simulating', () => {
    const m = new Game();
    const [a, b, c] = lineOfThree(m);
    m.roster[0].orders = [a, b];
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    isFalse(m.addOrder(0, c));
    isFalse(m.removeOrder(0, 0));
    isFalse(m.moveOrder(0, 0, 1));
    isFalse(m.clearOrders(0));
    eq(m.roster[0].orders.length, 2);
  });
}
