extends EntityState
class_name StateDodging

## Dodge/Roll state with i-frames

@export var dodge_speed: float = 12.0
@export var dodge_duration: float = 0.4
@export var i_frame_duration: float = 0.25
@export var cooldown: float = 0.5

var dodge_timer: float = 0.0
var dodge_direction: Vector3 = Vector3.ZERO
var has_i_frames: bool = false
static var cooldown_timer: float = 0.0

func _ready():
	can_be_interrupted = false
	priority = 10
	allows_movement = false
	allows_rotation = false

static func is_on_cooldown() -> bool:
	return cooldown_timer > 0.0

static func _static_process(delta: float):
	if cooldown_timer > 0:
		cooldown_timer -= delta

func on_enter(previous_state = null):
	if StateDodging.is_on_cooldown():
		complete()
		return
	
	dodge_timer = 0.0
	has_i_frames = true
	
	# Get dodge direction from input or facing
	if entity.has_method("get_movement_input"):
		dodge_direction = entity.get_movement_input()
	
	if dodge_direction.length() < 0.1:
		# Dodge backward if no input
		if entity is Node3D:
			dodge_direction = -entity.global_transform.basis.z
	
	dodge_direction = dodge_direction.normalized()
	
	# Set invulnerability
	if entity.has_method("set_invulnerable"):
		entity.set_invulnerable(true)
	
	if entity.has_method("play_animation"):
		entity.play_animation("dodge")

func on_exit(next_state = null):
	# Remove invulnerability
	if entity.has_method("set_invulnerable"):
		entity.set_invulnerable(false)
	
	# Start cooldown
	StateDodging.cooldown_timer = cooldown

func on_physics_process(delta: float):
	dodge_timer += delta
	
	# Update i-frames
	if has_i_frames and dodge_timer >= i_frame_duration:
		has_i_frames = false
		if entity.has_method("set_invulnerable"):
			entity.set_invulnerable(false)
	
	# Apply dodge movement
	if entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		# Ease out the speed
		var speed_mult = 1.0 - (dodge_timer / dodge_duration)
		speed_mult = ease(speed_mult, 0.5)  # Smooth curve
		body.velocity.x = dodge_direction.x * dodge_speed * speed_mult
		body.velocity.z = dodge_direction.z * dodge_speed * speed_mult
	
	# Check if dodge is complete
	if dodge_timer >= dodge_duration:
		complete()

func on_process(delta: float):
	# Update static cooldown
	StateDodging._static_process(delta)

func can_transition_to(state_name: String) -> bool:
	# Only high priority states can interrupt dodge
	if state_name in ["dead"]:
		return true
	return false

