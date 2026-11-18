extends Node3D
const Characters = preload("res://scripts/character_factory.gd")
const Environments = preload("res://scripts/environment_factory.gd")
const Cameras = preload("res://scripts/camera_director.gd")
const Props = preload("res://scripts/prop_factory.gd")

var story: Dictionary
var actors: Dictionary = {}
var environment: Node3D
var camera: Camera3D
var frame := 0
var scene_index := -1
var fps := 24
var recording := false
var checkpoints: Array = []

func _ready() -> void:
	var path := "res://../../examples/robot-flower/story.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--story="):
			path = arg.trim_prefix("--story=")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.has("scenes"):
		push_error("Invalid story JSON: " + path)
		get_tree().quit(2)
		return
	story = parsed
	fps = int(story.video.fps)
	recording = OS.has_feature("movie") or "--write-movie" in OS.get_cmdline_args()
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#A6D1D6")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#F8ECDC")
	env.ambient_light_energy = 0.40
	# Linear mantém as cores vivas; a luz total foi reduzida para não estourar calçada/pele (ACES lavava as paredes).
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -28, 0)
	sun.light_color = Color("#FFF0CF")
	sun.light_energy = 0.72
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 35, 0)
	fill.light_color = Color("#FFFFFF")
	fill.light_energy = 0.10
	fill.shadow_enabled = false
	add_child(fill)
	camera = Camera3D.new()
	camera.current = true
	add_child(camera)
	build_captions()
	build_scene(0)
	evaluate(0.0)
	print("STORY_READY ", story.title, " frames=", int(story.duration * fps))

# Legendas na tela (renderizadas no próprio vídeo): narração no topo, falas embaixo com o nome.
var caption_top: Label
var caption_bottom: Label

func _caption_label(anchor_top: bool) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var h := float(story.video.height)
	label.add_theme_font_size_override("font_size", int(h * (0.045 if anchor_top else 0.037)))
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color("#111111"))
	label.add_theme_constant_override("outline_size", int(h * 0.012))
	label.anchor_left = 0.06
	label.anchor_right = 0.94
	label.anchor_top = 0.07 if anchor_top else 0.74
	label.anchor_bottom = 0.25 if anchor_top else 0.90
	return label

func build_captions() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	caption_top = _caption_label(true)
	caption_bottom = _caption_label(false)
	layer.add_child(caption_top)
	layer.add_child(caption_bottom)

func speaker_name(id: String) -> String:
	for c in story.characters:
		if c.id == id:
			return c.name
	return id

func update_captions(scene: Dictionary, local_time: float) -> Dictionary:
	var narration := []
	var speech := []
	var speaking := {}
	for d in scene.get("dialogues", []):
		if local_time < float(d.time) or local_time > float(d.time) + float(d.duration):
			continue
		if d.has("speaker"):
			speaking[d.speaker] = true
			var line = "%s: %s" % [speaker_name(d.speaker), d.text]
			if not speech.has(d.text) and not speech.has(line):
				# Falas iguais ao mesmo tempo (ex.: "Surpresa!" em coro) aparecem uma vez só, sem nome.
				var same = scene.dialogues.filter(func(o): return o.has("speaker") and o.text == d.text and absf(float(o.time) - float(d.time)) < 0.3).size()
				speech.append(d.text if same > 1 else line)
		elif not narration.has(d.text):
			narration.append(d.text)
	caption_top.text = "
".join(narration)
	caption_bottom.text = "
".join(speech)
	return speaking

func build_scene(index: int) -> void:
	if environment:
		environment.free()
	for actor in actors.values():
		actor.free()
	actors.clear()
	scene_index = index
	var scene: Dictionary = story.scenes[index]
	environment = Environments.create(scene.environment)
	add_child(environment)
	scene_props.clear()
	for p in scene.get("props", []):
		var prop: Node3D = Props.create(p.model, p.id)
		prop.position = Vector3(p.position[0], p.position[1], p.position[2])
		prop.rotation_degrees.y = float(p.get("rotation", 0))
		prop.set_meta("clip", p.get("animation", "idle"))
		environment.add_child(prop)
		scene_props.append(prop)
	for id in scene.characters:
		for config in story.characters:
			if config.id == id:
				var actor = Characters.create(config)
				add_child(actor)
				actors[id] = actor

