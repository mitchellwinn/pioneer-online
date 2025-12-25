extends EntityState
class_name StateMeleeAttack

## StateMeleeAttack - Base state for melee attack combo slashes
## Each slash in a combo is an instance of this state with different parameters
## Supports alternating swing arcs and momentum-based forward movement

#region Configuration
@export_group("Combo Identity")
@export var combo_index: int = 0 # 0, 1, 2 for 3-hit combo
@export var next_state_name: String = "" # Name of next slash state (empty = combo end)
@export var is_final_hit: bool = false # Final hit has special properties

@export_group("Timing")
@export var wind_up_time: float = 0.1 # Before hitbox active
@export var active_time: float = 0.15 # Hitbox is active
@export var recovery_time: float = 0.25 # After attack, before can act
@export var cancel_window_start: float = 0.2 # When you can cancel into next attack
@export var cancel_window_end: float = 0.4 # Window closes

@export_group("Swing Type (for combo controller)")
## Direction hint: -1 = left-to-right, 1 = right-to-left, 0 = overhead (used by animations)
@export var swing_direction: int = -1
## Vertical hint: -1 = downward, 0 = horizontal, 1 = upward (used by animations)
@export var arc_vertical: float = 0.0

@export_group("Movement")
@export var step_distance: float = 1.5 # Fixed step distance for this slash (increased for more lunging)
@export var step_curve: Curve # Easing for the step movement

@export_group("Combat Modifiers")
@export var damage_multiplier: float = 1.0
@export var knockback_multiplier: float = 1.0
@export var hitstun_multiplier: float = 1.0

@export_group("Animation")
@export var animation_name: String = "slash_1"
@export var animation_speed: float = 1.5
#endregion

#region State Properties
# Override EntityState properties
func _init():
	allows_movement = false # Movement is controlled by step
	allows_rotation = false # Lock rotation during attack
	can_be_interrupted = false # Can't be interrupted by lower priority
	priority = 10 # High priority
#endregion

#region Runtime State
enum Phase {WIND_UP, ACTIVE, RECOVERY}
var _phase: Phase = Phase.WIND_UP
var _phase_timer: float = 0.0
var _total_timer: float = 0.0
var _step_progress: float = 0.0
var _initial_position: Vector3
var _step_direction: Vector3
var _queued_next_attack: bool = false
var _input_buffer_time: float = 0.0  # Time since last attack input (for buffering)
const INPUT_BUFFER_WINDOW: float = 0.25  # Accept inputs this long before they're needed (generous buffer)
var _melee_weapon = null # MeleeWeaponComponent
var _equipment_manager: Node = null
var _has_hit: bool = false  # Track if attack connected - enables dash cancel
var _skip_first_frame_input: bool = false  # Skip input check on first frame (when coming from dash)
var _is_local_player: bool = false  # True if this is the local player (not remote)
#endregion

func _is_local() -> bool:
	## Check if this entity is the local player (not a remote player)
	## Remote players only play animations - no combat logic
	if not entity:
		return false
	# Check for _is_remote_player flag (ActionPlayer has this)
	if "_is_remote_player" in entity:
		return not entity._is_remote_player
	# Fallback: check can_receive_input base value
	if "_can_receive_input_base" in entity:
		return entity._can_receive_input_base
	# Ultimate fallback: check multiplayer authority
	return entity.is_multiplayer_authority()

func on_enter(previous_state = null):
	_phase = Phase.WIND_UP
	_phase_timer = 0.0
	_total_timer = 0.0
	_step_progress = 0.0
	_queued_next_attack = false
	_input_buffer_time = 999.0  # Large value = no buffered input
	_has_hit = false

	# Cache whether this is the local player
	_is_local_player = _is_local()

	# Skip first frame input if coming from dash (dash already consumed the attack input)
	var prev_name = previous_state.name.to_lower() if previous_state else ""
	_skip_first_frame_input = "dash" in prev_name

	# Cancel any current animation to prevent blending conflicts
	# (e.g., walking backward animation fighting with swing animation)
	_cancel_current_animation()

	# --- LOCAL PLAYER ONLY: Combat logic ---
	# Remote players only play animations - no weapon setup, hitboxes, or movement
	if _is_local_player:
		# Get equipment manager and melee weapon
		_equipment_manager = entity.get_node_or_null("EquipmentManager")
		if _equipment_manager:
			_melee_weapon = _equipment_manager.get_current_melee_component()
			if not _melee_weapon:
				# Debug: why is weapon null?
				var cw = _equipment_manager.current_weapon
				print("[MeleeAttack] Weapon lookup failed! current_weapon=%s valid=%s holstered=%s" % [
					cw, is_instance_valid(cw) if cw else false, _equipment_manager.is_holstered])

		if _melee_weapon:
			_melee_weapon.set_attacking(true)
			# Apply damage/knockback/hitstun multipliers for this swing
			_melee_weapon.damage = _melee_weapon._base_damage * damage_multiplier
			_melee_weapon.knockback_force = _melee_weapon._base_knockback * knockback_multiplier
			_melee_weapon.hitstun_duration = _melee_weapon._base_hitstun * hitstun_multiplier
			# Connect to hit signal for dash cancel on hit
			if not _melee_weapon.attack_hit.is_connected(_on_attack_hit):
				_melee_weapon.attack_hit.connect(_on_attack_hit)

		# Store initial position and calculate step direction
		_initial_position = entity.global_position

		# Use entity's forward direction (rotation is synced between client/server)
		# Entity faces +Z in this setup (body rotation points +Z forward)
		_step_direction = entity.global_transform.basis.z
		_step_direction.y = 0
		if _step_direction.length() > 0.01:
			_step_direction = _step_direction.normalized()
		else:
			_step_direction = Vector3.FORWARD

	# --- ALL PLAYERS: Animation ---
	# Play animation at fixed speed (animation handles sword visuals)
	if entity.has_method("play_animation"):
		entity.play_animation(animation_name)

	# Set animation speed for this slash
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = animation_speed

	# Emit attack started (local only)
	if _is_local_player and _melee_weapon:
		_melee_weapon.attack_started.emit()

