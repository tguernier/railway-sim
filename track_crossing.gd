## A flat crossing (diamond) where two physical tracks cross without
## connecting. It adds no connectivity to the graph — a train cannot turn here
## — only mutual exclusion: the diamond belongs to both tracks, so only one
## train may hold it. Enforcement lives in Train.blocking_train.
##
## The two tracks are held weakly. Each of the four directed segments involved
## holds this crossing strongly, so pointing back weakly keeps the pair free
## of RefCounted cycles.
class_name TrackCrossing
extends RefCounted

## Where the two tracks cross, for drawing.
var position: Vector2
## Undirected angle between the tracks at the crossing, 0..PI/2.
var angle: float

var _a_ref: WeakRef = null
## One of the two crossing tracks, as its forward directed segment.
var track_a: TrackSegment:
	get: return _a_ref.get_ref() as TrackSegment if _a_ref != null else null
	set(s): _a_ref = weakref(s) if s != null else null

var _b_ref: WeakRef = null
## The other crossing track, as its forward directed segment.
var track_b: TrackSegment:
	get: return _b_ref.get_ref() as TrackSegment if _b_ref != null else null
	set(s): _b_ref = weakref(s) if s != null else null

## The far side's forward segment, given a segment on either track (in either
## direction). Null when `seg` belongs to neither track, or the far side has
## already been freed.
func other_track(seg: TrackSegment) -> TrackSegment:
	var a := track_a
	var b := track_b
	if a != null and (seg == a or seg == a.reverse):
		return b
	if b != null and (seg == b or seg == b.reverse):
		return a
	return null
