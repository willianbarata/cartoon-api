extends RefCounted
const G = preload("res://scripts/geometry.gd")
const Props = preload("res://scripts/prop_factory.gd")
const LAYOUT_DIR := "res://assets/environments/layouts/"
const ASSET_DIR := "res://assets/environments/"

static func create(config: Dictionary) -> Node3D:
	var kind: String = config.get("type", "forest")
	if kind != "forest":
		return create_layout(kind)
	var root := Node3D.new()
	root.name = "Environment"
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.get("seed", 12345))
	var grass = G.material("#83BE77")
	var wood = G.material("#A16C4B")
	var leaves = [G.material("#39886B"), G.material("#53A678"), G.material("#A3C877")]
	G.cylinder(root, "Meadow", Vector3(0, -0.27, 0), 9, 0.5, grass, -1, 64)
	G.sphere(root, "Path", Vector3(-0.4, -0.016, 0.65), Vector3(5.8, 0.06, 1.5), G.material("#D4CD96"))
	for i in range(int(config.get("treeCount", 12))):
		var x = rng.randf_range(-5.8, 5.8)
		var z = rng.randf_range(-5.8, -2.1)
		if i < 2:
			x = -3.4 if i == 0 else 3.5
			z = 0.2
		var tree = G.pivot(root, "tree_%03d" % (i + 1), Vector3(x, 0, z))
		var height = rng.randf_range(1.8, 3.1)
		G.cylinder(tree, "Trunk", Vector3(0, height * 0.34, 0), 0.14, height * 0.7, wood, 0.10)
		G.sphere(tree, "Crown", Vector3(0, height * 0.8, 0), Vector3(1.55, 1.8, 1.4), leaves[i % 3], 8)
		G.sphere(tree, "CrownSide", Vector3(0.4, height * 0.7, 0.18), Vector3(0.95, 1.1, 1.0), leaves[(i + 1) % 3], 8)
	for i in range(9):
		var p = Vector3(rng.randf_range(-4.8, 4.8), 0.09, rng.randf_range(-3.3, -1.4))
		G.sphere(root, "Rock%d" % i, p, Vector3(0.35, 0.24, 0.3), G.material("#97AAA2"), 8)
	flower(root, "flower_001", Vector3(0.9, 0, 0.35), 1.0)
	for i in range(int(config.get("flowerCount", 8)) - 1):
		flower(root, "flower_%03d" % (i + 2), Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-3, -1.2)), 0.5)
	G.pivot(root, "path_start", Vector3(-1.25, 0, 0.3))
	G.pivot(root, "path_end", Vector3(0.25, 0, 0.35))
	G.pivot(root, "interaction_001", Vector3(0.9, 0.6, 0.35))
	return root

static func flower(parent: Node3D, label: String, pos: Vector3, size: float) -> void:
	var n = G.pivot(parent, label, pos)
	n.scale = Vector3.ONE * size
	G.cylinder(n, "Stem", Vector3(0, 0.28, 0), 0.025, 0.56, G.material("#3B895C"))
	var leaf = G.sphere(n, "Leaf", Vector3(-0.11, 0.25, 0), Vector3(0.27, 0.07, 0.12), G.material("#54AB62"), 12)
	leaf.rotation.z = -0.45
	for i in range(7):
		var angle = TAU * i / 7.0
		G.sphere(n, "Petal%d" % i, Vector3(cos(angle) * 0.14, 0.58 + sin(angle) * 0.14, 0.015), Vector3(0.20, 0.20, 0.08), G.material("#F69AAA"), 16)
	G.sphere(n, "Pollen", Vector3(0, 0.58, 0.065), Vector3(0.17, 0.17, 0.10), G.material("#FFD16B"), 16)


# Cenário montado a partir de assets/environments/layouts/<tipo>.json (peças CC0 KayKit/Gobkit/props).
# Âncoras viram nós com o nome do ponto; as que têm assento guardam seat/seatYaw em metadados.
static func create_layout(kind: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Environment"
	var layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_DIR + kind + ".json"))
	if not layout is Dictionary:
		push_error("Layout de cenário inválido: " + kind)
		return root
	var floor_cfg: Dictionary = layout.floor
	var floor_size: Array = floor_cfg.size
	var floor_center: Array = floor_cfg.center
	G.box(root, "Floor", Vector3(floor_center[0], -0.05, floor_center[1]), Vector3(floor_size[0], 0.1, floor_size[1]), G.material(floor_cfg.color))
	for b in layout.get("boxes", []):
		G.box(root, b.name, Vector3(b.pos[0], b.pos[1], b.pos[2]), Vector3(b.size[0], b.size[1], b.size[2]), G.material(b.color))
	var index := 0
	for item in layout.get("items", []):
		index += 1
		var node: Node3D = _load_item(String(item.model), "Item%02d" % index)
		if node == null:
			continue
		node.position = Vector3(item.pos[0], item.pos[1], item.pos[2])
		node.rotation_degrees.y = float(item.get("rotY", 0))
		node.scale *= float(item.get("scale", 1.0))
		root.add_child(node)
	for anchor_name in layout.get("anchors", {}):
		var a: Dictionary = layout.anchors[anchor_name]
		var marker = G.pivot(root, anchor_name, Vector3(a.pos[0], a.pos[1], a.pos[2]))
		if a.has("seat"):
			marker.set_meta("seat", Vector3(a.seat[0], a.seat[1], a.seat[2]))
			marker.set_meta("seat_yaw", deg_to_rad(float(a.get("seatYaw", 0))))
	return root

static func _load_item(model: String, node_name: String) -> Node3D:
	if model.begins_with("props:"):
		return Props.create(model.trim_prefix("props:"), node_name)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(ASSET_DIR + model), state)
	if err != OK:
		push_error("Peça de cenário não carregou: %s (%s)" % [model, err])
		return null
	var node: Node3D = doc.generate_scene(state)
	node.name = node_name
	return node
