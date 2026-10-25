// A platform alongside a track segment where trains stop to board passengers.
// Entry and exit nodes are the platform segment's nodeStart / nodeEnd.
export class Platform {
  constructor(segment, reverseSegment, side) {
    // The track segment this platform spans (forward direction).
    this.segment = segment;
    // The reverse-direction segment.
    this.reverseSegment = reverseSegment;
    // Which side of the track the platform is drawn on (1 or -1).
    this.side = side;
    // Perpendicular offset from track center in pixels.
    this.width = 20.0;
    // Back-reference to the owning station.
    this.station = null;
  }
}
