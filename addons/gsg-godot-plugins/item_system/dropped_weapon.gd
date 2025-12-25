extends RigidBody3D
class_name DroppedWeapon

## A weapon that has been dropped on the ground.
## Any player can pick it up by interacting with it.
## Networked - the server owns dropped weapons.

signal picked_up(by_player: Node)

#region Configuration
@export var interaction_range: float = 2.0
@export var despawn_time: float = 60.0  # Seconds before auto-despawn (0 = never)
@export var highlight_color: Color = Color(1, 1, 0.5, 0.8)
#endregion

#region Weapon Data
var weapon_data: Dictionary = {}  # Full item data from database
var weapon_prefab_path: String = ""
var original_owner_id: int = -1  # Peer ID who dropped it
#endregion

#region State
var _visual_instance: Node3D = null
var _highlight_mesh: MeshInstance3D = null
var _interaction_area: Area3D = null
var _despawn_timer: float = 0.0
var _can_pickup: bool = true
var _nearby_players: Array[Node] = []
#endregion

func _ready():
	# Add to interactable group
	add_to_group("interactable")
	add_to_group("dropped_weapons")
	
	# Setup physics
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	# Use layer 128 (layer 8) for pickups - players don't collide with this layer
	collision_layer = 128  # Pickup layer - players walk through, not blocked
	collision_mask = 1     # Collide with environment only
	
	# Create interaction area
	_create_interaction_area()
	
	# Create highlight effect
	_create_highlight()
	
	# Start despawn timer
	if despawn_time > 0:
		_despawn_timer = despawn_time

func _process(delta: float):
	# Despawn timer
	if despawn_time > 0:
		_despawn_timer -= delta
		if _despawn_timer <= 0:
			_despawn()
	
	# Rotate highlight
	if _highlight_mesh:
		_highlight_mesh.rotate_y(delta * 2.0)

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
	
	# Connect signals for interaction prompt
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

func _show_prompt_to_player(player: Node):
	if not _can_pickup:
		return
	if player.has_method("show_interaction_prompt"):
		var prompt = get_interaction_prompt()
		player.show_interaction_prompt(prompt, self)

func _hide_prompt_from_player(player: Node):
	if player.has_method("hide_interaction_prompt"):
		if player.has_method("get_prompt_target") and player.get_prompt_target() == self:
			player.hide_interaction_prompt()

func _create_highlight():
	_highlight_mesh = MeshInstance3D.new()
	_highlight_mesh.name = "Highlight"
	
	var torus = TorusMesh.new()
	torus.inner_radius = 0.3
	torus.outer_radius = 0.4
	_highlight_mesh.mesh = torus
	_highlight_mesh.position.y = -0.1
	_highlight_mesh.rotation_degrees.x = 90
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = highlight_color
	mat.emission_enabled = true
	mat.emission = highlight_color
	mat.emission_energy_multiplier = 0.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_highlight_mesh.material_override = mat
	
	add_child(_highlight_mesh)

#region Setup
func setup_from_weapon(weapon_instance: Node3D, item_data: Dictionary):
	## Initialize from an existing weapon instance
	weapon_data = item_data.duplicate(true)
	weapon_prefab_path = item_data.get("prefab_path", "")
	
	# Clone the visual
	if weapon_instance:
		var visual = weapon_instance.duplicate()
		# Remove any scripts/components that shouldn't be on dropped version
		for child in visual.get_children():
			if child is Area3D or child.name in ["WeaponComponent", "GripPoint", "ForegripPoint", "MuzzlePoint", "AimPoint"]:
				pass  # Keep these for visual reference
		
		add_child(visual)
		visual.position = Vector3.ZERO
		visual.rotation = Vector3.ZERO
		_visual_instance = visual
	
	# Create collision shape based on weapon size
	var col_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(0.1, 0.15, 0.5)  # Approximate weapon size
	col_shape.shape = box
	add_child(col_shape)

