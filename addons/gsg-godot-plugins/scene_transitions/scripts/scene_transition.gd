extends CanvasLayer

enum Pattern {
	FADE = 0,
	CIRCLE = 1,
	HORIZONTAL = 2,
	VERTICAL = 3,
	DIAMOND = 4,
	PIXELATE = 5,
	HORIZONTAL_BARS = 6,
	STAR_BURST = 7,
	STAR_IRIS = 8
}

var overlay: ColorRect
var material: ShaderMaterial
var is_transitioning: bool = false

func _ready():
	# Layer 100 - below menus (menu layer is 101)
	layer = 100
	# Get the overlay node
	overlay = get_node("Overlay")
	# Load the shader material
	material = ShaderMaterial.new()
	material.shader = load("res://scripts/shaders/scene_transition.gdshader")
	overlay.material = material
	# Configure star mask (PNG alpha) if present
	var mask_path := "res://images/masks/star.png"
	var tex: Texture2D = load(mask_path)
	if tex:
		material.set_shader_parameter("star_tex", tex)
	# Tunables (can be adjusted in code if needed)
	material.set_shader_parameter("star_scale_open", 0.0)
	material.set_shader_parameter("star_scale_closed", 20.0)
	material.set_shader_parameter("star_edge_softness", 0.001)
	material.set_shader_parameter("star_close_clamp", 0.9999)
	# Start fully transparent
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("pattern", Pattern.FADE)
	overlay.visible = false

func transition_to_black(duration: float = 0.5, pattern: Pattern = Pattern.HORIZONTAL_BARS, play_sound: bool = false) -> void:
	"""Transition from transparent to black, masking the scene"""
	if is_transitioning:
		return
	
	is_transitioning = true
	GameManager.is_transitioning = true
	overlay.visible = true
	material.set_shader_parameter("pattern", pattern)
	
	# Play transition sound if requested
	if play_sound and SoundManager:
		SoundManager.play_sound("res://sounds/transition_1.wav")
	
	var tween = create_tween()
	tween.tween_method(
		func(value): material.set_shader_parameter("progress", value),
		0.0,
		1.0,
		duration
	)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN_OUT)
	
	await tween.finished
	is_transitioning = false
	GameManager.is_transitioning = false
	# Keep overlay visible and black (don't hide it)

func transition_from_black(duration: float = 0.5, pattern: Pattern = Pattern.HORIZONTAL_BARS, play_sound: bool = false) -> void:
	"""Transition from black back to transparent, revealing the scene"""
	if is_transitioning:
		return
	
	is_transitioning = true
	GameManager.is_transitioning = true
	overlay.visible = true
	material.set_shader_parameter("pattern", pattern)
	
	# Play transition sound if requested
	if play_sound and SoundManager:
		SoundManager.play_sound("res://sounds/transition_2.wav")
	
	var tween = create_tween()
	tween.tween_method(
		func(value): material.set_shader_parameter("progress", value),
		1.0,
		0.0,
		duration
	)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN_OUT)
	
	await tween.finished
	overlay.visible = false
	is_transitioning = false
	GameManager.is_transitioning = false

func instant_to_black() -> void:
	"""Instantly show black overlay"""
	overlay.visible = true
	material.set_shader_parameter("progress", 1.0)

func instant_clear() -> void:
	"""Instantly clear the overlay"""
	overlay.visible = false
	material.set_shader_parameter("progress", 0.0)
