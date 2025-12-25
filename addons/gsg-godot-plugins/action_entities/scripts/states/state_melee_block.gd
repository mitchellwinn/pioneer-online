extends EntityState
class_name StateMeleeBlock

## StateMeleeBlock - Blocking state for melee weapons
## Held diagonally to cover body, reduces incoming damage
## Perfect parry within window staggers attacker

#region Configuration
@export_group("Block Settings")
## Damage reduction while blocking (0.7 = 70% reduction)
@export var damage_reduction: float = 0.7
## Stamina cost per second while blocking
@export var stamina_drain_per_second: float = 5.0
## Stamina cost when hit while blocking (scaled by damage)
@export var stamina_cost_per_damage: float = 0.5
## Minimum stamina cost per block
@export var min_stamina_cost: float = 10.0
## Stagger time if guard is broken
@export var guard_break_stagger: float = 1.0

@export_group("Parry Settings")
## Time window for perfect parry (seconds) - ~6 frames at 60fps
@export var parry_window: float = 0.1
## Knockback force applied to attacker on parry
@export var parry_knockback: float = 12.0
## Hitstun duration applied to attacker on parry
@export var parry_stagger_duration: float = 0.6
## Stamina RESTORED on successful parry
@export var parry_stamina_restore: float = 15.0

@export_group("Animation")
@export var block_animation: String = "Block"
@export var block_impact_animation: String = "BlockImpact"
@export var parry_animation: String = "ParrySuccess"
#endregion

#region Runtime State
var _melee_weapon = null  # MeleeWeaponComponent
var _equipment_manager: Node = null
var _bone_hitbox_system = null  # BoneHitboxSystem for block detection
var _is_blocking: bool = false
var _block_start_time: float = 0.0  # When block started (for parry window)
#endregion

func _init():
	allows_movement = false  # Blocking is a committed stance - no movement
	allows_rotation = true   # Can still turn to face threats
	can_be_interrupted = true
	priority = 5

func on_enter(previous_state = null):
	_equipment_manager = entity.get_node_or_null("EquipmentManager")
	if _equipment_manager:
		_melee_weapon = _equipment_manager.get_current_melee_component()
	
	# Find bone hitbox system for block detection
	_bone_hitbox_system = entity.get_node_or_null("BoneHitboxSystem")
	
	if not _melee_weapon:
		# No melee weapon - exit immediately
		complete()
		return
	
	_start_blocking()

func on_exit(next_state = null):
	_stop_blocking()

func on_physics_process(delta: float):
	# Remote players only update timers - no combat logic
	var is_remote = "_is_remote_player" in entity and entity._is_remote_player
	if is_remote:
		return

	# Check if block is still held
	if not Input.is_action_pressed("aim") and not Input.is_action_pressed("attack_secondary"):
		complete()
		return
	
	# Drain stamina
	if entity.has_method("consume_stamina"):
		if not entity.consume_stamina(stamina_drain_per_second * delta):
			# Out of stamina - guard broken
			_on_guard_broken()
			return
	
	# Check for movement to transition
	if entity.has_method("get_movement_input"):
		var input_dir = entity.get_movement_input()
		if input_dir.length() > 0.1:
			# Allow movement but stay in block state
			if entity.has_method("set_speed_multiplier"):
				entity.set_speed_multiplier(0.5)  # Move slower while blocking
	
	# Can attack while blocking (riposte) - but need to check if state exists
	if state_manager.consume_buffered_input("attack_primary"):
		# Exit block and attack
		if state_manager.has_state("saber_light_slash_0"):
			transition_to("saber_light_slash_0")
		else:
			complete()

func is_in_parry_window() -> bool:
	## Check if we're still in the parry window
	var current_time = Time.get_ticks_msec() / 1000.0
	return (current_time - _block_start_time) <= parry_window

func on_melee_blocked(attacker: Node, damage: float, hit_info: Dictionary = {}) -> Dictionary:
	## Called when a melee attack is blocked. Returns result info.
	## This is the main entry point for melee vs block interactions.
	if not _is_blocking:
		return {"blocked": false, "parried": false}
	
	var result = {
		"blocked": true,
		"parried": false,
		"damage_taken": 0.0,
		"guard_broken": false
	}
	
	# Check for perfect parry
	if is_in_parry_window():
		result["parried"] = true
		_on_parry_success(attacker, hit_info)
		return result
	
	# Regular block - costs stamina
	var stamina_cost = maxf(min_stamina_cost, damage * stamina_cost_per_damage)
	
	if entity.has_method("consume_stamina"):
		if not entity.consume_stamina(stamina_cost):
			# Guard broken!
			result["guard_broken"] = true
			result["damage_taken"] = damage  # Full damage on guard break
			_on_guard_broken()
			return result
	
	# Successful block - reduced damage
	var damage_through = damage * (1.0 - damage_reduction)
	result["damage_taken"] = damage_through
	
	# Apply chip damage
	if damage_through > 0 and entity.has_method("take_damage"):
		entity.take_damage(damage_through, attacker, "melee")
	
	# Regular block: No animation on defender (just holds block pose)
	# Small pushback on blocker
	if entity.has_method("apply_knockback"):
		var push_dir = hit_info.get("knockback_direction", Vector3.ZERO)
		if push_dir != Vector3.ZERO:
			entity.apply_knockback(push_dir * 3.0)  # Light pushback
	
	return result

