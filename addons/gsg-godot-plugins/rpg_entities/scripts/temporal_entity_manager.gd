extends Node

# Manages entities that are spawned temporarily and may be despawned later
# Examples: overworld enemies, temporary party members following player, etc.

# Dictionary to track all temporal entities by ID
var temporal_entities: Dictionary = {}

# Spawn a new temporal entity
func spawn_entity(scene_path: String, entity_id: String, position: Vector3, parent_node: Node = null, enable_collision: bool = true, sprite_key: String = "", dialogue_name: String = "") -> Entity:
	# Load the scene
	var entity_scene = load(scene_path)
	if not entity_scene:
		push_error("TemporalEntityManager: Failed to load scene at path: " + scene_path)
		return null
	
	# Instance the entity
	var entity = entity_scene.instantiate()
	if not entity is Entity:
		push_error("TemporalEntityManager: Scene is not an Entity: " + scene_path)
		entity.queue_free()
		return null
	
	# Set entity ID
	entity.entity_id = entity_id
	
	# Set position
	entity.global_position = position
	
	# Add to scene tree
	var target_parent = parent_node if parent_node else get_tree().current_scene
	print("[TEMPORAL] Adding entity to parent: ", target_parent.name)
	target_parent.add_child(entity)
	
	# Set sprite if key provided
	if sprite_key != "":
		set_entity_sprite_from_key(entity, sprite_key)
	
	# Set dialogue if NPC and dialogue name provided
	if dialogue_name != "" and entity is NPC:
		(entity as NPC).dialogue = dialogue_name
		print("[TEMPORAL] Set dialogue: ", dialogue_name)
	
	# Configure collision
	set_entity_collision(entity, enable_collision)
	
	# Track in temporal entities
	temporal_entities[entity_id] = entity
	
	print("[TEMPORAL] Spawned entity '", entity_id, "' at ", position, " (collision: ", enable_collision, ")")
	return entity

# Set sprite texture for an entity using a sprite key
func set_entity_sprite_from_key(entity: Entity, sprite_key: String):
	if not is_instance_valid(entity):
		return
	
	# Look up sprite path from DataManager
	if not DataManager.npc_sprites.has(sprite_key):
		push_error("TemporalEntityManager: Sprite key not found in npc_sprites.json: ", sprite_key)
		return
	
	var sprite_data = DataManager.npc_sprites[sprite_key]
	if not sprite_data.has("sprite_path"):
		push_error("TemporalEntityManager: No sprite_path in npc_sprites.json for key: ", sprite_key)
		return
	
	var sprite_path = sprite_data["sprite_path"]
	
	# Get Sprite3D node
	var sprite = entity.get_node_or_null("Sprite3D")
	if not sprite:
		push_warning("TemporalEntityManager: Entity has no Sprite3D node: ", entity.entity_id)
		return
	
	# Load and set texture
	var texture = load(sprite_path)
	if not texture:
		push_error("TemporalEntityManager: Failed to load sprite texture: ", sprite_path)
		return
	
	sprite.texture = texture
	
	# Handle symmetrical sprites (use is_asymmetrical property on Entity)
	# If "symmetrical": true is set in JSON, we set is_asymmetrical = false
	# If "symmetrical": false (or missing), we default to is_asymmetrical = true (assuming sprites are asymmetrical by default if not specified, or follow entity default)
	
	# Actually, let's strictly follow the JSON config if present
	if sprite_data.has("symmetrical"):
		# symmetrical=true means is_asymmetrical=false
		entity.is_asymmetrical = not sprite_data["symmetrical"]
		print("[TEMPORAL] Set is_asymmetrical=", entity.is_asymmetrical, " for ", entity.entity_id)
			
	print("[TEMPORAL] Set sprite for '", entity.entity_id, "': ", sprite_key)

# Set collision state for an entity
func set_entity_collision(entity: Entity, enabled: bool):
	if not is_instance_valid(entity):
		return
	
	# Find CollisionShape3D node
	var collision_shape = entity.get_node_or_null("CollisionShape3D")
	if collision_shape:
		collision_shape.disabled = !enabled
	
	# Navigation avoidance still works even when collision is disabled
	# The entity will still try to navigate around others via NavigationAgent3D
	print("[TEMPORAL] Set collision for '", entity.entity_id, "' to ", enabled)

# Set collision layers for an entity to allow/prevent collision with specific layers
# layer: which collision layer(s) this entity exists on (bitmask)
# mask: which layers this entity can collide with (bitmask)
func set_entity_collision_layers(entity: Entity, layer: int, mask: int):
	if not is_instance_valid(entity):
		return
	
	if entity is CharacterBody3D:
		entity.collision_layer = layer
		entity.collision_mask = mask
		print("[TEMPORAL] Set collision layers for '", entity.entity_id, "' - layer: ", layer, ", mask: ", mask)

# Enable collision for an entity by ID
func enable_collision(entity_id: String) -> bool:
	var entity = get_entity(entity_id)
	if entity:
		set_entity_collision(entity, true)
		return true
	return false

# Disable collision for an entity by ID (can pass through but still navigates around)
func disable_collision(entity_id: String) -> bool:
	var entity = get_entity(entity_id)
	if entity:
		set_entity_collision(entity, false)
		return true
	return false

# Despawn an entity by ID
func despawn_entity(entity_id: String) -> bool:
	if not temporal_entities.has(entity_id):
		push_warning("TemporalEntityManager: Entity ID not found: " + entity_id)
		return false
	
	var entity = temporal_entities[entity_id]
	if is_instance_valid(entity):
		entity.queue_free()
	
	temporal_entities.erase(entity_id)
	print("[TEMPORAL] Despawned entity '", entity_id, "'")
	return true

# Get a temporal entity by ID
func get_entity(entity_id: String) -> Entity:
	if temporal_entities.has(entity_id):
		var entity = temporal_entities[entity_id]
		if is_instance_valid(entity):
			return entity
		else:
			# Clean up invalid reference
			temporal_entities.erase(entity_id)
	return null

# Check if an entity exists
func has_entity(entity_id: String) -> bool:
	return temporal_entities.has(entity_id) and is_instance_valid(temporal_entities[entity_id])

# Despawn all temporal entities
func despawn_all():
	for entity_id in temporal_entities.keys():
		var entity = temporal_entities[entity_id]
		if is_instance_valid(entity):
			entity.queue_free()
	temporal_entities.clear()
	print("[TEMPORAL] Despawned all temporal entities")

# Get all active temporal entities
func get_all_entities() -> Array[Entity]:
	var entities: Array[Entity] = []
	for entity_id in temporal_entities.keys():
		var entity = temporal_entities[entity_id]
		if is_instance_valid(entity):
			entities.append(entity)
		else:
			# Clean up invalid reference
			temporal_entities.erase(entity_id)
	return entities



