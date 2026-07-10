## An edit-mode plan for one train: the stops it will loop through and how
## many cars it has. Turned into a live Train when the simulation starts.
class_name TrainPlan
extends RefCounted

## Ordered list of town stops the train will visit in a loop.
var orders: Array[Town] = []
## Number of cars in the consist.
var car_count: int = 2
