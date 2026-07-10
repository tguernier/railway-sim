## A node in the track network — a junction where track segments meet.
class_name NetworkNode
extends RefCounted

## Signal variants (OpenTTD-style path signals). TWO_WAY bounds reservation
## spans in both travel directions. PATH and ONE_WAY are directional — they
## bound spans only for trains moving along signal_facing. From the opposite
## side a PATH signal is passed freely (it is simply not a waiting point),
## while a ONE_WAY signal cannot be passed at all: routing treats crossing it
## against its facing as forbidden.
enum SignalKind { NONE, TWO_WAY, PATH, ONE_WAY }

## World position of this node.
var position: Vector2
## The signal placed on this node (NONE for a plain junction). A signal node
## is a pure block boundary between two segment pairs (degree exactly 2),
## never a connection point for new tracks.
var signal_kind := SignalKind.NONE
## Unit travel direction a directional signal governs (the way it "faces").
## Also stored on TWO_WAY signals so cycling to a directional kind starts
## facing along the track the signal was placed on.
var signal_facing := Vector2.ZERO
## Whether this node is a player-placed signal of any kind.
var is_signal: bool:
	get: return signal_kind != SignalKind.NONE
	set(value): signal_kind = SignalKind.TWO_WAY if value else SignalKind.NONE

## Create a junction node at a position.
static func junction(pos: Vector2) -> NetworkNode:
	var node := NetworkNode.new()
	node.position = pos
	return node

## Whether the signal is a waiting point for travel in direction dir (only
## the sign of the dot product with the facing matters).
func signal_governs(dir: Vector2) -> bool:
	match signal_kind:
		SignalKind.NONE:
			return false
		SignalKind.TWO_WAY:
			return true
		_:
			return signal_facing.dot(dir) > 0.0

## Whether travel in direction dir through this node is forbidden — true only
## against the facing of a ONE_WAY signal.
func blocks_travel(dir: Vector2) -> bool:
	return signal_kind == SignalKind.ONE_WAY and signal_facing.dot(dir) < 0.0
