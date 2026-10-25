import { Game, GameState, TRAIN_COLORS } from './game.js';

// Side panel listing every roster train with its orders. In edit mode each
// card manages one train — cars, stops (reorder, remove, clear, add from a
// list or by picking towns on the map), buy/sell — through Game's order API,
// so every edit is an undo step exactly as the keyboard/map path is. While
// simulating the cards turn read-only and show where each train is going.
//
// The panel re-renders only when a signature of what it shows changes, and
// handles clicks by delegation on data-action attributes.

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const COLLAPSE_KEY = 'railway-sim.ordersPanelCollapsed';

export class OrdersPanel {
  constructor(game, root) {
    this.game = game;
    this.root = root;
    this._signature = '';
    this.collapsed = this._loadCollapsed();
    root.addEventListener('click', (e) => this._onClick(e));
    root.addEventListener('change', (e) => this._onChange(e));
  }

  _loadCollapsed() {
    try {
      const v = localStorage.getItem(COLLAPSE_KEY);
      if (v !== null) return v === '1';
    } catch { /* storage unavailable */ }
    return window.innerWidth < 700;
  }

  _saveCollapsed() {
    try { localStorage.setItem(COLLAPSE_KEY, this.collapsed ? '1' : '0'); } catch { /* ignore */ }
  }

  // --- Events ---

  _onClick(e) {
    const el = e.target.closest('[data-action]');
    if (el === null || el.tagName === 'SELECT') return;
    const g = this.game;
    const ti = Number(el.closest('[data-train]')?.dataset.train ?? -1);
    const oi = Number(el.dataset.order ?? -1);
    switch (el.dataset.action) {
      case 'toggle':
        this.collapsed = !this.collapsed;
        this._saveCollapsed();
        break;
      case 'select': g.selectTrain(ti); break;
      case 'buy': if (g.state === GameState.EDITING) g._buyTrain(); break;
      case 'sell': if (g.state === GameState.EDITING) g._sellTrain(ti); break;
      case 'cars': g.setCarCount(ti, g.roster[ti].carCount + Number(el.dataset.delta)); break;
      case 'up': g.moveOrder(ti, oi, -1); break;
      case 'down': g.moveOrder(ti, oi, 1); break;
      case 'remove': g.removeOrder(ti, oi); break;
      case 'clear': g.clearOrders(ti); break;
      case 'pick': {
        // Toggle map picking for this train (the O orders mode).
        const picking = g.editingOrders && g.selectedTrain === ti;
        g.selectTrain(ti);
        g.placingStation = false;
        g.placingSignal = false;
        if (g.editor.drawing) g.editor.cancel();
        g.editingOrders = !picking;
        break;
      }
    }
    // Keep keyboard focus off panel buttons: Space and the letter keys
    // belong to the game.
    if (el instanceof HTMLElement) el.blur();
    e.stopPropagation();
  }

  _onChange(e) {
    const el = e.target;
    if (el.dataset.action !== 'add-select' || el.value === '') return;
    const ti = Number(el.closest('[data-train]').dataset.train);
    const town = this.game.towns[Number(el.value)];
    if (town !== undefined) {
      this.game.selectTrain(ti);
      this.game.addOrder(ti, town);
    }
    el.value = '';
    el.blur();
  }

  // --- Rendering ---

  update() {
    const sig = this._computeSignature();
    if (sig === this._signature) return;
    this._signature = sig;
    this.root.innerHTML = this._html();
  }

  _computeSignature() {
    const g = this.game;
    const townIds = new Map(g.towns.map((t, i) => [t, i]));
    const parts = [
      this.collapsed, g.state, g.selectedTrain, g.editingOrders,
      g.towns.map((t) => `${t.name}:${t.station !== null}`).join(','),
      g.roster.map((p) => `${p.carCount}/${p.orders.map((t) => townIds.get(t)).join('.')}`).join('|'),
    ];
    if (g.state === GameState.SIMULATING) {
      parts.push(g.trains.map((tr) => [tr.currentOrderIndex, tr.passengersOnBoard,
        this._trainStatus(tr)].join(':')).join('|'));
    }
    return parts.join('#');
  }

  _trainStatus(tr) {
    const g = this.game;
    const target = tr.currentOrderTown();
    const name = target?.name || 'next stop';
    if (g.deadlockedTrains.includes(tr)) return 'Deadlocked';
    if (tr.dwellRemaining > 0) return `Boarding at ${name}`;
    if (tr.waitingForTrack) return `Waiting for path to ${name}`;
    return `Heading to ${name}`;
  }

