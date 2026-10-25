import { suite, t, eq, isFalse, V } from './test_base.js';
import { NetworkNode } from '../src/network_node.js';

export function runAll() {
  suite('TestNetworkNode');
  t('junction_creates_node_at_position', () => {
    eq(NetworkNode.junction(V(50, 60)).position, V(50, 60));
  });
  t('nodes_have_no_town_reference', () => {
    const node = NetworkNode.junction(V(0, 0));
    isFalse('town' in node);
    isFalse('type' in node);
  });
}
