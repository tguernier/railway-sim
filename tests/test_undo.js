import { suite, t, eq, approx, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { Game } from '../src/game.js';

const junction = (x, y) => NetworkNode.junction(V(x, y));

// Straight track at height y with a stationed town beside its middle. Built
// through the editor directly, so it pushes no undo entries itself.
function townWithStation(m, y) {
  m.editor.createBidirectionalTrack(junction(0, y), junction(600, y), []);
  const town = new Town(V(300, y + 30), '#fff');
  m.towns.push(town);
  m.editor.placeStation(V(300, y), m.towns);
  return town;
}

const signalled = (m) => m.network.segments.filter((s) => s.exitSignal).length;

export function runAll() {
  suite('TestUndo');
  t('place_town_undo_restores_color_index', () => {
    const m = new Game();
    m._placeTown(V(100, 100));
    eq(m.towns.length, 1);
    eq(m.nextColorIndex, 1);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.towns.length, 0);
    eq(m.nextColorIndex, 0);
    eq(m.undoStack.length, 0);
  });
  t('build_track_undo_removes_pair_and_fresh_junctions', () => {
    const m = new Game();
    m._handleIdleClick(V(0, 0), false);
    isTrue(m.editor.drawing);
    eq(m.undoStack.length, 0);
    m._handleDrawClick(V(300, 0), true);
    eq(m.network.segments.length, 2);
    eq(m.undoStack.length, 1);
    m.editor.cancel();
    eq(m.network.nodes.length, 2);
    m._undo();
    eq(m.network.segments.length, 0);
    eq(m.network.nodes.length, 0);
  });
  t('failed_finish_burns_no_undo', () => {
    const m = new Game();
    m.network.addNode(junction(0, 60));
    m._handleIdleClick(V(0, 0), false);
    m.editor.addWaypoint(V(50, 0));
    m.editor.addWaypoint(V(50, 30));
    m._handleDrawClick(V(0, 60), false);
    isTrue(m.editor.lastFinishRejected);
    eq(m.network.segments.length, 0);
    eq(m.undoStack.length, 0);
  });
  t('finish_on_track_undo_restores_single_segment', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m._handleIdleClick(V(900, 0), false);
    m._handleDrawClick(V(300, 0), false);
    isFalse(m.editor.drawing);
    eq(m.network.segments.length, 6);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.network.segments.length, 2);
    eq(m.network.nodes.length, 2);
  });
  t('split_undo_restores_original_pair', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m._handleIdleClick(V(300, 0), false);
    isTrue(m.editor.drawing);
    eq(m.network.segments.length, 4);
    eq(m.undoStack.length, 1);
    m.editor.cancel();
    eq(m.network.segments.length, 4);
    m._undo();
    eq(m.network.segments.length, 2);
    eq(m.network.nodes.length, 2);
  });
  t('place_station_undo', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m.towns.push(new Town(V(300, 30), '#fff'));
    m.placingStation = true;
    m._tryPlaceStation(V(300, 0));
    isFalse(m.placingStation);
    isTrue(m.towns[0].station !== null);
    eq(m.network.segments.length, 6);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.towns[0].station, null);
    eq(m.network.segments.length, 2);
    for (const s of m.network.segments) isFalse(s.isPlatformSegment());
  });
  t('failed_station_burns_no_undo', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m.placingStation = true;
    m._tryPlaceStation(V(300, 300));
    isTrue(m.placingStation);
    isTrue(m.statusMessage !== '');
    eq(m.undoStack.length, 0);
  });
  t('place_signal_undo_and_cycle_undo', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m.placingSignal = true;
    m._tryPlaceSignal(V(300, 0));
    isTrue(m.placingSignal);
    eq(m.network.segments.length, 4);
    eq(signalled(m), 2);
    eq(m.undoStack.length, 1);
    m._tryPlaceSignal(V(300, 0));
    eq(signalled(m), 1);
    eq(m.undoStack.length, 2);
    m._undo();
    eq(signalled(m), 2);
    m._undo();
    eq(signalled(m), 0);
    eq(m.network.segments.length, 2);
  });
  t('failed_signal_burns_no_undo', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), []);
    m.placingSignal = true;
    m._tryPlaceSignal(V(300, 300));
    isTrue(m.statusMessage !== '');
    eq(m.undoStack.length, 0);
  });
  t('delete_track_undo_restores_curve', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(junction(0, 0), junction(600, 0), [V(300, 40)]);
    m._rightClickAt(V(300, 40));
    eq(m.network.segments.length, 0);
    eq(m.network.nodes.length, 0);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.network.segments.length, 2);
    eq(m.network.nodes.length, 2);
    approx(m.network.segments[0].positionAt(0.5).y, 40, 10);
  });
  t('delete_miss_and_platform_burn_no_undo', () => {
    const m = new Game();
    townWithStation(m, 0);
    m._rightClickAt(V(1000, 1000));
    eq(m.undoStack.length, 0);
    m._rightClickAt(V(300, 0));
    isTrue(m.statusMessage !== '');
    eq(m.network.segments.length, 6);
    eq(m.undoStack.length, 0);
  });
  t('remove_town_undo_restores_station_and_order', () => {
    const m = new Game();
    const town = townWithStation(m, 0);
    m.trainOrders.push(town);
    eq(m.network.segments.length, 6);
    m._rightClickAt(town.position);
    eq(m.towns.length, 0);
    eq(m.trainOrders.length, 0);
    eq(m.network.segments.length, 4);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.towns.length, 1);
    isTrue(m.towns[0].station !== null);
    eq(m.trainOrders.length, 1);
    eq(m.trainOrders[0], m.towns[0]);
    eq(m.network.segments.length, 6);
  });
  t('order_add_undo', () => {
    const m = new Game();
    const town = townWithStation(m, 0);
    m.editingOrders = true;
    m._clickOrderStop(town.position);
    eq(m.trainOrders.length, 1);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.trainOrders.length, 0);
  });
  t('order_add_rejected_burns_no_undo', () => {
    const m = new Game();
    const town = new Town(V(300, 300), '#fff');
    m.towns.push(town);
    m.editingOrders = true;
    m._clickOrderStop(town.position);
    eq(m.trainOrders.length, 0);
    isTrue(m.statusMessage !== '');
    eq(m.undoStack.length, 0);
  });
  t('order_remove_undo_restores_index', () => {
    const m = new Game();
    const a = townWithStation(m, 0);
    const b = townWithStation(m, 400);
    m.trainOrders.push(a, b);
    m.removeOrder(0, 0);
    eq(m.trainOrders.length, 1);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.trainOrders.length, 2);
    eq(m.trainOrders[0].position, a.position);
    eq(m.trainOrders[1].position, b.position);
  });
  t('order_pop_undo', () => {
    const m = new Game();
    const a = townWithStation(m, 0);
    const b = townWithStation(m, 400);
    m.trainOrders.push(a, b);
    m._popOrderStop();
    eq(m.trainOrders.length, 1);
    m._popOrderStop();
    eq(m.trainOrders.length, 0);
    m._popOrderStop();
    eq(m.undoStack.length, 2);
    m._undo();
    eq(m.trainOrders.length, 1);
    eq(m.trainOrders[0].position, a.position);
    m._undo();
    eq(m.trainOrders.length, 2);
    eq(m.trainOrders[1].position, b.position);
  });
  t('buy_train_undo', () => {
    const m = new Game();
    m._buyTrain();
    eq(m.roster.length, 2);
    eq(m.selectedTrain, 1);
    eq(m.undoStack.length, 1);
    m._undo();
    eq(m.roster.length, 1);
    eq(m.selectedTrain, 0);
  });
  t('sell_train_undo_restores_plan', () => {
    const m = new Game();
    const town = townWithStation(m, 0);
    m._buyTrain();
    m.roster[1].carCount = 3;
    m.roster[1].orders.push(town);
    m._sellTrain();
    eq(m.roster.length, 1);
    eq(m.undoStack.length, 2);
    m._undo();
    eq(m.roster.length, 2);
    eq(m.roster[1].carCount, 3);
    eq(m.roster[1].orders.length, 1);
    eq(m.roster[1].orders[0], m.towns[0]);
  });
  t('sell_last_train_rejected', () => {
    const m = new Game();
    m._sellTrain();
    eq(m.roster.length, 1);
    isTrue(m.statusMessage !== '');
    eq(m.undoStack.length, 0);
  });
  t('two_actions_two_undos', () => {
    const m = new Game();
    m._placeTown(V(100, 100));
    m._placeTown(V(400, 100));
    eq(m.towns.length, 2);
    eq(m.undoStack.length, 2);
    m._undo();
    eq(m.towns.length, 1);
    eq(m.nextColorIndex, 1);
    m._undo();
    eq(m.towns.length, 0);
    eq(m.nextColorIndex, 0);
  });
  t('undo_empty_stack_shows_status', () => {
    const m = new Game();
    m._undo();
    eq(m.statusMessage, 'Nothing to undo');
    eq(m.towns.length, 0);
  });
  t('undo_stack_capped_at_limit', () => {
    const m = new Game();
    for (let i = 0; i < Game.UNDO_LIMIT + 5; i++) m._placeTown(V(10 * i, 100));
    eq(m.undoStack.length, Game.UNDO_LIMIT);
    for (let i = 0; i < Game.UNDO_LIMIT; i++) m._undo();
    eq(m.undoStack.length, 0);
    eq(m.towns.length, 5);
  });
  t('reset_clears_undo_stack', () => {
    const m = new Game();
    m._placeTown(V(100, 100));
    eq(m.undoStack.length, 1);
    m.resetGame();
    eq(m.undoStack.length, 0);
    m._undo();
    eq(m.statusMessage, 'Nothing to undo');
  });
}
