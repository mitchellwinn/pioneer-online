extends EntityState
class_name StateDead

## Dead state - entity has been killed

signal respawn_requested()

@export var ragdoll_on_death: bool = true
@export var fade_out_time: float = 0.0  # 0 = no fade
@export var auto_respawn_time: float = 0.0  # 0 = no auto respawn

var death_timer: float = 0.0
var killer: Node = null
var death_impulse: Vector3 = Vector3.ZERO
var hit_bone: String = ""

func _ready():
	can_be_interrupted = false
	priority = 100
	allows_movement = false
	allows_rotation = false

func on_enter(previous_state = null):
	death_timer = 0.0
	
	# Disable collision/physics
	if entity is CharacterBody3D:
		entity.set_physics_process(false)
	
	# Play death animation or enable ragdoll
	if ragdoll_on_death and entity.has_method("enable_ragdoll"):
		# Pass death impulse for dramatic ragdoll effect
		entity.enable_ragdoll(death_impulse, hit_bone)
	elif entity.has_method("play_animation"):
		entity.play_animation("death")
	
	# Stop all velocity
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO

func receive_entry_data(data: Dictionary):
	killer = data.get("killer", null)
	death_impulse = data.get("death_impulse", Vector3.ZERO)
	hit_bone = data.get("hit_bone", "")

func on_process(delta: float):
	death_timer += delta
	
	# Fade out
	if fade_out_time > 0 and death_timer <= fade_out_time:
		var alpha = 1.0 - (death_timer / fade_out_time)
		if entity.has_method("set_opacity"):
			entity.set_opacity(alpha)
	
	# Auto respawn
	if auto_respawn_time > 0 and death_timer >= auto_respawn_time:
		respawn_requested.emit()

func on_exit(next_state = null):
	# Re-enable physics
	if entity is CharacterBody3D:
		entity.set_physics_process(true)
	
	# Disable ragdoll
	if entity.has_method("disable_ragdoll"):
		entity.disable_ragdoll()
	
	# Reset opacity
	if entity.has_method("set_opacity"):
		entity.set_opacity(1.0)

func can_transition_to(state_name: String) -> bool:
	# Only revive can exit death state
	return false

func request_respawn():
	respawn_requested.emit()

