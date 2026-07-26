## Graph of track segments connecting network nodes. Supports pathfinding via Dijkstra.
class_name TrackNetwork
extends RefCounted

## Cost added to a segment unavailable to the routing train. Larger than any
## plausible route length, so one blocked segment always outweighs any free
## detour, while two equally-blocked routes still compare by real length
## beneath the penalty.
const BLOCKED_PENALTY := 10000.0

## Cost added for entering a segment against a *loose* one-way signal. Well
## below BLOCKED_PENALTY on purpose: running the wrong way past a loose signal
## is safe (reservations still keep trains apart), so a train takes the barred
## direction rather than queue behind occupied track. Players who want the
## harder guarantee reach for the strict variant instead. Still large enough to
## dominate any plausible detour, so a legal way round always wins.
const ONE_WAY_PENALTY := 2000.0

## How a one-way signal facing the other way affects entry into a directed
## segment. See one_way_against.
enum OneWay {
	NONE,    ## no one-way signal against this direction
	LOOSE,   ## passable from behind, but the pathfinder avoids it
	STRICT,  ## routing in this direction is barred outright
}

## Maximum heading change through a junction (end of the arriving segment vs
## start of the departing one). Junctions are turnouts: genuine continuations
## diverge by at most the turnout angle, while going back the way you came is
## a ~180° flip, so a right angle separates the two cleanly. Anything past it
## is a switchback — impossible for a train without stopping and reversing.
const MAX_THROUGH_ANGLE := PI / 2.0

## All track segments in the network.
var segments: Array[TrackSegment] = []
## All junction nodes in the network.
var nodes: Array[NetworkNode] = []
## Every flat crossing in the network. The same objects are registered on the
## segments involved, which is where exclusion reads them; this list exists so
## crossings can be drawn and cloned without walking every segment.
var crossings: Array[TrackCrossing] = []
## Adjacency list mapping each node to its outgoing segments.
var _outgoing: Dictionary = {}

## Add a network node.
func add_node(node: NetworkNode) -> void:
	if not nodes.has(node):
		nodes.append(node)

## Add a track segment to the network (also registers its endpoint nodes).
## Crossings against existing track are detected here — every structural edit
## funnels through this call, so the crossing set cannot drift out of step
## with the geometry. GameSnapshot opts out: it clones a network whose
## crossings are already known, and re-detecting per segment would make undo
## capture quadratic.
func add_segment(segment: TrackSegment, detect_crossings := true) -> void:
	segments.append(segment)
	add_node(segment.node_start)
	add_node(segment.node_end)
	if not _outgoing.has(segment.node_start):
		_outgoing[segment.node_start] = []
	_outgoing[segment.node_start].append(segment)
	if detect_crossings:
		_detect_crossings(segment)

## Remove a track segment from the network, along with any crossings on its
## physical track.
func remove_segment(segment: TrackSegment) -> void:
	segments.erase(segment)
	if _outgoing.has(segment.node_start):
		_outgoing[segment.node_start].erase(segment)
	_purge_crossings(segment)

## Get outgoing track segments from a node.
func get_outgoing(node: NetworkNode) -> Array:
	if _outgoing.has(node):
		return _outgoing[node]
	return []

## Get incoming track segments to a node.
func get_incoming(node: NetworkNode) -> Array:
	var result: Array = []
	for seg in segments:
		if seg.node_end == node:
			result.append(seg)
	return result

# --- Flat crossings ---

## Whether two segments meet at a shared endpoint. Such a pair joins at a
## junction rather than crossing, so it is exempt from crossing detection —
## the alternative is a crossover arm registering a spurious diamond against
## the very track it lands on. The cost is that a segment which both meets and
## genuinely crosses another (a loop swinging back over the line it left) has
## its crossing missed; the editor's MIN_LOOP_OFFSET rule already discourages
## that shape.
static func shares_node(a: TrackSegment, b: TrackSegment) -> bool:
	return a.node_start == b.node_start or a.node_start == b.node_end \
		or a.node_end == b.node_start or a.node_end == b.node_end

## Find and register every crossing a newly added segment makes. Skipped when
## its reverse twin is already in the network: the twin's scan covered this
## physical track and registered the results on all four directed segments, so
## rescanning would only duplicate them.
func _detect_crossings(segment: TrackSegment) -> void:
	var twin := segment.reverse
	if twin != null and twin != segment and segments.has(twin):
		return
	var seen: Dictionary = {}
	for other in segments:
		if other == segment or other == twin or seen.has(other):
			continue
		seen[other] = true
		if other.reverse != null:
			seen[other.reverse] = true
		if shares_node(segment, other):
			continue
		for point in TrackSegment.crossing_points(segment, other):
			register_crossing(segment, other, point)

