extends Node

func evaluate(emotion: String, intensity: float, time: float) -> void:
	var head = get_parent().get_node("Body/Head")
	var eye_scale := Vector2.ONE
	var brow := 0.0
	var mouth := Vector2(1, 1)
	match emotion.to_lower():
		"happy":
			eye_scale = Vector2(1.05, 0.7)
			mouth = Vector2(1.4, 2.6)
		"curious":
			eye_scale = Vector2(1.0, 1.13)
			brow = 0.19
		"surprised", "scared":
			eye_scale = Vector2(1.17, 1.25)
			mouth = Vector2(0.6, 4.5)
		"sad":
			eye_scale = Vector2(1.0, 0.7)
			brow = -0.3
		"angry":
			eye_scale = Vector2(1.0, 0.65)
			brow = 0.4
	var blink_phase = fposmod(time + 0.8, 3.7)
	var blink = 1.0 - 0.94 * maxf(0.0, 1.0 - absf(blink_phase - 0.08) / 0.08)
	for suffix in ["L", "R"]:
		var eye = head.get_node("Eye" + suffix)
		eye.scale = Vector3(lerpf(1, eye_scale.x, intensity), lerpf(1, eye_scale.y, intensity) * blink, 1)
		head.get_node("Brow" + suffix).rotation.z = brow * intensity * (-1 if suffix == "L" else 1)
	head.get_node("Mouth").scale = Vector3(0.16 * lerpf(1, mouth.x, intensity), 0.035 * lerpf(1, mouth.y, intensity), 0.03)
