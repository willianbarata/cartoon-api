extends Node
# Anima um personagem do elenco: clipes do GLB (Idle/Walk/Run) amostrados por tempo absoluto
# + ajustes procedurais de ossos para ações sem clipe (acenar, sentar, triste, comemorar...).
# Mesmo contrato do animation_controller.gd do robô.
enum State { IDLE, MOVING, ACTING, REACTING }
var state: State = State.IDLE

var player: AnimationPlayer
var skel: Skeleton3D
var bones := {}
var up := Vector3.UP
var left := Vector3.RIGHT
var forward := Vector3.BACK
var units_per_meter := 1.0
var height := 1.3
# Modelos gerados por IA vêm com braços em "A": os clipes do Gobkit pressupõem "T".
var arm_rest_down := 0.0

func setup(model: Node3D, character_height: float, rest_down: float = 0.0) -> void:
	height = character_height
	arm_rest_down = rest_down
	var players = model.find_children("*", "AnimationPlayer", true, false)
	var skeletons = model.find_children("*", "Skeleton3D", true, false)
	if players.is_empty() or skeletons.is_empty():
		push_error("Personagem sem AnimationPlayer/Skeleton3D")
		return
	player = players[0]
	# Sem avanço automático: a pose vem só de seek() com o tempo do roteiro.
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	skel = skeletons[0]
	for i in skel.get_bone_count():
		bones[skel.get_bone_name(i)] = i
	# Eixos no espaço do esqueleto, deduzidos da pose de repouso (o GLB não é Y-up internamente).
	var rest = func(name): return skel.get_bone_global_rest(bones[name]).origin
	var head_to_feet: Vector3 = rest.call("Head") - (rest.call("LeftFoot") + rest.call("RightFoot")) * 0.5
	up = head_to_feet.normalized()
	left = (rest.call("LeftUpperArm") - rest.call("RightUpperArm")).normalized()
	forward = left.cross(up).normalized()
	# A cabeça (origem do osso) fica a ~70% da altura total nesses modelos.
	units_per_meter = head_to_feet.length() / (height * 0.7)

func _clip(name: String, t: float, speed: float = 1.0) -> void:
	if player == null or not player.has_animation(name):
		return
	skel.reset_bone_poses()
	if player.current_animation != name:
		player.play(name)
	var length := player.get_animation(name).length
	player.seek(fposmod(t * speed, maxf(length, 0.001)), true)
	if arm_rest_down != 0.0:
		_rotate("LeftUpperArm", forward, arm_rest_down)
		_rotate("RightUpperArm", forward, -arm_rest_down)