## Record a crossing between two tracks, on the network and on all four
## directed segments involved. `known_angle` skips the tangent lookup when the
## caller already has it (cloning a snapshot of identical geometry).
func register_crossing(a: TrackSegment, b: TrackSegment, point: Vector2,
		known_angle := -1.0) -> TrackCrossing:
	var crossing := TrackCrossing.new()
	crossing.position = point
	crossing.angle = known_angle if known_angle >= 0.0 \
		else TrackSegment.crossing_angle(a, b, point)
	crossing.track_a = a
	crossing.track_b = b
	crossings.append(crossing)
	for seg in [a, a.reverse, b, b.reverse]:
		if seg != null and not seg.crossings.has(crossing):
			seg.crossings.append(crossing)
	return crossing

## Drop every crossing on a removed segment's physical track, from the network
## list and from the far track's segments. Idempotent: deletion paths remove
## both twins, so this runs twice per physical track.
func _purge_crossings(segment: TrackSegment) -> void:
	for crossing in segment.crossings.duplicate():
		crossings.erase(crossing)
		var other: TrackSegment = crossing.other_track(segment)
		if other != null:
			other.crossings.erase(crossing)
			if other.reverse != null:
				other.reverse.crossings.erase(crossing)
	segment.crossings.clear()
	var twin := segment.reverse
	if twin != null and twin != segment:
		twin.crossings.clear()

## Remove a node if it has no connections. Returns true if removed.
func cleanup_orphan(node: NetworkNode) -> bool:
	if get_outgoing(node).size() == 0 and get_incoming(node).size() == 0:
		nodes.erase(node)
		_outgoing.erase(node)
		return true
	return false

## How the one-way signal at a directed segment's start (if any) treats entry
## in that direction. The segment's twin arriving at that junction is what
## carries the signal; it is only one-way if no other arriving segment (the
## through continuation) carries one too, which would make it two-way.
##
## STRICT is OpenTTD's one-way path signal: a hard "no entry" that makes
## passing-loop branches directional. LOOSE is its plain path signal: the
## direction stays passable from behind, only penalized, so a bidirectional
## single line can carry a one-way signal purely for its *waiting point* —
## trains going the signalled way may stand at it, trains coming the other way
## have no stopping place there and must reserve straight through. That is
## what keeps a branch train back on its branch instead of stranding it across
## the junction it just crossed.
func one_way_against(seg: TrackSegment) -> OneWay:
	var twin := seg.reverse
	if twin == null or not twin.exit_signal:
		return OneWay.NONE
	for arriving in get_incoming(seg.node_start):
		if arriving != twin and arriving.exit_signal:
			return OneWay.NONE  # a signal serves this direction too — two-way
	return OneWay.LOOSE if twin.loose_one_way else OneWay.STRICT

## Whether a train arriving on prev can roll onto next without reversing:
## the reverse twin never continues, and the departure heading must stay
## within MAX_THROUGH_ANGLE of the arrival heading. A null prev means no
## established heading, so anything goes.
func can_continue(prev: TrackSegment, next: TrackSegment) -> bool:
	if prev == null:
		return true
	if next == prev.reverse:
		return false
	return absf(angle_difference(prev.angle_at(1.0), next.angle_at(0.0))) <= MAX_THROUGH_ANGLE

## Whether next is a legal move for a route currently arriving on prev.
## first marks the route's first hop: with allow_reversal (a train standing
## at a station stop may change direction) the first hop may also be prev's
## own reverse twin — the train leaves the way it came in. Other backward
## branches stay barred even then: a stopped train reverses along its own
## track, it does not bend through a switchback.
func _hop_allowed(prev: TrackSegment, next: TrackSegment, first: bool, allow_reversal: bool) -> bool:
	if can_continue(prev, next):
		return true
	return first and allow_reversal and prev != null and next == prev.reverse

## Get all departure angles (radians) of outgoing segments at a node.
func departure_angles_at(node: NetworkNode) -> Array[float]:
	var angles: Array[float] = []
	for seg in get_outgoing(node):
		angles.append(seg.angle_at(0.0))
	return angles

## Find the shortest route from a node to a station platform. The route always
## ends with a traversal of the platform segment (entering at whichever end
## gives the shorter path), so the train passes alongside the platform and
## finishes at its far end. With for_train given, both candidate entry ends
## are costed with reservation penalties, so the entry-end choice is
## traffic-aware too. `arriving`/`allow_reversal` seed the departure heading
## (see find_route): dispatch passes the platform segment the train stands on
## with allow_reversal, so it either continues forward or turns around in
## place — never bends backward through the junction at the platform's end.
func find_route_to_platform(from: NetworkNode, platform: Platform, for_train: Train = null,
		arriving: TrackSegment = null, allow_reversal := false) -> Array:
	var entry := platform.segment.node_start
	var exit := platform.segment.node_end
	if from == entry and _hop_allowed(arriving, platform.segment, true, allow_reversal):
		return [platform.segment]
	if from == exit and _hop_allowed(arriving, platform.reverse_segment, true, allow_reversal):
		return [platform.reverse_segment]
	var route_a := find_route(from, entry, for_train, arriving, platform.segment, allow_reversal)
	var route_b := find_route(from, exit, for_train, arriving, platform.reverse_segment, allow_reversal)
	var len_a := route_cost(route_a, for_train) if route_a.size() > 0 else INF
	var len_b := route_cost(route_b, for_train) if route_b.size() > 0 else INF
	if is_inf(len_a) and is_inf(len_b):
		return []
	if len_a <= len_b:
		route_a.append(platform.segment)
		return route_a
	route_b.append(platform.reverse_segment)
	return route_b

