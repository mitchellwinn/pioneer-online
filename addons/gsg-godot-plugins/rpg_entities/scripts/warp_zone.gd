extends Marker

class_name Warp

# Warp behavior
@export var button_triggered: bool = false # If true, requires player to press confirm
var just_warped = false # Prevents re-triggering immediately after warp

# Directional warping (optional - for button warps)
@export_group("Directional Settings")
@export_enum("None", "Up", "Down", "Left", "Right") var required_direction: String = "None" # Direction player must face to use
@export_enum("None", "Up", "Down", "Left", "Right") var exit_direction: String = "None" # Direction to face player after warping out
@export var direction_tolerance: float = 67.5 # Angle tolerance in degrees (67.5 = 3 directions, 45 = 2 directions)

# Destination (use ONE of these methods)
@export_group("Destination")
@export var destination_entity_id: String = "" # ID of destination (any entity: warp, marker, NPC, etc.)
@export var destination_scene: String = "" # Scene path for cross-scene warps (e.g. "res://scenes/maps/forest.tscn")
@export var destination_position: Vector3 = Vector3.ZERO # Manual position (fallback if no entity_id)
@export_file("*.tscn", "*.glb") var interior_scene_path: String = "" # Interior scene to spawn (e.g. "res://rooms_models/maine/interiors/DemoRoom.001.glb")

# Detection area for player
var trigger_area: Area3D

# Sign node reference
var sign_node: Sprite3D
var sign_animator: AnimationPlayer

# Note: Interiors are now preloaded at game start by GameManager
# This static tracking is kept for backwards compatibility but no longer used for spawning
static var spawned_interior: Node = null
static var interior_spawn_position: Vector3 = Vector3.ZERO
static var player_in_interior: bool = false

func _ready():
	# Call parent ready (registers entity_id)
	super._ready()
	
	# Get reference to Sign node
	sign_node = get_node_or_null("Sign")
	if sign_node:
		sign_node.visible = false # Start hidden
		sign_animator = sign_node.get_node_or_null("AnimationPlayer")
	
	# Connect to player's warp_target_changed signal
	if GameManager.player and is_instance_valid(GameManager.player):
		GameManager.player.warp_target_changed.connect(_on_player_warp_target_changed)
	else:
		# Player might not exist yet, connect when it spawns
		GameManager.player_spawned.connect(_on_player_spawned)
	
	# Update animation based on warp state
	_update_warp_animation()
	
	# Create trigger area for player detection
	trigger_area = Area3D.new()
	trigger_area.collision_layer = 0 # Area doesn't need to be on any layer
	trigger_area.collision_mask = 2 # Detect layer 2 (player)
	add_child(trigger_area)
	
	# Create collision shape for trigger
	var collision_shape = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = Vector3(0.5, 0.5, 0.5) # Adjust size as needed
	collision_shape.shape = shape
	trigger_area.add_child(collision_shape)
	
	# Connect area signals
	trigger_area.body_entered.connect(_on_body_entered)
	trigger_area.body_exited.connect(_on_body_exited)
	
	print("[WARP] Registered warp with entity_id: ", entity_id)

func _update_warp_animation():
	# Warp animation should be "on" if enabled and has a valid destination
	if not animator:
		return
	
	var has_destination = (destination_entity_id != "" or destination_scene != "" or destination_position != Vector3.ZERO)
	if has_destination:
		animator.play("on")
	else:
		animator.play("off")

func _on_player_spawned():
	# Connect to the newly spawned player's signal
	if GameManager.player and is_instance_valid(GameManager.player):
		GameManager.player.warp_target_changed.connect(_on_player_warp_target_changed)

func _on_player_warp_target_changed(new_target):
	# Show sign only if this warp is the new target
	if sign_node:
		var should_be_visible = (new_target == self)
		sign_node.visible = should_be_visible
		
		# Play float animation when becoming visible
		if should_be_visible and sign_animator:
			sign_animator.play("float")

func _physics_process(_delta):
	# Continuously check if player is in trigger and facing right direction
	if not _should_update_warp_target():
		return
	
	var bodies = trigger_area.get_overlapping_bodies()
	if GameManager.player in bodies:
		_update_player_warp_target_based_on_direction()

