## A deep copy of the editable world state (towns, network, train roster),
## used as an entry on the undo stack. Capture before a build action; restore
## swaps the cloned objects in as the live state. Money, game state, and the
## running trains are deliberately not snapshotted — undo is an editing-mode
## tool.
class_name GameSnapshot
extends RefCounted

## Cloned towns (stations/platforms rewired onto the cloned network).
var towns: Array[Town] = []
## Cloned track network.
var network: TrackNetwork
## Cloned per-train plans (orders point into the cloned towns).
var roster: Array[TrainPlan] = []
## Index of the roster train that was selected for editing.
var selected_train := 0
## Orders of the selected plan — mirrors main.train_orders.
var train_orders: Array[Town]:
	get: return roster[selected_train].orders
## Palette index for the next town placed.
var next_color_index := 0

## Deep-copy the editable state of the main game node. Old→new identity maps
## keep the clone internally consistent: reverse twins, adjacency, and
## platform/station weakref wiring all point at cloned objects.
static func capture(main) -> GameSnapshot:
	var snap := GameSnapshot.new()
	var node_map := {}
	var segment_map := {}

	# Nodes first, so segments can be built with their mapped endpoints.
	for node in main.network.nodes:
		node_map[node] = NetworkNode.junction(node.position)

	# Bare segment clones. The curve is duplicated directly — a segment does
	# not retain its waypoint list, so the curve is the source of truth.
	for seg in main.network.segments:
		var clone := TrackSegment.from_curve(
			node_map[seg.node_start], node_map[seg.node_end], seg.curve)
		clone.copy_signal_from(seg)
		segment_map[seg] = clone
	for seg in main.network.segments:
		if seg.reverse != null and segment_map.has(seg.reverse):
			segment_map[seg].reverse = segment_map[seg.reverse]

	# Rebuild the network: add_segment restores the adjacency list; add_node
	# covers junctions with no segments (e.g. a free-draw start node).
	# Crossing detection is off — the geometry is unchanged, so the known set
	# is cloned below instead of being re-derived at O(n²) per build action.
	snap.network = TrackNetwork.new()
	for seg in main.network.segments:
		snap.network.add_segment(segment_map[seg], false)
	for node in main.network.nodes:
		snap.network.add_node(node_map[node])

	# Crossings, rewired onto the cloned segments — the same mapping the
	# reverse twins get above.
	for crossing in main.network.crossings:
		var track_a: TrackSegment = crossing.track_a
		var track_b: TrackSegment = crossing.track_b
		if track_a == null or track_b == null:
			continue
		if not segment_map.has(track_a) or not segment_map.has(track_b):
			continue
		snap.network.register_crossing(segment_map[track_a], segment_map[track_b],
			crossing.position, crossing.angle)

	# Towns, with stations/platforms rewired onto the cloned segments.
	var town_map := {}
	for town in main.towns:
		var town_clone := Town.new(town.position, town.color)
		town_clone.radius = town.radius
		town_clone.waiting = town.waiting
		if town.station != null:
			var station_clone := Station.new(town_clone)
			for platform in town.station.platforms:
				var rev_clone: TrackSegment = null
				if platform.reverse_segment != null:
					rev_clone = segment_map[platform.reverse_segment]
				var platform_clone: Platform = Platform.new(
					segment_map[platform.segment], rev_clone, platform.side)
				platform_clone.width = platform.width
				platform_clone.station = station_clone
				platform_clone.segment.platform = platform_clone
				if platform_clone.reverse_segment != null:
					platform_clone.reverse_segment.platform = platform_clone
				station_clone.platforms.append(platform_clone)
			town_clone.station = station_clone
		town_map[town] = town_clone
		snap.towns.append(town_clone)

	for plan in main.roster:
		var plan_clone := TrainPlan.new()
		plan_clone.car_count = plan.car_count
		for town in plan.orders:
			plan_clone.orders.append(town_map[town])
		snap.roster.append(plan_clone)
	snap.selected_train = main.selected_train
	snap.next_color_index = main.next_color_index
	return snap

## Swap this snapshot's objects in as the live state. The snapshot's objects
## simply become the world — an undo stack entry is popped when restored, so
## it is never restored twice and needs no re-cloning.
func restore(main) -> void:
	main.towns = towns
	main.network = network
	main.roster = roster
	main.selected_train = selected_train
	main.next_color_index = next_color_index
	main.editor.network = network
	# Hover references point into the discarded world; the next mouse motion
	# re-derives them.
	main.hovered_town = null
	main.hovered_junction = null
	main.queue_redraw()
