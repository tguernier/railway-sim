# railway-sim
(this document is strictly human edited)

This is a railway company simulator game with a minimalist vector graphics aesthetic. It simulates a passenger transport network.

You can play the latest version of the game in the web browser at: https://tguernier.github.io/railway-sim/

To run the game locally:
```bash
python3 -m http.server 8000
```

## Features (so far)
- Track building with realistic curves / junctions
- Stations
- Multiple trains with per-train orders
- Passenger generation (basic)
- Track segment occupancy detection / track reservations with crossover detection
- Path based signalling with two-way / strict one way / loose one way signals
- Double track