func _should_update_warp_target() -> bool:
	# Check if we should update the warp target this frame
	return GameManager.player and is_instance_valid(GameManager.player) and trigger_area

func _update_player_warp_target_based_on_direction():
	# Update player's warp_target based on whether they're facing the required direction
	if _check_direction_requirement(GameManager.player):
		# Player is in area and facing right direction - set as warp target
		if GameManager.player.warp_target != self:
			GameManager.player.warp_target = self
	else:
		# Player in area but wrong direction - clear warp target if it was this warp
		if GameManager.player.warp_target == self:
			GameManager.player.warp_target = null

func _on_body_entered(body: Node3D):
	if is_instance_valid(GameManager.player) and body == GameManager.player:
		print("[WARP] Player entered warp: ", entity_id)

func _on_body_exited(body: Node3D):
	if is_instance_valid(GameManager.player) and body == GameManager.player:
		# Clear warp target if it's this warp
		if GameManager.player.warp_target == self:
			GameManager.player.warp_target = null
		just_warped = false
	print("[WARP] Player exited warp: ", entity_id)

func _direction_string_to_angle(dir: String) -> float:
	# Convert direction string to angle in degrees (0-360)
	# Using world-space coordinates: Right=0, Down=90, Left=180, Up=270
	match dir:
		"Right": return 0.0
		"Down": return 90.0
		"Left": return 180.0
		"Up": return 270.0
		_: return -1.0 # Invalid

func _dir_string_to_angle(dir_string: String) -> float:
	# Convert entity's dir_string to angle in degrees
	# Entity uses 8-directional strings, map them to closest cardinal
	match dir_string:
		"right": return 0.0
		"down_right": return 45.0
		"down": return 90.0
		"down_left": return 135.0
		"left": return 180.0
		"up_left": return 225.0
		"up": return 270.0
		"up_right": return 315.0
		_: return -1.0 # Invalid

func _check_direction_requirement(entity: Entity) -> bool:
	# If no direction required, always allow
	if required_direction == "None":
		return true
	
	# Get required direction as angle
	var required_angle = _direction_string_to_angle(required_direction)
	if required_angle < 0:
		return true
	
	# Get entity's facing direction (works even when standing still)
	if not "dir_string" in entity:
		return true
	
	# Convert entity's dir_string to angle for comparison
	var entity_angle = _dir_string_to_angle(entity.dir_string)
	if entity_angle < 0:
		return false # Invalid direction
	
	# Calculate angular difference (handle wrap-around)
	var angle_diff = abs(entity_angle - required_angle)
	if angle_diff > 180:
		angle_diff = 360 - angle_diff
	
	# Check if within tolerance
	return angle_diff <= direction_tolerance

