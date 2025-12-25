extends ProjectileBase
class_name ProjectileExplosive

## Explosive projectile (grenades, rockets, etc.)
## Can detonate on impact, timer, or proximity

enum DetonationMode {
	IMPACT,      # Explode on hit
	TIMER,       # Explode after fuse_time
	PROXIMITY,   # Explode when near enemy
	IMPACT_OR_TIMER  # Whichever comes first
}

@export_group("Explosion")
@export var explosion_radius: float = 5.0
@export var explosion_damage: float = 50.0
@export var explosion_knockback: float = 15.0
@export var explosion_effect: PackedScene
@export var detonation_mode: DetonationMode = DetonationMode.IMPACT

@export_group("Fuse (Timer Mode)")
@export var fuse_time: float = 3.0  # Time until explosion
@export var beep_sound: AudioStream  # Warning beep

@export_group("Proximity (Proximity Mode)")
@export var proximity_range: float = 2.0
@export var proximity_arm_delay: float = 0.5  # Delay before proximity active
@export var target_groups: Array[String] = ["enemies", "players"]

@export_group("Grenade Physics")
@export var throw_spin: bool = true  # Visual spin while flying

var _fuse_timer: float = 0.0
var _proximity_armed: bool = false
var _detonated: bool = false
var _spin_speed: float = 10.0

func _on_projectile_ready():
	# Grenades use gravity and bounce
	use_gravity = true
	gravity_scale = 1.0
	max_bounces = 3
	bounce_energy_loss = 0.4
	destroy_on_hit = (detonation_mode == DetonationMode.IMPACT)

func _on_physics_update(delta: float):
	_fuse_timer += delta
	
	# Visual spin
	if throw_spin and velocity.length() > 1.0:
		rotate_x(_spin_speed * delta)
	
	# Timer detonation
	if detonation_mode in [DetonationMode.TIMER, DetonationMode.IMPACT_OR_TIMER]:
		if _fuse_timer >= fuse_time:
			_detonate()
			return
	
	# Proximity detonation
	if detonation_mode == DetonationMode.PROXIMITY:
		if _fuse_timer >= proximity_arm_delay:
			_proximity_armed = true
		
		if _proximity_armed:
			var nearby = _find_nearby_targets()
			if nearby.size() > 0:
				_detonate()
				return

func _on_hit(body: Node, hit_pos: Vector3, hit_normal: Vector3):
	if detonation_mode in [DetonationMode.IMPACT, DetonationMode.IMPACT_OR_TIMER]:
		_detonate()

func _on_bounce(normal: Vector3):
	# Could play bounce sound here
	if debug_projectile:
		print("[%s] Bounced!" % name)

func _on_lifetime_expired():
	# Explode when lifetime ends (failsafe)
	_detonate()

func _detonate():
	if _detonated:
		return
	_detonated = true
	
	if debug_projectile:
		print("[%s] DETONATING at %s!" % [name, global_position])
	
	# Find all entities in explosion radius
	var targets = _find_targets_in_radius(explosion_radius)
	
	for target in targets:
		var distance = global_position.distance_to(target.global_position)
		var falloff = 1.0 - (distance / explosion_radius)
		falloff = clampf(falloff, 0.1, 1.0)  # Minimum 10% damage at edge
		
		var actual_damage = explosion_damage * falloff
		var actual_knockback = explosion_knockback * falloff
		
		# Direction away from explosion center
		var kb_dir = (target.global_position - global_position).normalized()
		if kb_dir.length() < 0.1:
			kb_dir = Vector3.UP
		kb_dir = (kb_dir + Vector3.UP * 0.3).normalized()  # Add upward component
		
		_apply_explosion_damage(target, actual_damage, actual_knockback, kb_dir)
	
	# Spawn explosion effect
	if explosion_effect:
		var effect = explosion_effect.instantiate()
		get_tree().current_scene.add_child(effect)
		effect.global_position = global_position
	
	_destroy()

func _find_targets_in_radius(radius: float) -> Array[Node3D]:
	var targets: Array[Node3D] = []
	
	for group in target_groups:
		for node in get_tree().get_nodes_in_group(group):
			if not node is Node3D:
				continue
			if node == owner_entity:
				continue
			
			var distance = global_position.distance_to(node.global_position)
			if distance <= radius:
				targets.append(node)
	
	# Also check for hittable group
	for node in get_tree().get_nodes_in_group("hittable"):
		if not node is Node3D:
			continue
		if node in targets:
			continue
		if node == owner_entity:
			continue
		
		var distance = global_position.distance_to(node.global_position)
		if distance <= radius:
			targets.append(node)
	
	return targets

func _find_nearby_targets() -> Array[Node3D]:
	return _find_targets_in_radius(proximity_range)

func _apply_explosion_damage(target: Node3D, dmg: float, kb: float, kb_dir: Vector3):
	## Apply explosion damage - server-authoritative in multiplayer
	var network = get_node_or_null("/root/NetworkManager")
	if network and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		# Client: Send to server
		var target_id = target.get_instance_id()
		if target.has_method("get_network_id"):
			target_id = target.get_network_id()
		
		var hit_data = {
			"target_id": target_id,
			"target_name": target.name,
			"damage": dmg,
			"damage_type": "explosion",
			"knockback_force": kb,
			"knockback_direction": kb_dir,
			"hitstun_duration": 0.3,
			"hit_position": global_position
		}
		network.request_projectile_hit(hit_data)
	else:
		# Server/singleplayer: Apply directly
		if target.has_method("take_damage"):
			target.take_damage(dmg, owner_entity, "explosion")
		
		if target.has_method("apply_knockback") and kb > 0:
			target.apply_knockback(kb_dir * kb)
		
		if target.has_method("apply_hitstun"):
			target.apply_hitstun(0.3)
	
	if debug_projectile:
		print("[%s] Explosion hit %s for %.1f damage" % [name, target.name, dmg])



