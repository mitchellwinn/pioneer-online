extends ProjectileBase
class_name ProjectileHoming

## Homing projectile that tracks a target
## Great for heat-seeking missiles, guided rockets, etc.

@export_group("Homing Settings")
@export var turn_speed: float = 5.0  # How fast it can turn (radians/sec)
@export var lock_on_range: float = 50.0  # Max range to acquire target
@export var lock_on_angle: float = 45.0  # Cone angle to acquire target (degrees)
@export var lose_lock_range: float = 100.0  # Range at which lock is lost
@export var acceleration: float = 20.0  # Speed increase per second
@export var max_speed: float = 80.0  # Maximum velocity

@export_group("Acquisition")
@export var auto_acquire: bool = true  # Automatically find nearest target
@export var target_groups: Array[String] = ["enemies", "players"]  # Groups to target
@export var acquire_delay: float = 0.3  # Delay before homing kicks in

var _acquire_timer: float = 0.0
var _has_lock: bool = false

func _on_projectile_ready():
	# Missiles usually use gravity for realistic arc
	use_gravity = false
	
func _on_initialized():
	_acquire_timer = 0.0
	_has_lock = get_target() != null

func _update_velocity(delta: float, current_velocity: Vector3) -> Vector3:
	# Delay before homing activates
	_acquire_timer += delta
	if _acquire_timer < acquire_delay:
		return current_velocity
	
	# Try to acquire target if we don't have one
	var target = get_target()
	if not target or not is_instance_valid(target):
		if auto_acquire:
			target = _find_best_target()
			if target:
				set_target(target)
				_has_lock = true
				if debug_projectile:
					print("[%s] Acquired target: %s" % [name, target.name])
	
	if not target or not is_instance_valid(target):
		_has_lock = false
		# No target - just accelerate forward
		var speed = current_velocity.length()
		speed = min(speed + acceleration * delta, max_speed)
		return current_velocity.normalized() * speed
	
	# Check if we lost lock (target too far)
	var distance = global_position.distance_to(target.global_position)
	if distance > lose_lock_range:
		_has_lock = false
		set_meta("target", null)
		if debug_projectile:
			print("[%s] Lost lock - target too far" % name)
		return current_velocity
	
	# Calculate direction to target
	var target_pos = target.global_position
	if target.has_method("get_center_position"):
		target_pos = target.get_center_position()
	elif "global_position" in target:
		# Aim slightly above ground level
		target_pos = target.global_position + Vector3.UP * 0.5
	
	var to_target = (target_pos - global_position).normalized()
	var current_dir = current_velocity.normalized()
	
	# Smoothly rotate toward target
	var new_dir = current_dir.lerp(to_target, turn_speed * delta).normalized()
	
	# Accelerate
	var speed = current_velocity.length()
	speed = min(speed + acceleration * delta, max_speed)
	
	return new_dir * speed

func _find_best_target() -> Node3D:
	## Find the best target within lock-on cone
	var best_target: Node3D = null
	var best_score: float = -1.0
	
	var forward = velocity.normalized() if velocity.length() > 0.1 else -global_transform.basis.z
	var lock_angle_rad = deg_to_rad(lock_on_angle)
	
	for group in target_groups:
		for node in get_tree().get_nodes_in_group(group):
			if not node is Node3D:
				continue
			if node == owner_entity:
				continue
			
			var target_pos = node.global_position
			var to_target = target_pos - global_position
			var distance = to_target.length()
			
			# Check range
			if distance > lock_on_range:
				continue
			
			# Check angle
			var angle = forward.angle_to(to_target.normalized())
			if angle > lock_angle_rad:
				continue
			
			# Score based on angle and distance (prefer centered and close)
			var angle_score = 1.0 - (angle / lock_angle_rad)
			var dist_score = 1.0 - (distance / lock_on_range)
			var score = angle_score * 0.7 + dist_score * 0.3
			
			if score > best_score:
				best_score = score
				best_target = node
	
	return best_target

func _on_hit(body: Node, hit_pos: Vector3, _hit_normal: Vector3):
	# Missiles often explode on impact
	if debug_projectile:
		print("[%s] IMPACT on %s!" % [name, body.name])

func _on_lifetime_expired():
	# Could explode when running out of fuel
	if debug_projectile:
		print("[%s] Fuel exhausted!" % name)

func has_lock() -> bool:
	return _has_lock