# Static function to warp any entity to any destination
# entity_id: ID of entity to warp (player, NPC, etc.)
# destination_id: ID of destination entity (warp, marker, NPC, etc.) OR a Vector3 position
# destination_scene: Optional scene path for cross-scene warps
# source_warp_id: Optional ID of source warp (for interior spawning)
static func warp_entity_to(entity_id: String, destination_id: String, destination_scene_path: String = "", source_warp_id: String = ""):
	# Get the entity to warp
	var entity = Entity.get_entity_by_id(entity_id)
	var is_player = false
	if not entity:
		# Fallback: if the caller passed an empty/unknown ID but this is the player, use GameManager.player
		if GameManager.player and is_instance_valid(GameManager.player):
			entity = GameManager.player
			is_player = true
			push_warning("[WARP] Entity id '" + entity_id + "' not found; falling back to GameManager.player")
		else:
			push_warning("[WARP] Entity not found: ", entity_id)
			return
	else:
		is_player = (entity == GameManager.player)
	
	# Block player control during warp
	if is_player:
		GameManager.is_transitioning = true
	
	print("[WARP] warp_entity_to entity=", entity.entity_id, " dest=", destination_id, " scene=", destination_scene_path)
	
	# Fade to black first
	await SceneTransition.transition_to_black(0.3)
	
	# Interiors are now preloaded at game start by GameManager
	# No need to spawn them dynamically anymore
	
	# Now get destination position and warp reference (after interior is spawned)
	var destination_pos = Vector3.ZERO
	var dest_entity = Entity.get_entity_by_id(destination_id)
	var dest_warp: Warp = null
	
	if not dest_entity:
		push_warning("[WARP] Destination entity not found: ", destination_id)
		# Cleanup before returning
		await SceneTransition.transition_from_black(0.3)
		if is_player:
			GameManager.is_transitioning = false
		return
	
	destination_pos = dest_entity.global_position
	print("[WARP] destination entity=", destination_id, " pos=", destination_pos)
	# Mark destination warp as just_warped to prevent re-trigger
	if dest_entity is Warp:
		dest_warp = dest_entity as Warp
		dest_warp.just_warped = true
	
	# Update player interior status based on Y position
	if is_player:
		player_in_interior = (destination_pos.y < -50.0)
	
	# Check if we need to change scenes
	if destination_scene_path != "":
		# Cross-scene warp - save destination entity ID for respawning after scene loads
		if is_player:
			# Save destination entity ID to DataManager
			if not DataManager.general_data.has("pending_warp"):
				DataManager.general_data["pending_warp"] = {}
			DataManager.general_data["pending_warp"]["destination_entity_id"] = destination_id
			
			# Save exit direction if specified
			if dest_warp and dest_warp.exit_direction != "None":
				DataManager.general_data["pending_warp"]["exit_direction"] = dest_warp.exit_direction
		
		entity.get_tree().change_scene_to_file(destination_scene_path)
		return # Scene change destroys everything, exit function
	else:
		# Same-scene warp - teleport entity
		if is_instance_valid(entity):
			var before = entity.global_position
			entity.global_position = destination_pos
			print("[WARP] Same-scene teleport from ", before, " to ", destination_pos)
			# Update player interior status
			if is_player:
				player_in_interior = (destination_pos.y < -50.0)
				print("[WARP] Teleported player, in_interior: ", player_in_interior)
			else:
				print("[WARP] Teleported entity: ", entity.entity_id)
		
		# If warping player, also warp party NPCs
		if is_player:
			var party_npcs = GameManager.get_party_npcs()
			for npc in party_npcs:
				if is_instance_valid(npc):
					npc.global_position = destination_pos
					print("[WARP] Teleported party NPC: ", npc.entity_id)
	
	# Apply exit direction if specified and warping player
	if is_player and dest_warp and dest_warp.exit_direction != "None":
		if is_instance_valid(entity):
			var exit_angle = dest_warp._direction_string_to_angle(dest_warp.exit_direction)
			if exit_angle >= 0:
				# Convert angle to direction vector
				var exit_rad = deg_to_rad(exit_angle)
				var exit_vec = Vector3(cos(exit_rad), 0, sin(exit_rad)).normalized()
				entity.direction = exit_vec
				if "dir_string" in entity:
					entity.dir_string = entity.get_string_dir()
				print("[WARP] Set player direction to: ", dest_warp.exit_direction)
	
	# Set destination warp as player's warp_target if it's button-triggered AND direction matches
	if is_player and dest_warp and dest_warp.button_triggered:
		if is_instance_valid(entity) and "warp_target" in entity:
			# Only set warp_target if player is facing the required direction
			if dest_warp._check_direction_requirement(entity):
				entity.warp_target = dest_warp
				print("[WARP] Set destination warp as warp_target: ", dest_warp.entity_id)
			else:
				print("[WARP] Player not facing required direction at destination warp")
	
	# Fade from black
	await SceneTransition.transition_from_black(0.3)
	
	# Restore player control
	if is_player:
		GameManager.is_transitioning = false

# Instance method for when player walks into this warp
func trigger_warp(entity: Entity):
	if not entity:
		return
	
	# Abort if already transitioning
	if GameManager.is_transitioning:
		return
	
	# Use this warp's destination settings
	var dest_id = destination_entity_id
	if dest_id == "":
		push_warning("[WARP] No destination set for warp: ", entity_id)
		return
	
	print("[WARP] trigger_warp from=", entity_id, " dest=", dest_id, " dest_scene=", destination_scene)
	
	# Mark as warped to prevent re-triggering
	just_warped = true
	
	# Call the static function on this class - pass this warp's entity_id for interior spawning
	await warp_entity_to(entity.entity_id, dest_id, destination_scene, self.entity_id)
	
	# Reset just_warped after a short delay
	await entity.get_tree().create_timer(0.5).timeout
	just_warped = false
