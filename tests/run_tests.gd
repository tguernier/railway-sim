## Headless test runner. Execute with:
##   godot --path /path/to/railway-sim --headless --script res://tests/run_tests.gd
extends SceneTree

func _initialize() -> void:
	var suites: Array = [
		TestNetworkNode.new(),
		TestTown.new(),
		TestTrackSegment.new(),
		TestTrackNetwork.new(),
		TestTrackEditor.new(),
		TestStation.new(),
		TestTrain.new(),
		TestMultiTrain.new(),
		TestGameSnapshot.new(),
		TestUndo.new(),
		TestMainInput.new(),
	]

	var total_pass := 0
	var total_fail := 0

	for suite in suites:
		suite.run_all()
		total_pass += suite._pass
		total_fail += suite._fail

	print("")
	if total_fail == 0:
		print("OK  %d tests passed." % total_pass)
	else:
		printerr("FAIL  %d passed, %d failed." % [total_pass, total_fail])

	quit(1 if total_fail > 0 else 0)
