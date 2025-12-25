extends Node
class_name CombatComponent

## CombatComponent - Handles health, damage, and combat abilities
## Server-authoritative: all damage calculations happen on server

signal health_changed(current: float, maximum: float)
signal shield_changed(current: float, maximum: float)
signal damage_taken(amount: float, source: Node, damage_type: String)
signal healed(amount: float, source: Node)
signal died(killer: Node)
signal revived()
signal ability_used(ability_id: String)
signal ability_cooldown_started(ability_id: String, duration: float)
signal ability_cooldown_ended(ability_id: String)

#region Configuration
@export_group("Health")
@export var max_health: float = 100.0
@export var current_health: float = 100.0
@export var health_regen_rate: float = 0.0  # Per second
@export var health_regen_delay: float = 5.0  # Seconds after damage before regen starts

@export_group("Shields/Armor")
@export var max_shields: float = 0.0
@export var current_shields: float = 0.0
@export var shield_regen_rate: float = 5.0
@export var shield_regen_delay: float = 3.0

@export_group("Defense")
@export var armor: float = 0.0  # Flat damage reduction
@export var damage_resistance: float = 0.0  # Percentage (0-1)

@export_group("Damage Distribution")
## How much of projectile damage goes to shields vs HP (0 = all HP, 1 = all shields)
@export var small_projectile_shield_ratio: float = 0.2  # Small projectiles: mostly HP
@export var medium_projectile_shield_ratio: float = 0.5  # Medium: balanced
@export var large_projectile_shield_ratio: float = 0.8  # Large: mostly shields
@export var melee_shield_ratio: float = 0.1  # Melee: almost all HP
## Shield damage reduction - while shields are active, reduce HP damage by this percent
@export var shield_hp_protection: float = 0.3  # 30% HP damage reduction while shielded

@export_group("Combat State")
@export var is_invulnerable: bool = false
@export var is_dead: bool = false
@export var can_be_revived: bool = true
@export var revive_health_percent: float = 0.3
#endregion

#region Abilities
## Ability definitions: ability_id -> {cooldown, damage, range, etc.}
var abilities: Dictionary = {}
## Active cooldowns: ability_id -> time_remaining
var ability_cooldowns: Dictionary = {}
#endregion

#region Internal State
var parent_entity: Node3D = null
var network_identity: Node = null  # NetworkIdentity - untyped to avoid circular dependency
var time_since_damage: float = 999.0
var time_since_shield_damage: float = 999.0
#endregion

func _ready():
	parent_entity = get_parent() as Node3D
	
	# Find NetworkIdentity sibling
	for child in get_parent().get_children():
		if child.get_script() and child.get_script().get_global_name() == "NetworkIdentity":
			network_identity = child
			break
	
	# Initialize health
	current_health = max_health
	current_shields = max_shields

func _get_zone_peers() -> Array[int]:
	## Get peers in the same zone as this entity for zone-filtered RPCs
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_entity_zone_id") and parent_entity:
		var zone_id = network.get_entity_zone_id(parent_entity)
		if not zone_id.is_empty():
			return network.get_peers_in_zone(zone_id)
	return []

func _physics_process(delta: float):
	if is_dead:
		return
	
	# Update timers
	time_since_damage += delta
	time_since_shield_damage += delta
	
	# Health regeneration
	if health_regen_rate > 0 and time_since_damage >= health_regen_delay:
		if current_health < max_health:
			heal(health_regen_rate * delta, null, true)  # Silent regen
	
	# Shield regeneration
	if shield_regen_rate > 0 and time_since_shield_damage >= shield_regen_delay:
		if current_shields < max_shields:
			var old_shields = current_shields
			var regen = shield_regen_rate * delta
			current_shields = minf(current_shields + regen, max_shields)
			if current_shields != old_shields:
				shield_changed.emit(current_shields, max_shields)
	
	# Update ability cooldowns
	var completed_cooldowns: Array[String] = []
	for ability_id in ability_cooldowns:
		ability_cooldowns[ability_id] -= delta
		if ability_cooldowns[ability_id] <= 0:
			completed_cooldowns.append(ability_id)
	
	for ability_id in completed_cooldowns:
		ability_cooldowns.erase(ability_id)
		ability_cooldown_ended.emit(ability_id)

