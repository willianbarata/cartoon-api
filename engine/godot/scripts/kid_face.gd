extends Node
# Expressões por blend shapes do Gobkit: lid, angry, happy, smile, close, robot, small.
# Avaliação por tempo absoluto (sem Tween), como o EmotionController do robô.

const EXPRESSIONS := {
	"neutral": {},
	"happy": {"happy": 1.0},
	"curious": {"smile": 0.6, "small": 0.4},
	"surprised": {"small": 1.0},
	"scared": {"small": 1.0, "angry": 0.35},
	"sad": {"angry": 0.8, "lid": 0.55},
	"angry": {"angry": 1.0, "lid": 0.75},
}

var mesh: MeshInstance3D
var shapes := {}
var blink_offset := 0.0
var weights := {}

func setup(model: Node3D, seed_name: String) -> void:
	var found = model.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty():
		return
	mesh = found[0]
	for i in mesh.mesh.get_blend_shape_count():
		shapes[String(mesh.mesh.get_blend_shape_name(i))] = i
	# Piscadas defasadas por personagem, mas determinísticas.
	blink_offset = float(hash(seed_name) % 1000) / 1000.0 * 3.0

func evaluate(emotion: String, intensity: float, time: float) -> void:
	if mesh == null:
		return
	var actor = get_parent()
	if actor.get_meta("crying", false):
		emotion = "sad"
		intensity = 1.0
	var target: Dictionary = EXPRESSIONS.get(emotion.to_lower(), {})
	weights.clear()
	for name in shapes:
		weights[name] = float(target.get(name, 0.0)) * intensity
	if actor.get_meta("talking", false) and shapes.has("small"):
		# Fala: abre/fecha a boca num ritmo de sílabas (determinístico) sobre a emoção atual.
		var syllable = absf(sin(time * 9.0)) * (0.65 + 0.35 * sin(time * 2.3))
		weights["small"] = maxf(weights["small"], syllable)
		if shapes.has("happy"):
			weights["happy"] *= 1.0 - syllable * 0.7
	var phase = fposmod(time + blink_offset, 3.7)
	var blink = maxf(0.0, 1.0 - absf(phase - 0.09) / 0.09)
	if shapes.has("lid"):
		weights["lid"] = maxf(weights["lid"], blink)
	for name in shapes:
		mesh.set_blend_shape_value(shapes[name], weights[name])
