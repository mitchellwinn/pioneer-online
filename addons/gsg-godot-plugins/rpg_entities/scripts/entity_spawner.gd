extends Marker
class_name EntitySpawner

# Entity spawning configuration
@export_group("Spawn Configuration")
## List of entity nodes to spawn from (drag entities from scene tree that are children of this spawner)
@export var spawn_prefabs: Array[Node] = []
## Spawn weight for each prefab (higher = more likely). Automatically resized to match spawn_prefabs.
@export var spawn_weights: Array[int] = []
## Radius around spawner to spawn entities
@export var spawn_radius: float = 5.0
## Maximum number of entities that can be spawned total (-1 for unlimited)
@export var max_total_spawns: int = -1
## Maximum number of entities that can be active at once (-1 for unlimited)
@export var max_active_spawns: int = 1
## Time between spawn attempts in seconds
@export var spawn_interval: float = 5.0
## Flag key to check in GameManager - if this flag exists and is true, spawner is disabled
@export var disable_flag: String = ""

# Spawn tracking
var spawned_count: int = 0 # Total entities spawned
var active_spawns: Array = [] # Currently active spawned entities
var spawn_timer: float = 0.0
var is_active: bool = true

func _ready():
	super._ready()
	
	# Validate spawn configuration
	if spawn_prefabs.is_empty():
		push_warning("[ENTITY_SPAWNER] No spawn prefabs configured for ", entity_id)
		is_active = false
		return
	
	# Auto-resize spawn_weights to match spawn_prefabs
	while spawn_weights.size() < spawn_prefabs.size():
		spawn_weights.append(1) # Default weight of 1
	while spawn_weights.size() > spawn_prefabs.size():
		spawn_weights.pop_back()
	
	# Deactivate prefab entities so only spawned ones are active
	for prefab in spawn_prefabs:
		if is_instance_valid(prefab):
			prefab.visible = false
			prefab.process_mode = Node.PROCESS_MODE_DISABLED
			# Disable collision for prefabs
			if prefab.has_method("set_collision_layer_value"):
				prefab.set_collision_layer_value(1, false)
			if prefab.has_method("set_collision_mask_value"):
				prefab.set_collision_mask_value(1, false)
	
	# Check if spawner should be disabled by flag
	if disable_flag != "":
		_check_disable_flag()

func _physics_process(delta):
	if not is_active:
		return
	
	# Check disable flag periodically
	if disable_flag != "":
		_check_disable_flag()
		if not is_active:
			return
	
	# Clean up invalid active spawns
	_cleanup_active_spawns()
	
	# Check if we can spawn
	if _can_spawn():
		spawn_timer += delta
		if spawn_timer >= spawn_interval:
			spawn_timer = 0.0
			_attempt_spawn()

func _check_disable_flag():
	# Check if the disable flag is set in GameManager
	var flag_value = GameManager.get_flag(disable_flag)
	if flag_value == "true" or flag_value == true:
		is_active = false
		# Despawn all active entities
		_despawn_all()

func _can_spawn() -> bool:
	# Check if battle is active or transitioning - don't spawn enemies during battle
	if BattleManager.in_battle or BattleManager.is_transitioning_to_battle:
		return false
		
	# Check if max total spawns reached
	if max_total_spawns >= 0 and spawned_count >= max_total_spawns:
		return false
	
	# Check if max active spawns reached
	if max_active_spawns >= 0 and active_spawns.size() >= max_active_spawns:
		return false
	
	return true

func _attempt_spawn():
	# Select a prefab based on spawn chances
	var prefab = _select_random_prefab()
	if not is_instance_valid(prefab):
		push_warning("[ENTITY_SPAWNER] Invalid prefab selected")
		return
	
	# Find a valid spawn position on navmesh
	var spawn_pos = _find_valid_spawn_position()
	if spawn_pos == null:
		push_warning("[ENTITY_SPAWNER] Could not find valid spawn position")
		return
	
	# Spawn the entity
	var spawned_entity = _spawn_entity(prefab, spawn_pos)
	if spawned_entity:
		active_spawns.append(spawned_entity)
		spawned_count += 1
		print("[ENTITY_SPAWNER] Spawned ", prefab.entity_id, " at ", spawn_pos, " (Total: ", spawned_count, ", Active: ", active_spawns.size(), ")")

