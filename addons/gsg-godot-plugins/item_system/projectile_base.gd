extends Area3D
class_name ProjectileBase

## Base class for all projectiles (bullets, missiles, grenades, etc.)
## Handles: collision detection, server-authoritative hits, damage/knockback/hitstun
## Extend this class for specific projectile behaviors (homing, bouncing, explosive, etc.)

#region Configuration
@export_group("Projectile Stats")
@export var speed: float = 100.0
@export var damage: float = 20.0
@export var damage_type: String = "projectile"
@export var lifetime: float = 5.0
@export var arm_time: float = 0.0  # Time before projectile can hit (0 = immediate)

@export_group("Impact Effects")
@export var knockback_force: float = 2.0
@export var hitstun_duration: float = 0.15
@export var impact_effect: PackedScene  # Spawn on hit
@export var impact_sound: String = ""  # Sound to play on impact (e.g. "res://sounds/explosion_1")

@export_group("Physics")
@export var use_gravity: bool = false
@export var gravity_scale: float = 1.0
@export var drag: float = 0.0  # Air resistance (0 = none)

@export_group("Collision")
@export var collision_mask_layers: int = 7  # Environment (1) + Players (2) + Enemies (4)
@export var destroy_on_hit: bool = true
@export var max_bounces: int = 0  # 0 = no bouncing
@export var bounce_energy_loss: float = 0.3  # How much speed is lost per bounce

@export_group("Debug")
@export var debug_projectile: bool = false
#endregion

#region Runtime State
var velocity: Vector3 = Vector3.ZERO
var owner_entity: Node = null
var _lifetime_timer: float = 0.0
var _armed: bool = false
var _destroyed: bool = false
var _bounce_count: int = 0
#endregion

func _ready():
	# Connect signals
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	
	# Set collision layers
	collision_layer = 4  # Projectiles layer
	collision_mask = collision_mask_layers
	monitoring = true
	monitorable = true
	
	# Set projectile metadata for bone hitbox system
	_update_projectile_meta()
	
	# Call subclass ready
	_on_projectile_ready()

func _physics_process(delta: float):
	if _destroyed:
		return
	
	var old_pos = global_position
	
	# Apply gravity if enabled
	if use_gravity:
		velocity.y -= 9.8 * gravity_scale * delta
	
	# Apply drag
	if drag > 0:
		velocity = velocity * (1.0 - drag * delta)
	
	# Let subclass modify velocity (for homing, etc.)
	velocity = _update_velocity(delta, velocity)
	
	# Move projectile
	global_position += velocity * delta
	
	# Update rotation to face velocity direction
	if velocity.length() > 0.1:
		_update_rotation()
	
	# Lifetime
	_lifetime_timer += delta
	
	if not _armed and _lifetime_timer >= arm_time:
		_armed = true
		# If armed immediately (arm_time = 0), do initial raycast from spawn
		if arm_time <= 0.0:
			_check_raycast_collision(old_pos, global_position)
		_on_armed()
	
	if _lifetime_timer >= lifetime:
		_on_lifetime_expired()
		_destroy()
		return
	
	# Raycast for fast-moving collision detection (prevents tunneling)
	if _armed and velocity.length() > 10.0:
		_check_raycast_collision(old_pos, global_position)
	
	# Subclass physics update
	_on_physics_update(delta)

#region Collision Handling
func _on_body_entered(body: Node3D):
	if debug_projectile:
		print("[%s] body_entered: %s (armed=%s)" % [name, body.name, _armed])
	
	if _destroyed or not _armed:
		return
	if _is_owner(body):
		return
	
	_handle_hit(body, global_position, Vector3.UP)

func _on_area_entered(area: Area3D):
	if _destroyed or not _armed:
		return
	if _is_owner(area) or _is_owner(area.get_parent()):
		return
	
	# Hit a bone hitbox - let bone system handle damage
	if area.has_meta("bone_name"):
		_on_bone_hitbox_hit(area)
		if destroy_on_hit:
			_destroy()
		return
	
	# Custom area handling
	_on_area_hit(area)

func _check_raycast_collision(from: Vector3, to: Vector3):
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.exclude = [self]
	if owner_entity and owner_entity is CollisionObject3D:
		query.exclude.append(owner_entity.get_rid())
	
	var result = space_state.intersect_ray(query)
	if result:
		var hit_body = result.collider
		if hit_body and not _is_owner(hit_body):
			global_position = result.position
			_handle_hit(hit_body, result.position, result.normal)

func _handle_hit(body: Node, hit_pos: Vector3, hit_normal: Vector3):
	if debug_projectile:
		print("[%s] Hit: %s at %s" % [name, body.name, hit_pos])
	
	# Check for bounce
	if max_bounces > 0 and _bounce_count < max_bounces:
		if _try_bounce(hit_normal):
			return
	
	# Apply hit effects
	_apply_hit_effects(body, hit_pos)
	
	# Spawn impact effect
	_spawn_impact_effect(hit_pos, hit_normal)
	
	# Subclass hit handling
	_on_hit(body, hit_pos, hit_normal)
	
	if destroy_on_hit:
		_destroy()

func _try_bounce(normal: Vector3) -> bool:
	## Attempt to bounce off surface. Returns true if bounced.
	if normal.length_squared() < 0.01:
		return false
	
	velocity = velocity.bounce(normal) * (1.0 - bounce_energy_loss)
	_bounce_count += 1
	
	if debug_projectile:
		print("[%s] Bounced! (%d/%d)" % [name, _bounce_count, max_bounces])
	
	_on_bounce(normal)
	return true

