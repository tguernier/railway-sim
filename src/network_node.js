// A node in the track network — a junction where track segments meet.
export class NetworkNode {
  constructor(position) {
    // World position of this node (Vec2).
    this.position = position;
  }

  // Create a junction node at a position.
  static junction(pos) {
    return new NetworkNode(pos);
  }
}
