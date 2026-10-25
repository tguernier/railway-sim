import * as THREE from 'three';
import { Vec2, TAU, radToDeg } from './vec2.js';
import { GameState, TRAIN_COLORS } from './game.js';
import { TrackEditor } from './track_editor.js';
import { OneWay } from './track_network.js';
import { Train } from './train.js';
import { circumradius } from './track_segment.js';

// Three.js view of the game. Game coordinates are top-down 2D pixels
// (x right, y down); the 3D world puts them on the ground plane as (x, 0, y),
// so one pixel is one world unit and the camera looks "north" (-z) by default.
//
// The scene is split in three layers:
//   static  — towns, track, platforms, junctions, signals; rebuilt whenever
//             game.worldVersion moves (every edit-mode click/key, undo, reset)
//   trains  — pooled car meshes, re-posed every frame
//   overlay — editor previews, hover rings, reservations; rebuilt every frame
// Text (badges, labels, angle readouts) is drawn on a 2D canvas over the
// WebGL one at projected positions.

// Heights of the layers above the ground.
const Y = {
  townDisc: 0.25,
  link: 0.45,
  ballastTop: 2.0,
  railTop: 3.4,
  junction: 3.8,
  overlay: 4.4,
  platformTop: 5.0,
};

const COLORS = {
  ground: '#9acd32',
  ballast: '#a7a196',
  sleeper: '#6e5845',
  rail: '#d6d8db',
  junction: '#ffffff',
  junctionEdge: '#696969',
  crossing: '#696969',
  pole: '#696969',
  red: '#ff2020',
  green: '#32cd32',
  strictBar: '#8b0000',
  carGray: '#696969',
};

// --- Geometry helpers ---

// Lateral unit vector at each polyline vertex: Vec2.orthogonal() of the
// local tangent, so offsets match the game logic's sides (Platform.side).
function lateralNormals(points) {
  const out = [];
  for (let i = 0; i < points.length; i++) {
    const prev = points[Math.max(i - 1, 0)];
    const next = points[Math.min(i + 1, points.length - 1)];
    out.push(next.sub(prev).normalized().orthogonal());
  }
  return out;
}

// Accumulates quad strips into one BufferGeometry.
class StripBuilder {
  constructor() {
    this.pos = [];
    this.idx = [];
  }

  // A strip between two edges, each an array of [x, y, z].
  quadStrip(edgeA, edgeB) {
    const base = this.pos.length / 3;
    for (let i = 0; i < edgeA.length; i++) this.pos.push(...edgeA[i], ...edgeB[i]);
    for (let i = 0; i < edgeA.length - 1; i++) {
      const a = base + i * 2;
      this.idx.push(a, a + 2, a + 1, a + 1, a + 2, a + 3);
    }
  }

  // Edge of a polyline at lateral offset `off` and height `y`.
  static edge(points, normals, off, y) {
    return points.map((p, i) => [p.x + normals[i].x * off, y, p.y + normals[i].y * off]);
  }

  // A flat ribbon between lateral offsets a and b.
  ribbon(points, a, b, y) {
    if (points.length < 2) return this;
    const n = lateralNormals(points);
    this.quadStrip(StripBuilder.edge(points, n, a, y), StripBuilder.edge(points, n, b, y));
    return this;
  }

  // A raised strip between lateral offsets a and b: top face plus both walls.
  solid(points, a, b, y0, y1) {
    if (points.length < 2) return this;
    const n = lateralNormals(points);
    const topA = StripBuilder.edge(points, n, a, y1);
    const topB = StripBuilder.edge(points, n, b, y1);
    this.quadStrip(topA, topB);
    this.quadStrip(StripBuilder.edge(points, n, a, y0), topA);
    this.quadStrip(StripBuilder.edge(points, n, b, y0), topB);
    return this;
  }

  build() {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(this.pos, 3));
    g.setIndex(this.idx);
    g.computeVertexNormals();
    return g;
  }
}

// Split a polyline into dash pieces (2-point polylines).
function dashPieces(points, dash) {
  const pieces = [];
  for (let i = 0; i < points.length - 1; i++) {
    const from = points[i];
    const to = points[i + 1];
    const dist = from.distanceTo(to);
    const dir = to.sub(from).normalized();
    let drawn = 0;
    let on = true;
    while (drawn < dist) {
      const len = Math.min(dash, dist - drawn);
      if (on) pieces.push([from.add(dir.mul(drawn)), from.add(dir.mul(drawn + len))]);
      drawn += len;
      on = !on;
    }
  }
  return pieces;
}

// Small deterministic RNG so a town's houses stay put between rebuilds.
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

