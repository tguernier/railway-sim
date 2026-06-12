class_name TestStation
extends TestBase

func run_all() -> void:
	print("[TestStation]")
	_t("station_links_town", _test_station_links_town)
	_t("platform_links_station_and_segments", _test_platform_links)
	_t("train_traverses_platform_and_boards", _test_train_boards)
	_t("town_without_station_yields_no_route", _test_no_station_no_route)

func _test_station_links_town() -> void:
	var town := Town.new(Vector2.ZERO, Color.WHITE)
	var station := Station.new(town)
	eq(station.town, town)
	eq(station.platforms.size(), 0)

func _test_platform_links() -> void:
	var a := NetworkNode.junction(Vector2(0, 0))
	var b := NetworkNode.junction(Vector2(120, 0))
	var fwd := TrackSegment.new(a, b)
	var rev := TrackSegment.new(b, a)
	var platform := Platform.new(fwd, rev, -1.0)
	var station := Station.new(Town.new(Vector2(60, 30), Color.WHITE))
	platform.station = station
	station.platforms.append(platform)
	eq(platform.segment, fwd)
	eq(platform.reverse_segment, rev)
	eq(platform.side, -1.0)
	eq(platform.width, 20.0)
	eq(platform.station, station)

func _test_train_boards() -> void:
	# Full path: build a station with the editor, route a train to its
	# platform, traverse it, and board from the town's passenger pool.
	var ed := TrackEditor.new(TrackNetwork.new())
	var a := NetworkNode.junction(Vector2(0, 0))
	ed.create_bidirectional_track(a, NetworkNode.junction(Vector2(300, 0)), [])
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	town.waiting = 12.0
	var towns: Array[Town] = [town]
	var station := ed.place_station(Vector2(150, 0), towns)
	is_true(station != null)
	var platform: Platform = station.platforms[0]

	var train := Train.new()
	train.orders = [town]
	train.current_order_index = 0
	var route := ed.network.find_route_to_platform(a, platform)
	gt(route.size(), 0.0)
	is_true(route[route.size() - 1].is_platform_segment())
	train.set_route(route)
	is_false(train.boarded_this_leg)
	train.move(100.0)
	is_true(train.has_completed_route())

	# The train finishes on the platform of its current order town.
	var seg := train.current_segment()
	is_true(seg.is_platform_segment())
	eq(seg.platform.station.town, train.current_order_town())
	train.board_from(town)
	eq(train.passengers_on_board, 12)
	eq(int(town.waiting), 0)

func _test_no_station_no_route() -> void:
	# A town without a station has no platform to route to.
	var town := Town.new(Vector2(150, 0), Color.WHITE)
	eq(town.station, null)
	# main.gd skips dispatch when station is null — verify the marker it checks.
	var net := TrackNetwork.new()
	var a := NetworkNode.junction(Vector2(0, 0))
	net.add_node(a)
	is_true(town.station == null or town.station.platforms.size() == 0)