#region Health Management
func take_damage(amount: float, source: Node = null, damage_type: String = "normal", knockback_dir: Vector3 = Vector3.ZERO, knockback_force: float = 0.0) -> float:
	if is_dead or is_invulnerable:
		return 0.0
	
	# Only server should process damage in multiplayer
	if network_identity and not network_identity.is_local_authority:
		# Request damage from server
		_request_damage.rpc_id(1, amount, source.get_path() if source else "", damage_type)
		return 0.0
	
	var base_damage = _calculate_damage(amount, damage_type)
	
	# Distribute damage between shields and HP based on damage type
	var shield_ratio = _get_shield_ratio(damage_type)
	var shield_damage = base_damage * shield_ratio
	var hp_damage = base_damage * (1.0 - shield_ratio)
	
	# Apply to shields
	var actual_shield_damage: float = 0.0
	if current_shields > 0 and shield_damage > 0:
		actual_shield_damage = minf(shield_damage, current_shields)
		current_shields -= actual_shield_damage
		time_since_shield_damage = 0.0
		
		# Shield overflow goes to HP
		var shield_overflow = shield_damage - actual_shield_damage
		hp_damage += shield_overflow
	elif shield_damage > 0:
		# No shields, all shield damage goes to HP
		hp_damage += shield_damage
	
	# While shields are active, HP takes reduced damage
	var actual_hp_damage: float = 0.0
	if hp_damage > 0:
		if current_shields > 0:
			# Shields provide protection
			hp_damage *= (1.0 - shield_hp_protection)
		
		actual_hp_damage = hp_damage
		current_health -= actual_hp_damage
		time_since_damage = 0.0
	
	var total_damage = actual_shield_damage + actual_hp_damage
	
	if total_damage > 0:
		damage_taken.emit(total_damage, source, damage_type)
		health_changed.emit(current_health, max_health)
		shield_changed.emit(current_shields, max_shields)
		
		# Calculate knockback direction from source if not provided
		if knockback_dir.length_squared() < 0.01 and source and parent_entity:
			knockback_dir = (parent_entity.global_position - source.global_position).normalized()
			knockback_dir.y = 0.1  # Slight upward push
		
		# Apply hit feedback (knockback + flinch) with sync to clients
		if knockback_dir.length_squared() > 0.01 or total_damage >= 10.0:
			var effective_knockback = knockback_force if knockback_force > 0 else (total_damage * 0.1)
			apply_hit_feedback(knockback_dir, effective_knockback, total_damage)
		
		if current_health <= 0:
			current_health = 0
			_die(source)
	
	# Sync to clients in same zone
	if network_identity and multiplayer.is_server():
		var peers = _get_zone_peers()
		if peers.size() > 0:
			for peer_id in peers:
				if peer_id != 1:
					_sync_health.rpc_id(peer_id, current_health, current_shields)
		else:
			_sync_health.rpc(current_health, current_shields)  # Fallback
	
	return total_damage

func _get_shield_ratio(damage_type: String) -> float:
	## Get the shield/HP damage distribution ratio for a damage type
	## Higher = more damage to shields, Lower = more damage to HP
	match damage_type:
		"melee", "slash", "blunt":
			return melee_shield_ratio
		"projectile_small", "bullet_small", "energy_small":
			return small_projectile_shield_ratio
		"projectile_medium", "bullet_medium", "energy_medium":
			return medium_projectile_shield_ratio
		"projectile_large", "bullet_large", "energy_large", "explosive":
			return large_projectile_shield_ratio
		"true":
			return 0.5  # True damage splits evenly
		_:
			return medium_projectile_shield_ratio  # Default to balanced

func heal(amount: float, source: Node = null, silent: bool = false) -> float:
	if is_dead:
		return 0.0
	
	var actual_heal = minf(amount, max_health - current_health)
	current_health += actual_heal
	
	if not silent and actual_heal > 0:
		healed.emit(actual_heal, source)
		health_changed.emit(current_health, max_health)
	
	return actual_heal

