extends Node
class_name EntityState

## Base class for all entity states (movement, combat, abilities)
## Extend this to create specific states like Idle, Moving, Attacking, etc.

# Reference to the entity this state belongs to
var entity: Node3D

# Reference to the state manager
var state_manager  # EntityStateManager - untyped to avoid circular dependency

# Whether this state can be interrupted by other states
@export var can_be_interrupted: bool = true

# Priority for state transitions (higher = harder to interrupt)
@export var priority: int = 0

# Whether this state allows movement input
@export var allows_movement: bool = true

# Whether this state allows rotation/aiming
@export var allows_rotation: bool = true

## Optional: Animation to play when entering this state
## If set, on_enter() will automatically play this animation
## Leave empty for states that handle animation manually
@export var state_animation: String = ""

# Called when this state becomes active
func on_enter(previous_state = null):
	# Auto-play state animation if defined
	if not state_animation.is_empty() and entity and entity.has_method("play_animation"):
		entity.play_animation(state_animation)

# Called when this state stops being active
func on_exit(next_state = null):
	pass

# Called every frame while this state is active
func on_process(delta: float):
	pass

# Called every physics frame while this state is active
func on_physics_process(delta: float):
	pass

# Called when input is received (for player-controlled entities)
func on_input(event: InputEvent):
	pass

# Called to handle movement input - return true if handled
func handle_movement_input(input_dir: Vector3) -> bool:
	return false

# Called when the entity takes damage while in this state
func on_damage_taken(amount: float, source: Node):
	pass

# Check if we can transition to a specific state
func can_transition_to(state_name: String) -> bool:
	return true

# Request a state transition (goes through state manager)
func transition_to(state_name: String, force: bool = false) -> bool:
	if state_manager:
		return state_manager.change_state(state_name, force)
	return false

# Queue a state to transition to after this one completes
func queue_state(state_name: String):
	if state_manager:
		state_manager.queue_state(state_name)

# Complete this state and transition to next (queued or default)
func complete():
	if state_manager:
		state_manager.complete_current_state()

# Get data to pass to the next state
func get_exit_data() -> Dictionary:
	return {}

# Receive data from the previous state
func receive_entry_data(data: Dictionary):
	pass