// Shared unit geometries.
const GEO = {
  box: new THREE.BoxGeometry(1, 1, 1),
  sphere: new THREE.SphereGeometry(1, 12, 8),
  // 4-sided cylinder / torus: a diamond with its corners on the axes, like
  // the 2D game's junction markers.
  diamond: new THREE.CylinderGeometry(1, 1, 1, 4),
  diamondRing: new THREE.TorusGeometry(1, 0.09, 4, 4).rotateX(-Math.PI / 2),
  ring: new THREE.TorusGeometry(1, 0.04, 6, 48).rotateX(-Math.PI / 2),
  pole: new THREE.CylinderGeometry(0.8, 0.8, 1, 6),
};

export class Renderer {
  constructor(game, container) {
    this.game = game;
    this.container = container;

    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    container.appendChild(this.renderer.domElement);
    this.canvas = this.renderer.domElement;

    this.labels = document.createElement('canvas');
    this.labels.className = 'labels';
    container.appendChild(this.labels);
    this.ctx = this.labels.getContext('2d');

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color('#bfe3f5');
    this.scene.fog = new THREE.Fog('#bfe3f5', 4000, 9000);

    this.camera = new THREE.PerspectiveCamera(45, 1, 5, 20000);
    // Orbit rig around a ground target. Defaults frame a classic
    // 1152×648 window.
    this.rig = {
      target: new THREE.Vector3(576, 0, 324),
      distance: 800,
      yaw: 0,
      pitch: THREE.MathUtils.degToRad(50),
    };

    this.scene.add(new THREE.HemisphereLight('#ffffff', '#5d7a2a', 1.6));
    this.sun = new THREE.DirectionalLight('#fff4e0', 2.2);
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048);
    this.sun.shadow.bias = -0.0005;
    this.scene.add(this.sun, this.sun.target);

    const ground = new THREE.Mesh(new THREE.PlaneGeometry(40000, 40000), new THREE.MeshLambertMaterial({ color: COLORS.ground }));
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    this.scene.add(ground);
    const grid = new THREE.GridHelper(40000, 400, '#7fae22', '#8cbc2a');
    grid.position.y = 0.05;
    grid.material.transparent = true;
    grid.material.opacity = 0.35;
    this.scene.add(grid);

    this.staticGroup = new THREE.Group();
    this.overlayGroup = new THREE.Group();
    this.trainGroup = new THREE.Group();
    this.scene.add(this.staticGroup, this.overlayGroup, this.trainGroup);

    this._materials = new Map();
    this._worldVersion = -1;
    // Per-frame recolouring hooks registered by the static build.
    this._signalLamps = [];
    this._crossingMarkers = [];
    // Train meshes by Train object.
    this._trainMeshes = new Map();
    this._overlayGeoms = [];
    this._reservationKey = '';
    this._reservationGroup = new THREE.Group();
    this.scene.add(this._reservationGroup);
    this._segIds = new WeakMap();
    this._nextSegId = 1;

