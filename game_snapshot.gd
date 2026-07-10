## A deep copy of the editable world state (towns, network, trains, money),
## used as an entry on the undo stack. Capture before a build action; restore
## swaps the cloned objects in as the live state. Money and trains are
## snapshotted because purchases and consist resizes happen in edit mode; the
## undo stack is cleared at simulation start so earned money is never rewound.
class_name GameSnapshot
extends RefCounted

## Cloned towns (stations/platforms rewired onto the cloned network).
var towns: Array[Town] = []
## Cloned track network.
var network: TrackNetwork
## Cloned trains (orders and home platforms rewired onto the clones).
var trains: Array[Train] = []
## Index of the selected train.
var selected_train := 0
## Player money at capture time.
var money := 0.0
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
		var node_clone := NetworkNode.junction(node.position)
		node_clone.signal_kind = node.signal_kind
		node_clone.signal_facing = node.signal_facing
		node_map[node] = node_clone

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
	var platform_map := {}
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
				platform_map[platform] = platform_clone
			town_clone.station = station_clone
		town_map[town] = town_clone
		snap.towns.append(town_clone)

	# Trains carry no runtime state in edit mode — car count, home platform,
	# and orders describe them fully.
	for train in main.trains:
		var train_clone := Train.new()
		train_clone.car_count = train.car_count
		if train.home_platform != null and platform_map.has(train.home_platform):
			train_clone.home_platform = platform_map[train.home_platform]
		for town in train.orders:
			train_clone.orders.append(town_map[town])
		snap.trains.append(train_clone)

	snap.selected_train = main.selected_train
	snap.money = main.money
	snap.next_color_index = main.next_color_index
	return snap

## Swap this snapshot's objects in as the live state. The snapshot's objects
## simply become the world — an undo stack entry is popped when restored, so
## it is never restored twice and needs no re-cloning.
func restore(main) -> void:
	main.towns = towns
	main.network = network
	main.trains = trains
	main.network.trains = trains
	main.selected_train = clampi(selected_train, 0, maxi(trains.size() - 1, 0))
	main.money = money
	main.next_color_index = next_color_index
	main.editor.network = network
	# Hover references point into the discarded world; the next mouse motion
	# re-derives them.
	main.hovered_town = null
	main.hovered_junction = null
	main.queue_redraw()
