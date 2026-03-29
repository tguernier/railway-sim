class_name TestNetworkNode
extends TestBase

func run_all() -> void:
	print("[TestNetworkNode]")
	_t("from_town_creates_town_node", _test_from_town)
	_t("junction_creates_junction_node", _test_junction)
	_t("is_town_and_is_junction", _test_type_checks)
	_t("town_creates_node_automatically", _test_town_auto_node)

func _test_from_town() -> void:
	var t := Town.new(Vector2(10, 20), Color.RED)
	var node := NetworkNode.from_town(t)
	eq(node.type, NetworkNode.NodeType.TOWN)
	eq(node.position, Vector2(10, 20))
	eq(node.town, t)

func _test_junction() -> void:
	var node := NetworkNode.junction(Vector2(50, 60))
	eq(node.type, NetworkNode.NodeType.JUNCTION)
	eq(node.position, Vector2(50, 60))
	eq(node.town, null)

func _test_type_checks() -> void:
	var town_node := NetworkNode.from_town(Town.new(Vector2.ZERO, Color.WHITE))
	var junc_node := NetworkNode.junction(Vector2.ZERO)
	is_true(town_node.is_town())
	is_false(town_node.is_junction())
	is_false(junc_node.is_town())
	is_true(junc_node.is_junction())

func _test_town_auto_node() -> void:
	var t := Town.new(Vector2(30, 40), Color.BLUE)
	is_true(t.node != null)
	eq(t.node.type, NetworkNode.NodeType.TOWN)
	eq(t.node.town, t)
	eq(t.node.position, Vector2(30, 40))