func _rotate(bone: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.0001 or not bones.has(bone):
		return
	var i: int = bones[bone]
	var parent := skel.get_bone_parent(i)
	var global := skel.get_bone_global_pose(i)
	var parent_basis := skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
	var wanted := Basis(axis, angle) * global.basis
	skel.set_bone_pose_rotation(i, (parent_basis.inverse() * wanted).get_rotation_quaternion())

func _swing(bone: String, from_dir: Vector3, to_dir: Vector3, angle: float) -> void:
	# Gira o osso no plano (from_dir -> to_dir): ângulo positivo leva from_dir em direção a to_dir.
	var axis := from_dir.cross(to_dir)
	if axis.length() < 0.0001:
		return
	_rotate(bone, axis.normalized(), angle)

func _face_target(actor: Node3D, target: Vector3, from_yaw: float, local_time: float) -> void:
	var direction := target - actor.position
	direction.y = 0
	if direction.length() > 0.05:
		actor.rotation.y = lerp_angle(from_yaw, atan2(direction.x, direction.z), smoothstep(0, 0.4, local_time))

func capture() -> Dictionary:
	var actor = get_parent()
	var poses := []
	for i in skel.get_bone_count():
		poses.append([skel.get_bone_pose_position(i), skel.get_bone_pose_rotation(i)])
	return {"position": actor.position, "yaw": actor.rotation.y, "bones": poses}

func blend_from(snapshot: Dictionary, weight: float) -> void:
	# Transição: mistura a pose anterior (snapshot) com a pose atual já aplicada.
	var actor = get_parent()
	actor.position = snapshot.position.lerp(actor.position, weight)
	actor.rotation.y = lerp_angle(snapshot.yaw, actor.rotation.y, weight)
	for i in skel.get_bone_count():
		var old: Array = snapshot.bones[i]
		skel.set_bone_pose_position(i, old[0].lerp(skel.get_bone_pose_position(i), weight))
		skel.set_bone_pose_rotation(i, old[1].slerp(skel.get_bone_pose_rotation(i), weight))

func _shift_hips(meters: Vector3) -> void:
	if not bones.has("Hips"):
		return
	var i: int = bones["Hips"]
	var parent := skel.get_bone_parent(i)
	var parent_basis := skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
	var offset_skel := (up * meters.y + forward * meters.z + left * meters.x) * units_per_meter
	skel.set_bone_pose_position(i, skel.get_bone_pose_position(i) + parent_basis.inverse() * offset_skel)

func _seat_legs(amount: float) -> void:
	_rotate("LeftUpperLeg", left, -amount * PI / 2)
	_rotate("RightUpperLeg", left, -amount * PI / 2)
	_shift_hips(Vector3(0, -amount * height * 0.22, 0))

func _arms_down(amount: float) -> void:
	# Clipes do Gobkit deixam os braços quase horizontais; baixa para uma pose mais natural.
	_rotate("LeftUpperArm", forward, -1.1 * amount)
	_rotate("RightUpperArm", forward, 1.1 * amount)

func evaluate(action: String, local_time: float, duration: float, time: float, from: Vector3, to: Vector3, target: Vector3, from_yaw: float = 0.0) -> void:
	var actor = get_parent()
	if skel == null:
		return
	local_time = minf(local_time, duration)
	var u = clampf(local_time / maxf(duration, 0.001), 0, 1)
	var ease = u * u * (3.0 - 2.0 * u)
	actor.position = from
	if action in ["stand", "jump", "celebrate", "surprised", "dance"] and to.distance_to(from) > 0.01:
		actor.position = from.lerp(to, smoothstep(0.0, 0.4, u))
	actor.rotation.y = from_yaw
	actor.set_meta("talking", action == "talk")
	actor.set_meta("crying", action == "cry")
	state = State.IDLE if action in ["idle", "stand"] else State.ACTING
	var right := -left
	match action:
		"talk":
			# Fala animada: gestos alternando os braços, tronco balançando e cabeça marcando as sílabas.
			_clip("Idle", time)
			_arms_down(0.75)
			var beat = sin(local_time * 3.1) * 0.5 + 0.5
			var counter = sin(local_time * 2.3 + 1.2) * 0.5 + 0.5
			_swing("RightUpperArm", right, forward, 0.45 + 0.55 * beat)
			_swing("RightUpperArm", forward, up, 0.25 * beat)
			_swing("LeftUpperArm", left, forward, 0.25 + 0.45 * counter)
			_rotate("RightHand", forward, sin(local_time * 6.2) * 0.25)
			_rotate("Chest", up, sin(local_time * 1.9) * 0.12)
			_rotate("Chest", left, 0.05 + sin(local_time * 3.1) * 0.04)
			_rotate("Head", left, absf(sin(local_time * 9.0)) * 0.1 - 0.03)
			_rotate("Head", forward, sin(local_time * 1.7) * 0.1)
		"cry":
			_clip("Idle", time * 0.5)
			var cover = smoothstep(0.0, 0.6, local_time)
			for side_dir in [left, right]:
				var bone = "LeftUpperArm" if side_dir == left else "RightUpperArm"
				_swing(bone, side_dir, forward, 1.35 * cover)
				_swing(bone, forward, up, 0.95 * cover)
				_swing(bone, side_dir, -side_dir, 0.3 * cover)
			_rotate("Chest", left, 0.18 * cover)
			_rotate("Head", left, 0.3 * cover)
			_rotate("Chest", up, sin(local_time * 19.0) * 0.035 * cover)
			_shift_hips(Vector3(0, absf(sin(local_time * 9.5)) * 0.012 * cover, 0))
		"hug":
			_clip("Idle", time)
			actor.position = from.lerp(to, smoothstep(0.0, 0.45, u))
			_face_target(actor, target, from_yaw, local_time)
			var reach = smoothstep(0.15, 0.55, u)
			for side_dir in [left, right]:
				var bone = "LeftUpperArm" if side_dir == left else "RightUpperArm"
				_swing(bone, side_dir, forward, 1.3 * reach)
				_swing(bone, side_dir, -side_dir, 0.35 * reach)
			_rotate("Chest", left, 0.12 * reach)
			_rotate("Head", forward, 0.18 * reach)
		"point":
			_clip("Idle", time)
			_face_target(actor, target, from_yaw, local_time)
			var raise = smoothstep(0.0, 0.4, local_time)
			_rotate("LeftUpperArm", forward, -1.1)
			_swing("RightUpperArm", right, forward, 1.45 * raise)
			_swing("RightUpperArm", forward, up, 0.12 * raise)
		"think":
			_clip("Idle", time * 0.7)
			var lift = smoothstep(0.0, 0.5, local_time)
			_rotate("LeftUpperArm", forward, -1.1)
			_swing("RightUpperArm", right, forward, 1.25 * lift)
			_swing("RightUpperArm", forward, up, 0.95 * lift)
			_swing("RightUpperArm", right, left, 0.35 * lift)
			_rotate("Head", forward, 0.16 * lift + sin(local_time * 1.3) * 0.04)
			_rotate("Head", left, -0.12 * lift)
		"walk", "walk_to", "run":
			state = State.MOVING
			actor.position = from.lerp(to, ease)
			var direction = to - from
			actor.rotation.y = lerp_angle(from_yaw, atan2(direction.x, direction.z), smoothstep(0, 0.4, local_time))
			_clip("Run" if action == "run" else "Walk", time, 1.4 if action == "run" else 1.0)
			# O rig IA acrescenta joelhos ao clipe Gobkit, que só movimenta quadril e pés.
			# Flexão alternada no balanço da perna evita o aspecto de deslizar com pernas rígidas.
			var cycle := time * (1.4 if action == "run" else 1.0) * TAU / 1.0416667
			var flex := 0.85 if action == "run" else 0.62
			for side in ["Left", "Right"]:
				var leg_phase := cycle + (0.0 if side == "Left" else PI)
				var bend := maxf(0.0, -sin(leg_phase)) * flex
				_rotate(side + "LowerLeg", left, bend)
				_rotate(side + "Foot", left, -bend * 0.6)
			# Braços caídos balançando em oposição às pernas (antes ficavam abertos e duros).
			_arms_down(1.05 if action == "run" else 1.15)
			var swing := (0.7 if action == "run" else 0.45)
			_rotate("LeftUpperArm", left, sin(cycle + PI) * swing)
			_rotate("RightUpperArm", left, sin(cycle) * swing)
			if action == "run":
				_rotate("Chest", left, 0.18)
				actor.position.y += absf(sin(time * 11.0)) * 0.06
		"look_at":
			_clip("Idle", time)
			_arms_down(0.8)
			var direction = target - actor.position
			var yaw = wrapf(atan2(direction.x, direction.z) - from_yaw, -PI, PI)
			_rotate("Head", up, clampf(yaw, -1.0, 1.0) * smoothstep(0, 0.5, local_time) * 0.8)
			_rotate("Head", left, 0.25 * smoothstep(0, 0.7, local_time))
		"bend_down":
			_clip("Idle", time)
			_arms_down(0.8)
			_rotate("Chest", left, ease * 0.6)
			_rotate("Head", left, ease * 0.2)
		"celebrate":
			# Comemora pulando sem parar e socando o ar.
			state = State.REACTING
			_clip("Idle", time)
			var rise = smoothstep(0, 0.25, local_time)
			actor.rotation.y = lerp_angle(from_yaw, 0, rise) + sin(local_time * 6.0) * 0.15 * rise
			var hop = absf(sin(local_time * 7.5))
			_rotate("LeftUpperArm", forward, rise * (1.0 + 0.5 * hop))
			_rotate("RightUpperArm", forward, -rise * (1.0 + 0.5 * absf(sin(local_time * 7.5 + 1.5))))
			_rotate("Head", left, -0.15 * hop * rise)
			actor.position.y += hop * 0.22 * rise
		"surprised":
			# Susto: pula para trás, braços para cima, depois balança.
			state = State.REACTING
			_clip("Idle", time)
			var rise = smoothstep(0, 0.2, local_time)
			actor.rotation.y = lerp_angle(from_yaw, 0, rise)
			_rotate("LeftUpperArm", forward, rise * 1.4)
			_rotate("RightUpperArm", forward, -rise * 1.4)
			_rotate("Chest", left, -0.2 * rise + sin(local_time * 5.0) * 0.04)
			_rotate("Head", left, -0.2 * rise)
			actor.position.y += sin(PI * clampf(local_time / 0.45, 0, 1)) * 0.3
			actor.position += Vector3(sin(actor.rotation.y), 0, cos(actor.rotation.y)) * -0.25 * smoothstep(0, 0.4, local_time)
		"dance":
			# Dança no ritmo (~2 batidas/s): quadril, braços alternados, pulinhos e giro.
			state = State.REACTING
			_clip("Idle", time)
			var beat_t = local_time * 2.0 * PI * 2.0
			actor.rotation.y = from_yaw + sin(local_time * 2.0) * 0.5
			_rotate("Chest", forward, sin(beat_t * 0.5) * 0.18)
			_rotate("Chest", up, sin(beat_t * 0.5 + 0.7) * 0.15)
			_rotate("LeftUpperArm", forward, 0.4 + sin(beat_t * 0.5) * 0.9)
			_rotate("RightUpperArm", forward, -0.4 + sin(beat_t * 0.5) * 0.9)
			_rotate("Head", forward, -sin(beat_t * 0.5) * 0.15)
			_rotate("Head", left, absf(sin(beat_t * 0.5)) * 0.12)
			_shift_hips(Vector3(sin(beat_t * 0.5) * 0.04, 0, 0))
			actor.position.y += absf(sin(beat_t * 0.5)) * 0.08
		"laugh":
			# Gargalhada: cabeça para trás, mãos na barriga, ombros pulando.
			_clip("Idle", time)
			var shake = absf(sin(local_time * 14.0))
			for side_dir in [left, right]:
				var bone = "LeftUpperArm" if side_dir == left else "RightUpperArm"
				_swing(bone, side_dir, forward, 0.9)
				_swing(bone, side_dir, -side_dir, 0.45)
			_rotate("Chest", left, -0.12 + shake * 0.08)
			_rotate("Head", left, -0.3 + shake * 0.1)
			actor.position.y += shake * 0.04
		"jump":
			_clip("Idle", time)
			var air = sin(PI * u)
			_rotate("LeftUpperArm", forward, air * 1.3)
			_rotate("RightUpperArm", forward, -air * 1.3)
			_rotate("LeftUpperLeg", left, -air * 0.6)
			_rotate("RightUpperLeg", left, -air * 0.6)
			actor.position.y += air * 0.55
		"wave":
			_clip("Idle", time)
			_rotate("LeftUpperArm", forward, -1.1)
			_rotate("RightUpperArm", forward, -1.25 * smoothstep(0, 0.3, local_time))
			_rotate("RightHand", forward, sin(local_time * 12) * 0.35)
		"nod":
			_clip("Idle", time)
			_arms_down(0.8)
			_rotate("Head", left, (sin(local_time * 8) * 0.5 + 0.5) * 0.35)
		"shake_head":
			_clip("Idle", time)
			_arms_down(0.8)
			_rotate("Head", up, sin(local_time * 8) * 0.45)
		"turn_left", "turn_right":
			_clip("Walk", time)
			_arms_down(0.5)
			actor.rotation.y = from_yaw + ease * PI / 2 * (1 if action == "turn_left" else -1)
		"sit":
			_clip("Idle", time)
			_arms_down(0.9)
			if to.distance_to(from) > 0.01:
				# Sentar em móvel: vai até o assento e gira para a orientação dele.
				var reach = smoothstep(0.0, 0.5, u)
				actor.position = from.lerp(to, reach)
				actor.rotation.y = lerp_angle(from_yaw, float(actor.get_meta("target_yaw", from_yaw)), reach)
			_seat_legs(ease)
		"sad":
			_clip("Idle", time * 0.6)
			_arms_down(1.0)
			_rotate("Chest", left, 0.15 * smoothstep(0, 0.6, local_time))
			_rotate("Head", left, 0.4 * smoothstep(0, 0.6, local_time))
		_:
			_clip("Idle", time)
			_arms_down(0.8)
			if action in ["idle", "stand"]:
				_rotate("Head", up, sin(local_time * 2.3) * 0.18)
	# Vida em toda pose parada: respiração e troca de peso (nunca fica congelado).
	if action not in ["walk", "walk_to", "run", "dance", "celebrate", "jump"]:
		_rotate("Chest", up, sin(time * 1.4 + float(get_instance_id() % 7)) * 0.05)
		_rotate("Chest", left, sin(time * 2.1) * 0.02)
		if from.y < 0.05:
			_shift_hips(Vector3(sin(time * 1.4) * 0.015, absf(sin(time * 2.8)) * 0.006, 0))
	# Continua sentado no móvel (posição acima do chão) em ações que não deslocam nem levantam.
	if from.y > 0.05 and action not in ["walk", "walk_to", "run", "sit", "jump", "stand", "hug", "celebrate", "dance", "surprised"]:
		_seat_legs(1.0)