func setup_from_data(item_data: Dictionary):
	## Initialize from just item data (load prefab)
	weapon_data = item_data.duplicate(true)
	weapon_prefab_path = item_data.get("prefab_path", "")
	
	# Load and instance the prefab for visuals
	if not weapon_prefab_path.is_empty() and ResourceLoader.exists(weapon_prefab_path):
		var prefab = load(weapon_prefab_path)
		if prefab:
			var visual = prefab.instantiate()
			add_child(visual)
			visual.position = Vector3.ZERO
			visual.rotation = Vector3.ZERO
			_visual_instance = visual
	
	# Create collision
	var col_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(0.1, 0.15, 0.5)
	col_shape.shape = box
	add_child(col_shape)

func drop_with_force(direction: Vector3, force: float = 5.0):
	## Apply physics force when dropped
	## Low force (< 5) = gentle drop
	## Medium force (5-10) = tossed
	## High force (> 10) = shot out of hands, flying and spinning
	freeze = false
	
	# Scale up force for more dramatic effect
	var up_force = 2.0 + force * 0.3  # More force = more upward
	apply_central_impulse(direction * force + Vector3.UP * up_force)
	
	# More spin for higher forces (weapon tumbling through air)
	var spin_intensity = 1.0 + force * 0.5
	apply_torque_impulse(Vector3(
		(randf() - 0.5) * spin_intensity,
		(randf() - 0.5) * spin_intensity, 
		(randf() - 0.5) * spin_intensity
	) * 3.0)
	
	# Freeze after settling (longer for high force)
	var settle_time = 1.5 + force * 0.1
	await get_tree().create_timer(settle_time).timeout
	if is_instance_valid(self):
		freeze = true
#endregion

#region Interaction Interface
func can_interact() -> bool:
	## Called by interaction system to check if pickup is allowed
	return _can_pickup and not weapon_data.is_empty()

func start_interaction(player: Node):
	## Called when a player interacts with this weapon
	if not can_interact():
		return
	
	# Check if player can pick up
	var equipment = player.get_node_or_null("EquipmentManager")
	if not equipment:
		return
	
	# Add to player's inventory database first
	var item_db = get_node_or_null("/root/ItemDatabase")
	var network = get_node_or_null("/root/NetworkManager")
	if item_db and network:
		var peer_id = player.get_multiplayer_authority() if player.has_method("get_multiplayer_authority") else 1
		var char_id = network.get_character_id_for_peer(peer_id) if network.has_method("get_character_id_for_peer") else 0
		var steam_id = network.get_steam_id_for_peer(peer_id) if network.has_method("get_steam_id_for_peer") else 0
		
		if char_id > 0 and item_db.has_method("add_to_inventory"):
			var item_id = weapon_data.get("id", weapon_data.get("item_id", ""))
			if not item_id.is_empty():
				var inv_id = item_db.add_to_inventory(steam_id, char_id, item_id, 1, weapon_data.get("instance_data", {}))
				if inv_id > 0:
					weapon_data["inventory_id"] = inv_id
					print("[DroppedWeapon] Added to inventory: ", item_id, " inv_id=", inv_id)
	
	# Try to equip the weapon
	if equipment.has_method("pickup_weapon"):
		var success = equipment.pickup_weapon(weapon_data)
		if success:
			_can_pickup = false
			picked_up.emit(player)
			_on_picked_up(player)
	elif equipment.has_method("equip_weapon"):
		# Fallback: directly equip
		var slot = _get_appropriate_slot()
		var success = equipment.equip_weapon(slot, weapon_data)
		if success:
			_can_pickup = false
			picked_up.emit(player)
			_on_picked_up(player)

func get_interaction_prompt() -> String:
	## Returns text to display when player is near
	var weapon_name = weapon_data.get("name", "Weapon")
	return "Pick up " + weapon_name

func _get_appropriate_slot() -> String:
	## Determine which equipment slot this weapon should go in
	var size = weapon_data.get("size", "medium")
	match size:
		"large":
			return "primary_weapon"
		"medium":
			return "secondary_weapon"
		"small":
			return "sidearm"
	return "primary_weapon"
#endregion

#region Cleanup
func _on_picked_up(player: Node):
	# Visual feedback
	if _highlight_mesh:
		_highlight_mesh.visible = false
	
	# Despawn after short delay (for network sync)
	await get_tree().create_timer(0.1).timeout
	queue_free()

func _despawn():
	# Could drop loot or just disappear
	queue_free()
#endregion