func _select_random_prefab():
	if spawn_prefabs.is_empty():
		return null
	
	# Calculate total weight
	var total_weight = 0
	for weight in spawn_weights:
		total_weight += weight
	
	if total_weight <= 0:
		# If all weights are 0, pick randomly
		return spawn_prefabs[randi() % spawn_prefabs.size()]
	
	# Roll random value between 0 and total_weight
	var roll = randi() % total_weight
	var cumulative_weight = 0
	
	# Find which prefab this roll corresponds to
	for i in range(spawn_prefabs.size()):
		cumulative_weight += spawn_weights[i]
		if roll < cumulative_weight:
			return spawn_prefabs[i]
	
	# Fallback to last prefab
	return spawn_prefabs[spawn_prefabs.size() - 1]

func _find_valid_spawn_position():
	# Try multiple times to find a valid position
	var max_attempts = 10
	for attempt in range(max_attempts):
		# Generate random position in spawn radius
		var random_offset = Vector3(
			randf_range(-spawn_radius, spawn_radius),
			0,
			randf_range(-spawn_radius, spawn_radius)
		)
		var target_pos = global_position + random_offset
		
		# Raycast from above to find actual ground level
		var space_state = get_world_3d().direct_space_state
		var ray_start = target_pos + Vector3(0, 50, 0) # Start 50 units above
		var ray_end = target_pos + Vector3(0, -50, 0) # End 50 units below
		
		var query = PhysicsRayQueryParameters3D.create(ray_start, ray_end)
		query.collision_mask = 1 # Only hit layer 1 (ground)
		var result = space_state.intersect_ray(query)
		
		if result:
			# Found ground, now validate it's on navmesh
			var ground_pos = result.position
			var nav_map = get_world_3d().navigation_map
			var closest_point = NavigationServer3D.map_get_closest_point(nav_map, ground_pos)
			
			# Check if the navmesh point is within acceptable distance horizontally
			var horizontal_dist = Vector2(ground_pos.x - closest_point.x, ground_pos.z - closest_point.z).length()
			if horizontal_dist <= 2.0:
				# Check spawn point is not too far above spawner (max 2 units)
				if closest_point.y - global_position.y > 2.0:
					continue # Abandon this point, try another
				# Valid position found on navmesh
				return closest_point
	
	# Failed to find valid position
	return null

func _spawn_entity(prefab, spawn_position: Vector3):
	# Duplicate the prefab with all children (deep copy, including scripts)
	# 1 = DUPLICATE_GROUPS, 2 = DUPLICATE_SIGNALS, 4 = DUPLICATE_USE_INSTANTIATION, 8 = DUPLICATE_SCRIPTS
	var spawned = prefab.duplicate(15)
	if not is_instance_valid(spawned):
		return null
	
	# Generate unique entity ID (only if spawned has entity_id like Entity/Marker/NPC)
	var unique_id = entity_id + "_spawn_" + str(spawned_count)
	if "entity_id" in spawned:
		spawned.entity_id = unique_id
	else:
		push_warning("[ENTITY_SPAWNER] Spawned prefab has no entity_id property (base type: " + str(spawned.get_class()) + ")")
	
	# Add to scene
	get_parent().add_child(spawned)
	spawned.global_position = spawn_position
	
	# Make sure it's visible and active
	spawned.visible = true
	spawned.process_mode = Node.PROCESS_MODE_INHERIT
	
	# Re-enable collision
	if spawned.has_method("set_collision_layer_value"):
		spawned.set_collision_layer_value(1, true)
	if spawned.has_method("set_collision_mask_value"):
		spawned.set_collision_mask_value(1, true)
	
	# Explicitly copy dialogue and troop since DUPLICATE_SCRIPTS doesn't always copy exported properties
	if "dialogue" in prefab:
		spawned.dialogue = prefab.dialogue
		print("[ENTITY_SPAWNER] Copied dialogue: ", spawned.dialogue)
	if "troop" in prefab:
		spawned.troop = prefab.troop
		print("[ENTITY_SPAWNER] Copied troop: ", spawned.troop)
	
	return spawned

func _cleanup_active_spawns():
	# Remove invalid or freed entities from active spawns list
	var to_remove: Array[int] = []
	for i in range(active_spawns.size()):
		if not is_instance_valid(active_spawns[i]) or active_spawns[i].is_queued_for_deletion():
			to_remove.append(i)
	
	# Remove in reverse order to maintain indices
	to_remove.reverse()
	for i in to_remove:
		active_spawns.remove_at(i)

func _despawn_all():
	# Queue all active spawns for deletion
	for entity in active_spawns:
		if is_instance_valid(entity):
			entity.queue_free()
	active_spawns.clear()

# Public API
func enable_spawner():
	is_active = true
	spawn_timer = 0.0

func disable_spawner():
	is_active = false

func clear_spawns():
	_despawn_all()
	spawned_count = 0

func reset_spawner():
	clear_spawns()
	spawn_timer = 0.0
	is_active = true
