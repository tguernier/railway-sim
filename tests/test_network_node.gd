class_name TestNetworkNode
extends TestBase

func run_all() -> void:
	print("[TestNetworkNode]")
	_t("junction_creates_node_at_position", _test_junction)
	_t("nodes_have_no_town_reference", _test_no_town_reference)

func _test_junction() -> void:
	var node := NetworkNode.junction(Vector2(50, 60))
	eq(node.position, Vector2(50, 60))

func _test_no_town_reference() -> void:
	var node := NetworkNode.junction(Vector2.ZERO)
	is_false("town" in node)
	is_false("type" in node)
