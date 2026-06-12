## A node in the track network — a junction where track segments meet.
class_name NetworkNode
extends RefCounted

## World position of this node.
var position: Vector2

## Create a junction node at a position.
static func junction(pos: Vector2) -> NetworkNode:
	var node := NetworkNode.new()
	node.position = pos
	return node
