extends RefCounted
# Cria um personagem do elenco fixo a partir do GLB convertido (tools/blender/convert_gobkit.py).
# Estrutura igual à do robô para o story_player: raiz com AnimationController e EmotionController.
const Animator = preload("res://scripts/kid_animator.gd")
const Face = preload("res://scripts/kid_face.gd")
const ASSET_DIR := "res://assets/characters/"

static func create(config: Dictionary) -> Node3D:
	var model: String = config.model
	var meta = JSON.parse_string(FileAccess.get_file_as_string(ASSET_DIR + model + ".json"))
	var root := Node3D.new()
	root.name = config.id
	root.set_meta("character", config)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(ASSET_DIR + model + ".glb"), state)
	if err != OK or not meta is Dictionary:
		push_error("Modelo do elenco não carregou: %s (%s)" % [model, err])
		return root
	# generate_scene precisa do mesmo GLTFDocument que leu o arquivo (outro gera esqueleto vazio).
	var visual: Node3D = doc.generate_scene(state)
	visual.name = "Model"
	visual.scale = Vector3.ONE * float(meta.scale)
	for m in visual.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m
		if mi.mesh:
			for s in mi.mesh.get_surface_count():
				var mat = mi.mesh.surface_get_material(s)
				if mat is BaseMaterial3D:
					mat.metallic = 0.0
					mat.roughness = maxf(mat.roughness, 0.8)
					if mat.albedo_texture != null:
						mat.albedo_color = Color.WHITE
					elif mi.mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR:
						# Malhas pintadas por cor de vértice (projeção das folhas); acessórios lisos (laço) mantêm a cor.
						mat.albedo_color = Color.WHITE
						mat.vertex_color_use_as_albedo = true
	root.add_child(visual)
	var height := float(meta.height)
	# Altura dos olhos ~78% em personagens cabeçudos; usada pela câmera em close-up.
	root.set_meta("focus_height", height * 0.78)
	root.set_meta("height", height)
	var animator = Animator.new()
	animator.name = "AnimationController"
	root.add_child(animator)
	animator.setup(visual, height, float(meta.get("armRestDown", 0.0)))
	var face = Face.new()
	face.name = "EmotionController"
	root.add_child(face)
	face.setup(visual, config.id)
	return root