  _html() {
    const g = this.game;
    const editing = g.state === GameState.EDITING;
    const toggle = `<button class="icon" data-action="toggle" aria-expanded="${!this.collapsed}" title="${this.collapsed ? 'Show' : 'Hide'} trains">${this.collapsed ? '▸' : '▾'}</button>`;
    const cost = editing ? `<span class="meta">Fleet cost ${Math.trunc(g.fleetCost())}</span>` : '';
    const head = `<header><h2>Trains <span class="count">${g.roster.length}</span></h2>${cost}${toggle}</header>`;
    if (this.collapsed) return head;
    const cards = g.roster.map((plan, ti) => (editing ? this._editCard(plan, ti) : this._simCard(ti))).join('');
    const buy = editing
      ? `<button class="wide" data-action="buy">+ Buy train <span class="meta">(${Game.TRAIN_COST})</span></button>`
      : '';
    return `${head}<div class="cards">${cards}</div>${buy}`;
  }

  // One stop in a card. `tag` marks the stop a running train is at
  // ('here') or heading to ('next').
  _stopRow(town, oi, count, controls, tag = '') {
    const name = esc(town.name || `Town ${this.game.towns.indexOf(town) + 1}`);
    const buttons = controls ? `<span class="row-actions">
        <button class="icon" data-action="up" data-order="${oi}" title="Move up" ${oi === 0 ? 'disabled' : ''}>↑</button>
        <button class="icon" data-action="down" data-order="${oi}" title="Move down" ${oi === count - 1 ? 'disabled' : ''}>↓</button>
        <button class="icon danger" data-action="remove" data-order="${oi}" title="Remove stop">×</button>
      </span>` : '';
    return `<li class="${tag !== '' ? 'current' : ''}"><span class="n">${oi + 1}</span><span class="town-dot" style="background:${town.color}"></span><span class="name">${name}</span>${tag !== '' ? `<span class="tag">${tag}</span>` : ''}${buttons}</li>`;
  }

  _editCard(plan, ti) {
    const g = this.game;
    const selected = ti === g.selectedTrain;
    const picking = selected && g.editingOrders;
    const stops = plan.orders.length > 0
      ? `<ol class="stops">${plan.orders.map((t, oi) => this._stopRow(t, oi, plan.orders.length, true)).join('')}</ol>`
      : '<p class="empty">No stops yet.</p>';
    const last = plan.orders[plan.orders.length - 1];
    const options = g.towns
      .map((t, i) => [t, i])
      .filter(([t]) => t.station !== null)
      .map(([t, i]) => `<option value="${i}" ${t === last ? 'disabled' : ''}>${esc(t.name || `Town ${i + 1}`)}${t === last ? ' (previous stop)' : ''}</option>`)
      .join('');
    const add = options !== ''
      ? `<select data-action="add-select" aria-label="Add a stop to train ${ti + 1}"><option value="">Add stop…</option>${options}</select>`
      : '<span class="meta">Build stations to add stops.</span>';
    const problem = Game.orderProblem(plan);
    return `<section class="card${selected ? ' selected' : ''}" data-train="${ti}" style="--swatch:${TRAIN_COLORS[ti % TRAIN_COLORS.length]}">
      <div class="card-head">
        <button class="title" data-action="select" title="Select train ${ti + 1} for keyboard editing"><span class="swatch"></span>Train ${ti + 1}</button>
        <span class="cars">Cars
          <button class="icon" data-action="cars" data-delta="-1" title="Remove a car" ${plan.carCount <= 1 ? 'disabled' : ''}>−</button>
          <b>${plan.carCount}</b>
          <button class="icon" data-action="cars" data-delta="1" title="Add a car" ${plan.carCount >= g.maxCarCount() ? 'disabled' : ''}>+</button>
        </span>
        <button class="danger" data-action="sell" title="${g.roster.length <= 1 ? 'The last train cannot be sold' : 'Sell this train'}" ${g.roster.length <= 1 ? 'disabled' : ''}>Sell</button>
      </div>
      ${stops}
      <div class="add">${add}
        <button data-action="pick" class="${picking ? 'active' : ''}" aria-pressed="${picking}">${picking ? 'Done picking' : 'Pick on map'}</button>
        <button data-action="clear" ${plan.orders.length === 0 ? 'disabled' : ''}>Clear</button>
      </div>
      ${problem !== '' ? `<p class="problem">⚠ ${esc(problem.charAt(0).toUpperCase() + problem.slice(1))}</p>` : ''}
    </section>`;
  }

  _simCard(ti) {
    const g = this.game;
    const tr = g.trains[ti];
    const color = TRAIN_COLORS[ti % TRAIN_COLORS.length];
    if (tr === undefined) return '';
    const here = tr.dwellRemaining > 0 ? 'here' : 'next';
    const stops = tr.orders.map((t, oi) => this._stopRow(t, oi, tr.orders.length, false, oi === tr.currentOrderIndex ? here : '')).join('');
    const status = this._trainStatus(tr);
    return `<section class="card" data-train="${ti}" style="--swatch:${color}">
      <div class="card-head">
        <span class="title"><span class="swatch"></span>Train ${ti + 1}</span>
        <span class="meta">${tr.passengersOnBoard}/${tr.capacity} aboard</span>
      </div>
      <p class="status${status === 'Deadlocked' || status.startsWith('Waiting') ? ' warn' : ''}">${esc(status)}</p>
      <ol class="stops">${stops}</ol>
    </section>`;
  }
}
