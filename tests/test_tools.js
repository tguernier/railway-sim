import { suite, t, eq, isTrue, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';
import { Town } from '../src/town.js';
import { Game, GameState } from '../src/game.js';

const J = (x, y) => NetworkNode.junction(V(x, y));
const left = (pos, shift = false) => ({ type: 'mouse', button: 'left', shift, pos });
const key = (code) => ({ type: 'key', code });

// A straight line with two stationed towns and a train ordered between them.
function readyLine(m) {
  m.editor.createBidirectionalTrack(J(0, 0), J(1200, 0), []);
  const a = new Town(V(300, 30), '#fff', 'A');
  const b = new Town(V(900, 30), '#fff', 'B');
  m.towns.push(a, b);
  m.editor.placeStation(V(300, 0), m.towns);
  m.editor.placeStation(V(900, 0), m.towns);
  m.roster[0].orders = [a, b];
  return [a, b];
}

export function runAll() {
  suite('TestTools');
  t('tool_reflects_modes_and_keys', () => {
    const m = new Game();
    eq(m.tool, 'track');
    m.handleInput(key('KeyD'));
    eq(m.tool, 'double');
    m.handleInput(key('KeyP'));
    eq(m.tool, 'station');
    m.handleInput(key('Escape'));
    eq(m.tool, 'double');  // back to whichever track tool was active
    m.handleInput(key('KeyS'));
    eq(m.tool, 'signal');
    m.handleInput(key('KeyS'));
    m.handleInput(key('KeyO'));
    eq(m.tool, 'orders');
  });
  t('set_tool_switches_exclusively', () => {
    const m = new Game();
    for (const tool of ['town', 'station', 'signal', 'delete', 'orders', 'double', 'track']) {
      m.setTool(tool);
      eq(m.tool, tool);
      const flags = [m.placingTown, m.placingStation, m.placingSignal, m.deleting, m.editingOrders];
      isTrue(flags.filter(Boolean).length <= 1);
    }
  });
  t('switching_tool_cancels_a_drawing_but_track_kinds_keep_it', () => {
    const m = new Game();
    m.handleInput(left(V(0, 0)));
    isTrue(m.editor.drawing);
    eq(m.network.nodes.length, 1);
    m.setTool('double');
    isTrue(m.editor.drawing);  // single ↔ double just changes what the finish lays
    m.setTool('town');
    isFalse(m.editor.drawing);
    eq(m.network.nodes.length, 0);  // the fresh start junction went with it
  });
  t('town_tool_places_with_a_plain_click', () => {
    const m = new Game();
    m.setTool('town');
    m.handleInput(left(V(100, 100)));
    m.handleInput(left(V(400, 100)));
    eq(m.towns.length, 2);
    eq(m.undoStack.length, 2);
    isFalse(m.editor.drawing);
    m.handleInput(key('Escape'));
    eq(m.tool, 'track');
  });
  t('delete_tool_removes_track_and_towns', () => {
    const m = new Game();
    m.editor.createBidirectionalTrack(J(0, 0), J(600, 0), []);
    m.towns.push(new Town(V(300, 300), '#fff', 'T'));
    m.setTool('delete');
    m.handleInput(left(V(300, 0)));
    eq(m.network.segments.length, 0);
    m.handleInput(left(V(300, 300)));
    eq(m.towns.length, 0);
    eq(m.undoStack.length, 2);
    eq(m.tool, 'delete');  // stays active for more deletions
  });
  t('commands_run_stop_undo', () => {
    const m = new Game();
    readyLine(m);
    m.setTool('station');
    m.startSimulation();
    eq(m.state, GameState.SIMULATING);
    eq(m.tool, null);
    m.setTool('town');  // tools do nothing while running
    eq(m.tool, null);
    m.stopSimulation();
    eq(m.state, GameState.EDITING);
    eq(m.tool, 'track');
    m.setTool('town');
    m.handleInput(left(V(600, 400)));
    eq(m.towns.length, 3);
    m.undo();
    eq(m.towns.length, 2);
    isFalse(m.showReservations);
    m.toggleReservations();
    isTrue(m.showReservations);
  });
  t('hint_is_a_short_tip_for_the_tool', () => {
    const m = new Game();
    isTrue(m.hintText().startsWith('Click a junction'));
    m.setTool('station');
    isTrue(m.hintText().includes("town's circle"));
    m.setTool('track');
    m.handleInput(left(V(0, 0)));
    m.handleInput(left(V(0, 60)));       // a bend
    m.handleInput(left(V(5, 5), true));  // a hairpin — too tight
    isTrue(m.hintText().startsWith('Curve too tight'));
    for (const tool of ['town', 'signal', 'delete', 'orders']) {
      m.setTool(tool);
      isTrue(m.hintText().length < 140);
      isFalse(m.hintText().includes('|'));
    }
  });
}
