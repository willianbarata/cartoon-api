extends Node
enum State { IDLE, MOVING, ACTING, REACTING }
var state: State = State.IDLE

# Absolute-time evaluation: replays identically without Tween, sleep, or accumulated deltas.
func evaluate(action: String, local_time: float, duration: float, time: float, from: Vector3, to: Vector3, target: Vector3, from_yaw: float = 0.0) -> void:
	var actor = get_parent()
	local_time = minf(local_time, duration)
	var body = actor.get_node("Body")
	var head = actor.get_node("Body/Head")
	var u = clampf(local_time / maxf(duration, 0.001), 0, 1)
	var ease = u * u * (3.0 - 2.0 * u)
	actor.position = from
	actor.rotation.y = from_yaw
	body.position.y = 0.84 + sin(time * 2.5) * 0.015
	body.rotation = Vector3.ZERO
	head.rotation = Vector3.ZERO
	for suffix in ["L", "R"]:
		actor.get_node("Leg" + suffix).rotation = Vector3.ZERO
		body.get_node("Arm" + suffix).rotation = Vector3(0, 0, -0.10 if suffix == "L" else 0.10)
		body.get_node("Arm" + suffix + "/Elbow").rotation = Vector3.ZERO
	state = State.IDLE if action in ["idle", "stand"] else State.ACTING
	match action:
		"walk", "walk_to", "run":
			state = State.MOVING
			actor.position = from.lerp(to, ease)
			var direction = to - from
			actor.rotation.y = lerp_angle(from_yaw, atan2(direction.x, direction.z), smoothstep(0, 0.4, local_time))
			var envelope = sin(PI * u) ** 0.4
			var stride = sin(local_time * (15 if action == "run" else 10)) * envelope
			actor.get_node("LegL").rotation.x = stride * 0.55
			actor.get_node("LegR").rotation.x = -stride * 0.55
			body.get_node("ArmL").rotation.x = -stride * 0.5
			body.get_node("ArmR").rotation.x = stride * 0.5
			body.position.y += absf(stride) * 0.055
		"look_at":
			state = State.ACTING
			var direction = target - actor.position
			head.rotation.y = wrapf(atan2(direction.x, direction.z) - from_yaw, -PI, PI) * smoothstep(0, 0.5, local_time) * 0.65
			head.rotation.x = 0.3 * smoothstep(0, 0.7, local_time)
			head.rotation.z = sin(local_time * 2) * 0.12
		"bend_down":
			state = State.ACTING
			body.rotation.x = ease * 0.65
			head.rotation.x = ease * 0.1
			body.position.y -= ease * 0.12
			body.get_node("ArmL").rotation.x = -ease * 0.3
		"celebrate", "surprised":
			state = State.REACTING
			var rise = smoothstep(0, 0.35, local_time)
			actor.rotation.y = lerp_angle(from_yaw, 0, rise)
			body.rotation.x = lerpf(0.65, 0, rise)
			body.get_node("ArmL").rotation.z = -rise * 1.7
			body.get_node("ArmR").rotation.z = rise * 1.7
			body.position.y += sin(PI * u) * 0.13
		"jump":
			state = State.ACTING
			actor.position.y += sin(PI * u) * 0.65
		"wave":
			body.get_node("ArmR").rotation.z = 2.3 + sin(local_time * 14) * 0.22
		"nod":
			head.rotation.x = sin(local_time * 8) * 0.3
		"shake_head":
			head.rotation.y = sin(local_time * 8) * 0.4
		"turn_left", "turn_right":
			actor.rotation.y = from_yaw + ease * PI / 2 * (1 if action == "turn_left" else -1)
		"sit":
			body.position.y -= ease * 0.28
			actor.get_node("LegL").rotation.x = -ease * PI / 2
			actor.get_node("LegR").rotation.x = -ease * PI / 2
		"sad":
			head.rotation.x = 0.35
			body.rotation.x = 0.15
		"dance":
			body.rotation.z = sin(local_time * 6.3) * 0.15
			body.get_node("ArmL").rotation.z = -1.0 - sin(local_time * 6.3) * 0.6
			body.get_node("ArmR").rotation.z = 1.0 - sin(local_time * 6.3) * 0.6
			actor.position.y += absf(sin(local_time * 6.3)) * 0.08
		"laugh":
			head.rotation.x = -0.3 + absf(sin(local_time * 14)) * 0.1
		"talk":
			head.rotation.x = sin(local_time * 6) * 0.08
			body.get_node("ArmR").rotation.x = -0.5 - sin(local_time * 3) * 0.2
		"cry":
			head.rotation.x = 0.35
			body.rotation.x = 0.15 + sin(local_time * 19) * 0.02
			body.get_node("ArmL").rotation.x = -2.0 * ease
			body.get_node("ArmR").rotation.x = -2.0 * ease
		"hug":
			actor.position = from.lerp(to, smoothstep(0.0, 0.45, u))
			body.get_node("ArmL").rotation.x = -1.4 * ease
			body.get_node("ArmR").rotation.x = -1.4 * ease
		"point":
			body.get_node("ArmR").rotation.x = -1.5 * smoothstep(0, 0.4, local_time)
		"think":
			body.get_node("ArmR").rotation.x = -2.2 * smoothstep(0, 0.5, local_time)
			head.rotation.z = 0.15
		"idle", "stand":
			head.rotation.y = sin(local_time * 2.3) * 0.26
			head.rotation.z = sin(local_time * 1.7) * 0.05
