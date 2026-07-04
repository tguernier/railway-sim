## A deep copy of the editable world state (towns, network, train orders),
## used as an entry on the undo stack. Capture before a build action; restore
## swaps the cloned objects in as the live state. Money, game state, and the
## train are deliberately not snapshotted — undo is an editing-mode tool.
class_name GameSnapshot
extends RefCounted

## Cloned towns (stations/platforms rewired onto the cloned network).
var towns: Array[Town] = []
## Cloned track network.
var network: TrackNetwork
## Train orders, as references into the cloned towns.
var train_orders: Array[Town] = []
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
		var clone: TrackSegment = TrackSegment.new(node_map[seg.node_start], node_map[seg.node_end])
		clone.curve = seg.curve.duplicate()
		segment_map[seg] = clone
	for seg in main.network.segments:
		if seg.reverse != null and segment_map.has(seg.reverse):
			segment_map[seg].reverse = segment_map[seg.reverse]

	# Rebuild the network: add_segment restores the adjacency list; add_node
	# covers junctions with no segments (e.g. a free-draw start node).
	snap.network = TrackNetwork.new()
	for seg in main.network.segments:
		snap.network.add_segment(segment_map[seg])
	for node in main.network.nodes:
		snap.network.add_node(node_map[node])

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

	for town in main.train_orders:
		snap.train_orders.append(town_map[town])
	snap.next_color_index = main.next_color_index
	return snap

## Swap this snapshot's objects in as the live state. The snapshot's objects
## simply become the world — an undo stack entry is popped when restored, so
## it is never restored twice and needs no re-cloning.
func restore(main) -> void:
	main.towns = towns
	main.network = network
	main.train_orders = train_orders
	main.next_color_index = next_color_index
	main.editor.network = network
	# Hover references point into the discarded world; the next mouse motion
	# re-derives them.
	main.hovered_town = null
	main.hovered_junction = null
	main.queue_redraw()
