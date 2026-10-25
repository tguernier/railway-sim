// Headless test runner: node tests/run_tests.js
import { results } from './test_base.js';

const suites = [
  './test_network_node.js',
  './test_town.js',
  './test_track_segment.js',
  './test_track_network.js',
  './test_track_editor.js',
  './test_crossings.js',
  './test_station.js',
  './test_train.js',
  './test_multi_train.js',
  './test_game_snapshot.js',
  './test_undo.js',
  './test_main_input.js',
];

for (const path of suites) {
  const mod = await import(path);
  mod.runAll();
}

console.log('');
if (results.fail === 0) {
  console.log(`OK  ${results.pass} tests passed.`);
} else {
  console.error(`FAIL  ${results.pass} passed, ${results.fail} failed.`);
}
process.exit(results.fail > 0 ? 1 : 0);
