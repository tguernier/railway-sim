import { GameState } from './game.js';

// The build toolbar: one button per editing tool (track, double track, town,
// station, signal, crossover, delete) and the run controls (undo, run/stop, reservation
// overlay, reset), each labelled with its keyboard shortcut — the shortcuts
// themselves stay in Game.handleInput. Buttons call Game's tool/command API,
// so the toolbar and the keyboard always agree on the active mode.
//
// Like OrdersPanel it re-renders only when a signature of what it shows
// changes, and handles clicks by delegation on data attributes.

// 20×20 line icons (stroke = currentColor).
const ICONS = {
  track: '<path d="M6 2v16M14 2v16M3.5 5h13M3.5 10h13M3.5 15h13"/>',
  double: '<path d="M2.5 2v16M7 2v16M13 2v16M17.5 2v16M1 6h7.5M1 14h7.5M11.5 6h7.5M11.5 14h7.5"/>',
  town: '<path d="M2.5 10 10 3.5l7.5 6.5M4.5 8.5V17h11V8.5M8.5 17v-4.5h3V17"/>',
  station: '<path d="M2.5 7.5 10 3l7.5 4.5M5 7.5v5M15 7.5v5M2 12.5h16v3.5H2z"/>',
  signal: '<path d="M10 18v-7.5"/><rect x="6.5" y="2" width="7" height="9" rx="2.5"/><circle cx="10" cy="5.2" r="1.3" fill="currentColor"/>',
  crossover: '<path d="M4 2v16M16 2v16M4 4.5 16 15.5M4 15.5 16 4.5"/>',
  delete: '<path d="M3.5 5.5h13M8 5.5V3.5h4v2M5.5 5.5l1 11.5h7l1-11.5M8.5 8.5v6M11.5 8.5v6"/>',
  undo: '<path d="M6.5 4 3 7.5 6.5 11"/><path d="M3 7.5h8.5a4.5 4.5 0 0 1 0 9H8"/>',
  run: '<path d="M6 3.5v13l10.5-6.5z" fill="currentColor"/>',
  stop: '<rect x="5" y="5" width="10" height="10" rx="1" fill="currentColor"/>',
  overlay: '<path d="M1.5 10S4.5 4.5 10 4.5 18.5 10 18.5 10 15.5 15.5 10 15.5 1.5 10 1.5 10z"/><circle cx="10" cy="10" r="2.5"/>',
  reset: '<path d="M3.5 10a6.5 6.5 0 1 0 2.2-4.9"/><path d="M3.5 2.5v4h4"/>',
};

const icon = (name) => `<svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${ICONS[name]}</svg>`;

// Editing tools, in toolbar order: [tool, label, shortcut, tooltip].
const TOOLS = [
  ['track', 'Track', 'Esc', 'Draw single track — click a junction, track, or open ground to start'],
  ['double', 'Double', 'D', 'Draw double track — two one-way running lines with signals'],
  ['town', 'Town', '⇧ click', 'Place towns (Shift+click also works with the track tools)'],
  ['station', 'Station', 'P', "Build a station on a track inside a town's circle"],
  ['signal', 'Signal', 'S', 'Place signals; click one to cycle its type'],
  ['crossover', 'Crossover', 'C', 'Add a scissors crossover to double track: trains can turn back at its stations and use either platform'],
  ['delete', 'Delete', 'right-click', 'Remove track or towns (right-click also works with the track tools)'],
];

export class Toolbar {
  constructor(game, root) {
    this.game = game;
    this.root = root;
    this._signature = '';
    root.addEventListener('click', (e) => this._onClick(e));
  }

  _onClick(e) {
    const el = e.target.closest('button');
    if (el === null || el.disabled) return;
    const g = this.game;
    if (el.dataset.tool !== undefined) {
      // Clicking the active tool again (other than a track tool) puts it
      // down, back to drawing track.
      const tool = el.dataset.tool;
      g.setTool(g.tool === tool && tool !== 'track' && tool !== 'double'
        ? (g.editor.doubleTrack ? 'double' : 'track')
        : tool);
    } else {
      switch (el.dataset.command) {
        case 'undo': g.undo(); break;
        case 'run': g.startSimulation(); break;
        case 'stop': g.stopSimulation(); break;
        case 'overlay': g.toggleReservations(); break;
        case 'reset':
          if (window.confirm('Reset the game? Everything built is lost.')) g.resetGame();
          break;
      }
    }
    // Keep keyboard focus off the toolbar: Space and the letter keys belong
    // to the game.
    el.blur();
    e.stopPropagation();
  }

  update() {
    const g = this.game;
    const sig = [g.state, g.tool, g.undoStack.length > 0, g.editor.drawing, g.readyToStart(),
      g.showReservations, Math.trunc(g.money)].join('|');
    if (sig === this._signature) return;
    this._signature = sig;
    this.root.innerHTML = this._html();
  }

  _button({ attr, name, label, key, title, pressed = null, disabled = false, cls = '' }) {
    const pressedAttr = pressed === null ? '' : ` aria-pressed="${pressed}"`;
    const keyHint = key ? `<kbd>${key}</kbd>` : '';
    const tip = key ? `${title} (${key})` : title;
    return `<button type="button" ${attr} class="${cls}" title="${tip}"${pressedAttr}${disabled ? ' disabled' : ''}>${icon(name)}<span class="label">${label}</span>${keyHint}</button>`;
  }

  _html() {
    const g = this.game;
    const editing = g.state === GameState.EDITING;
    const tools = TOOLS.map(([tool, label, key, title]) => this._button({
      attr: `data-tool="${tool}"`, name: tool, label, key, title,
      pressed: g.tool === tool, disabled: !editing,
    })).join('');
    const runStop = editing
      ? this._button({ attr: 'data-command="run"', name: 'run', label: 'Run', key: 'Space',
        title: g.readyToStart() ? 'Start the trains' : 'Start the trains (every train needs at least 2 stops)',
        cls: g.readyToStart() ? 'go' : '' })
      : this._button({ attr: 'data-command="stop"', name: 'stop', label: 'Stop', key: 'Esc',
        title: 'Stop and return to editing (fleet cost refunded)', cls: 'halt' });
    const commands = [
      this._button({ attr: 'data-command="undo"', name: 'undo', label: 'Undo', key: 'U', title: 'Undo the last build action',
        disabled: !editing || g.editor.drawing || g.undoStack.length === 0 }),
      runStop,
      this._button({ attr: 'data-command="overlay"', name: 'overlay', label: 'Paths', key: 'V',
        title: 'Show the track each train has reserved (while running)', pressed: g.showReservations }),
      this._button({ attr: 'data-command="reset"', name: 'reset', label: 'Reset', key: 'R', title: 'Start over with an empty map', cls: 'danger' }),
    ].join('');
    const money = `<div class="money" title="Money"><span class="label">Money</span> <b>${Math.trunc(g.money).toLocaleString('en-US')}</b></div>`;
    return `<div class="group" role="toolbar" aria-label="Build tools">${tools}</div>`
      + `<div class="group" role="toolbar" aria-label="Simulation">${commands}</div>${money}`;
  }
}
