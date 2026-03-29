## A town on the map that generates and holds waiting passengers.
class_name Town
extends RefCounted

## World position of the town.
var position: Vector2
## Display colour of the town.
var color: Color
## Number of passengers currently waiting at this town.
var waiting: float = 0.0
## The network node representing this town in the track graph.
var node: NetworkNode

## Initialize a town with a position and color.
func _init(pos: Vector2, col: Color) -> void:
	position = pos
	color = col
	node = NetworkNode.from_town(self)

## Generate passengers at the town.
func generate_passengers() -> void:
	waiting += randf() * 0.5

## Pickup passengers from the town.
func pickup_passengers(capacity: int) -> int:
	var count := int(waiting) if int(waiting) <= capacity else capacity
	waiting -= count
	return count
