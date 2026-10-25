import { suite, t, eq, approx, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { Game, GameState } from '../src/game.js';

const junction = (x, y) => NetworkNode.junction(V(x, y));

// Split a straight track at (150, 0) and leave the editor drawing from the
// new junction — the setup for closing a passing loop back onto that track.
function mainDrawingFromSplit() {
  const m = new Game();
  m.editor.createBidirectionalTrack(junction(0, 0), junction(900, 0), []);
  m._handleIdleClick(V(150, 0), false);
  isTrue(m.editor.drawing);
  return m;
}

export function runAll() {
  suite('TestMainInput');
  t('rejoin_departure_track_closes_passing_loop', () => {
    const m = mainDrawingFromSplit();
    const ed = m.editor;
    m._handleDrawClick(V(450, -40), false);
    eq(ed.waypoints.length, 1);
    m._handleDrawClick(V(750, 0), false);
    isFalse(ed.lastFinishRejected);
    isFalse(ed.drawing);
    eq(m.network.segments.length, 8);
    eq(m.undoStack.length, 2);
    isTrue(ed.findTrackAt(V(450, -40)).length > 0);
  });
  t('shift_rejoin_departure_track_continues', () => {
    const m = mainDrawingFromSplit();
    const ed = m.editor;
    m._handleDrawClick(V(450, -40), false);
    m._handleDrawClick(V(750, 0), true);
    isFalse(ed.lastFinishRejected);
    isTrue(ed.drawing);
    approx(ed.startNode.position.x, 750, 5);
    eq(m.network.segments.length, 8);
  });
  t('click_near_start_still_adds_waypoint', () => {
    const m = mainDrawingFromSplit();
    m._handleDrawClick(V(170, 5), false);
    isTrue(m.editor.drawing);
    eq(m.editor.waypoints.length, 1);
    eq(m.network.segments.length, 4);
    eq(m.undoStack.length, 1);
  });
  t('shallow_departure_click_is_waypoint', () => {
    const m = mainDrawingFromSplit();
    m._handleDrawClick(V(280, -12), false);
    isTrue(m.editor.drawing);
    eq(m.editor.waypoints.length, 1);
    eq(m.network.segments.length, 4);
  });
  t('flat_rejoin_rejected_with_message', () => {
    const m = mainDrawingFromSplit();
    m._handleDrawClick(V(750, 0), false);
    isTrue(m.editor.drawing);
    eq(m.network.segments.length, 4);
    isTrue(m.statusMessage !== '');
    eq(m.undoStack.length, 1);
  });
  t('escape_stops_sim_and_keeps_world', () => {
    const m = new Game();
    const ed = m.editor;
    ed.createBidirectionalTrack(junction(0, 0), junction(1200, 0), []);
    const a = new Town(V(300, 30), '#fff');
    const b = new Town(V(900, 30), '#fff');
    m.towns.push(a, b);
    ed.placeStation(V(300, 0), m.towns);
    ed.placeStation(V(900, 0), m.towns);
    m.roster[0].orders = [a, b];
    m._buyTrain();
    m.roster[1].orders = [b, a];
    const segmentsBefore = m.network.segments.length;
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    eq(m.money, 1000 - 500 - 2 * 150);
    m.handleInput({ type: 'key', code: 'Escape' });
    eq(m.state, GameState.EDITING);
    eq(m.trains.length, 0);
    eq(m.money, 1000);
    eq(m.network.segments.length, segmentsBefore);
    eq(m.towns.length, 2);
    eq(m.roster.length, 2);
    for (const s of m.network.segments) eq(s.reservedBy, null);
    m._startSimulation();
    eq(m.state, GameState.SIMULATING);
    eq(m.trains.length, 2);
  });
}
