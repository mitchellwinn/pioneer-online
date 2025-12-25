extends RigidBody3D
class_name DroppedItem

## DroppedItem - Base class for items that can be picked up in the world
## Works with the interaction system to show "[E] <prompt>" overlay
## Subclass for specific item types (credits, weapons, consumables, etc.)

signal picked_up(by_player: Node, item_data: Dictionary)
signal despawned()

#region Configuration
@export_group("Interaction")
@export var interaction_range: float = 2.0
@export var despawn_time: float = 120.0  # Seconds before auto-despawn (0 = never)
@export var interaction_prompt: String = "Pick up"

@export_group("Visual")
@export var bob_height: float = 0.1
@export var bob_speed: float = 2.0
@export var rotate_speed: float = 1.5
@export var highlight_color: Color = Color(1, 1, 0.5, 0.8)
#endregion

#region Item Data
var item_data: Dictionary = {}  # Generic item data
var item_id: String = ""
var item_name: String = "Item"
var quantity: int = 1
var dropped_by_peer_id: int = -1  # Who dropped it
#endregion

#region Internal State
var _visual_root: Node3D = null
var _highlight_mesh: MeshInstance3D = null
var _interaction_area: Area3D = null
var _despawn_timer: float = 0.0
var _can_pickup: bool = true
var _bob_time: float = 0.0
var _start_y: float = 0.0
var _is_settled: bool = true  # Start settled - will unsettle when dropped
var _nearby_players: Array[Node] = []
var _drop_grace_time: float = 0.0  # Grace period after dropping before checking velocity
#endregion

func _ready():
	# Add to groups
	add_to_group("interactable")
	add_to_group("dropped_items")
	
	# Setup physics
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	# Use layer 128 (layer 8) for pickups - players don't collide with this layer
	# Only collide with environment (layer 1) for physics
	collision_layer = 128  # Pickup layer - players walk through, not blocked
	collision_mask = 1     # Collide with environment only
	gravity_scale = 1.0
	
	# Create interaction area
	_create_interaction_area()
	
	# Start despawn timer
	if despawn_time > 0:
		_despawn_timer = despawn_time
	
	_start_y = global_position.y

func _process(delta: float):
	# Safety check - don't process if not in tree
	if not is_inside_tree():
		return
	
	# Despawn timer
	if despawn_time > 0 and _despawn_timer > 0:
		_despawn_timer -= delta
		if _despawn_timer <= 0:
			_despawn()
			return
	
	# Visual effects when settled
	if _is_settled and _visual_root and is_instance_valid(_visual_root):
		# Bobbing
		_bob_time += delta * bob_speed
		_visual_root.position.y = sin(_bob_time) * bob_height
		
		# Rotation
		_visual_root.rotate_y(delta * rotate_speed)
	
	# Update interaction prompt for nearby players
	_update_nearby_players()

func _physics_process(delta: float):
	# Safety check
	if not is_inside_tree():
		return
	
	# Grace period after dropping - don't check for settlement yet
	if _drop_grace_time > 0:
		_drop_grace_time -= delta
		return
	
	# Check if settled after being dropped
	if not _is_settled and not freeze:
		if linear_velocity.length() < 0.1:
			_on_settled()

func _create_interaction_area():
	_interaction_area = Area3D.new()
	_interaction_area.name = "InteractionArea"
	_interaction_area.collision_layer = 0
	_interaction_area.collision_mask = 2  # Player layer
	_interaction_area.monitoring = true
	add_child(_interaction_area)
	
	var shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = interaction_range
	shape.shape = sphere
	_interaction_area.add_child(shape)
	
	_interaction_area.body_entered.connect(_on_body_entered)
	_interaction_area.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node):
	if body.is_in_group("players") and body not in _nearby_players:
		_nearby_players.append(body)
		_show_prompt_to_player(body)

func _on_body_exited(body: Node):
	if body in _nearby_players:
		_nearby_players.erase(body)
		_hide_prompt_from_player(body)

func _update_nearby_players():
	for player in _nearby_players:
		if not is_instance_valid(player):
			_nearby_players.erase(player)
			continue
		
		# Check distance
		var dist = global_position.distance_to(player.global_position)
		if dist <= interaction_range:
			_show_prompt_to_player(player)
		else:
			_hide_prompt_from_player(player)

func _show_prompt_to_player(player: Node):
	if not _can_pickup:
		return
	if player.has_method("show_interaction_prompt"):
		var prompt = _get_interaction_prompt()
		player.show_interaction_prompt(prompt, self)

func _hide_prompt_from_player(player: Node):
	if player.has_method("hide_interaction_prompt"):
		if player.has_method("get_prompt_target") and player.get_prompt_target() == self:
			player.hide_interaction_prompt()

func _on_settled():
	_is_settled = true
	freeze = true
	# Raise item above ground for floating effect
	global_position.y += 0.3
	_start_y = global_position.y

#region Setup Methods
func setup(data: Dictionary):
	## Initialize from item data dictionary
	item_data = data.duplicate(true)
	item_id = data.get("id", data.get("item_id", ""))
	item_name = data.get("name", "Item")
	quantity = data.get("quantity", 1)
	
	# Create visual representation (override in subclasses)
	_create_visual()
	
	# Create collision
	_create_collision()

func _create_visual():
	## Override in subclasses to create the visual representation
	# Default: create a simple box
	_visual_root = Node3D.new()
	_visual_root.name = "Visual"
	add_child(_visual_root)
	
	var mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	mesh_instance.mesh = box
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = highlight_color
	mat.emission_enabled = true
	mat.emission = highlight_color
	mat.emission_energy_multiplier = 0.3
	mesh_instance.material_override = mat
	
	_visual_root.add_child(mesh_instance)

func _create_collision():
	## Create physics collision shape
	var col_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	col_shape.shape = box
	add_child(col_shape)

func drop_with_force(direction: Vector3, force: float = 3.0):
	## Apply physics force when dropped
	if not is_inside_tree():
		return
	
	freeze = false
	_is_settled = false
	_drop_grace_time = 0.5  # Don't check for settlement for 0.5 seconds
	
	var up_force = 2.0 + force * 0.2
	apply_central_impulse(direction * force + Vector3.UP * up_force)
	
	# Add some spin
	apply_torque_impulse(Vector3(
		(randf() - 0.5) * 2.0,
		(randf() - 0.5) * 2.0,
		(randf() - 0.5) * 2.0
	))
	
	# Auto-settle after timeout
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(self) and is_inside_tree() and not _is_settled:
		_on_settled()
#endregion

#region Interaction Interface (for ActionPlayer)
func can_interact() -> bool:
	return _can_pickup

func start_interaction(player: Node):
	## Called when a player presses E to interact
	if not can_interact():
		return
	
	var success = _on_pickup(player)
	if success:
		_can_pickup = false
		picked_up.emit(player, item_data)
		
		# Hide prompt and cleanup
		_hide_prompt_from_player(player)
		await get_tree().create_timer(0.1).timeout
		queue_free()

func _on_pickup(player: Node) -> bool:
	## Override in subclasses to handle pickup logic
	## Return true if pickup was successful
	return true

func _get_interaction_prompt() -> String:
	## Override to customize the prompt text
	## Uses "E - Action" format for the interaction prompt system
	if quantity > 1:
		return "E - %s (x%d)" % [item_name, quantity]
	return "E - %s" % item_name

func get_interaction_prompt() -> String:
	## Alias for compatibility with interaction system
	return _get_interaction_prompt()
#endregion

#region Cleanup
func _despawn():
	despawned.emit()
	queue_free()
#endregion

