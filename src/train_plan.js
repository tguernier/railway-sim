// An edit-mode plan for one train: the stops it will loop through and how
// many cars it has. Turned into a live Train when the simulation starts.
export class TrainPlan {
  constructor() {
    // Ordered list of town stops the train will visit in a loop.
    this.orders = [];
    // Number of cars in the consist.
    this.carCount = 2;
  }
}
