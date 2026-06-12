## A town on the map that generates and holds waiting passengers.
## Towns are not part of the track graph — building a Station is what
## links a town to the railway.
class_name Town
extends RefCounted

## World position of the town.
var position: Vector2
## Display colour of the town.
var color: Color
## Number of passengers currently waiting at this town.
var waiting: float = 0.0
## The station serving this town, if one has been built.
var station: Station = null
## Catchment radius of the town circle.
var radius: float = 60.0

## Initialize a town with a position and color.
func _init(pos: Vector2, col: Color) -> void:
	position = pos
	color = col

## Generate passengers at the town.
func generate_passengers() -> void:
	waiting += randf() * 0.5

## Pickup passengers from the town.
func pickup_passengers(capacity: int) -> int:
	var count := int(waiting) if int(waiting) <= capacity else capacity
	waiting -= count
	return count
