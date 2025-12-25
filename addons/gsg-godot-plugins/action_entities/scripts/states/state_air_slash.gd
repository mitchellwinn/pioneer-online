extends EntityState
class_name StateAirSlash

## StateAirSlash - Aerial attack that can be performed from dash
## Once hitbox becomes active, player can dash again
## Creates a fluid dash -> air slash -> dash chain

@export_group("Timing")
@export var wind_up_time: float = 0.08  # Before hitbox active
@export var active_time: float = 0.15  # Hitbox is active
@export var recovery_time: float = 0.2  # After attack

@export_group("Combat")
@export var damage_multiplier: float = 1.2
@export var knockback_multiplier: float = 1.5

@export_group("Physics")
@export var air_stall: float = 0.5  # Reduces gravity during slash (0 = float, 1 = normal)

@export_group("Animation")
@export var animation_name: String = "AirSwing"
@export var animation_speed: float = 1.0

@export_group("Debug")
@export var debug_air_slash: bool = false

enum Phase { WIND_UP, ACTIVE, RECOVERY }

var current_phase: Phase = Phase.WIND_UP
var phase_timer: float = 0.0
var total_timer: float = 0.0
var can_dash_cancel: bool = false  # Becomes true when hitbox activates
var _melee_weapon = null

func _ready():
	can_be_interrupted = false
	priority = 10
	allows_movement = false
	allows_rotation = false

func on_enter(previous_state = null):
	current_phase = Phase.WIND_UP
	phase_timer = 0.0
	total_timer = 0.0
	can_dash_cancel = false
	
	# Get melee weapon for hitbox control
	var equip_manager = entity.get_node_or_null("EquipmentManager")
	if equip_manager and equip_manager.has_method("get_current_melee_component"):
		_melee_weapon = equip_manager.get_current_melee_component()
	
	if _melee_weapon:
		_melee_weapon.set_attacking(true)
		# Apply damage multipliers
		_melee_weapon.damage = _melee_weapon._base_damage * damage_multiplier
		_melee_weapon.knockback_force = _melee_weapon._base_knockback * knockback_multiplier
	
	# Play animation
	if entity.has_method("play_animation"):
		entity.play_animation(animation_name)
	
	# Set animation speed
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = animation_speed
	
	if debug_air_slash:
		print("[StateAirSlash] ENTER from %s" % (previous_state.name if previous_state else "none"))

func on_physics_process(delta: float):
	phase_timer += delta
	total_timer += delta

	# Remote players only update timers - no combat logic
	var is_remote = "_is_remote_player" in entity and entity._is_remote_player
	if is_remote:
		return

	# Phase transitions
	match current_phase:
		Phase.WIND_UP:
			if phase_timer >= wind_up_time:
				_enter_active_phase()
		Phase.ACTIVE:
			if phase_timer >= active_time:
				_enter_recovery_phase()
		Phase.RECOVERY:
			if phase_timer >= recovery_time:
				_finish_attack()
				return
	
	# Check for dash cancel (only after hitbox becomes active)
	if can_dash_cancel and _check_dash_input():
		if _can_dash_now() and state_manager.has_state("dash"):
			transition_to("dash", true)
			return
	
	# Apply air physics (gravity only - preserve horizontal momentum)
	if entity is CharacterBody3D:
		var body = entity as CharacterBody3D
		var gravity = entity.gravity if "gravity" in entity else 20.0
		
		# Reduced gravity during slash (air stall)
		body.velocity.y -= gravity * air_stall * delta
		# Horizontal momentum is preserved - no velocity modification

func _enter_active_phase():
	current_phase = Phase.ACTIVE
	phase_timer = 0.0
	can_dash_cancel = true  # NOW player can dash cancel!
	
	# Enable hitbox
	if _melee_weapon:
		_melee_weapon._hits_this_swing.clear()
		if _melee_weapon._hitbox:
			_melee_weapon._hitbox.monitoring = true
	
	if debug_air_slash:
		print("[StateAirSlash] ACTIVE - can now dash cancel!")

func _enter_recovery_phase():
	current_phase = Phase.RECOVERY
	phase_timer = 0.0
	
	# Disable hitbox
	if _melee_weapon and _melee_weapon._hitbox:
		_melee_weapon._hitbox.monitoring = false
	
	if debug_air_slash:
		print("[StateAirSlash] RECOVERY")

func _check_dash_input() -> bool:
	if not entity or not "can_receive_input" in entity:
		return false
	
	if entity.can_receive_input:
		# Capture direction at input time
		if Input.is_action_just_pressed("dash") or Input.is_action_just_pressed("dodge"):
			var dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
			if dir.length_squared() < 0.01:
				dir = Vector2(0, -1)  # Default forward
			entity.set_meta("_buffered_dash_direction", dir)
			return true
		return false
	else:
		# Server: check buffered input WITH direction data
		if state_manager:
			var result = state_manager.consume_buffered_input_with_data("dodge")
			if result.found:
				var dir = result.data.get("direction", Vector2(0, -1))
				entity.set_meta("_buffered_dash_direction", dir)
				return true
		return false

func _can_dash_now() -> bool:
	## Check if dash is off cooldown and has stamina
	var current_time = Time.get_ticks_msec() / 1000.0
	var last_time = entity.get_meta("_last_dash_time", -999.0)
	if current_time - last_time < 0.1:  # Default cooldown
		return false
	
	# Check stamina
	if entity.has_method("has_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		if not entity.has_stamina(dash_cost):
			return false
	
	return true

func _finish_attack():
	if debug_air_slash:
		print("[StateAirSlash] FINISHED")
	
	# Always transition to idle - let idle handle airborne detection
	# This keeps state flow clean: air_slash → idle → (idle detects air) → airborne
	transition_to("idle", true)

func on_exit(next_state = null):
	# Cleanup hitbox
	if _melee_weapon:
		if _melee_weapon._hitbox:
			_melee_weapon._hitbox.monitoring = false
		_melee_weapon.set_attacking(false)
		_melee_weapon.damage = _melee_weapon._base_damage
		_melee_weapon.attack_finished.emit()
	
	# Reset animation speed
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = 1.0
	
	if debug_air_slash:
		print("[StateAirSlash] EXIT to %s" % (next_state.name if next_state else "none"))

func can_transition_to(state_name: String) -> bool:
	if state_name in ["stunned", "dead"]:
		return true
	if state_name == "dash" and can_dash_cancel:
		return true
	return false

