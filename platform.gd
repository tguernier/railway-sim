## A platform alongside a track segment where trains stop to board passengers.
## Entry and exit nodes are the platform segment's node_start / node_end.
class_name Platform
extends RefCounted

## The track segment this platform spans (forward direction).
var segment: TrackSegment
## The reverse-direction segment.
var reverse_segment: TrackSegment
## Which side of the track the platform is drawn on (1.0 or -1.0).
var side: float = 1.0
## Perpendicular offset from track center in pixels.
var width: float = 20.0

## Back-reference to the owning station. Stored as a weak reference to avoid
## cycles (the station owns its platforms).
var _station_ref: WeakRef = null
var station: Station:
	get: return _station_ref.get_ref() as Station if _station_ref != null else null
	set(s): _station_ref = weakref(s) if s != null else null

## Initialize a platform spanning a forward/reverse segment pair.
func _init(seg: TrackSegment, rev: TrackSegment, platform_side: float) -> void:
	segment = seg
	reverse_segment = rev
	side = platform_side
