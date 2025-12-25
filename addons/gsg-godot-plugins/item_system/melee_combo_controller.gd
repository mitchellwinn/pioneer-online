extends Node
class_name MeleeComboController

## MeleeComboController - Manages melee attack combos
## Creates and configures attack states for the entity's state machine

#region Signals
signal combo_started(combo_name: String)
signal slash_performed(slash_index: int)
signal combo_finished(combo_name: String, completed: bool)
signal combo_reset()
#endregion

#region Configuration
@export var state_machine: Node  # EntityStateManager - untyped to avoid load order issues
@export var equipment_manager: Node

@export_group("Combo Timing")
## Time after combo ends before it resets (allows delayed continuation)
@export var combo_reset_time: float = 0.5
## Global cooldown between any attacks (keep very low for responsiveness)
@export var attack_cooldown: float = 0.0
#endregion

#region Default Combo Definitions
## Each combo is an array of slash configs
## swing_dir: -1 = right-to-left, 1 = left-to-right, 0 = overhead/vertical
## arc_vertical: -1 = downward, 0 = horizontal, 1 = upward
const DEFAULT_COMBOS = {
	"saber_light": [
		{
			# Slash 1: Right-to-left horizontal sweep - moderate speed
			"animation": "Swing1",
			"animation_speed": 1.0,
			"wind_up": 0.08,
			"active": 0.12,
			"recovery": 0.18,
			"cancel_start": 0.12,  # Can chain earlier
			"cancel_end": 0.50,    # Much longer window to chain (hitlag extends this)
			"step_distance": 0.5,
			"damage_mult": 1.0,
			"knockback_mult": 1.0,
			"hitstun_mult": 1.0,
			"swing_dir": -1,
			"arc_angle": 100.0,
			"arc_vertical": 0.0,
			"is_final": false
		},
		{
			# Slash 2: Left-to-right return sweep - faster
			"animation": "Swing2",
			"animation_speed": 1.0,
			"wind_up": 0.06,
			"active": 0.12,
			"recovery": 0.16,
			"cancel_start": 0.10,  # Can chain earlier
			"cancel_end": 0.45,    # Much longer window to chain
			"step_distance": 0.4,
			"damage_mult": 1.0,
			"knockback_mult": 1.0,
			"hitstun_mult": 1.0,
			"swing_dir": 1,
			"arc_angle": 90.0,
			"arc_vertical": 0.0,
			"is_final": false
		},
		{
			# Slash 3: Big overhead slam - powerful finisher
			"animation": "Swing3",
			"animation_speed": 1.0,
			"wind_up": 0.08,
			"active": 0.12,
			"recovery": 0.15,
			"cancel_start": 0.15,  # Can restart combo early
			"cancel_end": 0.50,
			"step_distance": 0.8,
			"damage_mult": 1.5,
			"knockback_mult": 2.0,
			"hitstun_mult": 1.5,
			"swing_dir": 0,
			"arc_angle": 140.0,
			"arc_vertical": -1.0,
			"is_final": true
		}
	],
	"saber_heavy": [
		{
			# Single heavy overhead attack
			"animation": "Swing3",  # Use Swing3 for heavy attack too
			"animation_speed": 0.7,  # Slower and more powerful for heavy attack
			"wind_up": 0.25,
			"active": 0.2,
			"recovery": 0.4,
			"cancel_start": 0.55,
			"cancel_end": 0.7,
			"step_distance": 1.0,  # Fixed step distance
			"damage_mult": 2.0,
			"knockback_mult": 2.5,
			"hitstun_mult": 2.0,
			"swing_dir": 0,
			"arc_angle": 160.0,
			"arc_vertical": -1.0,
			"is_final": true
		}
	]
}
#endregion

#region Runtime State
var _combos: Dictionary = {}  # combo_name -> Array[StateMeleeAttack]
var _current_combo: String = ""
var _current_slash_index: int = -1
var _combo_reset_timer: float = 0.0
var _attack_cooldown_timer: float = 0.0
var _is_attacking: bool = false
#endregion

func _ready():
	# Find state machine if not set
	if not state_machine:
		state_machine = get_parent().get_node_or_null("StateManager")
	if not state_machine:
		state_machine = get_parent().get_node_or_null("EntityStateManager")
	
	# Find equipment manager if not set
	if not equipment_manager:
		equipment_manager = get_parent().get_node_or_null("EquipmentManager")
	
	# Defer setup to ensure state machine is ready
	if state_machine:
		call_deferred("_setup_default_combos")
		call_deferred("_setup_block_state")
	else:
		push_warning("[MeleeComboController] No state machine found!")

func _process(delta: float):
	# Update timers
	if _attack_cooldown_timer > 0:
		_attack_cooldown_timer -= delta
	
	if not _is_attacking and _current_combo != "":
		_combo_reset_timer -= delta
		if _combo_reset_timer <= 0:
			_reset_combo()

#region Combo Setup
func _setup_default_combos():
	for combo_name in DEFAULT_COMBOS:
		register_combo(combo_name, DEFAULT_COMBOS[combo_name])

func register_combo(combo_name: String, slash_configs: Array):
	## Register a combo with the state machine
	var states: Array[StateMeleeAttack] = []
	
	for i in range(slash_configs.size()):
		var config = slash_configs[i]
		var state = _create_slash_state(combo_name, i, config, slash_configs.size())
		states.append(state)
		
		# Register state with state machine
		var state_name = _get_state_name(combo_name, i)
		if state_machine:
			state_machine.add_state(state_name, state)
	
	_combos[combo_name] = states