func on_exit(next_state = null):
	# Ensure hitbox is disabled
	if _melee_weapon:
		if _melee_weapon._hitbox:
			_melee_weapon._hitbox.monitoring = false
		_melee_weapon.set_attacking(false)
		# Reset damage/knockback to base values
		_melee_weapon.damage = _melee_weapon._base_damage
		_melee_weapon.attack_finished.emit()
		# Disconnect hit signal
		if _melee_weapon.attack_hit.is_connected(_on_attack_hit):
			_melee_weapon.attack_hit.disconnect(_on_attack_hit)

	# Reset animation speed to normal
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.speed_scale = 1.0

	# NOTE: We no longer re-buffer attack inputs here as the global input buffer
	# already captures them. Re-buffering caused double attacks.

	# Notify combo controller
	var combo_ctrl = entity.get_node_or_null("MeleeComboController")
	if combo_ctrl:
		combo_ctrl.on_slash_finished(combo_index)

func _on_attack_hit(_target: Node, _hit_info: Dictionary):
	## Called when attack connects - enables dash cancel
	_has_hit = true

func on_physics_process(delta: float):
	# Remote players: only update timers for animation sync, no combat logic
	if not _is_local_player:
		_phase_timer += delta
		_total_timer += delta
		return

	# --- LOCAL PLAYER ONLY: Full combat processing ---
	_phase_timer += delta
	_total_timer += delta
	_input_buffer_time += delta

	# Handle phase transitions
	match _phase:
		Phase.WIND_UP:
			if _phase_timer >= wind_up_time:
				_enter_active_phase()
		Phase.ACTIVE:
			if _phase_timer >= active_time:
				_enter_recovery_phase()
		Phase.RECOVERY:
			if _phase_timer >= recovery_time:
				_finish_attack()
				return

	# Check for attack input - buffer it for later
	if _check_attack_input():
		_input_buffer_time = 0.0  # Reset buffer timer

	# Queue attack if we have buffered input and are in/past cancel window
	# Also accept buffered input during recovery for better responsiveness
	var can_queue = _is_in_cancel_window() or _phase == Phase.RECOVERY
	if can_queue and _input_buffer_time < INPUT_BUFFER_WINDOW:
		_queued_next_attack = true

	# If queued and past cancel window start, transition
	if _queued_next_attack and _total_timer >= cancel_window_start:
		_try_next_slash()
		return

	# Check for dash cancel after hit
	if _has_hit and _check_dash_input():
		_try_dash_cancel()
		return

	# Apply step movement
	_apply_step_movement(delta)

func on_input(event: InputEvent):
	# Buffer attack input - will be processed in on_physics_process
	if event.is_action_pressed("fire") or event.is_action_pressed("attack_primary"):
		_input_buffer_time = 0.0  # Reset buffer timer on input

func _enter_active_phase():
	_phase = Phase.ACTIVE
	_phase_timer = 0.0
	
	# Enable hitbox
	if _melee_weapon:
		_melee_weapon._hits_this_swing.clear()
		if _melee_weapon._hitbox:
			_melee_weapon._hitbox.monitoring = true
			if _melee_weapon.debug_hitbox:
				print("[MeleeAttack] HITBOX ACTIVE for %.2fs" % active_time)
		else:
			push_warning("[MeleeAttack] No hitbox found on weapon!")
	else:
		push_warning("[MeleeAttack] No melee weapon found!")

func _enter_recovery_phase():
	_phase = Phase.RECOVERY
	_phase_timer = 0.0
	
	# Disable hitbox
	if _melee_weapon and _melee_weapon._hitbox:
		_melee_weapon._hitbox.monitoring = false
		if _melee_weapon.debug_hitbox:
			print("[MeleeAttack] HITBOX DISABLED")