var scene_props: Array = []
const BLEND_SECONDS := 0.3
const MOVE_ACTIONS := ["walk_to", "walk", "run"]
const FACE_TARGET_ACTIONS := ["hug", "point"]
# Posições determinísticas dos atores no instante avaliado (fim do último deslocamento iniciado).
var anchors: Dictionary = {}

func target_position(id: String) -> Vector3:
	if anchors.has(id):
		return anchors[id]
	if actors.has(id):
		return actors[id].position
	var node = environment.find_child(id, true, false)
	return node.global_position if node else Vector3.ZERO

# Planeja o estado do ator só a partir do roteiro e do tempo (sem ler poses de outros atores).
# `allow_actor_targets` = false na primeira passada: abraço ainda não desloca.
func plan_actor(scene: Dictionary, id: String, local_time: float, allow_actor_targets: bool) -> Dictionary:
	var initial: Array = scene.get("placements", {}).get(id, [-1.25, 0, 0.3])
	var position = Vector3(initial[0], initial[1], initial[2])
	var plan := {"selected": {"action": "idle", "time": 0, "duration": scene.duration}, "from": position, "to": position,
		"from_yaw": 0.0, "emotion": "neutral", "emotion_time": 0.0, "previous": null}
	var yaw := 0.0
	for event in scene.events:
		if event.actor != id or float(event.time) > local_time:
			continue
		if event.has("emotion"):
			plan.emotion = event.emotion
			plan.emotion_time = float(event.time)
		if not event.has("action"):
			continue
		plan.previous = {"selected": plan.selected, "from": plan.from, "to": plan.to, "from_yaw": plan.from_yaw}
		plan.selected = event
		plan.from_yaw = yaw
		plan.from = position
		plan.to = position
		if event.action in MOVE_ACTIONS:
			var destination = target_position(event.get("target", "path_end"))
			destination.y = 0
			var flat = Vector3(position.x, 0, position.z)
			var direction = (destination - flat).normalized()
			plan.to = destination - direction * 0.65
			plan.to.y = 0
			position = plan.to
			yaw = atan2(direction.x, direction.z)
		elif event.action == "hug" and allow_actor_targets:
			var destination = target_position(event.target)
			var offset = destination - position
			offset.y = 0
			if offset.length() > 0.62:
				plan.to = destination - offset.normalized() * 0.62
				plan.to.y = position.y
				position = plan.to
			yaw = atan2(offset.x, offset.z)
		elif event.action in ["stand", "jump", "celebrate", "surprised", "dance"] and position.y > 0.05:
			# Levanta do móvel: desce para o chão à frente do assento.
			plan.to = position + Vector3(sin(yaw), 0, cos(yaw)) * 0.55
			plan.to.y = 0
			position = plan.to
		elif event.action == "sit" and event.has("target") and seat_of(event.target) != null:
			var seat: Dictionary = seat_of(event.target)
			plan.to = seat.position
			position = plan.to
			yaw = seat.yaw
		elif event.action in FACE_TARGET_ACTIONS:
			var offset = target_position(event.target) - position
			yaw = atan2(offset.x, offset.z)
		elif event.action in ["turn_left", "turn_right"]:
			yaw += PI / 2 * (1 if event.action == "turn_left" else -1)
		elif event.action in ["celebrate", "surprised"]:
			yaw = 0
	plan.position = position
	plan.yaw = yaw
	return plan

