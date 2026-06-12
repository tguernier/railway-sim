## A railway station linking a town to the track network via platforms.
class_name Station
extends RefCounted

## The town this station serves. Stored as a weak reference to avoid cycles
## (the town owns its station).
var _town_ref: WeakRef = null
var town: Town:
	get: return _town_ref.get_ref() as Town if _town_ref != null else null
	set(t): _town_ref = weakref(t) if t != null else null

## Platforms at this station.
var platforms: Array[Platform] = []

## Initialize a station serving a town.
func _init(served_town: Town) -> void:
	town = served_town
