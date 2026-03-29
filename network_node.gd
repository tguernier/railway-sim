## A node in the track network — either a town or a junction.
class_name NetworkNode
extends RefCounted

## The kind of network node.
enum NodeType { TOWN, JUNCTION }

## What kind of node this is.
var type: NodeType
## World position of this node.
var position: Vector2
## The town at this node, if type == TOWN.
var town: Town

## Create a town node.
static func from_town(t: Town) -> NetworkNode:
	var node := NetworkNode.new()
	node.type = NodeType.TOWN
	node.position = t.position
	node.town = t
	return node

## Create a junction node at a position.
static func junction(pos: Vector2) -> NetworkNode:
	var node := NetworkNode.new()
	node.type = NodeType.JUNCTION
	node.position = pos
	return node

## Whether this node is a town.
func is_town() -> bool:
	return type == NodeType.TOWN

## Whether this node is a junction.
func is_junction() -> bool:
	return type == NodeType.JUNCTION
