extends RefCounted

static func evaluate(camera: Camera3D, config: Dictionary, actor: Node3D, time: float, group: Array = []) -> void:
	var preset = config.get("preset", "fixed")
	if preset == "group" and not group.is_empty():
		_frame_group(camera, config, group)
		return
	var focus = Vector3(-0.1, 0.85, 0)
	var position = Vector3(1.4, float(config.get("height", 3.3)), float(config.get("distance", 8.0)))
	if preset in ["follow", "tracking"]:
		focus = actor.position + Vector3(0, 0.9, 0)
		position += actor.position
	elif preset == "close_up":
		focus = actor.position + Vector3(0, float(actor.get_meta("focus_height", 1.35)), 0)
		position = focus + Vector3(0.6, 0.3, 2.7)
	elif preset == "orbit":
		position = Vector3(sin(time * 0.15) * 6, 3.0, cos(time * 0.15) * 6)
	camera.position = position
	camera.fov = float(config.get("fov", 40))
	camera.look_at(focus, Vector3.UP)
	camera.set_meta("focus_distance", position.distance_to(focus))


# Enquadra todos os atores: centro do grupo e distância para caber na largura do quadro (vertical
# ou horizontal), nunca mais perto que `distance`. Usa só posições já determinísticas dos atores.
static func _frame_group(camera: Camera3D, config: Dictionary, group: Array) -> void:
	var lo := Vector3(INF, 0, INF)
	var hi := Vector3(-INF, 0, -INF)
	var top := 1.4
	for a in group:
		lo.x = minf(lo.x, a.position.x)
		hi.x = maxf(hi.x, a.position.x)
		lo.z = minf(lo.z, a.position.z)
		hi.z = maxf(hi.z, a.position.z)
		top = maxf(top, float(a.get_meta("height", 1.4)) + a.position.y)
	var center := Vector3((lo.x + hi.x) * 0.5, 0, (lo.z + hi.z) * 0.5)
	var fov := float(config.get("fov", 40))
	var size := camera.get_viewport().get_visible_rect().size if camera.is_inside_tree() else Vector2(540, 960)
	var aspect := size.x / maxf(size.y, 1.0)
	var half_h := deg_to_rad(fov) * 0.5
	var half_w := atan(tan(half_h) * aspect)
	var needed := ((hi.x - lo.x) * 0.5 + 0.5) / tan(half_w) + (hi.z - center.z)
	var distance := maxf(float(config.get("distance", 6.0)), needed)
	var height := float(config.get("height", 2.2))
	var focus := center + Vector3(0, top * 0.55, 0)
	camera.position = Vector3(center.x, height, center.z + distance)
	camera.fov = fov
	camera.look_at(focus, Vector3.UP)
	camera.set_meta("focus_distance", camera.position.distance_to(focus))


# Movimento de câmera sobre qualquer preset (tempo absoluto, determinístico):
# push = aproximação lenta (fração da distância ao foco ao longo da cena),
# handheld = balanço de câmera na mão, shake = tremidas de impacto [{time, duration, strength}].
static func apply_motion(camera: Camera3D, config: Dictionary, time: float, duration: float) -> void:
	var push := float(config.get("push", 0.0))
	if push > 0.0:
		var u := smoothstep(0.0, 1.0, clampf(time / maxf(duration, 0.001), 0, 1))
		# Proporcional à distância do foco: em close não atravessa o personagem (máx. ~36% com push 0.8).
		var dist := float(camera.get_meta("focus_distance", 3.0))
		camera.position += -camera.global_transform.basis.z * push * dist * 0.45 * u
	var hand := float(config.get("handheld", 0.0))
	if hand > 0.0:
		camera.rotate_object_local(Vector3.RIGHT, (sin(time * 1.3) * 0.010 + sin(time * 3.1) * 0.004) * hand)
		camera.rotate_object_local(Vector3.UP, (sin(time * 0.9 + 1.0) * 0.012 + sin(time * 2.3) * 0.004) * hand)
		camera.position.y += sin(time * 1.7) * 0.03 * hand
	for s in config.get("shake", []):
		var p := (time - float(s.time)) / maxf(float(s.duration), 0.001)
		if p < 0.0 or p > 1.0:
			continue
		var a := float(s.get("strength", 1.0)) * (1.0 - p) * (1.0 - p)
		camera.rotate_object_local(Vector3.RIGHT, sin(time * 47.0) * 0.03 * a)
		camera.rotate_object_local(Vector3.FORWARD, sin(time * 53.0 + 1.0) * 0.025 * a)
		camera.position += Vector3(sin(time * 41.0), sin(time * 59.0), 0) * 0.05 * a
