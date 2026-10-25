import { Game } from './game.js';
import { Renderer } from './renderer.js';
import { OrdersPanel } from './orders_panel.js';
import { Toolbar } from './toolbar.js';

// Browser front end: wires DOM input to Game.handleInput, runs the frame
// loop, and keeps the toolbar, panels, and tip line in step with the game.

const game = new Game();
const view = new Renderer(game, document.getElementById('app'));
const canvas = view.canvas;
const ordersPanel = new OrdersPanel(game, document.getElementById('orders'));
const toolbar = new Toolbar(game, document.getElementById('toolbar'));
const hud = {
  hint: document.getElementById('hint'),
  status: document.getElementById('status'),
};

// Keys the camera owns (never forwarded to the game).
const PAN_KEYS = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, 1], ArrowDown: [0, -1] };
const ROTATE_KEYS = { KeyQ: -1, KeyE: 1 };
// Keys the game reads; their browser defaults (scrolling, quick find) are
// suppressed.
const GAME_KEYS = new Set([
  'KeyR', 'KeyV', 'Escape', 'KeyU', 'Space', 'KeyZ', 'KeyO', 'KeyP', 'KeyS',
  'KeyT', 'KeyX', 'Comma', 'Period', 'BracketLeft', 'BracketRight', 'KeyD', 'KeyC',
]);
const held = new Set();

// Middle-drag pans (grab the ground); Shift+middle-drag orbits.
let drag = null;

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

canvas.addEventListener('pointerdown', (e) => {
  if (e.button === 1) {
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    drag = e.shiftKey
      ? { mode: 'orbit', x: e.clientX, y: e.clientY }
      : { mode: 'pan', anchor: view.groundAt(e.clientX, e.clientY) };
    return;
  }
  const pos = view.groundAt(e.clientX, e.clientY);
  if (pos === null) return;
  const button = e.button === 0 ? 'left' : e.button === 2 ? 'right' : null;
  if (button !== null) game.handleInput({ type: 'mouse', button, shift: e.shiftKey, pos });
});

canvas.addEventListener('pointermove', (e) => {
  if (drag !== null) {
    if (drag.mode === 'pan' && drag.anchor !== null) {
      const here = view.groundAt(e.clientX, e.clientY);
      if (here !== null) view.panBy(drag.anchor.sub(here));
    } else if (drag.mode === 'orbit') {
      view.orbit((e.clientX - drag.x) * 0.006, (e.clientY - drag.y) * 0.004);
      drag.x = e.clientX;
      drag.y = e.clientY;
    }
  }
  const pos = view.groundAt(e.clientX, e.clientY);
  if (pos !== null) game.handleInput({ type: 'motion', pos });
});

canvas.addEventListener('pointerup', (e) => {
  if (e.button === 1) drag = null;
});

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  view.zoomAt(Math.exp(e.deltaY * 0.0012), e.clientX, e.clientY);
}, { passive: false });

window.addEventListener('keydown', (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  // A focused dropdown in the orders panel keeps its own keys (arrows, Space).
  if (e.target instanceof HTMLSelectElement) return;
  if (e.code in PAN_KEYS || e.code in ROTATE_KEYS) {
    e.preventDefault();
    held.add(e.code);
    return;
  }
  if (!GAME_KEYS.has(e.code)) return;
  e.preventDefault();
  if (e.repeat) return;
  game.handleInput({ type: 'key', code: e.code });
});

window.addEventListener('keyup', (e) => held.delete(e.code));
window.addEventListener('blur', () => held.clear());

function updateCameraKeys(delta) {
  if (held.size === 0) return;
  const { right, up } = view.screenAxes();
  const speed = view.rig.distance * 0.9 * delta;
  let rotate = 0;
  for (const code of held) {
    if (code in PAN_KEYS) {
      const [dx, dy] = PAN_KEYS[code];
      view.panBy(right.mul(dx * speed).add(up.mul(dy * speed)));
    } else if (code in ROTATE_KEYS) {
      rotate += ROTATE_KEYS[code];
    }
  }
  if (rotate !== 0) view.orbit(rotate * 1.6 * delta, 0);
}

// Patch a text node only when it changed — the HUD is rewritten each frame.
function setText(el, text) {
  if (el.textContent !== text) el.textContent = text;
  el.hidden = text === '';
}

function updateHud() {
  setText(hud.hint, game.hintText());
  setText(hud.status, game.statusTimer > 0 ? game.statusMessage : '');
}

let last = performance.now();
function frame(now) {
  // Cap the step so a backgrounded tab doesn't come back with one huge tick.
  const delta = Math.min((now - last) / 1000, 0.1);
  last = now;
  updateCameraKeys(delta);
  game.process(delta);
  view.render();
  updateHud();
  toolbar.update();
  ordersPanel.update();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// Exposed for debugging from the console and for automated checks.
window.railway = { game, view };
