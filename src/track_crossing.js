// Kinds of mutual exclusion between two tracks.
export const CrossingKind = Object.freeze({
  // A flat crossing (diamond): the tracks cross in space. Detected
  // geometrically, drawn as a lozenge.
  DIAMOND: 'diamond',
  // A fouling pair: the two taper pieces where a double-track section's
  // tracks converge on a junction run so close that trains on both would
  // overlap. Registered by TrackEditor.createDoubleTrack, never drawn.
  FOUL: 'foul',
});

// Two physical tracks that must never be held by different trains at once:
// a flat crossing (diamond) where they cross without connecting, or a
// double-track taper pair (see CrossingKind). It adds no connectivity to the
// graph — a train cannot turn here — only mutual exclusion. Enforcement
// lives in Train.blockingTrain.
export class TrackCrossing {
  constructor(kind = CrossingKind.DIAMOND) {
    // Which kind of exclusion this is (CrossingKind).
    this.kind = kind;
    // Where the two tracks cross, for drawing (Vec2).
    this.position = null;
    // Undirected angle between the tracks at the crossing, 0..PI/2.
    this.angle = 0;
    // The two crossing tracks, each as its forward directed segment.
    this.trackA = null;
    this.trackB = null;
  }

  // The far side's forward segment, given a segment on either track (in
  // either direction). Null when `seg` belongs to neither track.
  otherTrack(seg) {
    const a = this.trackA;
    const b = this.trackB;
    if (a !== null && (seg === a || seg === a.reverse)) return b;
    if (b !== null && (seg === b || seg === b.reverse)) return a;
    return null;
  }
}
