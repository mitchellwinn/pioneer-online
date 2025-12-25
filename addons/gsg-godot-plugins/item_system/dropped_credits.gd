extends "res://addons/gsg-godot-plugins/item_system/dropped_item.gd"
class_name DroppedCredits

## DroppedCredits - Credits that can be picked up in the world
## Visual is defined in tscn, script just controls color via shader parameter

#region Credit Tiers
const CREDIT_TIERS = {
	"copper": { "min": 1, "max": 5, "color": Color(0.72, 0.45, 0.2), "size": 0.6 },
	"silver": { "min": 6, "max": 15, "color": Color(0.75, 0.75, 0.8), "size": 0.8 },
	"gold": { "min": 16, "max": 50, "color": Color(1.0, 0.85, 0.2), "size": 1.0 },
	"platinum": { "min": 51, "max": 100, "color": Color(0.9, 0.95, 1.0), "size": 1.2 },
	"diamond": { "min": 101, "max": 999999, "color": Color(0.6, 0.9, 1.0), "size": 1.4 }
}
#endregion

@export var credit_amount: int = 10

var _tier_name: String = "gold"

func _ready():
	# Set _visual_root reference for base class bobbing/rotation
	_visual_root = get_node_or_null("Visual")
	
	# Lock rotation so credits stay upright - they should bob, not roll
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	# Allow Y rotation for visual spin
	axis_lock_angular_y = false
	
	# Determine tier and apply visuals
	_apply_tier_from_amount()
	
	# Setup item data
	item_id = "credits"
	item_name = "Credits"
	quantity = credit_amount
	interaction_prompt = ""
	
	super._ready()
	
	# Configure NetworkIdentity for RigidBody3D sync
	var network_id = get_node_or_null("NetworkIdentity")
	if network_id:
		# Sync RigidBody3D properties: position, rotation, and linear_velocity
		# Must use typed array to match NetworkIdentity.sync_properties type
		var props: Array[String] = ["global_position", "global_rotation", "linear_velocity"]
		network_id.sync_properties = props

func _apply_tier_from_amount():
	## Apply tier-based color, scale, and brightness via shader parameter
	for tier_name in CREDIT_TIERS:
		var tier = CREDIT_TIERS[tier_name]
		if credit_amount >= tier.min and credit_amount <= tier.max:
			_tier_name = tier_name
			
			# Set shader color and brightness on visual meshes
			var visual = get_node_or_null("Visual")
			if visual:
				var color = tier.color
				# Higher tier = brighter (bigger credits are more valuable)
				var brightness_mult = 1.2 + (tier.size - 0.6) * 0.5  # Scale from 1.2 to 1.6
				for child in visual.get_children():
					if child is CSGPrimitive3D and child.material_override:
						# Use Color (vec4) for shader parameter to match uniform type
						child.material_override.set_shader_parameter("base_color", color)
						child.material_override.set_shader_parameter("brightness", 1.5 * brightness_mult)
				
				# Scale visual based on tier
				visual.scale = Vector3.ONE * tier.size
			
			# Update collision size
			var col = get_node_or_null("CollisionShape3D")
			if col and col.shape:
				col.shape.radius = 0.25 * tier.size  # Updated base radius
			
			highlight_color = tier.color
			break

func _create_visual():
	# Visual is already in the tscn - just ensure tier is applied
	_apply_tier_from_amount()

func _create_collision():
	# Collision is already in the tscn
	pass

func _get_interaction_prompt() -> String:
	return "E - %d Credits" % credit_amount

func _on_pickup(player: Node) -> bool:
	## Credits are picked up as inventory items - only converted on extraction
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db:
		push_warning("[DroppedCredits] Cannot add credits - missing ItemDatabase")
		return false

	var character_id = _get_character_id_from_player(player)
	if character_id <= 0:
		print("[DroppedCredits] No character ID - credits not saved")
		return true

	# Get steam_id for inventory
	var steam_id = 0
	if "steam_id" in player:
		steam_id = player.steam_id
	elif player.has_method("get_steam_id"):
		steam_id = player.get_steam_id()
	else:
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_method("get_player_data"):
			var peer_id = player.get_multiplayer_authority() if player.has_method("get_multiplayer_authority") else 1
			var pd = network.get_player_data(peer_id)
			if pd:
				steam_id = pd.steam_id

	# Add credit chips to inventory (stackable) - NOT directly to credit balance
	# Credits only become real on successful extraction
	if item_db.has_method("add_to_inventory"):
		var inv_id = item_db.add_to_inventory(steam_id, character_id, "credit_chip", credit_amount)
		if inv_id > 0:
			print("[DroppedCredits] +%d credit chips added to inventory" % credit_amount)
			return true
		else:
			push_warning("[DroppedCredits] Failed to add credit chips to inventory")
			return false
	else:
		# Fallback: add directly to credits (old behavior)
		var new_total = item_db.add_credits(character_id, credit_amount)
		print("[DroppedCredits] +%d credits (total: %d) [fallback]" % [credit_amount, new_total])
		return true

func _get_character_id_from_player(player: Node) -> int:
	if "character_id" in player and player.character_id > 0:
		return player.character_id
	
	var network_id = player.get_node_or_null("NetworkIdentity")
	if network_id and "character_id" in network_id and network_id.character_id > 0:
		return network_id.character_id
	
	var network = get_node_or_null("/root/NetworkManager")
	if network:
		var peer_id = 1
		if network_id and "owner_peer_id" in network_id:
			peer_id = network_id.owner_peer_id
		elif player.has_method("get_multiplayer_authority"):
			peer_id = player.get_multiplayer_authority()
		
		if network.has_method("get_character_id_for_peer"):
			var char_id = network.get_character_id_for_peer(peer_id)
			if char_id > 0:
				return char_id
	
	return 0

func drop_with_force(direction: Vector3, force: float = 3.0):
	## Apply physics force for credits to scatter with proper physics
	if not is_inside_tree():
		return
	
	# Ensure RigidBody is unfrozen and ready for physics
	freeze = false
	_is_settled = false
	_drop_grace_time = 0.5  # Don't check for settlement for 0.5 seconds
	
	# Set physics properties for good bouncing
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.bounce = 0.4  # Nice bounce
	physics_material_override.friction = 0.8
	
	# Apply impulse with gentle upward arc
	var up_boost = 1.5 + force * 0.3  # Gentle upward arc
	var impulse = direction * force + Vector3.UP * up_boost
	apply_central_impulse(impulse)
	
	# Add gentle Y spin only (credits stay upright due to axis lock)
	apply_torque_impulse(Vector3(0, randf_range(-1.0, 1.0), 0))
	
	# Auto-settle after physics settles (check in _physics_process)
	# The grace period prevents immediate re-settling

#region Static Factory
static func create(amount: int, at_position: Vector3 = Vector3.ZERO) -> DroppedCredits:
	var credit_scene = preload("res://prefabs/pickups/dropped_credits.tscn")
	if not credit_scene:
		push_error("[DroppedCredits] Could not load dropped_credits.tscn")
		return null
	
	var credits = credit_scene.instantiate() as DroppedCredits
	credits.credit_amount = amount
	credits.quantity = amount
	credits.global_position = at_position
	return credits
#endregion