func revive(health_percent: float = -1.0):
	if not is_dead or not can_be_revived:
		return
	
	is_dead = false
	
	if health_percent < 0:
		health_percent = revive_health_percent
	
	current_health = max_health * health_percent
	health_changed.emit(current_health, max_health)
	revived.emit()

func _calculate_damage(base_damage: float, damage_type: String) -> float:
	var damage = base_damage
	
	# Apply armor (flat reduction)
	damage = maxf(0, damage - armor)
	
	# Apply resistance (percentage reduction)
	damage *= (1.0 - damage_resistance)
	
	# Damage type modifiers could go here
	match damage_type:
		"true":
			damage = base_damage  # Ignores all defenses
		"fire", "ice", "electric":
			pass  # Could add elemental resistances
	
	return damage

func _die(killer: Node = null):
	is_dead = true
	died.emit(killer)

	# Sync death to clients in same zone
	if network_identity and multiplayer.is_server():
		var killer_path = killer.get_path() if killer else ""
		var peers = _get_zone_peers()
		if peers.size() > 0:
			for peer_id in peers:
				if peer_id != 1:
					_sync_death.rpc_id(peer_id, killer_path)
		else:
			_sync_death.rpc(killer_path)  # Fallback
#endregion

#region Abilities
func register_ability(ability_id: String, data: Dictionary):
	abilities[ability_id] = data

func can_use_ability(ability_id: String) -> bool:
	if not abilities.has(ability_id):
		return false
	if is_dead:
		return false
	if ability_cooldowns.has(ability_id):
		return false
	return true

func use_ability(ability_id: String, target: Variant = null) -> bool:
	if not can_use_ability(ability_id):
		return false
	
	var ability_data = abilities[ability_id]
	
	# Start cooldown
	if ability_data.has("cooldown"):
		ability_cooldowns[ability_id] = ability_data.cooldown
		ability_cooldown_started.emit(ability_id, ability_data.cooldown)
	
	ability_used.emit(ability_id)
	
	# Execute ability effect (override in subclass or connect to signal)
	return true

func get_ability_cooldown_remaining(ability_id: String) -> float:
	return ability_cooldowns.get(ability_id, 0.0)

func get_ability_cooldown_percent(ability_id: String) -> float:
	if not abilities.has(ability_id):
		return 0.0
	if not ability_cooldowns.has(ability_id):
		return 0.0
	var total = abilities[ability_id].get("cooldown", 1.0)
	return ability_cooldowns[ability_id] / total
#endregion

#region Network RPCs
@rpc("any_peer", "call_remote", "reliable")
func _request_damage(amount: float, source_path: String, damage_type: String):
	if not multiplayer.is_server():
		return
	
	var source = get_node_or_null(source_path) if source_path else null
	take_damage(amount, source, damage_type)

@rpc("authority", "call_remote", "reliable")
func _sync_health(health: float, shields: float):
	current_health = health
	current_shields = shields
	health_changed.emit(current_health, max_health)

@rpc("authority", "call_remote", "reliable")
func _sync_death(killer_path: String):
	is_dead = true
	var killer = get_node_or_null(killer_path) if killer_path else null
	died.emit(killer)