func _finish_attack():
	## Attack finished - return to idle
	# Force transition to idle - use state_manager if available, otherwise find it
	var sm = state_manager
	if not sm and entity:
		sm = entity.get_node_or_null("StateManager")
	
	if sm and sm.has_method("change_state"):
		# Force change to idle (bypasses complete() which might have issues)
		sm.change_state("idle", true) # force=true to ensure transition
	else:
		push_error("[StateMeleeAttack] Cannot finish attack - no state manager!")

func _is_in_cancel_window() -> bool:
	return _total_timer >= cancel_window_start and _total_timer <= cancel_window_end

func _check_attack_input() -> bool:
	if not entity or not "can_receive_input" in entity or not entity.can_receive_input:
		return false
	# Skip first frame if coming from dash (input was already consumed by dash)
	if _skip_first_frame_input:
		_skip_first_frame_input = false
		return false
	return Input.is_action_just_pressed("fire") or Input.is_action_just_pressed("attack_primary")

func _try_next_slash():
	## Try to transition to next slash in combo
	# Consume the buffered attack input since we're using it for combo continuation
	# This prevents the same input from triggering another attack later
	if state_manager and state_manager.has_method("consume_buffered_input"):
		state_manager.consume_buffered_input("attack_primary")
		state_manager.consume_buffered_input("fire")

	if not next_state_name.is_empty():
		# Continue to next slash in combo
		if state_manager and state_manager.has_state(next_state_name):
			transition_to(next_state_name, true)
	else:
		# Final hit - allow restarting combo via combo controller
		var combo_ctrl = entity.get_node_or_null("MeleeComboController")
		if combo_ctrl and combo_ctrl.has_method("try_attack"):
			# Let combo controller handle restarting
			combo_ctrl.try_attack()

func _check_dash_input() -> bool:
	## Check for dash input (Alt key or double-tap via try_dash)
	if not entity or not "can_receive_input" in entity or not entity.can_receive_input:
		return false
	
	# Check direct input
	if Input.is_action_just_pressed("dash") or Input.is_action_just_pressed("dodge"):
		var dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if dir.length_squared() < 0.01:
			dir = Vector2(0, -1)  # Default forward
		entity.set_meta("_buffered_dash_direction", dir)
		return true
	
	# Check double-tap via entity
	if entity.has_method("try_dash") and entity.try_dash():
		return true
	
	return false

func _try_dash_cancel():
	## Cancel attack into dash after hit
	if state_manager and state_manager.has_state("dash") and _has_stamina_for_dash():
		transition_to("dash", true)

func _has_stamina_for_dash() -> bool:
	## Check if entity has enough stamina to dash
	if entity.has_method("has_stamina"):
		var dash_cost = entity.dash_stamina_cost if "dash_stamina_cost" in entity else 20.0
		return entity.has_stamina(dash_cost)
	return true

func _apply_step_movement(_delta: float):
	## Apply forward step during attack - fixed distance, velocity decreases over duration
	if not entity is CharacterBody3D:
		return
	
	var char_body = entity as CharacterBody3D
	var total_duration = wind_up_time + active_time + recovery_time
	
	# Progress from 0 to 1 over attack duration
	var progress = clampf(_total_timer / total_duration, 0.0, 1.0)
	
	# Velocity multiplier: starts at 1, decreases to 0 (inverted progress)
	var speed_mult = 1.0 - progress
	
	# Base speed calculated from fixed step distance and duration
	var base_speed = step_distance / total_duration * 2.0 # *2 because average of 1->0 is 0.5
	
	# Apply velocity in step direction
	var step_speed = base_speed * speed_mult
	char_body.velocity.x = _step_direction.x * step_speed
	char_body.velocity.z = _step_direction.z * step_speed
	
	char_body.move_and_slide()

func _cancel_current_animation():
	## Stop any currently playing animation to prevent blending conflicts with attack
	var anim_controller = entity.get_node_or_null("AnimationController")
	if anim_controller and "animation_player" in anim_controller and anim_controller.animation_player:
		anim_controller.animation_player.stop()
		anim_controller.animation_player.clear_queue()
	elif entity.has_node("AnimationPlayer"):
		var anim_player = entity.get_node("AnimationPlayer")
		anim_player.stop()
		anim_player.clear_queue()

func can_transition_to(state_name: String) -> bool:
	## Allow transitions based on state
	# Always allow these
	if state_name in ["stunned", "dead"]:
		return true

	# Allow dash cancel after hit
	if state_name == "dash" and _has_hit:
		return true

	# Allow combo transitions during cancel window OR recovery phase
	var state_lower = state_name.to_lower()
	if "slash" in state_lower or "attack" in state_lower:
		var in_window = _is_in_cancel_window() or _phase == Phase.RECOVERY
		return in_window or _queued_next_attack

	return false
