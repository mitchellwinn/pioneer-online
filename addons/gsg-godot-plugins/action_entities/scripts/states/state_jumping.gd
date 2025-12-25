extends EntityState
class_name StateJumping

## Jumping state - applies jump force and transitions to airborne
## This is a brief transition state, not a sustained state

@export var jump_force: float = 8.0
@export var debug_jumping: bool = false

var anim_controller: PlayerAnimationController = null

func _ready():
	can_be_interrupted = false
	priority = 5
	allows_movement = true
	allows_rotation = true

func _find_anim_controller():
	if not anim_controller and entity:
		anim_controller = entity.get_node_or_null("AnimationController") as PlayerAnimationController
		if not anim_controller:
			anim_controller = entity.find_child("AnimationController", true, false) as PlayerAnimationController

func on_enter(previous_state = null):
	_find_anim_controller()

	if debug_jumping:
		var prev_name = previous_state.name if previous_state else "none"
		print("[StateJumping] ENTER from %s" % prev_name)

	# Apply jump force immediately
	if entity is CharacterBody3D:
		entity.velocity.y = jump_force
		if debug_jumping:
			print("[StateJumping] Applied jump force: %.2f" % jump_force)

	# Set jump animation
	if anim_controller:
		anim_controller.set_jumping(true)

	# Immediately transition to airborne state
	call_deferred("_transition_to_airborne")

func _transition_to_airborne():
	transition_to("airborne", true)

func on_exit(next_state = null):
	if debug_jumping:
		var next_name = next_state.name if next_state else "none"
		print("[StateJumping] EXIT to %s" % next_name)

func can_transition_to(state_name: String) -> bool:
	# Allow transition to airborne
	if state_name == "airborne":
		return true
	if state_name in ["stunned", "dead"]:
		return true
	return false
