extends NPCStateWander
class_name NPCStatePatrol

# Patrol state - wanders around and detects entities in range
# Switches to aggro when player or party member is detected

# Detection parameters
@export var run_detection_radius: float = 3.0 # Radius for detecting running entities
@export var walk_detection_radius: float = 1.5 # Radius for detecting walking entities
@export var fov_angle: float = 90.0 # Field of view cone angle in degrees
@export var fov_scan_speed: float = 2.0 # How fast the FOV ray scans (radians per second)
@export var detection_chance: float = 0.05 # Chance per frame to detect (0.0 to 1.0)

# FOV scanning
var fov_current_angle: float = 0.0
var fov_scan_direction: int = 1 # 1 for right, -1 for left
var fov_raycast: RayCast3D

# Detection areas
var run_area: Area3D
var walk_area: Area3D
var entities_in_run_range: Array = []
var entities_in_walk_range: Array = []

# Target tracking
var detected_target = null
var is_transitioning_to_aggro: bool = false

func on_start():
	super.on_start()
	
	# Reset transition flag
	is_transitioning_to_aggro = false
	
	# Create FOV raycast
	fov_raycast = RayCast3D.new()
	fov_raycast.enabled = true
	fov_raycast.collision_mask = 0b010 # Layer 2 (player only)
	fov_raycast.target_position = Vector3(0, 0, -5) # Will be updated each frame
	npc.add_child(fov_raycast)
	
	fov_current_angle = -deg_to_rad(fov_angle / 2.0)
	
	# Create run detection area
	run_area = Area3D.new()
	run_area.collision_layer = 0
	run_area.collision_mask = 0b010 # Layer 2 (player only)
	run_area.monitoring = true
	run_area.body_entered.connect(_on_run_area_entered)
	run_area.body_exited.connect(_on_run_area_exited)
	var run_shape = CollisionShape3D.new()
	var run_sphere = SphereShape3D.new()
	run_sphere.radius = run_detection_radius
	run_shape.shape = run_sphere
	run_area.add_child(run_shape)
	npc.add_child(run_area)
	
	# Create walk detection area
	walk_area = Area3D.new()
	walk_area.collision_layer = 0
	walk_area.collision_mask = 0b010 # Layer 2 (player only)
	walk_area.monitoring = true
	walk_area.body_entered.connect(_on_walk_area_entered)
	walk_area.body_exited.connect(_on_walk_area_exited)
	var walk_shape = CollisionShape3D.new()
	var walk_sphere = SphereShape3D.new()
	walk_sphere.radius = walk_detection_radius
	walk_shape.shape = walk_sphere
	walk_area.add_child(walk_shape)
	npc.add_child(walk_area)
	
	print("[PATROL] Started patrol for: ", npc.entity_id)

func on_end():
	super.on_end()
	
	# Clean up raycast
	if fov_raycast:
		fov_raycast.queue_free()
		fov_raycast = null
	
	# Clean up detection areas
	if run_area:
		run_area.queue_free()
		run_area = null
	if walk_area:
		walk_area.queue_free()
		walk_area = null
	
	entities_in_run_range.clear()
	entities_in_walk_range.clear()
	detected_target = null

func on_physics_process(delta: float):
	# Don't process if we're not the active state
	if npc.state_manager and npc.state_manager.current_state != self:
		return
	
	# Don't process if already transitioning
	if is_transitioning_to_aggro:
		return
	
	# Don't detect targets if dialogue is open or battle is in progress
	if (DialogueManager and DialogueManager.is_open) or (BattleManager and BattleManager.in_battle):
		return
	
	# Call parent wander behavior
	super.on_physics_process(delta)
	
	# Scan for targets
	_update_fov_scan(delta)
	_check_proximity_detection()
	
	# If we detected something, do excited jump then switch to aggro
	if detected_target:
		is_transitioning_to_aggro = true
		print("[PATROL] Target detected! Playing excited jump motion")
		# Stop movement during the motion
		if npc.is_navigating:
			npc.stop_navigation()
		
		# Play excited jump motion and wait for it to complete
		await play_motion("excited_jump")
		
		print("[PATROL] Motion complete! Switching to aggro")
		# Pass the target to aggro state before switching
		if state_manager.states.has("aggro"):
			var aggro_state = state_manager.states["aggro"]
			aggro_state.target = detected_target
		state_manager.change_state("aggro")

func _update_fov_scan(delta: float):
	if not fov_raycast or not npc:
		return
	
	# Update scan angle
	fov_current_angle += fov_scan_speed * delta * fov_scan_direction
	
	# Reverse direction at FOV boundaries
	var half_fov = deg_to_rad(fov_angle / 2.0)
	if fov_current_angle > half_fov:
		fov_current_angle = half_fov
		fov_scan_direction = -1
	elif fov_current_angle < -half_fov:
		fov_current_angle = -half_fov
		fov_scan_direction = 1
	
	# Get NPC's forward direction (based on their current facing)
	var forward = Vector3.FORWARD
	if npc.direction.length() > 0.01:
		forward = npc.direction.normalized()
	elif npc.last_direction.length() > 0.01:
		forward = npc.last_direction.normalized()
	
	# Rotate forward by scan angle
	var scan_direction = forward.rotated(Vector3.UP, fov_current_angle)
	
	# Update raycast direction
	fov_raycast.target_position = scan_direction * 5.0
	fov_raycast.global_position = npc.global_position + Vector3(0, 0.5, 0) # Eye height
	fov_raycast.force_raycast_update()
	
	# Check if ray hit something
	if fov_raycast.is_colliding():
		var collider = fov_raycast.get_collider()
		if _is_valid_target(collider):
			# Roll for detection
			if randf() < detection_chance:
				detected_target = collider
				print("[PATROL] FOV detected target: ", collider.name)

func _check_proximity_detection():
	# Check entities in run range (higher priority)
	for entity in entities_in_run_range:
		if not is_instance_valid(entity) or entity == npc:
			continue
		
		if entity is Entity and entity.is_running:
			# Roll for detection
			if randf() < detection_chance:
				detected_target = entity
				print("[PATROL] Detected running target: ", entity.name)
				return
	
	# Check entities in walk range
	for entity in entities_in_walk_range:
		if not is_instance_valid(entity) or entity == npc:
			continue
		
		if entity is Entity:
			# Roll for detection
			if randf() < detection_chance:
				detected_target = entity
				print("[PATROL] Detected walking target: ", entity.name)
				return

func _on_run_area_entered(body):
	if body is Entity and body != npc:
		if not entities_in_run_range.has(body):
			entities_in_run_range.append(body)

func _on_run_area_exited(body):
	if body in entities_in_run_range:
		entities_in_run_range.erase(body)

func _on_walk_area_entered(body):
	if body is Entity and body != npc:
		if not entities_in_walk_range.has(body):
			entities_in_walk_range.append(body)

func _on_walk_area_exited(body):
	if body in entities_in_walk_range:
		entities_in_walk_range.erase(body)

func _is_valid_target(target) -> bool:
	if not target:
		return false
	
	# Check if it's an entity on player layer only
	if target is Entity:
		if target.collision_layer & 0b010: # Layer 2 (player)
			return true
	
	return false