# Objetos com "moves": posição/rumo calculados só pelo tempo; anima "walk" (ou o pedido) durante o trajeto.
func update_props(scene: Dictionary, local_time: float) -> void:
	var configs := {}
	for p in scene.get("props", []):
		configs[p.id] = p
	for prop in scene_props:
		var cfg: Dictionary = configs.get(String(prop.name), {})
		var pos := Vector3(cfg.position[0], cfg.position[1], cfg.position[2])
		var yaw := deg_to_rad(float(cfg.get("rotation", 0)))
		var clip: String = cfg.get("animation", "idle")
		var speed := 1.0
		for m in cfg.get("moves", []):
			var start := float(m.time)
			if local_time < start:
				break
			var dest := Vector3(m.to[0], m.to[1], m.to[2])
			var u := clampf((local_time - start) / maxf(float(m.duration), 0.001), 0, 1)
			var flat := Vector3(dest.x - pos.x, 0, dest.z - pos.z)
			if flat.length() > 0.01 and cfg.get("faceMove", true):
				yaw = atan2(flat.x, flat.z)
			if u < 1.0:
				pos = pos.lerp(dest, u)
				clip = m.get("animation", "walk")
				speed = float(m.get("speed", 1.5))
				break
			pos = dest
		prop.position = pos
		prop.rotation.y = yaw
		Props.animate(prop, clip, local_time * speed)

func seat_of(id: String):
	var node = environment.find_child(id, true, false) if environment else null
	if node and node.has_meta("seat"):
		return {"position": node.get_meta("seat"), "yaw": float(node.get_meta("seat_yaw"))}
	return null

func evaluate(time: float) -> void:
	var index := 0
	var offset := 0.0
	while index < story.scenes.size() - 1 and time >= offset + float(story.scenes[index].duration):
		offset += float(story.scenes[index].duration)
		index += 1
	if index != scene_index:
		build_scene(index)
	var scene: Dictionary = story.scenes[index]
	var local_time = time - offset
	var speaking := update_captions(scene, local_time)
	update_props(scene, local_time)
	anchors.clear()
	var first_pass := {}
	for id in actors:
		first_pass[id] = plan_actor(scene, id, local_time, false).position
	anchors = first_pass
	for id in actors:
		var actor = actors[id]
		var plan := plan_actor(scene, id, local_time, true)
		var selected: Dictionary = plan.selected
		var animator = actor.get_node("AnimationController")
		actor.set_meta("target_yaw", plan.yaw)
		var since: float = local_time - float(selected.time)
		var previous = plan.previous
		if previous != null and since < BLEND_SECONDS and animator.has_method("capture") 				and previous.selected.action != selected.action:
			var before: Dictionary = previous.selected
			animator.evaluate(before.action, local_time - float(before.time), float(before.get("duration", 1)), local_time,
				previous.from, previous.to, target_position(before.get("target", "flower_001")), previous.from_yaw)
			var snapshot = animator.capture()
			animator.evaluate(selected.action, since, float(selected.get("duration", 1)), local_time, plan.from, plan.to,
				target_position(selected.get("target", "flower_001")), plan.from_yaw)
			animator.blend_from(snapshot, smoothstep(0.0, BLEND_SECONDS, since))
		else:
			animator.evaluate(selected.action, since, float(selected.get("duration", 1)), local_time, plan.from, plan.to,
				target_position(selected.get("target", "flower_001")), plan.from_yaw)
		if speaking.has(id):
			actor.set_meta("talking", true)
		actor.get_node("EmotionController").evaluate(plan.emotion, smoothstep(0, 0.35, local_time - plan.emotion_time), local_time)
	Cameras.evaluate(camera, scene.camera, actors[scene.camera.target], local_time, actors.values())
	Cameras.apply_motion(camera, scene.camera, local_time, float(scene.duration))

func _process(delta: float) -> void:
	if story.is_empty():
		return
	# Movie Maker advances exactly one frame per call. Frame zero was set in _ready.
	var time = float(frame) / fps if recording else fmod(Time.get_ticks_msec() / 1000.0, float(story.duration))
	evaluate(time)
	if recording and frame % fps == 0:
		var actor = actors.values()[0]
		print("CHECKPOINT ", frame, " ", actor.position, " state=", actor.get_node("AnimationController").state)
	frame += 1