func _apply_hit_effects(body: Node, hit_pos: Vector3):
	## Apply damage, knockback, hitstun - uses server-authoritative system in multiplayer
	var kb_dir = velocity.normalized() if velocity.length() > 0.1 else Vector3.FORWARD
	
	# Check if we're in multiplayer client mode
	var network = get_node_or_null("/root/NetworkManager")
	if network and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		# Client: Send hit request to server
		var target_id = body.get_instance_id()
		if body.has_method("get_network_id"):
			target_id = body.get_network_id()
		
		var hit_data = {
			"target_id": target_id,
			"target_name": body.name,
			"damage": damage,
			"damage_type": damage_type,
			"knockback_force": knockback_force,
			"knockback_direction": kb_dir,
			"hitstun_duration": hitstun_duration,
			"hit_position": hit_pos
		}
		network.request_projectile_hit(hit_data)
		
		if debug_projectile:
			print("[%s] Sent hit request to server for %s" % [name, body.name])
		
		# Note: No hitlag for projectiles - it feels weird to freeze the shooter
		return
	
	# Server or singleplayer: Apply directly
	if body.has_method("take_damage"):
		body.take_damage(damage, owner_entity, damage_type)
		if debug_projectile:
			print("[%s] Applied %.1f damage to %s" % [name, damage, body.name])
	
	if body.has_method("apply_knockback") and knockback_force > 0:
		body.apply_knockback(kb_dir * knockback_force)
	
	if body.has_method("apply_hitstun") and hitstun_duration > 0:
		body.apply_hitstun(hitstun_duration)
	
	# Note: No hitlag for projectiles - melee weapons handle their own hitlag

func _apply_local_hitlag(body: Node):
	## Apply hitlag to attacker for hit feedback
	if not owner_entity:
		return
	if not body.has_method("get_hitlag_duration"):
		return
	
	var should_hitlag = true
	if body.has_method("should_apply_hitlag_for_type"):
		should_hitlag = body.should_apply_hitlag_for_type(damage_type)
	
	if should_hitlag and owner_entity.has_method("apply_hitlag_freeze"):
		owner_entity.apply_hitlag_freeze(body.get_hitlag_duration())

func _spawn_impact_effect(pos: Vector3, _normal: Vector3):
	# Spawn visual effect - effect handles its own billboard/camera facing
	if impact_effect:
		var scene_root = get_tree().current_scene
		if scene_root:
			var effect = impact_effect.instantiate()
			scene_root.add_child(effect)
			effect.global_position = pos
	
	# Play impact sound
	if not impact_sound.is_empty():
		var sound_manager = get_node_or_null("/root/SoundManager")
		if sound_manager and sound_manager.has_method("play_sound_3d"):
			sound_manager.play_sound_3d(impact_sound + ".wav", pos)
#endregion

#region Utility
func _is_owner(node: Node) -> bool:
	if node == null:
		return false
	if node == owner_entity:
		return true
	return _is_owner(node.get_parent())

func _update_rotation():
	## Update projectile rotation to face velocity direction
	var target = global_position + velocity.normalized()
	look_at(target, Vector3.UP)

func _update_projectile_meta():
	## Set metadata for bone hitbox system
	set_meta("projectile_data", {
		"damage": damage,
		"damage_type": damage_type,
		"velocity": velocity,
		"owner": owner_entity,
		"knockback_force": knockback_force,
		"knockback_direction": velocity.normalized() if velocity.length() > 0 else Vector3.FORWARD,
		"hitstun_duration": hitstun_duration,
		"hit_direction": velocity.normalized() if velocity.length() > 0 else Vector3.FORWARD
	})

func _destroy():
	if _destroyed:
		return
	_destroyed = true
	_on_destroyed()
	queue_free()
#endregion

#region Public API
func initialize(vel: Vector3, dmg: float, dmg_type: String, owner: Node, kb_force: float = -1.0, hs_duration: float = -1.0):
	## Initialize projectile with firing parameters
	velocity = vel
	damage = dmg
	damage_type = dmg_type
	owner_entity = owner
	
	if kb_force >= 0:
		knockback_force = kb_force
	if hs_duration >= 0:
		hitstun_duration = hs_duration
	
	_update_projectile_meta()
	_update_rotation()
	
	_on_initialized()

func set_target(target_node: Node3D):
	## Set a target for homing projectiles (override _update_velocity to use)
	set_meta("target", target_node)

func get_target() -> Node3D:
	return get_meta("target", null)
#endregion

#region Virtual Methods (Override in subclasses)
func _on_projectile_ready():
	## Called after base _ready() - override for subclass setup
	pass

func _on_initialized():
	## Called after initialize() - override for post-init logic
	pass

func _on_armed():
	## Called when projectile becomes armed (can hit things)
	pass

func _update_velocity(_delta: float, current_velocity: Vector3) -> Vector3:
	## Override to modify velocity each frame (for homing, spiral, etc.)
	## Return the new velocity
	return current_velocity

func _on_physics_update(_delta: float):
	## Called each physics frame - override for custom behavior
	pass

func _on_hit(_body: Node, _hit_pos: Vector3, _hit_normal: Vector3):
	## Called when hitting something - override for custom hit logic
	pass

func _on_bounce(_normal: Vector3):
	## Called when bouncing - override for bounce effects
	pass

func _on_bone_hitbox_hit(_area: Area3D):
	## Called when hitting a bone hitbox
	pass

func _on_area_hit(_area: Area3D):
	## Called when hitting a non-bone area
	pass

func _on_lifetime_expired():
	## Called when lifetime runs out - override for timeout behavior (explode, etc.)
	pass

func _on_destroyed():
	## Called just before queue_free - override for cleanup
	pass
#endregion

