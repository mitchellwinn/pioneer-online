extends EntityState
class_name StateAttackBase

## Base class for attack states
## Extend this for specific attacks (light, heavy, ability, etc.)

signal attack_hit(target: Node, damage: float)
signal attack_missed()

@export var attack_name: String = "attack"
@export var animation_name: String = "attack"
@export var damage: float = 10.0
@export var attack_duration: float = 0.5
@export var hit_window_start: float = 0.15
@export var hit_window_end: float = 0.35
@export var combo_window_start: float = 0.3  # When combo input becomes valid
@export var movement_during_attack: float = 0.2  # 0 = no movement, 1 = full movement
@export var can_combo_into: Array[String] = []  # States this can combo into

var attack_timer: float = 0.0
var has_hit: bool = false
var combo_input_received: bool = false
var queued_combo_state: String = ""

func _ready():
	can_be_interrupted = false
	priority = 15
	allows_movement = false
	allows_rotation = false

func on_enter(previous_state = null):
	# Check if combat is allowed
	if not _can_attack():
		# Reject attack, go back to previous state
		call_deferred("_reject_attack", previous_state)
		return
	
	attack_timer = 0.0
	has_hit = false
	combo_input_received = false
	queued_combo_state = ""
	
	# Reduce movement but don't stop completely
	allows_movement = movement_during_attack > 0
	
	if entity.has_method("play_animation"):
		entity.play_animation(animation_name)
	
	# Face toward aim direction if available
	if entity.has_method("face_aim_direction"):
		entity.face_aim_direction()

func _reject_attack(previous_state):
	# Return to idle if attack was rejected
	transition_to("idle", true)

func _can_attack() -> bool:
	if entity.has_method("can_attack"):
		return entity.can_attack()
	return true

func on_physics_process(delta: float):
	attack_timer += delta
	
	# Apply reduced movement if allowed
	if allows_movement and entity.has_method("get_movement_input"):
		var input_dir = entity.get_movement_input()
		if input_dir.length() > 0.1 and entity.has_method("apply_movement"):
			entity.apply_movement(input_dir, movement_during_attack)
	
	# Check for hits during hit window
	if not has_hit and attack_timer >= hit_window_start and attack_timer <= hit_window_end:
		_check_for_hits()
	
	# Check for combo input after combo window starts
	if attack_timer >= combo_window_start and not combo_input_received:
		_check_combo_input()
	
	# Attack complete
	if attack_timer >= attack_duration:
		_finish_attack()

func _check_for_hits():
	# Override in subclass to implement hit detection
	# Use raycast, area overlap, or animation hitbox
	pass

func _register_hit(target: Node, actual_damage: float):
	# Check if we can damage this target (PvP check)
	if entity.has_method("can_damage_player") and not entity.can_damage_player(target):
		attack_missed.emit()
		return
	
	has_hit = true
	attack_hit.emit(target, actual_damage)
	
	# Apply damage if target has combat component
	if target.has_method("take_damage"):
		target.take_damage(actual_damage, entity, attack_name)

func _check_combo_input():
	# Check for combo attacks
	for combo_state in can_combo_into:
		var action = _get_action_for_state(combo_state)
		if action and state_manager.consume_buffered_input(action):
			combo_input_received = true
			queued_combo_state = combo_state
			return

func _get_action_for_state(state_name: String) -> String:
	# Map state names to input actions
	match state_name:
		"attack_light", "attack_1":
			return "attack_primary"
		"attack_heavy", "attack_2":
			return "attack_secondary"
		"attack_special", "attack_3":
			return "ability_1"
		_:
			return ""

func _finish_attack():
	if combo_input_received and queued_combo_state != "":
		transition_to(queued_combo_state)
	else:
		complete()

func on_input(event: InputEvent):
	# Buffer combo inputs
	if attack_timer >= combo_window_start:
		for combo_state in can_combo_into:
			var action = _get_action_for_state(combo_state)
			if action and event.is_action_pressed(action):
				combo_input_received = true
				queued_combo_state = combo_state
				return

func can_transition_to(state_name: String) -> bool:
	# High priority interrupts
	if state_name in ["stunned", "dead", "dodging"]:
		return true
	# Combo states
	if state_name in can_combo_into and attack_timer >= combo_window_start:
		return true
	return false

func on_damage_taken(amount: float, source: Node):
	# Getting hit during attack can stagger us
	if amount > 0 and entity.has_method("should_stagger"):
		if entity.should_stagger(amount):
			transition_to("stunned")