## Apply hit feedback (knockback + flinch + ragdoll reaction) - called after damage on server, synced to clients
func apply_hit_feedback(knockback_dir: Vector3, knockback_force: float, damage_amount: float, hit_bone: String = "", hit_position: Vector3 = Vector3.ZERO):
	## Apply knockback and flinch animation
	if parent_entity and knockback_force > 0:
		parent_entity.apply_knockback(knockback_dir * knockback_force)
	
	# Apply procedural hit reaction (active ragdoll) - scales with damage
	if parent_entity and parent_entity.has_method("apply_hit_reaction_at_position"):
		var impact_force = damage_amount * 0.5  # Scale impact with damage
		if hit_position.length_squared() > 0.01:
			parent_entity.apply_hit_reaction_at_position(hit_position, knockback_dir, impact_force)
		elif not hit_bone.is_empty():
			parent_entity.apply_hit_reaction(hit_bone, knockback_dir, impact_force)
		else:
			# Fallback - apply to spine
			parent_entity.apply_hit_reaction("spine_01.x", knockback_dir, impact_force)
	
	# Apply flinch/stagger animation if significant damage (fallback for non-ragdoll entities)
	if parent_entity and damage_amount >= 10.0:
		_apply_flinch_animation(knockback_dir)
	
	# Sync to clients in same zone
	if network_identity and multiplayer.is_server():
		var peers = _get_zone_peers()
		if peers.size() > 0:
			for peer_id in peers:
				if peer_id != 1:
					_sync_hit_feedback.rpc_id(peer_id, knockback_dir, knockback_force, damage_amount, hit_bone, hit_position)
		else:
			_sync_hit_feedback.rpc(knockback_dir, knockback_force, damage_amount, hit_bone, hit_position)  # Fallback

@rpc("authority", "call_remote", "unreliable")  # Unreliable for performance
func _sync_hit_feedback(knockback_dir: Vector3, knockback_force: float, damage_amount: float, hit_bone: String = "", hit_position: Vector3 = Vector3.ZERO):
	## Client receives hit feedback to apply visuals
	if multiplayer.is_server():
		return
	
	if parent_entity and knockback_force > 0:
		parent_entity.apply_knockback(knockback_dir * knockback_force)
	
	# Apply procedural hit reaction on clients too
	if parent_entity and parent_entity.has_method("apply_hit_reaction_at_position"):
		var impact_force = damage_amount * 0.5
		if hit_position.length_squared() > 0.01:
			parent_entity.apply_hit_reaction_at_position(hit_position, knockback_dir, impact_force)
		elif not hit_bone.is_empty():
			parent_entity.apply_hit_reaction(hit_bone, knockback_dir, impact_force)
		else:
			parent_entity.apply_hit_reaction("spine_01.x", knockback_dir, impact_force)
	
	if damage_amount >= 10.0:
		_apply_flinch_animation(knockback_dir)

var _flinch_tween: Tween = null
var _mesh_root_base_rotation: Vector3 = Vector3.ZERO
var _flinch_initialized: bool = false

func _apply_flinch_animation(hit_direction: Vector3):
	## Apply a quick flinch/stagger to the entity
	if not parent_entity:
		return
	
	# Find animation player or skeleton for flinch
	var anim_controller = parent_entity.get_node_or_null("PlayerAnimationController")
	if anim_controller and anim_controller.has_method("play_flinch"):
		anim_controller.play_flinch(hit_direction)
		return
	
	# Fallback: simple rotation jolt
	var mesh_root = parent_entity.get_node_or_null("MeshRoot")
	if mesh_root:
		# Store the TRUE original rotation on first flinch (not mid-flinch rotation)
		if not _flinch_initialized:
			_mesh_root_base_rotation = mesh_root.rotation
			_flinch_initialized = true
		
		# Kill any existing flinch tween to prevent stacking
		if _flinch_tween and _flinch_tween.is_valid():
			_flinch_tween.kill()
			# Reset to base rotation before starting new flinch
			mesh_root.rotation = _mesh_root_base_rotation
		
		_flinch_tween = parent_entity.create_tween()
		var flinch_rot = _mesh_root_base_rotation + Vector3(0.1, 0, 0)  # Flinch forward
		_flinch_tween.tween_property(mesh_root, "rotation", flinch_rot, 0.05)
		_flinch_tween.tween_property(mesh_root, "rotation", _mesh_root_base_rotation, 0.15)
#endregion

#region Utility
func get_health_percent() -> float:
	return current_health / max_health if max_health > 0 else 0.0

func get_shield_percent() -> float:
	return current_shields / max_shields if max_shields > 0 else 0.0

func is_full_health() -> bool:
	return current_health >= max_health

func is_alive() -> bool:
	return not is_dead
#endregion