func _on_parry_success(attacker: Node, hit_info: Dictionary):
	## Perfect parry! Punish the attacker (if melee) or reflect projectile
	var is_projectile_parry = (attacker == null)
	
	if is_projectile_parry:
		print("[StateMeleeBlock] PARRY! Reflected projectile!")
	else:
		print("[StateMeleeBlock] PARRY! Staggering attacker: ", attacker.name)
	
	# Restore stamina as reward
	if entity.has_method("restore_stamina"):
		entity.restore_stamina(parry_stamina_restore)
	
	# Play parry effect/animation
	if entity.has_method("play_animation"):
		entity.play_animation(parry_animation)
	
	# For projectile parries, we're done (projectile reflection handled by BoneHitboxSystem)
	if is_projectile_parry:
		return
	
	# Stagger the melee attacker
	if attacker:
		# Play BlockImpact animation on ATTACKER (they got parried/staggered)
		if attacker.has_method("play_animation"):
			attacker.play_animation(block_impact_animation)
		
		# Apply knockback to attacker (push them back)
		if attacker.has_method("apply_knockback"):
			var knockback_dir = -hit_info.get("knockback_direction", Vector3.ZERO)
			if knockback_dir == Vector3.ZERO:
				knockback_dir = (attacker.global_position - entity.global_position).normalized()
			attacker.apply_knockback(knockback_dir * parry_knockback)
		
		# Apply hitstun to attacker
		if attacker.has_method("apply_hitstun"):
			attacker.apply_hitstun(parry_stagger_duration)
		
		# Trigger recoil animation on attacker's weapon
		var attacker_equip = attacker.get_node_or_null("EquipmentManager")
		if attacker_equip and attacker_equip.has_method("trigger_weapon_recoil"):
			attacker_equip.trigger_weapon_recoil(0.5)  # Strong recoil
		
		# Cancel attacker's attack state and put them in stunned
		var attacker_state_mgr = attacker.get_node_or_null("StateManager")
		if attacker_state_mgr and attacker_state_mgr.has_method("change_state"):
			if attacker_state_mgr.has_state("stunned"):
				attacker_state_mgr.change_state("stunned", true)

func on_damage_taken(amount: float, source: Node):
	## Called for non-melee damage (bullets, etc.) - delegates to bone hitbox system
	## Melee damage goes through on_melee_blocked instead
	if not _is_blocking:
		return
	
	# For ranged attacks, just do stamina cost
	var stamina_cost = maxf(min_stamina_cost, amount * stamina_cost_per_damage)
	if entity.has_method("consume_stamina"):
		if not entity.consume_stamina(stamina_cost):
			_on_guard_broken()
			return
	
	# Play block impact feedback
	if entity.has_method("play_animation"):
		entity.play_animation(block_impact_animation)

func _start_blocking():
	_is_blocking = true
	_block_start_time = Time.get_ticks_msec() / 1000.0
	
	if _melee_weapon:
		_melee_weapon.start_block()
	
	# Tell bone hitbox system we're blocking (for combat detection)
	if _bone_hitbox_system and _bone_hitbox_system.has_method("set_blocking"):
		_bone_hitbox_system.set_blocking(true, _melee_weapon, self)
	
	# Play block animation (full body - no movement while blocking)
	if entity.has_method("play_animation"):
		entity.play_animation(block_animation)

func _stop_blocking():
	_is_blocking = false
	
	if _melee_weapon:
		_melee_weapon.stop_block()
	
	# Tell bone hitbox system we stopped blocking
	if _bone_hitbox_system and _bone_hitbox_system.has_method("set_blocking"):
		_bone_hitbox_system.set_blocking(false, null, null)

func _on_guard_broken():
	## Guard was broken - stagger the entity
	_stop_blocking()
	
	if state_manager.has_state("stunned"):
		transition_to("stunned", true)
	else:
		complete()