func _create_slash_state(combo_name: String, index: int, config: Dictionary, total_slashes: int) -> StateMeleeAttack:
	var state = StateMeleeAttack.new()
	
	# Identity
	state.combo_index = index
	state.is_final_hit = config.get("is_final", index == total_slashes - 1)
	
	# Animation
	state.animation_name = config.get("animation", "slash_%d" % (index + 1))
	state.animation_speed = config.get("animation_speed", 1.0 + (index * 0.2))  # Default: increases per step
	
	# Timing
	state.wind_up_time = config.get("wind_up", 0.1)
	state.active_time = config.get("active", 0.15)
	state.recovery_time = config.get("recovery", 0.25)
	state.cancel_window_start = config.get("cancel_start", 0.2)
	state.cancel_window_end = config.get("cancel_end", 0.4)
	
	# Movement - fixed step distance
	state.step_distance = config.get("step_distance", config.get("step", 0.8))
	
	# Combat modifiers
	state.damage_multiplier = config.get("damage_mult", 1.0)
	state.knockback_multiplier = config.get("knockback_mult", 1.0)
	state.hitstun_multiplier = config.get("hitstun_mult", 1.0)
	
	# Swing type hints (used by animations)
	state.swing_direction = config.get("swing_dir", -1 if index % 2 == 0 else 1)
	state.arc_vertical = config.get("arc_vertical", 0.0)
	
	# Link to next slash (if not last)
	if index < total_slashes - 1:
		state.next_state_name = _get_state_name(combo_name, index + 1)
	else:
		state.next_state_name = ""  # Last slash ends combo
	
	# Create step curve - final hit has more dramatic acceleration
	var curve = Curve.new()
	curve.add_point(Vector2(0, 0))
	if state.is_final_hit:
		# Final hit: quick burst forward
		curve.add_point(Vector2(0.2, 0.6))
		curve.add_point(Vector2(0.5, 0.9))
		curve.add_point(Vector2(1, 1))
	else:
		# Regular hits: quick burst
		curve.add_point(Vector2(0.3, 0.7))
		curve.add_point(Vector2(1, 1))
	state.step_curve = curve
	
	return state

func _get_state_name(combo_name: String, index: int) -> String:
	return "%s_slash_%d" % [combo_name, index]

func _setup_block_state():
	## Register the blocking state with the state machine
	if not state_machine:
		return
	
	# Check if blocking state already exists
	if state_machine.has_state("melee_block"):
		return
	
	# Create and register blocking state
	var block_state = StateMeleeBlock.new()
	state_machine.add_state("melee_block", block_state)
#endregion

#region Combat Interface
func try_attack(combo_name: String = "saber_light") -> bool:
	## Try to start or continue a combo
	if _attack_cooldown_timer > 0:
		print("[MeleeComboController] try_attack BLOCKED: cooldown timer = %.3f" % _attack_cooldown_timer)
		return false

	if not _combos.has(combo_name):
		push_warning("[MeleeComboController] Unknown combo: ", combo_name)
		return false

	# Check if we can attack
	if equipment_manager:
		var melee = equipment_manager.get_current_melee_component()
		if not melee:
			print("[MeleeComboController] try_attack BLOCKED: no melee weapon component")
			return false  # No melee weapon equipped
	else:
		print("[MeleeComboController] try_attack BLOCKED: no equipment manager")
	
	# Determine which slash to perform
	var target_slash = 0
	
	if _current_combo == combo_name and _current_slash_index >= 0:
		# Continue combo
		target_slash = _current_slash_index + 1
		if target_slash >= _combos[combo_name].size():
			target_slash = 0  # Loop or restart
	
	# Start the attack state
	var state_name = _get_state_name(combo_name, target_slash)
	if state_machine and state_machine.has_state(state_name):
		_current_combo = combo_name
		_current_slash_index = target_slash
		_is_attacking = true
		_combo_reset_timer = combo_reset_time
		
		state_machine.change_state(state_name)
		
		if target_slash == 0:
			combo_started.emit(combo_name)
		slash_performed.emit(target_slash)
		
		return true
	
	return false

func on_slash_finished(slash_index: int):
	## Called by attack state when a slash completes
	_is_attacking = false
	_attack_cooldown_timer = attack_cooldown
	print("[MeleeComboController] on_slash_finished(%d) - cooldown set to %.3f" % [slash_index, attack_cooldown])

	# Check if combo completed
	if _current_combo != "" and slash_index >= _combos[_current_combo].size() - 1:
		combo_finished.emit(_current_combo, true)

func _reset_combo():
	var was_combo = _current_combo
	_current_combo = ""
	_current_slash_index = -1
	
	if was_combo != "":
		combo_reset.emit()

func cancel_combo():
	## Force cancel current combo (e.g., taking damage)
	if _current_combo != "":
		combo_finished.emit(_current_combo, false)
		_reset_combo()
	_is_attacking = false
#endregion

#region Query
func is_attacking() -> bool:
	return _is_attacking

func get_current_combo() -> String:
	return _current_combo

func get_current_slash() -> int:
	return _current_slash_index

func can_attack() -> bool:
	var result = _attack_cooldown_timer <= 0
	if not result:
		print("[MeleeComboController] can_attack() = FALSE, cooldown_timer=%.3f" % _attack_cooldown_timer)
	return result
#endregion

