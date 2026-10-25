// A railway station linking a town to the track network via platforms.
export class Station {
  constructor(town) {
    // The town this station serves (the town owns its station).
    this.town = town;
    // Platforms at this station.
    this.platforms = [];
  }
}