    this._raycaster = new THREE.Raycaster();
    this._groundPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);

    this.resize();
    // Narrow (portrait) viewports start zoomed out far enough to show the
    // 1152 px-wide play area.
    this.rig.distance *= Math.max(1, 1.6 / this.camera.aspect);
    this.applyCamera();
    window.addEventListener('resize', () => this.resize());
  }

  // --- Camera ---

  applyCamera() {
    const { target, distance, yaw, pitch } = this.rig;
    const horiz = distance * Math.cos(pitch);
    this.camera.position.set(
      target.x + horiz * Math.sin(yaw),
      distance * Math.sin(pitch),
      target.z + horiz * Math.cos(yaw),
    );
    this.camera.lookAt(target);
    // Keep the sun's shadow frustum on the part of the map in view.
    const span = distance * 1.3;
    const cam = this.sun.shadow.camera;
    cam.left = -span; cam.right = span; cam.top = span; cam.bottom = -span;
    cam.near = 10; cam.far = 6000;
    cam.updateProjectionMatrix();
    this.sun.position.set(target.x - 600, 1600, target.z + 900);
    this.sun.target.position.copy(target);
  }

  // Game-space point (Vec2) on the ground under a client-space position, or null.
  groundAt(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    const ndc = new THREE.Vector2(
      ((clientX - rect.left) / rect.width) * 2 - 1,
      -((clientY - rect.top) / rect.height) * 2 + 1,
    );
    this._raycaster.setFromCamera(ndc, this.camera);
    const hit = new THREE.Vector3();
    if (this._raycaster.ray.intersectPlane(this._groundPlane, hit) === null) return null;
    return new Vec2(hit.x, hit.z);
  }

  // Shift the camera target by a ground-space delta (Vec2).
  panBy(delta) {
    this.rig.target.x += delta.x;
    this.rig.target.z += delta.y;
    this.applyCamera();
  }

  // Zoom by a factor, keeping the ground point under the cursor fixed.
  zoomAt(factor, clientX, clientY) {
    const before = this.groundAt(clientX, clientY);
    this.rig.distance = THREE.MathUtils.clamp(this.rig.distance * factor, 120, 5000);
    this.applyCamera();
    const after = this.groundAt(clientX, clientY);
    if (before !== null && after !== null) this.panBy(before.sub(after));
  }

  orbit(dYaw, dPitch) {
    this.rig.yaw += dYaw;
    this.rig.pitch = THREE.MathUtils.clamp(this.rig.pitch + dPitch, THREE.MathUtils.degToRad(18), THREE.MathUtils.degToRad(89));
    this.applyCamera();
  }

  // Unit ground vectors (Vec2) for screen-right and screen-up at the current yaw.
  screenAxes() {
    const yaw = this.rig.yaw;
    return {
      right: new Vec2(Math.cos(yaw), -Math.sin(yaw)),
      up: new Vec2(-Math.sin(yaw), -Math.cos(yaw)),
    };
  }

  resize() {
    const w = this.container.clientWidth;
    const h = this.container.clientHeight;
    this.renderer.setSize(w, h);
    this.camera.aspect = w / Math.max(h, 1);
    this.camera.updateProjectionMatrix();
    const dpr = Math.min(window.devicePixelRatio, 2);
    this.labels.width = Math.round(w * dpr);
    this.labels.height = Math.round(h * dpr);
    this.labels.style.width = `${w}px`;
    this.labels.style.height = `${h}px`;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.applyCamera();
  }

  // --- Materials ---

  // Cached material by kind and colour. Kinds: 'std' (lit), 'basic' (unlit),
  // 'glow' (unlit, for lamps), with optional opacity.
  mat(kind, color, opacity = 1) {
    const key = `${kind}|${color}|${opacity}`;
    let m = this._materials.get(key);
    if (m === undefined) {
      const opts = { color };
      if (opacity < 1) Object.assign(opts, { transparent: true, opacity, depthWrite: false });
      if (kind === 'std') {
        m = new THREE.MeshStandardMaterial({ ...opts, roughness: 0.85, metalness: 0.05, side: THREE.DoubleSide });
      } else if (kind === 'metal') {
        m = new THREE.MeshStandardMaterial({ ...opts, roughness: 0.35, metalness: 0.8, side: THREE.DoubleSide });
      } else {
        m = new THREE.MeshBasicMaterial({ ...opts, side: THREE.DoubleSide });
      }
      this._materials.set(key, m);
    }
    return m;
  }

  _mesh(geometry, material, { cast = false, receive = false } = {}) {
    const mesh = new THREE.Mesh(geometry, material);
    mesh.castShadow = cast;
    mesh.receiveShadow = receive;
    return mesh;
  }

  // Box oriented along a 2D heading, centred at game-space point p.
  _box(p, angle, length, width, y0, y1, material, cast = true) {
    const m = this._mesh(GEO.box, material, { cast, receive: true });
    m.scale.set(length, y1 - y0, width);
    m.position.set(p.x, (y0 + y1) / 2, p.y);
    m.rotation.y = -angle;
    return m;
  }

  // --- Static world ---

  _disposeGroup(group) {
    group.traverse((o) => {
      if (o.geometry && !Object.values(GEO).includes(o.geometry)) o.geometry.dispose();
    });
    group.clear();
  }

  _rebuildStatic() {
    this._disposeGroup(this.staticGroup);
    this._signalLamps = [];
    this._crossingMarkers = [];
    const net = this.game.network;
    this._buildTracks(net);
    this._buildPlatforms();
    this._buildTowns(net);
    this._buildJunctions(net);
    this._buildCrossings(net);
    this._buildSignals(net);
  }

  // Each physical track once (reverse twins deduplicated by identity, as the
  // 2D game does — parallel tracks between the same junctions are legal).
  _physicalTracks(net) {
    const seen = new Set();
    const out = [];
    for (const seg of net.segments) {
      if (seen.has(seg)) continue;
      seen.add(seg);
      if (seg.reverse !== null) seen.add(seg.reverse);
      out.push(seg);
    }
    return out;
  }

  _buildTracks(net) {
    const ballast = new StripBuilder();
    const rails = new StripBuilder();
    const sleepers = [];
    for (const seg of this._physicalTracks(net)) {
      const pts = seg.getBakedPoints();
      if (pts.length < 2) continue;
      ballast.solid(pts, -9, 9, 0, Y.ballastTop);
      rails.solid(pts, -4.6, -3.4, Y.ballastTop, Y.railTop);
      rails.solid(pts, 3.4, 4.6, Y.ballastTop, Y.railTop);
      const len = seg.length();
      for (let d = 4; d < len; d += 8) {
        const t = d / len;
        sleepers.push({ p: seg.positionAt(t), a: seg.angleAt(t) });
      }
    }
    this.staticGroup.add(this._mesh(ballast.build(), this.mat('std', COLORS.ballast), { receive: true }));
    this.staticGroup.add(this._mesh(rails.build(), this.mat('metal', COLORS.rail), { cast: true }));
    if (sleepers.length > 0) {
      const inst = new THREE.InstancedMesh(GEO.box, this.mat('std', COLORS.sleeper), sleepers.length);
      const m = new THREE.Matrix4();
      const q = new THREE.Quaternion();
      const up = new THREE.Vector3(0, 1, 0);
      for (let i = 0; i < sleepers.length; i++) {
        const { p, a } = sleepers[i];
        q.setFromAxisAngle(up, -a);
        m.compose(new THREE.Vector3(p.x, Y.ballastTop + 0.4, p.y), q, new THREE.Vector3(3, 0.8, 13));
        inst.setMatrixAt(i, m);
      }
      inst.receiveShadow = true;
      this.staticGroup.add(inst);
    }
  }

  _buildPlatforms() {
    for (const town of this.game.towns) {
      if (town.station === null) continue;
      for (const platform of town.station.platforms) {
        const seg = platform.segment;
        const pts = seg.getBakedPoints();
        if (pts.length < 2) continue;
        const s = platform.side;
        const near = 10 * s;
        const far = platform.width * s + 4 * s;
        const slab = new StripBuilder().solid(pts, Math.min(near, far), Math.max(near, far), 0, Y.platformTop).build();
        this.staticGroup.add(this._mesh(slab, this.mat('std', town.color), { cast: true, receive: true }));
        // Pale edge line on the track side.
        const edge = new StripBuilder().ribbon(pts, near, near + 1.6 * s, Y.platformTop + 0.05).build();
        this.staticGroup.add(this._mesh(edge, this.mat('basic', '#f4f1e8')));
        // A shelter at the platform's middle.
        const mid = seg.positionAt(0.5);
        const ang = seg.angleAt(0.5);
        const perp = Vec2.fromAngle(ang).orthogonal().mul(s);
        const centre = mid.add(perp.mul((near + far) / 2 * s + 2));
        this.staticGroup.add(this._box(centre, ang, 34, 7, Y.platformTop, Y.platformTop + 9, this.mat('std', '#eeeae0')));
        this.staticGroup.add(this._box(centre.sub(perp.mul(1.5)), ang, 40, 13, Y.platformTop + 9, Y.platformTop + 10.5, this.mat('std', '#5b5b66')));
      }
    }
  }

  _buildTowns(net) {
    const tracks = this._physicalTracks(net);
    for (const town of this.game.towns) {
      const p = town.position;
      const disc = this._mesh(new THREE.CircleGeometry(town.radius, 64).rotateX(-Math.PI / 2), this.mat('basic', town.color, 0.25));
      disc.position.set(p.x, Y.townDisc, p.y);
      disc.renderOrder = 1;
      this.staticGroup.add(disc);
      if (town.station !== null) {
        const ring = this._mesh(new THREE.RingGeometry(town.radius - 1, town.radius + 1, 96).rotateX(-Math.PI / 2), this.mat('basic', town.color));
        ring.position.set(p.x, Y.townDisc + 0.05, p.y);
        this.staticGroup.add(ring);
        const mid = town.station.platforms[0].segment.positionAt(0.5);
        const link = new StripBuilder();
        for (const piece of dashPieces([p, mid], 6)) link.ribbon(piece, -0.9, 0.9, Y.link);
        this.staticGroup.add(this._mesh(link.build(), this.mat('basic', town.color, 0.6)));
      } else {
        const dashes = 24;
        for (let i = 0; i < dashes; i++) {
          const a0 = TAU * i / dashes;
          const g = new THREE.RingGeometry(town.radius - 1, town.radius + 1, 4, 1, a0, TAU / dashes * 0.6).rotateX(-Math.PI / 2);
          const dash = this._mesh(g, this.mat('basic', town.color, 0.6));
          dash.position.set(p.x, Y.townDisc + 0.05, p.y);
          this.staticGroup.add(dash);
        }
      }
      const dot = this._mesh(new THREE.CircleGeometry(6, 24).rotateX(-Math.PI / 2), this.mat('basic', town.color));
      dot.position.set(p.x, Y.townDisc + 0.1, p.y);
      this.staticGroup.add(dot);
      this._buildHouses(town, tracks);
    }
  }

  // A few houses scattered inside the catchment, kept clear of any track or
  // platform so they never sit on the line.
  _buildHouses(town, tracks) {
    const rand = rng(Math.round(town.position.x * 73856093) ^ Math.round(town.position.y * 19349663));
    const nearby = [];
    for (const seg of tracks) {
      for (const q of seg.getBakedPoints()) {
        if (q.distanceTo(town.position) < town.radius + 30) nearby.push(q);
      }
    }
    const houses = [];
    const wall = new THREE.Color(town.color).lerp(new THREE.Color('#ffffff'), 0.55);
    for (let attempt = 0; attempt < 60 && houses.length < 7; attempt++) {
      const r = 14 + rand() * (town.radius - 24);
      const a = rand() * TAU;
      const c = town.position.add(Vec2.fromAngle(a).mul(r));
      if (nearby.some((q) => q.distanceTo(c) < 30)) continue;
      if (houses.some((h) => h.distanceTo(c) < 15)) continue;
      houses.push(c);
      const w = 8 + rand() * 6;
      const d = 8 + rand() * 5;
      const h = 7 + rand() * (houses.length === 1 ? 22 : 9);
      const ang = rand() * Math.PI;
      const shade = wall.clone().offsetHSL(0, 0, (rand() - 0.5) * 0.15);
      this.staticGroup.add(this._box(c, ang, w, d, 0, h, this.mat('std', `#${shade.getHexString()}`)));
      this.staticGroup.add(this._box(c, ang, w + 1.5, d + 1.5, h, h + 1.6, this.mat('std', '#7a4a3a')));
    }
  }

  _buildJunctions(net) {
    for (const node of net.nodes) {
      const top = this._mesh(GEO.diamond, this.mat('std', COLORS.junction), { cast: true });
      top.scale.set(6.5, 1.2, 6.5);
      top.position.set(node.position.x, Y.junction, node.position.y);
      const edge = this._mesh(GEO.diamond, this.mat('std', COLORS.junctionEdge));
      edge.scale.set(8.5, 1, 8.5);
      edge.position.set(node.position.x, Y.junction - 0.3, node.position.y);
      this.staticGroup.add(top, edge);
    }
  }

  // Flat crossings: a hollow lozenge (unlike a junction's solid diamond),
  // recoloured per frame with the holder's colour under the V overlay.
  _buildCrossings(net) {
    for (const crossing of net.crossings) {
      const material = new THREE.MeshBasicMaterial({ color: COLORS.crossing });
      const marker = new THREE.Mesh(GEO.diamondRing, material);
      marker.scale.set(8, 8, 8);
      marker.position.set(crossing.position.x, Y.junction, crossing.position.y);
      this.staticGroup.add(marker);
      this._crossingMarkers.push({ crossing, material });
    }
  }

  // Path signals: a mast with a lamp on the right-hand side of the direction
  // served; strict one-ways add a no-entry bar on the far side.
  _buildSignals(net) {
    for (const seg of net.segments) {
      if (!seg.exitSignal) continue;
      const total = seg.length();
      if (total <= 0) continue;
      const t = Math.min(Math.max(1 - 10 / total, 0), 1);
      const pos = seg.positionAt(t);
      const ang = seg.angleAt(t);
      const side = Vec2.fromAngle(ang).rotated(Math.PI / 2);
      const base = pos.add(side.mul(12));
      const pole = this._mesh(GEO.pole, this.mat('std', COLORS.pole), { cast: true });
      pole.scale.set(1, 18, 1);
      pole.position.set(base.x, 9, base.y);
      const head = this._box(base, ang, 3.4, 3.4, 15, 22, this.mat('std', '#2a2a2a'));
      const material = new THREE.MeshBasicMaterial({ color: COLORS.red });
      const lamp = new THREE.Mesh(GEO.sphere, material);
      lamp.scale.setScalar(1.5);
      // On the face looking back at approaching trains.
      const face = base.sub(Vec2.fromAngle(ang).mul(1.6));
      lamp.position.set(face.x, 19.5, face.y);
      this.staticGroup.add(pole, head, lamp);
      this._signalLamps.push({ seg, material });
      if (seg.reverse !== null && net.oneWayAgainst(seg.reverse) === OneWay.STRICT) {
        const barAt = pos.sub(side.mul(9));
        this.staticGroup.add(this._box(barAt, ang + Math.PI / 2, 9, 2.4, Y.railTop, Y.railTop + 1.6, this.mat('std', COLORS.strictBar)));
      }
    }
  }

  // --- Trains ---

  _trainMesh(tr, color) {
    let entry = this._trainMeshes.get(tr);
    if (entry !== undefined && entry.cars.length === tr.carCount) return entry;
    if (entry !== undefined) this.trainGroup.remove(entry.group);
    const group = new THREE.Group();
    const cars = [];
    const L = Train.CAR_LENGTH;
    for (let i = 0; i < tr.carCount; i++) {
      const car = new THREE.Group();
      const body = this._mesh(GEO.box, this.mat('std', i === 0 ? color : COLORS.carGray), { cast: true });
      body.scale.set(L - 2, 9, 12);
      body.position.y = Y.railTop + 1.5 + 4.5;
      const roof = this._mesh(GEO.box, this.mat('std', '#3b3b40'), { cast: true });
      roof.scale.set(L - 3, 1.4, 10.5);
      roof.position.y = Y.railTop + 1.5 + 9.7;
      const chassis = this._mesh(GEO.box, this.mat('std', '#222222'));
      chassis.scale.set(L - 6, 1.6, 9);
      chassis.position.y = Y.railTop + 0.8;
      car.add(body, roof, chassis);
      if (i === 0) {
        const head = this._mesh(GEO.box, this.mat('basic', '#ffe94a'));
        head.scale.set(0.6, 2.2, 4);
        head.position.set(L / 2 - 0.8, Y.railTop + 4.5, 0);
        car.add(head);
      }
      if (i === tr.carCount - 1) {
        const tail = this._mesh(GEO.box, this.mat('basic', '#ff3030'));
        tail.scale.set(0.6, 2.2, 4);
        tail.position.set(-L / 2 + 0.8, Y.railTop + 4.5, 0);
        car.add(tail);
      }
      group.add(car);
      cars.push(car);
    }
    this.trainGroup.add(group);
    entry = { group, cars };
    this._trainMeshes.set(tr, entry);
    return entry;
  }

  _updateTrains() {
    const live = new Set(this.game.state === GameState.SIMULATING ? this.game.trains : []);
    for (const [tr, entry] of this._trainMeshes) {
      if (!live.has(tr)) {
        this.trainGroup.remove(entry.group);
        this._trainMeshes.delete(tr);
      }
    }
    const half = Train.CAR_LENGTH / 2;
    this.game.trains.forEach((tr, i) => {
      if (!live.has(tr)) return;
      const entry = this._trainMesh(tr, TRAIN_COLORS[i % TRAIN_COLORS.length]);
      const visible = tr.currentSegment() !== null;
      entry.group.visible = visible;
      if (!visible) return;
      for (let c = 0; c < tr.carCount; c++) {
        const xf = tr.pointBehind(c * (Train.CAR_LENGTH + Train.CAR_GAP) + half);
        entry.cars[c].position.set(xf.position.x, 0, xf.position.y);
        entry.cars[c].rotation.y = -xf.angle;
      }
    });
  }

  // --- Reservation overlay (V) ---

  _segId(seg) {
    let id = this._segIds.get(seg);
    if (id === undefined) {
      id = this._nextSegId++;
      this._segIds.set(seg, id);
    }
    return id;
  }

  _updateReservations() {
    const g = this.game;
    const show = g.state === GameState.SIMULATING && g.showReservations;
    const key = show ? g.trains.map((tr) => tr.reserved.map((s) => this._segId(s)).join(',')).join('|') : '';
    if (key === this._reservationKey) return;
    this._reservationKey = key;
    this._disposeGroup(this._reservationGroup);
    if (!show) return;
    g.trains.forEach((tr, i) => {
      const b = new StripBuilder();
      for (const seg of tr.reserved) b.ribbon(seg.getBakedPoints(), -6, 6, Y.railTop + 0.3);
      if (b.pos.length === 0) return;
      const mesh = this._mesh(b.build(), this.mat('basic', TRAIN_COLORS[i % TRAIN_COLORS.length], 0.45));
      mesh.renderOrder = 2;
      this._reservationGroup.add(mesh);
    });
  }

  // --- Per-frame overlay ---

  _overlayMesh(geometry, material, transient = true) {
    if (transient) this._overlayGeoms.push(geometry);
    const m = new THREE.Mesh(geometry, material);
    this.overlayGroup.add(m);
    return m;
  }

  _ring(p, radius, color, y = Y.overlay, thickness = 1) {
    const m = this._overlayMesh(GEO.ring, this.mat('basic', color), false);
    m.scale.set(radius, thickness, radius);
    m.position.set(p.x, y, p.y);
    return m;
  }

  _diamondOutline(p, r, color) {
    const m = this._overlayMesh(GEO.diamondRing, this.mat('basic', color), false);
    m.scale.set(r, r, r);
    m.position.set(p.x, Y.junction + 0.6, p.y);
  }

  _updateOverlay() {
    for (const geo of this._overlayGeoms) geo.dispose();
    this._overlayGeoms = [];
    this.overlayGroup.clear();
    const g = this.game;
    const ed = g.editor;

    if (g.state === GameState.SIMULATING) {
      for (const tr of g.deadlockedTrains) {
        const p = tr.currentPosition();
        if (p !== null) this._ring(p, 24, '#ff0000', 10, 6);
      }
    }

    if (g.state === GameState.EDITING) {
      if ((g.editingOrders || g.placingStation) && g.hoveredTown !== null) {
        this._ring(g.hoveredTown.position, g.hoveredTown.radius + 4, '#ffff00', Y.townDisc + 0.3, 12);
      }
      if (!g.editingOrders && !g.placingStation) {
        const hr = 13;
        const hj = g.hoveredJunction;
        if (hj !== null && g.network.nodes.includes(hj)) {
          if (ed.drawing && hj !== ed.startNode) this._diamondOutline(hj.position, hr, '#00ff00');
          else if (!ed.drawing) this._diamondOutline(hj.position, hr, '#ffffff');
        }
        if (ed.drawing && ed.startNode !== null) this._diamondOutline(ed.startNode.position, hr, '#ffffff');
      }
      if (g.editingOrders) this._orderPreview();
      else if (!g.placingStation && !g.placingSignal && ed.drawing && g.mousePos !== null) this._curvaturePreview();
    }
  }

  // The track being drawn, coloured by curvature (green OK, red too tight),
  // plus its waypoints.
  _curvaturePreview() {
    const g = this.game;
    const ed = g.editor;
    for (const wp of ed.waypoints) {
      const m = this._overlayMesh(GEO.sphere, this.mat('basic', '#ffffff'), false);
      m.scale.setScalar(5);
      m.position.set(wp.x, Y.overlay, wp.y);
    }
    const preview = ed.buildPreviewSegment(g.mousePos);
    const points = preview.getBakedPoints();
    if (points.length < 3) {
      const b = new StripBuilder();
      for (const piece of dashPieces(points, 8)) b.ribbon(piece, -1, 1, Y.overlay);
      if (b.pos.length > 0) this._overlayMesh(b.build(), this.mat('basic', '#ffffff', 0.5));
      return;
    }
    const total = preview.length();
    if (total <= 0) return;
    const step = Math.max(total / 20, 2);
    const ok = new StripBuilder();
    const bad = new StripBuilder();
    let offset = 0;
    for (let i = 0; i < points.length - 1; i++) {
      if (i > 0) offset += points[i].distanceTo(points[i - 1]);
      const p0 = preview.curve.sampleBaked(Math.max(offset - step, 0));
      const p2 = preview.curve.sampleBaked(Math.min(offset + step, total));
      const r = circumradius(p0, points[i], p2);
      (r >= TrackEditor.MIN_CURVE_RADIUS ? ok : bad).ribbon([points[i], points[i + 1]], -2, 2, Y.overlay);
    }
    if (ok.pos.length > 0) this._overlayMesh(ok.build(), this.mat('basic', '#4dff4d', 0.8));
    if (bad.pos.length > 0) this._overlayMesh(bad.build(), this.mat('basic', '#ff3333', 0.8));
  }

  // Dashed order loops for every roster train (selected one brighter).
  _orderPreview() {
    const g = this.game;
    g.roster.forEach((plan, ti) => {
      const orders = plan.orders;
      if (orders.length < 2) return;
      const b = new StripBuilder();
      for (let i = 0; i < orders.length; i++) {
        const from = orders[i].position;
        const to = orders[(i + 1) % orders.length].position;
        for (const piece of dashPieces([from, to], 10)) b.ribbon(piece, -1.5, 1.5, Y.overlay + ti * 0.05);
      }
      const alpha = ti === g.selectedTrain ? 0.75 : 0.3;
      this._overlayMesh(b.build(), this.mat('basic', TRAIN_COLORS[ti % TRAIN_COLORS.length], alpha));
    });
  }

  // --- Labels (2D canvas over the scene) ---

  // Screen position (CSS px) of a game-space point at height y, or null when
  // behind the camera.
  _project(p, y = 0) {
    const v = new THREE.Vector3(p.x, y, p.y).project(this.camera);
    if (v.z > 1) return null;
    return { x: (v.x + 1) / 2 * this.container.clientWidth, y: (1 - v.y) / 2 * this.container.clientHeight };
  }

  _text(text, x, y, color, size = 14, align = 'left') {
    const ctx = this.ctx;
    ctx.font = `600 ${size}px system-ui, -apple-system, "Segoe UI", sans-serif`;
    ctx.textAlign = align;
    ctx.textBaseline = 'middle';
    ctx.lineWidth = 3;
    // Round joins: miter joins spike off sharp glyphs like "W".
    ctx.lineJoin = 'round';
    ctx.strokeStyle = 'rgba(0, 0, 0, 0.55)';
    ctx.strokeText(text, x, y);
    ctx.fillStyle = color;
    ctx.fillText(text, x, y);
  }

  // A rounded badge whose left end sits where a single-number circle would:
  // 24 px tall, widening to fit lists like "2 · 4".
  _badge(text, x, y, color, ring) {
    const ctx = this.ctx;
    ctx.font = '600 14px system-ui, -apple-system, "Segoe UI", sans-serif';
    const w = Math.max(24, ctx.measureText(text).width + 14);
    const left = x - 12;
    const pill = (pad) => {
      ctx.beginPath();
      ctx.roundRect(left - pad, y - 12 - pad, w + pad * 2, 24 + pad * 2, 12 + pad);
    };
    pill(0);
    ctx.fillStyle = color;
    ctx.fill();
    if (ring) {
      pill(1.5);
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#ffffff';
      ctx.stroke();
    }
    this._text(text, left + w / 2, y + 1, '#ffffff', 14, 'center');
  }

  _drawLabels() {
    const ctx = this.ctx;
    const g = this.game;
    ctx.clearRect(0, 0, this.container.clientWidth, this.container.clientHeight);

    for (const town of g.towns) {
      if (town.name === '') continue;
      const s = this._project(town.position.add(new Vec2(0, town.radius)), 0);
      if (s !== null) this._text(town.name, s.x, s.y + 12, '#ffffff', 13, 'center');
    }

    if (g.state === GameState.SIMULATING) {
      for (const town of g.towns) {
        const s = this._project(town.position.add(new Vec2(0, -town.radius)), 0);
        if (s === null) continue;
        this._text(`Waiting: ${Math.trunc(town.waiting)}`, s.x, s.y - 12, town.station !== null ? '#ffffff' : '#ff4040', 14, 'center');
      }
      for (const tr of g.trains) {
        const head = tr.currentPosition();
        if (head === null) continue;
        const s = this._project(head, 22);
        if (s === null) continue;
        this._text(`${tr.passengersOnBoard}/${tr.capacity}`, s.x, s.y - 10, '#ffffff', 13, 'center');
        if (tr.dwellRemaining > 0) this._text('Boarding...', s.x, s.y + 30, '#ffffff', 13, 'center');
        else if (tr.waitingForTrack) this._text('Waiting for path...', s.x, s.y + 30, '#ff4040', 13, 'center');
      }
      return;
    }

    // Order badges: one per station per train, listing every visit's stop
    // number (a station may be visited several times in a loop), one row
    // per roster train in its colour; the selected train's get a white ring.
    g.roster.forEach((plan, ti) => {
      const visits = new Map();
      plan.orders.forEach((stop, i) => {
        if (!visits.has(stop)) visits.set(stop, []);
        visits.get(stop).push(i + 1);
      });
      for (const [stop, numbers] of visits) {
        const anchor = stop.position.add(new Vec2(stop.radius, -stop.radius).mul(0.75));
        const s = this._project(anchor, 0);
        if (s !== null) this._badge(numbers.join(' · '), s.x, s.y + ti * 28, TRAIN_COLORS[ti % TRAIN_COLORS.length], ti === g.selectedTrain);
      }
    });

    const ed = g.editor;
    if (ed.drawing && !g.editingOrders && !g.placingStation && !g.placingSignal && g.mousePos !== null) {
      this._turnoutAngleLabel();
      this._finishAngleLabel();
    }
  }

  // Divergence at the start node, when it already has track.
  _turnoutAngleLabel() {
    const g = this.game;
    const ed = g.editor;
    const existing = g.network.departureAnglesAt(ed.startNode);
    if (existing.length === 0) return;
    const preview = ed.buildPreviewSegment(g.mousePos);
    if (preview.length() <= 0) return;
    const diff = TrackEditor.minDivergence(existing, preview.angleAt(0));
    const s = this._project(ed.startNode.position, Y.junction);
    if (s === null) return;
    this._text(`${Math.trunc(radToDeg(diff))}°`, s.x + 15, s.y - 15, diff <= TrackEditor.MAX_TURNOUT_ANGLE ? '#00ff00' : '#ff3030');
  }

  // Divergence at the junction or track point the click would connect to.
  _finishAngleLabel() {
    const g = this.game;
    const ed = g.editor;
    let target;
    let existing = [];
    const hj = g.hoveredJunction;
    if (hj !== null && hj !== ed.startNode && g.network.nodes.includes(hj)) {
      existing = g.network.departureAnglesAt(hj);
      target = hj.position;
    } else {
      const hit = ed.findTrackAt(g.mousePos);
      if (hit.length === 0) return;
      const [seg, t] = hit;
      if (seg.nodeStart === ed.startNode || seg.nodeEnd === ed.startNode) return;
      existing = [seg.angleAt(t)];
      target = seg.positionAt(t);
    }
    if (existing.length === 0) return;
    const preview = ed.buildPreviewSegment(target);
    if (preview.length() <= 0) return;
    const diff = TrackEditor.minDivergence(existing, preview.angleAt(1) + Math.PI);
    const s = this._project(target, Y.junction);
    if (s === null) return;
    this._text(`${Math.trunc(radToDeg(diff))}°`, s.x + 15, s.y + 25, diff <= TrackEditor.MAX_TURNOUT_ANGLE ? '#00ff00' : '#ff3030');
  }

  // --- Frame ---

  render() {
    const g = this.game;
    if (g.worldVersion !== this._worldVersion) {
      this._worldVersion = g.worldVersion;
      this._rebuildStatic();
    }
    for (const { seg, material } of this._signalLamps) {
      material.color.set(g.signalIsGreen(seg) ? COLORS.green : COLORS.red);
    }
    const tint = g.state === GameState.SIMULATING && g.showReservations;
    for (const { crossing, material } of this._crossingMarkers) {
      const holder = tint ? g.crossingHolder(crossing) : null;
      const idx = holder !== null ? g.trains.indexOf(holder) : -1;
      material.color.set(idx >= 0 ? TRAIN_COLORS[idx % TRAIN_COLORS.length] : COLORS.crossing);
    }
    this._updateTrains();
    this._updateReservations();
    this._updateOverlay();
    this.renderer.render(this.scene, this.camera);
    this._drawLabels();
  }
}
