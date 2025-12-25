extends EntityState
class_name StateStunned

## Stunned/Staggered state - entity is briefly incapacitated

@export var default_stun_duration: float = 0.5

var stun_timer: float = 0.0
var stun_duration: float = 0.5

func _ready():
	can_be_interrupted = false
	priority = 50
	allows_movement = false
	allows_rotation = false

func on_enter(previous_state = null):
	stun_timer = 0.0
	
	if entity.has_method("play_animation"):
		entity.play_animation("stagger")

func receive_entry_data(data: Dictionary):
	stun_duration = data.get("stun_duration", default_stun_duration)

func on_physics_process(delta: float):
	stun_timer += delta
	
	# Apply friction to slow down
	if entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		body.velocity.x = move_toward(body.velocity.x, 0, 20.0 * delta)
		body.velocity.z = move_toward(body.velocity.z, 0, 20.0 * delta)
	
	if stun_timer >= stun_duration:
		complete()

func can_transition_to(state_name: String) -> bool:
	# Only death can interrupt stun
	if state_name == "dead":
		return true
	return false

