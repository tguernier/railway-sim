// A town on the map that generates and holds waiting passengers.
// Towns are not part of the track graph — building a Station is what
// links a town to the railway.
export class Town {
  constructor(position, color, name = '') {
    // World position of the town (Vec2).
    this.position = position;
    // Display colour of the town (CSS hex string).
    this.color = color;
    // Display name, shown on the map and in the orders panel.
    this.name = name;
    // Number of passengers currently waiting at this town.
    this.waiting = 0.0;
    // The station serving this town, if one has been built.
    this.station = null;
    // Catchment radius of the town circle.
    this.radius = 60.0;
  }

  // Generate passengers at the town.
  generatePassengers() {
    this.waiting += Math.random() * 0.5;
  }

  // Pickup passengers from the town.
  pickupPassengers(capacity) {
    const whole = Math.trunc(this.waiting);
    const count = whole <= capacity ? whole : capacity;
    this.waiting -= count;
    return count;
  }
}
