// A flat crossing (diamond) where two physical tracks cross without
// connecting. It adds no connectivity to the graph — a train cannot turn here
// — only mutual exclusion: the diamond belongs to both tracks, so only one
// train may hold it. Enforcement lives in Train.blockingTrain.
export class TrackCrossing {
  constructor() {
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
