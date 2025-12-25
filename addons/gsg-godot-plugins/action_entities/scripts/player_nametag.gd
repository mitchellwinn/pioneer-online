extends Node3D
class_name PlayerNametag

## PlayerNametag - Displays player name above head with relationship-based colors
## Styled to match the CinematicHUD aesthetic

@export var nametag_label: Label3D
@export var offset: Vector3 = Vector3(0, 2.1, 0) # Height above player head (above the model)
@export var max_distance: float = 50.0 # Max distance to show nametag
@export var show_in_hub_only: bool = true # Only show in hub/test scenes

# Style configuration matching CinematicHUD
@export_group("Style")
@export var font_size: int = 64  # Larger for readability
@export var outline_size: int = 8  # Outline for visibility
@export var default_color: Color = Color.WHITE  # Clean white like HUD
@export var squad_color: Color = Color(0.4, 0.8, 1.0, 1.0)  # Cyan for squad
@export var friend_color: Color = Color(0.3, 0.85, 0.4, 1.0)  # Green for friends

var player_entity: Node3D # ActionPlayer - untyped to avoid load order issues
var player_name: String = ""
var steam_id: int = 0
var _peer_id: int = 0

func _ready():
	# Find parent player entity
	player_entity = get_parent() as Node3D
	if not player_entity or not player_entity.has_method("get_movement_input"):
		push_error("[PlayerNametag] Must be child of ActionPlayer")
		return

	# Get player info from NetworkIdentity
	if player_entity.has_node("NetworkIdentity"):
		var network_id = player_entity.get_node("NetworkIdentity")
		_peer_id = network_id.owner_peer_id

	# Get display name from entity (set by MultiplayerScene), NetworkManager, or Steam
	player_name = _get_player_display_name()

	# Setup label with modern style
	if not nametag_label:
		nametag_label = Label3D.new()
		nametag_label.name = "NametagLabel"
		add_child(nametag_label)

	_apply_style()
	_update_nametag_color()
	_check_visibility()

func _get_player_display_name() -> String:
	## Get display name from various sources with fallbacks
	
	# First try: entity's display_name property (set by MultiplayerScene)
	if player_entity and "display_name" in player_entity:
		if not player_entity.display_name.is_empty():
			return player_entity.display_name
	
	# Second try: NetworkManager's player data
	var network = get_node_or_null("/root/NetworkManager")
	if network and _peer_id > 0:
		if network.connected_peers.has(_peer_id):
			var pd = network.connected_peers[_peer_id]
			if not pd.display_name.is_empty():
				return pd.display_name
	
	# Third try: SteamManager for local player
	var steam_manager = get_node_or_null("/root/SteamManager")
	if steam_manager and steam_manager.has_method("get_persona_name"):
		var is_local = _is_local_player()
		if is_local:
			var steam_name = steam_manager.get_persona_name()
			if not steam_name.is_empty():
				return steam_name
	
	# Fallback
	return "Player_%d" % (_peer_id if _peer_id > 0 else randi() % 9999)

func _is_local_player() -> bool:
	if not player_entity:
		return false
	if "can_receive_input" in player_entity:
		return player_entity.can_receive_input
	return false

func _apply_style():
	## Apply clean style matching the HUD font
	if not nametag_label:
		return
	
	nametag_label.text = player_name
	nametag_label.font_size = font_size
	nametag_label.outline_size = outline_size  # Outline for visibility against any background
	nametag_label.outline_modulate = Color(0, 0, 0, 0.9)  # Dark outline
	nametag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nametag_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nametag_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED  # Full billboard for better visibility
	nametag_label.no_depth_test = true
	nametag_label.double_sided = true
	nametag_label.pixel_size = 0.004  # Larger for better readability at distance
	nametag_label.render_priority = 10  # Render on top

func _process(_delta):
	if not player_entity or not nametag_label:
		return
	
	if not player_entity.is_inside_tree():
		return

	# Update position above player head
	global_position = player_entity.global_position + offset

	# Billboard mode handles camera facing automatically
	_check_visibility()

func _check_visibility():
	if not nametag_label:
		return

	var visible = true

	# Check if in hub/test scene
	if show_in_hub_only:
		var current_scene = get_tree().current_scene
		if current_scene:
			var scene_name = current_scene.name.to_lower()
			visible = visible and (scene_name.contains("hub") or scene_name.contains("test"))

	# Check distance to camera
	var camera = get_viewport().get_camera_3d()
	if camera and visible:
		var distance = camera.global_position.distance_to(global_position)
		visible = visible and (distance <= max_distance)

	nametag_label.visible = visible

func _update_nametag_color():
	if not nametag_label:
		return

	var color = default_color

	# Check if squad member (cyan to match HUD)
	if _is_squad_member():
		color = squad_color
	# Check if Steam friend (green)
	elif _is_steam_friend():
		color = friend_color

	nametag_label.modulate = color

func _is_squad_member() -> bool:
	# Check if this player is in the same squad as the local player via NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if not network or _peer_id <= 0:
		return false
	
	# Get local peer id
	var local_peer_id = 1
	if multiplayer and multiplayer.has_multiplayer_peer():
		local_peer_id = multiplayer.get_unique_id()
	
	# Don't highlight self
	if _peer_id == local_peer_id:
		return false
	
	# Check if in same squad via NetworkManager
	if network.has_method("_get_player_squad"):
		var my_squad = network._get_player_squad(local_peer_id)
		var their_squad = network._get_player_squad(_peer_id)
		return my_squad > 0 and my_squad == their_squad
	
	# Fallback: check player entity's squad_members array
	var local_player = _get_local_player()
	if local_player and "squad_members" in local_player:
		return player_entity in local_player.squad_members
	
	return false

func _get_local_player(): # Returns ActionPlayer or null
	# Find the local player (the one controlled by this client)
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			return player
	return null

func _is_steam_friend() -> bool:
	# Get steam_id from NetworkManager using peer_id
	var network = get_node_or_null("/root/NetworkManager")
	var target_steam_id = 0
	
	if network and _peer_id > 0 and network.connected_peers.has(_peer_id):
		target_steam_id = network.connected_peers[_peer_id].steam_id
	
	if target_steam_id == 0 or not has_node("/root/SteamManager"):
		return false

	var steam_manager = get_node("/root/SteamManager")
	if not steam_manager.has_method("get_friends_list"):
		return false
	
	# Check if this steam_id is in our friends list
	var friends = steam_manager.get_friends_list()
	return target_steam_id in friends

func set_nametag_color(color: Color):
	if nametag_label:
		nametag_label.modulate = color

func set_nametag_text(text: String):
	player_name = text
	if nametag_label:
		nametag_label.text = text