## Check that a loop of station platforms is fully connected, mirroring how
## dispatch routes the train: start at the far end of the first platform,
## route to each subsequent platform in turn, and finish back at the first.
## Returns the index of the first platform that cannot be reached from the
## stop before it, or -1 if the whole loop is routable. Safe to call whenever
## the network changes (e.g. before starting the simulation, or to revalidate
## orders after the track is edited mid-simulation).
##
## platforms: Array[Platform]
func first_unroutable_stop(platforms: Array) -> int:
	if platforms.size() == 0:
		return -1
	var arriving: TrackSegment = platforms[0].segment
	for i in range(1, platforms.size() + 1):
		var idx := i % platforms.size()
		var route := find_route_to_platform(arriving.node_end, platforms[idx], null, arriving, true)
		if route.size() == 0:
			return idx
		arriving = route[-1]
	return -1

## Cost of a route for a train: total length, plus BLOCKED_PENALTY for each
## segment unavailable to it and ONE_WAY_PENALTY for each entered against a
## loose one-way signal (mirrors find_route's relaxation — the lookahead
## compares the two, so they must agree). Also what a train's per-extension
## lookahead uses to weigh its provisional tail against the re-pathed
## alternative.
func route_cost(route: Array, for_train: Train) -> float:
	var total := 0.0
	for seg in route:
		total += seg.length()
		if for_train != null and for_train.is_blocked(seg):
			total += BLOCKED_PENALTY
		if one_way_against(seg) == OneWay.LOOSE:
			total += ONE_WAY_PENALTY
	return total

## Find the shortest route between two nodes using Dijkstra (weighted by
## segment length). Directions barred by a one-way signal are never taken.
## With for_train given, segments unavailable to that train (held by another
## train, directly or via the reverse twin) cost BLOCKED_PENALTY extra —
## traffic is a preference to route around, never a reason to fail.
##
## The search is direction-aware: its state is the directed segment a path
## arrives on (not the node), and every junction transition must satisfy
## can_continue — trains never switchback mid-route. `arriving` seeds the
## heading at `from` (the segment the train stands on or the route so far
## arrives by); with allow_reversal the first hop may be arriving's reverse
## twin (a stopped train departing back the way it came). With exit_seg the
## goal only counts when the path can continue onto it — used to guarantee
## the platform traversal appended by find_route_to_platform is takeable.
func find_route(from: NetworkNode, to: NetworkNode, for_train: Train = null,
		arriving: TrackSegment = null, exit_seg: TrackSegment = null,
		allow_reversal := false) -> Array:
	if from == to and exit_seg == null:
		return []

	# Each entry: [cost, node, path]; the arriving segment is path[-1], or
	# `arriving` while the path is still empty.
	var queue: Array = [[0.0, from, []]]
	var visited: Dictionary = {}

	while queue.size() > 0:
		# Find the lowest-cost entry
		var best_idx := 0
		for i in range(1, queue.size()):
			if queue[i][0] < queue[best_idx][0]:
				best_idx = i
		var current: Array = queue[best_idx]
		queue.remove_at(best_idx)

		var cost: float = current[0]
		var node: NetworkNode = current[1]
		var path: Array = current[2]
		var prev: TrackSegment = path[-1] if path.size() > 0 else arriving

		# Visited is keyed by the arriving segment: with the no-switchback
		# rule, reachability onward depends on the heading a node is reached
		# with, so each directed segment (not each node) is a search state.
		# The start state (empty path) is unique and needs no mark.
		if path.size() > 0:
			if visited.has(prev):
				continue
			visited[prev] = true

		# Check at dequeue time — this is the shortest path to this state
		if node == to and (exit_seg == null or can_continue(prev, exit_seg)):
			return path

		for seg in get_outgoing(node):
			var against := one_way_against(seg)
			if against == OneWay.STRICT:
				continue  # a strict one-way signal bars entry in this direction
			if not _hop_allowed(prev, seg, path.size() == 0, allow_reversal):
				continue  # reversing through a junction is not a move
			if visited.has(seg):
				continue
			var new_path: Array = path.duplicate()
			new_path.append(seg)
			var new_cost: float = cost + seg.length()
			if for_train != null and for_train.is_blocked(seg):
				new_cost += BLOCKED_PENALTY
			if against == OneWay.LOOSE:
				new_cost += ONE_WAY_PENALTY
			queue.append([new_cost, seg.node_end, new_path])

	return []
