extends Node

## NetworkManager - Handles multiplayer connections, authority, and synchronization
## Designed for server-authoritative gameplay with client prediction

#region Signals
signal connection_started()
signal connection_failed(reason: String)
signal connected_to_server()
signal disconnected_from_server(reason: String)
signal server_started()
signal server_stopped()
signal peer_connected(peer_id: int, player_data: Dictionary)
signal peer_disconnected(peer_id: int)
signal player_spawned(peer_id: int, entity: Node)
signal player_despawned(peer_id: int)
signal latency_updated(peer_id: int, latency_ms: int)
signal tick_processed(tick: int)
#endregion

#region Configuration
@export_group("Server Settings")
@export var default_port: int = 7777
@export var max_clients: int = 32
@export var tick_rate: int = 20  # Server ticks per second
@export var use_compression: bool = true

@export_group("Client Settings")
@export var interpolation_delay: float = 0.1  # Seconds behind server
@export var prediction_enabled: bool = true
@export var reconciliation_enabled: bool = true
@export var max_prediction_ticks: int = 10

@export_group("Connection")
@export var connection_timeout: float = 10.0
@export var heartbeat_interval: float = 1.0
@export var max_missed_heartbeats: int = 5
#endregion

#region Network State
enum NetworkState { OFFLINE, CONNECTING, CONNECTED, HOSTING }
var state: NetworkState = NetworkState.OFFLINE

var peer: ENetMultiplayerPeer = null
var is_server: bool = false
var local_peer_id: int = 0
var server_address: String = ""
var server_port: int = 7777

# Connected peers (server only): peer_id -> PlayerData
var connected_peers: Dictionary = {}

# Server time synchronization
var server_tick: int = 0
var client_tick: int = 0
var tick_delta: float = 0.0
var tick_accumulator: float = 0.0

# Latency tracking
var latency_samples: Dictionary = {}  # peer_id -> Array of samples
var current_latency: Dictionary = {}  # peer_id -> int (ms)
const LATENCY_SAMPLE_COUNT: int = 10
#endregion

#region Player Data
class PlayerData:
	var peer_id: int = 0
	var steam_id: int = 0
	var display_name: String = ""
	var character_id: int = 0
	var entity: Node = null
	var last_heartbeat: float = 0.0
	var latency_ms: int = 0
	var input_buffer: Array[Dictionary] = []
	var db_data: Dictionary = {}  # Player data from database
	var character_data: Dictionary = {}  # Selected character data from database
	var zone_id: String = ""  # Current zone the player is in

	func to_dict() -> Dictionary:
		return {
			"peer_id": peer_id,
			"steam_id": steam_id,
			"display_name": display_name,
			"character_id": character_id,
			"character_data": character_data,
			"zone_id": zone_id
		}

	static func from_dict(data: Dictionary) -> PlayerData:
		var pd = PlayerData.new()
		pd.peer_id = data.get("peer_id", 0)
		pd.steam_id = data.get("steam_id", 0)
		pd.display_name = data.get("display_name", "")
		pd.character_id = data.get("character_id", 0)
		pd.zone_id = data.get("zone_id", "")
		return pd
#endregion

func _ready():
	# Connect multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# Connect Steam signals for invite integration
	_connect_steam_signals()

func _physics_process(delta: float):
	if state == NetworkState.OFFLINE:
		return
	
	# Server tick processing
	if is_server:
		tick_accumulator += delta
		var tick_interval = 1.0 / tick_rate
		
		while tick_accumulator >= tick_interval:
			tick_accumulator -= tick_interval
			server_tick += 1
			_process_server_tick()
			tick_processed.emit(server_tick)
	
	# Heartbeat
	_process_heartbeats(delta)

#region Server Management
func start_server(port: int = -1) -> Error:
	if state != NetworkState.OFFLINE:
		push_error("[NetworkManager] Already connected/hosting")
		return ERR_ALREADY_IN_USE
	
	# Clear any stale data from previous sessions
	_cleanup_stale_data()
	
	if port < 0:
		port = default_port
	
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, max_clients)
	
	if error != OK:
		push_error("[NetworkManager] Failed to start server: ", error)
		connection_failed.emit("Failed to create server")
		return error
	
	if use_compression:
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.multiplayer_peer = peer
	
	is_server = true
	local_peer_id = 1
	server_port = port
	state = NetworkState.HOSTING
	
	print("[NetworkManager] Server started on port ", port)
	server_started.emit()
	
	return OK

func stop_server():
	if not is_server:
		return
	
	# Disconnect all clients
	for peer_id in connected_peers.keys():
		_kick_peer(peer_id, "Server shutting down")
	
	_cleanup_network()
	server_stopped.emit()
	print("[NetworkManager] Server stopped")

func _kick_peer(peer_id: int, reason: String = ""):
	if not is_server:
		return
	
	if connected_peers.has(peer_id):
		_rpc_kicked.rpc_id(peer_id, reason)
		peer.disconnect_peer(peer_id)
#endregion

#region Client Connection
func connect_to_server(address: String, port: int = -1) -> Error:
	if state != NetworkState.OFFLINE:
		push_error("[NetworkManager] Already connected")
		return ERR_ALREADY_IN_USE
	
	# Clear any stale data from previous sessions
	_cleanup_stale_data()
	
	if port < 0:
		port = default_port
	
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(address, port)
	
	if error != OK:
		push_error("[NetworkManager] Failed to connect: ", error)
		connection_failed.emit("Failed to create client")
		return error
	
	if use_compression:
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.multiplayer_peer = peer
	
	is_server = false
	server_address = address
	server_port = port
	state = NetworkState.CONNECTING
	
	connection_started.emit()
	print("[NetworkManager] Connecting to ", address, ":", port)
	
	# Start connection timeout
	get_tree().create_timer(connection_timeout).timeout.connect(_on_connection_timeout)
	
	return OK

func disconnect_from_server():
	if state == NetworkState.OFFLINE:
		return
	
	_cleanup_network()
	disconnected_from_server.emit("Client disconnected")
	print("[NetworkManager] Disconnected from server")

func _cleanup_network():
	if peer:
		peer.close()
		peer = null
	
	multiplayer.multiplayer_peer = null
	
	state = NetworkState.OFFLINE
	is_server = false
	local_peer_id = 0
	connected_peers.clear()
	server_tick = 0
	client_tick = 0

func _cleanup_stale_data():
	## Clean up any leftover data from previous sessions
	print("[NetworkManager] Cleaning up stale session data...")
	
	# Despawn any existing player entities
	for peer_id in connected_peers:
		var player_data = connected_peers[peer_id]
		if player_data.entity and is_instance_valid(player_data.entity):
			player_data.entity.queue_free()
			print("[NetworkManager] Cleaned up stale entity for peer: ", peer_id)
	
	connected_peers.clear()
	server_tick = 0
	client_tick = 0
#endregion

#region Connection Callbacks
func _on_peer_connected(peer_id: int):
	print("[NetworkManager] Peer connected: ", peer_id)
	
	# On clients, peer_id 1 is the server - don't treat it as a player
	if not is_server and peer_id == 1:
		print("[NetworkManager] Connected to server (peer 1) - not a player")
		return
	
	# Initialize peer data
	var player_data = PlayerData.new()
	player_data.peer_id = peer_id
	player_data.last_heartbeat = Time.get_ticks_msec() / 1000.0
	connected_peers[peer_id] = player_data
	
	# Emit signal so MultiplayerScene can spawn the remote player
	peer_connected.emit(peer_id, player_data.to_dict())
	
	if is_server:
		# Give player their own squad
		_on_player_joined_server(peer_id)
		# Send server state to new peer
		_sync_server_state_to_peer(peer_id)

func _on_peer_disconnected(peer_id: int):
	print("[NetworkManager] Peer disconnected: ", peer_id)
	
	# Clean up squad data on server
	if is_server:
		_on_player_left_server(peer_id)
	
	# Clean up on both server AND client
	if connected_peers.has(peer_id):
		var player_data = connected_peers[peer_id]
		connected_peers.erase(peer_id)
		peer_disconnected.emit(peer_id)
		
		# Despawn their entity
		if player_data.entity and is_instance_valid(player_data.entity):
			player_despawned.emit(peer_id)
			player_data.entity.queue_free()
			print("[NetworkManager] Despawned entity for peer: ", peer_id)

func _on_connected_to_server():
	print("[NetworkManager] Connected to server")
	state = NetworkState.CONNECTED
	local_peer_id = multiplayer.get_unique_id()
	connected_to_server.emit()

func _on_connection_failed():
	print("[NetworkManager] Connection failed")
	_cleanup_network()
	connection_failed.emit("Connection failed")

func _on_server_disconnected():
	print("[NetworkManager] Server disconnected")
	_cleanup_network()
	disconnected_from_server.emit("Server disconnected")

func _on_connection_timeout():
	if state == NetworkState.CONNECTING:
		print("[NetworkManager] Connection timeout")
		_cleanup_network()
		connection_failed.emit("Connection timeout")
#endregion

#region Server Tick Processing
## Enable to see input processing logs on server
var debug_server_inputs: bool = false

func _process_server_tick():
	# Process buffered inputs from all clients
	for peer_id in connected_peers:
		var player_data = connected_peers[peer_id] as PlayerData
		_process_player_inputs(player_data)
	
	# Broadcast state to all clients
	_broadcast_world_state()

func _process_player_inputs(player_data: PlayerData):
	if player_data.input_buffer.size() == 0:
		return
	
	if debug_server_inputs:
		print("[NetworkManager:Server] Processing %d inputs for peer %d" % [
			player_data.input_buffer.size(), player_data.peer_id
		])
	
	# Process inputs in order
	while player_data.input_buffer.size() > 0:
		var input = player_data.input_buffer.pop_front()
		_apply_player_input(player_data, input)

func _apply_player_input(player_data: PlayerData, input: Dictionary):
	if not player_data.entity or not is_instance_valid(player_data.entity):
		if debug_server_inputs:
			print("[NetworkManager:Server] WARNING: No entity for peer %d, dropping input" % player_data.peer_id)
		return
	
	# BLOCK ALL MOVEMENT/ACTION INPUTS IF PLAYER IS IN DIALOGUE (server-authoritative)
	if is_player_in_dialogue(player_data.peer_id):
		# Only allow UI-related inputs, completely block movement/actions
		return
	
	# Validate and apply input to player entity
	if player_data.entity.has_method("apply_network_input"):
		player_data.entity.apply_network_input(input)
	else:
		if debug_server_inputs:
			print("[NetworkManager:Server] WARNING: Entity for peer %d has no apply_network_input method!" % player_data.peer_id)

## Check if a player is currently in dialogue (server-authoritative)
func is_player_in_dialogue(peer_id: int) -> bool:
	return _player_dialogue_nodes.has(peer_id) and not _player_dialogue_nodes[peer_id].is_empty()

func _broadcast_world_state():
	## Zone-aware world state broadcast - only send state for players in same zone
	# Group players by zone
	var zone_peers: Dictionary = {}  # zone_id -> Array[peer_id]
	for peer_id in connected_peers:
		var player_data = connected_peers[peer_id] as PlayerData
		var zone_id = player_data.zone_id if player_data.zone_id else ""
		if not zone_peers.has(zone_id):
			zone_peers[zone_id] = []
		zone_peers[zone_id].append(peer_id)

	# For each zone, gather and broadcast only that zone's player states
	for zone_id in zone_peers:
		var zone_state = _gather_zone_world_state(zone_peers[zone_id])

		# Send to each peer in this zone
		for peer_id in zone_peers[zone_id]:
			if peer_id != 1:  # Don't send to server
				_rpc_world_state.rpc_id(peer_id, server_tick, zone_state)

func _gather_world_state() -> Dictionary:
	## Gather all players (legacy - used for initial sync)
	var state_data = {}

	# Gather entity states
	for peer_id in connected_peers:
		var player_data = connected_peers[peer_id] as PlayerData
		if player_data.entity and is_instance_valid(player_data.entity):
			if player_data.entity.has_method("get_network_state"):
				state_data[peer_id] = player_data.entity.get_network_state()

	return state_data

func _gather_zone_world_state(peer_ids: Array) -> Dictionary:
	## Gather world state for a specific set of peers (same zone)
	var state_data = {}

	for peer_id in peer_ids:
		if not connected_peers.has(peer_id):
			continue
		var player_data = connected_peers[peer_id] as PlayerData
		if player_data.entity and is_instance_valid(player_data.entity):
			if player_data.entity.has_method("get_network_state"):
				state_data[peer_id] = player_data.entity.get_network_state()

	return state_data
#endregion

#region Client State Sync
var _last_world_state_log: float = 0.0

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_world_state(tick: int, world_state: Dictionary):
	if is_server:
		return
	
	client_tick = tick
	
	# Debug: log world state receipt periodically
	var now = Time.get_ticks_msec() / 1000.0
	if debug_client_sync and now - _last_world_state_log > 2.0:
		print("[NetworkManager:Client] Received world_state with %d peers: %s" % [world_state.size(), world_state.keys()])
		_last_world_state_log = now
	
	# Apply state to entities
	for peer_id in world_state:
		var entity_state = world_state[peer_id]
		_apply_entity_state(peer_id, entity_state)

var debug_client_sync: bool = false  # Enable for sync debugging

func _apply_entity_state(peer_id, entity_state: Dictionary):
	# Ensure peer_id is int (RPC may convert dict keys to strings)
	var pid: int = int(peer_id)
	
	# For local player: still apply for reconciliation (player handles it)
	# For remote players: apply for interpolation
	
	# Find the entity for this peer
	var entity: Node = null
	
	# First check our connected_peers cache
	if connected_peers.has(pid):
		var player_data = connected_peers[pid] as PlayerData
		if player_data.entity and is_instance_valid(player_data.entity):
			entity = player_data.entity
	
	# If not found, search by NetworkIdentity
	if not entity:
		entity = _find_entity_by_peer_id(pid)
		# Cache it for future lookups
		if entity:
			if connected_peers.has(pid):
				connected_peers[pid].entity = entity
			if debug_client_sync:
				print("[NetworkManager:Client] Found entity for peer %d: %s" % [pid, entity.name])
	
	if not entity:
		# Entity not spawned yet - this is normal during initial sync
		if debug_client_sync:
			print("[NetworkManager:Client] No entity found for peer %d" % pid)
		return
	
	# Apply state to the entity
	if entity.has_method("apply_network_state"):
		entity.apply_network_state(entity_state)
		if debug_client_sync:
			print("[NetworkManager:Client] Applied state to peer %d at %s" % [pid, entity_state.get("position", "?")])
	else:
		# Fallback: directly set position/rotation
		if entity_state.has("position"):
			entity.global_position = entity_state.position
		if entity_state.has("rotation"):
			entity.rotation = entity_state.rotation

func _find_entity_by_peer_id(peer_id: int) -> Node:
	## Search for an entity with matching NetworkIdentity
	
	# First try MultiplayerScene if available
	var multiplayer_scene = get_tree().get_first_node_in_group("multiplayer_scene")
	if multiplayer_scene and multiplayer_scene.has_method("get_player"):
		var player = multiplayer_scene.get_player(peer_id)
		if player:
			return player
	
	# Fallback: search players group
	for node in get_tree().get_nodes_in_group("players"):
		if node.has_node("NetworkIdentity"):
			var network_id = node.get_node("NetworkIdentity")
			if network_id.owner_peer_id == peer_id:
				return node
	return null

func _sync_server_state_to_peer(peer_id: int):
	# Send current world state to newly connected peer
	var world_state = _gather_world_state()
	_rpc_initial_sync.rpc_id(peer_id, server_tick, world_state, _get_peers_info())

@rpc("authority", "call_remote", "reliable")
func _rpc_initial_sync(tick: int, world_state: Dictionary, peers_info: Array):
	if is_server:
		return
	
	client_tick = tick
	
	# Initialize peer list
	for peer_info in peers_info:
		var player_data = PlayerData.from_dict(peer_info)
		connected_peers[player_data.peer_id] = player_data
		peer_connected.emit(player_data.peer_id, peer_info)

func _get_peers_info() -> Array:
	var info = []
	for peer_id in connected_peers:
		info.append(connected_peers[peer_id].to_dict())
	return info
#endregion

#region Player Input (Client -> Server)
func send_input(input: Dictionary):
	if is_server:
		# Local server player
		if connected_peers.has(1):
			var player_data = connected_peers[1] as PlayerData
			player_data.input_buffer.append(input)
	else:
		# Send to server
		_rpc_player_input.rpc_id(1, client_tick, input)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_player_input(tick: int, input: Dictionary):
	if not is_server:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if not connected_peers.has(sender_id):
		if debug_server_inputs:
			print("[NetworkManager:Server] Received input from unknown peer %d" % sender_id)
		return
	
	var player_data = connected_peers[sender_id] as PlayerData
	input["tick"] = tick
	input["peer_id"] = sender_id
	player_data.input_buffer.append(input)
	
	# Log notable inputs (actions, not just movement)
	if debug_server_inputs:
		var actions = input.get("actions", 0)
		if actions != 0:  # Only log when there are action inputs
			print("[NetworkManager:Server] Received input from peer %d: tick=%d actions=%d move=(%.2f,%.2f)" % [
				sender_id, tick, actions, input.get("move_x", 0), input.get("move_z", 0)
			])
#endregion

func get_local_character_id() -> int:
	## Get the character_id for the local player (used by inventory, etc.)
	if connected_peers.has(local_peer_id):
		return connected_peers[local_peer_id].character_id
	return 0

func get_character_id_for_peer(peer_id: int) -> int:
	## Get the character_id for a specific peer
	if connected_peers.has(peer_id):
		return connected_peers[peer_id].character_id
	return 0

func get_steam_id_for_peer(peer_id: int) -> int:
	## Get the steam_id for a specific peer
	if connected_peers.has(peer_id):
		return connected_peers[peer_id].steam_id
	return 0

func is_active() -> bool:
	## Check if network manager is actively connected
	return peer != null and multiplayer.has_multiplayer_peer()

#region Player Registration
## Pending zone requests: peer_id -> zone_type ("hub", "test", etc.)
var _pending_zone_requests: Dictionary = {}

func register_player(steam_id: int, display_name: String, character_id: int = 0, requested_zone: String = "hub"):
	if is_server:
		# Server player - load/create from database
		var db_result = _load_or_create_player(steam_id, display_name)
		if not db_result.success:
			push_error("[NetworkManager] Failed to load/create player: ", steam_id)
			return

		var player_data = PlayerData.new()
		player_data.peer_id = 1
		player_data.steam_id = steam_id
		player_data.display_name = display_name
		player_data.db_data = db_result.data
		player_data.character_data = db_result.character
		player_data.character_id = db_result.character.get("character_id", 0)
		connected_peers[1] = player_data
		_pending_zone_requests[1] = requested_zone
		# Give server player their own squad
		_on_player_joined_server(1)
		peer_connected.emit(1, player_data.to_dict())
	else:
		# Client registering with server
		_rpc_register_player.rpc_id(1, steam_id, display_name, character_id, requested_zone)

func get_pending_zone_request(peer_id: int) -> String:
	return _pending_zone_requests.get(peer_id, "hub")

func clear_pending_zone_request(peer_id: int):
	_pending_zone_requests.erase(peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_register_player(steam_id: int, display_name: String, _character_id: int, requested_zone: String = "hub"):
	if not is_server:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if not connected_peers.has(sender_id):
		return
	
	# Load/create player from database
	var db_result = _load_or_create_player(steam_id, display_name)
	if not db_result.success:
		# Kick player if DB fails
		_kick_peer(sender_id, "Database error")
		return
	
	# Check if banned
	if db_result.data.get("is_banned", 0) == 1:
		_kick_peer(sender_id, "You are banned: " + db_result.data.get("ban_reason", ""))
		return
	
	var player_data = connected_peers[sender_id] as PlayerData
	player_data.steam_id = steam_id
	player_data.display_name = display_name
	player_data.db_data = db_result.data
	player_data.character_data = db_result.character
	player_data.character_id = db_result.character.get("character_id", 0)

	# Store their zone request for server_root to use
	_pending_zone_requests[sender_id] = requested_zone
	print("[NetworkManager] Player %d requested zone: %s" % [sender_id, requested_zone])

	# Notify all clients (includes character data)
	_rpc_player_registered.rpc(sender_id, player_data.to_dict())
	peer_connected.emit(sender_id, player_data.to_dict())
	
	# Broadcast updated player list with names
	_broadcast_player_list()
	
	print("[NetworkManager] Player registered: ", display_name, " (Steam: ", steam_id, ", Char: ", player_data.character_id, ")")
	
	# Now that we have character_id, send equipment from database
	_send_equipment_to_client(sender_id)

func _load_or_create_player(steam_id: int, display_name: String) -> Dictionary:
	## Load player from DB or create if new (auto-creates default character)
	var db = get_node_or_null("/root/DatabaseManager")
	if not db:
		push_warning("[NetworkManager] No DatabaseManager - player data won't persist")
		return {"success": true, "data": {}, "character": {}, "is_new": true}
	
	var is_new_player = false
	
	# Try to get existing player
	var player_data = db.get_player(steam_id)
	
	if player_data.is_empty():
		# New player - create record
		var created = db.create_player(steam_id, display_name)
		if not created:
			return {"success": false, "data": {}, "character": {}, "is_new": false}
		
		player_data = db.get_player(steam_id)
		is_new_player = true
		print("[NetworkManager] Created new player record for: ", display_name)
	else:
		# Existing player - update login
		db.update_player_login(steam_id)
		print("[NetworkManager] Loaded existing player: ", display_name)
	
	# Load or create character (single slot)
	var characters = db.get_characters(steam_id)
	var character_data = {}
	
	if characters.is_empty():
		# Create default character
		var char_id = db.create_character(steam_id, display_name, "default")
		if char_id > 0:
			character_data = db.get_character(char_id)
			print("[NetworkManager] Created default character for: ", display_name)
			
			# Give starting weapons to new character
			var item_db = get_node_or_null("/root/ItemDatabase")
			if item_db:
				item_db.give_starting_weapons(steam_id, char_id)
	else:
		# Use first (and only) character
		character_data = characters[0]
		print("[NetworkManager] Loaded character: ", character_data.get("character_name", "Unknown"))
		
		# Check if existing character needs starting weapons
		var item_db = get_node_or_null("/root/ItemDatabase")
		if item_db and not item_db.has_starting_weapons(character_data.character_id):
			print("[NetworkManager] Giving starting weapons to existing character")
			item_db.give_starting_weapons(steam_id, character_data.character_id)
	
	return {
		"success": true, 
		"data": player_data, 
		"character": character_data,
		"is_new": is_new_player
	}

@rpc("authority", "call_remote", "reliable")
func _rpc_player_registered(peer_id: int, player_info: Dictionary):
	if is_server:
		return
	
	var player_data = PlayerData.from_dict(player_info)
	connected_peers[peer_id] = player_data
	peer_connected.emit(peer_id, player_info)

func set_player_entity(peer_id: int, entity: Node):
	print("[NetworkManager] set_player_entity called for peer %d, entity=%s, has_peer=%s" % [
		peer_id, entity.name if entity else "null", connected_peers.has(peer_id)])
	
	if connected_peers.has(peer_id):
		connected_peers[peer_id].entity = entity
		player_spawned.emit(peer_id, entity)
		print("[NetworkManager] Entity cached for peer %d" % peer_id)
	else:
		# Peer not in connected_peers - add it now
		var player_data = PlayerData.new()
		player_data.peer_id = peer_id
		player_data.entity = entity
		connected_peers[peer_id] = player_data
		player_spawned.emit(peer_id, entity)
		print("[NetworkManager] Created new peer entry for %d with entity" % peer_id)
	
	# Server: Send equipment data to the client
	if is_server and peer_id != 1:
		# Wait for ItemDatabase to be ready before sending equipment
		var item_db = get_node_or_null("/root/ItemDatabase")
		if item_db and item_db.is_ready:
			_send_equipment_to_client(peer_id)
		else:
			# Queue for later when ItemDatabase is ready
			print("[NetworkManager] ItemDatabase not ready, queuing equipment send for peer %d" % peer_id)
			_pending_equipment_sends.append(peer_id)
			if item_db and not item_db.item_database_ready.is_connected(_on_item_database_ready):
				item_db.item_database_ready.connect(_on_item_database_ready)

var _pending_equipment_sends: Array[int] = []

func _on_item_database_ready():
	## Called when ItemDatabase finishes initializing - send queued equipment
	print("[NetworkManager] ItemDatabase ready - sending queued equipment to %d peers" % _pending_equipment_sends.size())
	for peer_id in _pending_equipment_sends:
		if connected_peers.has(peer_id):
			_send_equipment_to_client(peer_id)
	_pending_equipment_sends.clear()

func _send_equipment_to_client(peer_id: int):
	## Server-side: Look up player's equipment from database and send to client
	## NOTE: This requires character_id to be set. Called after player registration.
	if not connected_peers.has(peer_id):
		return
	
	var player_data = connected_peers[peer_id] as PlayerData
	var character_id = player_data.character_id
	
	if character_id <= 0:
		print("[NetworkManager] No character_id for peer %d, waiting for registration" % peer_id)
		return
	
	var item_db = get_node_or_null("/root/ItemDatabase")
	if not item_db or not item_db.is_server_instance:
		print("[NetworkManager] ItemDatabase not available on server!")
		return
	
	# Get equipped items from database
	var equipped = item_db.get_equipped_items(character_id)
	
	if equipped.is_empty():
		print("[NetworkManager] No equipment in DB for character %d - this shouldn't happen!" % character_id)
		# Try giving starting weapons as a fallback
		var steam_id = player_data.steam_id
		if steam_id > 0:
			item_db.give_starting_weapons(steam_id, character_id)
			equipped = item_db.get_equipped_items(character_id)
	
	var equipment_data: Dictionary = {}
	
	# Build full weapon data for each equipped slot
	for slot_name in equipped:
		var slot_data = equipped[slot_name]
		var item_id = slot_data.get("item_id", "")
		
		if item_id.is_empty():
			continue
		
		# Get full weapon data including stats
		var weapon_data = item_db.get_full_weapon_data(item_id)
		if not weapon_data.is_empty():
			# Merge inventory data (like inventory_id) into weapon_data
			weapon_data.merge(slot_data)
			equipment_data[slot_name] = weapon_data
	
	if equipment_data.is_empty():
		print("[NetworkManager] WARNING: No equipment to send for peer %d" % peer_id)
		return
	
	print("[NetworkManager] Sending equipment to peer %d: %s" % [peer_id, equipment_data.keys()])
	_rpc_receive_equipment.rpc_id(peer_id, equipment_data)
	
	# Also broadcast this player's equipment to ALL other clients
	_broadcast_player_equipment(peer_id, equipment_data)
	
	# Send existing players' equipment to this new client
	send_all_existing_equipment_to_client(peer_id)

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_equipment(equipment_data: Dictionary):
	## Client-side: Receive equipment data from server and equip weapons
	if is_server:
		return
	
	print("[NetworkManager:Client] Received equipment data: %s" % [equipment_data.keys()])
	
	if equipment_data.is_empty():
		print("[NetworkManager:Client] Equipment data is empty - server may not have items loaded")
		return
	
	# Store equipment data
	_pending_equipment = equipment_data
	
	# Try to apply now, or wait for player to spawn
	_try_apply_pending_equipment()

var _pending_equipment: Dictionary = {}

func _try_apply_pending_equipment():
	## Try to apply pending equipment - called when equipment arrives or player spawns
	if _pending_equipment.is_empty():
		return
	
	var local_player = _find_entity_by_peer_id(local_peer_id)
	if not local_player:
		print("[NetworkManager:Client] Waiting for local player to spawn before equipping...")
		return
	
	_apply_equipment_to_player(local_player, _pending_equipment)
	_pending_equipment.clear()

func _apply_equipment_to_player(player: Node, equipment_data: Dictionary):
	## Apply equipment data to a player's EquipmentManager
	var equipment_manager = player.get_node_or_null("EquipmentManager")
	if not equipment_manager:
		print("[NetworkManager] ERROR: No EquipmentManager on player!")
		return
	
	for slot_name in equipment_data:
		var weapon_data = equipment_data[slot_name]
		var result = equipment_manager.equip_weapon(slot_name, weapon_data)
		print("[NetworkManager] Equipped %s to slot %s: %s" % [weapon_data.get("name", "?"), slot_name, result])
	
	print("[NetworkManager] Equipment applied to player")

func check_pending_equipment(player: Node):
	## Called by MultiplayerScene after spawning local player to apply any pending equipment
	if not _pending_equipment.is_empty():
		print("[NetworkManager] Applying pending equipment to newly spawned player")
		_apply_equipment_to_player(player, _pending_equipment)
		_pending_equipment.clear()
	else:
		print("[NetworkManager] No pending equipment to apply")

func _broadcast_player_equipment(owner_peer_id: int, equipment_data: Dictionary):
	## Server-side: Tell ALL other clients about a player's equipment (for remote player visuals)
	if not is_server:
		return
	
	# Store for late-joining clients
	_all_player_equipment[owner_peer_id] = equipment_data
	
	for peer_id in connected_peers:
		if peer_id == owner_peer_id or peer_id == 1:
			continue  # Skip the owner (already got it) and server
		
		print("[NetworkManager] Broadcasting peer %d equipment to peer %d" % [owner_peer_id, peer_id])
		_rpc_receive_remote_player_equipment.rpc_id(peer_id, owner_peer_id, equipment_data)

var _all_player_equipment: Dictionary = {}  # peer_id -> equipment_data (server-side cache)

func send_all_existing_equipment_to_client(peer_id: int):
	## Server-side: Send all existing players' equipment to a newly connected client
	if not is_server:
		return
	
	for existing_peer_id in _all_player_equipment:
		if existing_peer_id == peer_id:
			continue  # Don't send their own equipment this way
		
		print("[NetworkManager] Sending existing peer %d equipment to new peer %d" % [existing_peer_id, peer_id])
		_rpc_receive_remote_player_equipment.rpc_id(peer_id, existing_peer_id, _all_player_equipment[existing_peer_id])

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_remote_player_equipment(owner_peer_id: int, equipment_data: Dictionary):
	## Client-side: Receive equipment data for a remote player (so we can see their weapons)
	if is_server:
		return
	
	print("[NetworkManager:Client] Received equipment for remote peer %d: %s" % [owner_peer_id, equipment_data.keys()])
	
	# Validate equipment data has prefab_paths
	for slot in equipment_data:
		var data = equipment_data[slot]
		if not data.has("prefab_path") or data.prefab_path.is_empty():
			push_warning("[NetworkManager:Client] Missing prefab_path for peer %d slot %s" % [owner_peer_id, slot])
		else:
			print("[NetworkManager:Client] Peer %d slot %s has prefab: %s" % [owner_peer_id, slot, data.prefab_path])
	
	# Store for when the player spawns
	_pending_remote_equipment[owner_peer_id] = equipment_data
	
	# Try to apply now if player already exists
	var remote_player = _find_entity_by_peer_id(owner_peer_id)
	if remote_player:
		_apply_equipment_to_player(remote_player, equipment_data)
		_pending_remote_equipment.erase(owner_peer_id)

var _pending_remote_equipment: Dictionary = {}  # peer_id -> equipment_data

func check_pending_remote_equipment(peer_id: int, player: Node):
	## Called when a remote player spawns to apply any pending equipment
	if _pending_remote_equipment.has(peer_id):
		print("[NetworkManager] Applying pending equipment to remote player peer %d" % peer_id)
		_apply_equipment_to_player(player, _pending_remote_equipment[peer_id])
		_pending_remote_equipment.erase(peer_id)

## Broadcast a single weapon equip to all other clients (called when weapon is equipped mid-game)
func broadcast_weapon_equip(slot_name: String, weapon_data: Dictionary):
	## Called by EquipmentManager when a new weapon is equipped
	if is_server:
		# Server directly broadcasts to all clients
		var peer_id = 1  # Server is peer 1
		_handle_weapon_equip_broadcast(peer_id, slot_name, weapon_data)
	else:
		# Client sends to server, which broadcasts
		_rpc_request_weapon_equip_broadcast.rpc_id(1, slot_name, weapon_data)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_weapon_equip_broadcast(slot_name: String, weapon_data: Dictionary):
	## Client requests server to broadcast their weapon equip
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_weapon_equip_broadcast(sender_id, slot_name, weapon_data)

func _handle_weapon_equip_broadcast(owner_peer_id: int, slot_name: String, weapon_data: Dictionary):
	## Server broadcasts weapon equip/unequip to all other clients
	if not is_server:
		return

	# Update cached equipment for this peer
	if not _all_player_equipment.has(owner_peer_id):
		_all_player_equipment[owner_peer_id] = {}

	if weapon_data.is_empty():
		# Unequip - remove from cache
		_all_player_equipment[owner_peer_id].erase(slot_name)
		print("[NetworkManager] Caching UNEQUIP for peer %d slot %s" % [owner_peer_id, slot_name])
	else:
		# Equip - add to cache
		_all_player_equipment[owner_peer_id][slot_name] = weapon_data
		print("[NetworkManager] Caching equip for peer %d slot %s" % [owner_peer_id, slot_name])

	# UPDATE SERVER'S COPY of the player entity so it can equip the weapon visually
	var server_entity = _find_entity_by_peer_id(owner_peer_id)
	if server_entity:
		var equipment = server_entity.get_node_or_null("EquipmentManager")
		if equipment and not weapon_data.is_empty():
			# Equip weapon on server's copy too (for visual sync and state tracking)
			equipment.equip_weapon(slot_name, weapon_data)
	
	# Broadcast to peers in same zone
	var owner_zone = get_player_zone(owner_peer_id)
	for peer_id in connected_peers:
		if peer_id == owner_peer_id or peer_id == 1:
			continue
		# Zone filter: only send to peers in same zone
		if not owner_zone.is_empty() and get_player_zone(peer_id) != owner_zone:
			continue
		print("[NetworkManager] Broadcasting weapon %s from peer %d to peer %d: %s" % [
			"unequip" if weapon_data.is_empty() else "equip",
			owner_peer_id, peer_id, slot_name
		])
		_rpc_receive_weapon_equip.rpc_id(peer_id, owner_peer_id, slot_name, weapon_data)

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_weapon_equip(owner_peer_id: int, slot_name: String, weapon_data: Dictionary):
	## Client receives notification that a remote player equipped/unequipped a weapon
	if is_server:
		return
	
	# Empty weapon_data means unequip
	if weapon_data.is_empty():
		print("[NetworkManager:Client] Peer %d UNEQUIPPED slot %s" % [owner_peer_id, slot_name])
		var remote_player = _find_entity_by_peer_id(owner_peer_id)
		if remote_player:
			var equipment_manager = remote_player.get_node_or_null("EquipmentManager")
			if equipment_manager and equipment_manager.has_method("unequip_weapon"):
				equipment_manager.unequip_weapon(slot_name)
		# Also clear from pending
		if _pending_remote_equipment.has(owner_peer_id):
			_pending_remote_equipment[owner_peer_id].erase(slot_name)
		return
	
	print("[NetworkManager:Client] Peer %d equipped %s in slot %s" % [owner_peer_id, weapon_data.get("name", "?"), slot_name])
	
	# Find the remote player and equip the weapon
	var remote_player = _find_entity_by_peer_id(owner_peer_id)
	if remote_player:
		var equipment_manager = remote_player.get_node_or_null("EquipmentManager")
		if equipment_manager:
			equipment_manager.equip_weapon(slot_name, weapon_data)
	else:
		# Player not spawned yet, store for later
		if not _pending_remote_equipment.has(owner_peer_id):
			_pending_remote_equipment[owner_peer_id] = {}
		_pending_remote_equipment[owner_peer_id][slot_name] = weapon_data

## Broadcast weapon draw/holster state to all other clients
func broadcast_weapon_state(slot_name: String, holstered: bool):
	## Called by EquipmentManager when a weapon is drawn or holstered
	if is_server:
		_handle_weapon_state_broadcast(1, slot_name, holstered)
	else:
		_rpc_request_weapon_state_broadcast.rpc_id(1, slot_name, holstered)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_weapon_state_broadcast(slot_name: String, holstered: bool):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_weapon_state_broadcast(sender_id, slot_name, holstered)

func _handle_weapon_state_broadcast(owner_peer_id: int, slot_name: String, holstered: bool):
	if not is_server:
		return

	# UPDATE SERVER'S COPY of the player entity - use direct state application
	var server_entity = _find_entity_by_peer_id(owner_peer_id)
	if server_entity:
		var equipment = server_entity.get_node_or_null("EquipmentManager")
		if equipment:
			# Use direct remote state application (bypasses timers, avoids sync issues)
			if equipment.has_method("apply_remote_state"):
				equipment.apply_remote_state(slot_name, holstered)
			else:
				# Fallback to old method
				if not slot_name.is_empty() and equipment.is_weapon_equipped(slot_name):
					if equipment.current_slot != slot_name:
						equipment.switch_to_slot(slot_name)
					if holstered and not equipment.is_holstered:
						equipment.holster_current()
					elif not holstered and equipment.is_holstered:
						equipment._draw_weapon(slot_name)
				elif holstered:
					equipment.holster_current()

	# Broadcast to peers in same zone
	var owner_zone = get_player_zone(owner_peer_id)
	for peer_id in connected_peers:
		if peer_id == owner_peer_id or peer_id == 1:
			continue
		# Zone filter: only send to peers in same zone
		if not owner_zone.is_empty() and get_player_zone(peer_id) != owner_zone:
			continue
		_rpc_receive_weapon_state.rpc_id(peer_id, owner_peer_id, slot_name, holstered)

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_weapon_state(owner_peer_id: int, slot_name: String, holstered: bool):
	if is_server:
		return

	var remote_player = _find_entity_by_peer_id(owner_peer_id)
	if not remote_player:
		return

	var equipment_manager = remote_player.get_node_or_null("EquipmentManager")
	if not equipment_manager:
		return

	# Use direct remote state application (bypasses timers, handles holstering old weapon)
	if equipment_manager.has_method("apply_remote_state"):
		equipment_manager.apply_remote_state(slot_name, holstered)
	else:
		# Fallback to old method
		var current_holstered = equipment_manager.is_holstered if "is_holstered" in equipment_manager else true
		var current_slot = equipment_manager.current_slot if "current_slot" in equipment_manager else ""

		if holstered:
			if not current_holstered:
				if equipment_manager.has_method("holster_current"):
					equipment_manager.holster_current()
		else:
			if current_holstered or current_slot != slot_name:
				if equipment_manager.has_method("_draw_weapon"):
					equipment_manager._draw_weapon(slot_name)

## Broadcast projectile spawn to all other clients (for visual sync)
func broadcast_projectile(prefab_path: String, position: Vector3, direction: Vector3, velocity: float, dmg: float, dmg_type: String):
	## Called by WeaponComponent when local player fires
	if is_server:
		# Server directly broadcasts to all clients
		_handle_projectile_broadcast(local_peer_id, prefab_path, position, direction, velocity, dmg, dmg_type)
	else:
		# Client sends to server, which broadcasts
		_rpc_request_projectile_broadcast.rpc_id(1, prefab_path, position, direction, velocity, dmg, dmg_type)

@rpc("any_peer", "call_remote", "unreliable")  # Unreliable for performance (visual only)
func _rpc_request_projectile_broadcast(prefab_path: String, position: Vector3, direction: Vector3, velocity: float, dmg: float, dmg_type: String):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_projectile_broadcast(sender_id, prefab_path, position, direction, velocity, dmg, dmg_type)

func _handle_projectile_broadcast(owner_peer_id: int, prefab_path: String, position: Vector3, direction: Vector3, velocity: float, dmg: float, dmg_type: String):
	## Server broadcasts projectile to peers in same zone
	if not is_server:
		return

	var owner_zone = get_player_zone(owner_peer_id)
	for peer_id in connected_peers:
		if peer_id == owner_peer_id or peer_id == 1:  # Don't send to owner or server
			continue
		# Zone filter: only send to peers in same zone
		if not owner_zone.is_empty() and get_player_zone(peer_id) != owner_zone:
			continue
		_rpc_receive_projectile.rpc_id(peer_id, owner_peer_id, prefab_path, position, direction, velocity, dmg, dmg_type)

@rpc("authority", "call_remote", "unreliable")
func _rpc_receive_projectile(owner_peer_id: int, prefab_path: String, position: Vector3, direction: Vector3, velocity: float, dmg: float, dmg_type: String):
	## Client receives notification to spawn visual projectile
	if is_server:
		return
	
	# Load and spawn projectile
	var prefab = load(prefab_path)
	if not prefab:
		push_warning("[NetworkManager] Could not load projectile prefab: %s" % prefab_path)
		return
	
	var projectile = prefab.instantiate()
	get_tree().current_scene.add_child(projectile)
	
	var spawn_pos = position + direction * 0.1
	projectile.global_position = spawn_pos
	
	# Find owner for collision exclusion
	var owner_entity = _find_entity_by_peer_id(owner_peer_id)
	
	if projectile.has_method("initialize"):
		projectile.initialize(direction * velocity, dmg, dmg_type, owner_entity)

## Server-authoritative projectile hit validation
func request_projectile_hit(hit_data: Dictionary):
	## Client reports projectile hit for server validation
	if is_server:
		_handle_projectile_hit(local_peer_id, hit_data)
	else:
		_rpc_request_projectile_hit.rpc_id(1, hit_data)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_projectile_hit(hit_data: Dictionary):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_projectile_hit(sender_id, hit_data)

func _handle_projectile_hit(attacker_peer_id: int, hit_data: Dictionary):
	## Server validates and applies projectile damage, knockback, hitstun
	var target_id = hit_data.get("target_id", -1)
	var target_name = hit_data.get("target_name", "")
	var damage = hit_data.get("damage", 0.0)
	var damage_type = hit_data.get("damage_type", "projectile")
	var knockback_force = hit_data.get("knockback_force", 0.0)
	var knockback_direction: Vector3 = hit_data.get("knockback_direction", Vector3.ZERO)
	var hitstun_duration = hit_data.get("hitstun_duration", 0.0)
	var hit_position: Vector3 = hit_data.get("hit_position", Vector3.ZERO)
	
	if damage <= 0:
		return
	
	# Find target entity
	var target_entity = null
	if target_id > 0:
		target_entity = _find_entity_by_peer_id(target_id)
	if not target_entity and target_id > 0:
		target_entity = _find_server_entity_by_id(target_id)
	if not target_entity and not target_name.is_empty():
		target_entity = find_server_entity_by_name(target_name)
	
	if not target_entity:
		print("[NetworkManager] Projectile hit target not found: id=%d name=%s" % [target_id, target_name])
		return
	
	print("[NetworkManager] Projectile hit: %s -> %s for %.1f damage" % [attacker_peer_id, target_entity.name, damage])
	
	var attacker_entity = _find_entity_by_peer_id(attacker_peer_id)
	
	# Apply damage
	if target_entity.has_method("take_damage"):
		target_entity.take_damage(damage, attacker_entity, damage_type)
	
	# Apply knockback on server
	if knockback_force > 0 and knockback_direction.length_squared() > 0.01:
		if target_entity.has_method("apply_knockback"):
			var kb_vec = knockback_direction.normalized() * knockback_force
			target_entity.apply_knockback(kb_vec)
			print("[NetworkManager] Applied projectile knockback: %s" % kb_vec)
	
	# Apply hitstun on server
	if hitstun_duration > 0 and target_entity.has_method("apply_hitstun"):
		target_entity.apply_hitstun(hitstun_duration)
	
	# Broadcast hit result to all clients
	_broadcast_projectile_hit_result(target_entity.name, {
		"damage": damage,
		"knockback_force": knockback_force,
		"knockback_direction": knockback_direction,
		"hitstun_duration": hitstun_duration,
		"hit_position": hit_position
	})

func _broadcast_projectile_hit_result(target_name: String, hit_result: Dictionary):
	## Broadcast projectile hit to all clients for visual sync
	for peer_id in connected_peers:
		if peer_id == 1:
			continue
		_rpc_receive_projectile_hit.rpc_id(peer_id, target_name, hit_result)

@rpc("authority", "call_remote", "reliable")
func _rpc_receive_projectile_hit(target_name: String, hit_result: Dictionary):
	## Client receives projectile hit result from server
	if is_server:
		return
	
	# Find target
	var target_entity = find_server_entity_by_name(target_name)
	if not target_entity:
		return
	
	# Apply knockback (server authoritative)
	var kb_force = hit_result.get("knockback_force", 0.0)
	var kb_dir: Vector3 = hit_result.get("knockback_direction", Vector3.ZERO)
	if kb_force > 0 and kb_dir.length_squared() > 0.01 and target_entity.has_method("apply_knockback"):
		target_entity.apply_knockback(kb_dir.normalized() * kb_force)
	
	# Apply hitstun
	var hitstun = hit_result.get("hitstun_duration", 0.0)
	if hitstun > 0 and target_entity.has_method("apply_hitstun"):
		target_entity.apply_hitstun(hitstun)

## Server-authoritative melee hit validation
func request_melee_hit(hit_data: Dictionary):
	## Client request to validate melee hit
	if is_server:
		_handle_melee_hit(local_peer_id, hit_data)
	else:
		_rpc_request_melee_hit.rpc_id(1, hit_data)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_melee_hit(hit_data: Dictionary):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_melee_hit(sender_id, hit_data)

## Anti-cheat: Track last attack time per player for rate limiting
var _last_melee_attack_time: Dictionary = {}  # peer_id -> timestamp (ms)
const MELEE_ATTACK_COOLDOWN_MS: int = 200  # Minimum ms between attacks

## Server-authoritative combat limits
const MAX_MELEE_KNOCKBACK: float = 15.0
const MAX_MELEE_HITSTUN: float = 1.0
const MAX_MELEE_DAMAGE: float = 200.0  # Sanity cap for any single hit

func _handle_melee_hit(attacker_peer_id: int, hit_data: Dictionary):
	## Server validates and applies melee damage, knockback, hitstun
	## IMPORTANT: Damage is calculated SERVER-SIDE from weapon stats, not trusted from client
	## Then broadcasts to all clients so everyone sees the same result
	var target_id = hit_data.get("target_id", -1)
	var target_name = hit_data.get("target_name", "")
	var weapon_id = hit_data.get("weapon_id", "")
	var bone_name = hit_data.get("bone_name", "")
	var knockback_direction: Vector3 = hit_data.get("knockback_direction", Vector3.ZERO)

	# Anti-cheat: Rate limit attacks
	var current_time = Time.get_ticks_msec()
	var last_attack = _last_melee_attack_time.get(attacker_peer_id, 0)
	if current_time - last_attack < MELEE_ATTACK_COOLDOWN_MS:
		print("[NetworkManager] Melee attack rate-limited for peer %d (too fast)" % attacker_peer_id)
		return
	_last_melee_attack_time[attacker_peer_id] = current_time

	# Find target entity - try multiple methods
	var target_entity = null

	# First try by peer_id (for players)
	if target_id > 0:
		target_entity = _find_entity_by_peer_id(target_id)

	# Then try by network_id or instance_id (for server entities)
	if not target_entity and target_id > 0:
		target_entity = _find_server_entity_by_id(target_id)

	# Finally try by name (most reliable for server entities)
	if not target_entity and not target_name.is_empty():
		target_entity = find_server_entity_by_name(target_name)

	if not target_entity:
		print("[NetworkManager] Melee hit target not found: id=%d name=%s" % [target_id, target_name])
		return

	# Find attacker entity for knockback direction and weapon lookup
	var attacker_entity = _find_entity_by_peer_id(attacker_peer_id)
	if not attacker_entity:
		print("[NetworkManager] Melee hit rejected - attacker not found: peer %d" % attacker_peer_id)
		return

	# Validate distance (anti-cheat)
	var distance = attacker_entity.global_position.distance_to(target_entity.global_position)
	if distance > 5.0:  # Max melee range (generous for lag compensation)
		print("[NetworkManager] Melee hit rejected - too far: %.2f" % distance)
		return

	# SERVER-AUTHORITATIVE: Get weapon stats from ItemDatabase, NOT from client
	var damage: float = 0.0
	var knockback_force: float = 0.0
	var hitstun_duration: float = 0.0
	var damage_type: String = "melee"

	var weapon_stats = _get_server_weapon_stats(attacker_entity, weapon_id)
	if weapon_stats.is_empty():
		# Fallback: use bare-handed damage
		damage = 10.0
		knockback_force = 2.0
		hitstun_duration = 0.2
		print("[NetworkManager] No weapon found - using bare-handed damage")
	else:
		damage = weapon_stats.get("damage", 30.0)
		knockback_force = weapon_stats.get("knockback_force", 5.0)
		hitstun_duration = weapon_stats.get("hitstun_duration", 0.3)
		damage_type = weapon_stats.get("damage_type", "melee")

	# Apply server-side caps (anti-cheat)
	damage = minf(damage, MAX_MELEE_DAMAGE)
	knockback_force = minf(knockback_force, MAX_MELEE_KNOCKBACK)
	hitstun_duration = minf(hitstun_duration, MAX_MELEE_HITSTUN)

	if damage <= 0:
		return

	print("[NetworkManager] Server-authoritative melee hit: %s -> %s (dmg=%.1f, kb=%.1f, hs=%.2f)" % [
		attacker_entity.name, target_entity.name, damage, knockback_force, hitstun_duration
	])
	
	# Apply damage through bone hitbox system if available
	var bone_system = target_entity.get_node_or_null("BoneHitboxSystem")
	if bone_system and bone_name:
		var hit_info = {
			"damage": damage,
			"damage_type": damage_type,
			"attacker": attacker_entity,
			"bone_name": bone_name
		}
		bone_system.process_hit(bone_name, damage, hit_info)
		print("[NetworkManager] Melee hit applied via bone system: %s -> %s (bone: %s)" % [
			attacker_peer_id, target_id, bone_name
		])
	elif target_entity.has_method("take_damage"):
		# Fallback to direct damage
		target_entity.take_damage(damage, attacker_entity, damage_type)
		print("[NetworkManager] Melee hit applied direct: %s -> %s" % [attacker_peer_id, target_id])
	
	# Apply knockback on server
	if knockback_force > 0 and knockback_direction.length_squared() > 0.01:
		if target_entity.has_method("apply_knockback"):
			var kb_vec = knockback_direction.normalized() * knockback_force
			target_entity.apply_knockback(kb_vec)
			print("[NetworkManager] Applied knockback: %s (force=%.2f)" % [kb_vec, knockback_force])
	
	# Apply hitstun on server
	if hitstun_duration > 0:
		if target_entity.has_method("apply_hitstun"):
			target_entity.apply_hitstun(hitstun_duration)
	
	# Broadcast hit result to all clients (so they all see knockback/hitstun)
	_broadcast_melee_hit_result(target_id, {
		"damage": damage,
		"knockback_force": knockback_force,
		"knockback_direction": knockback_direction,
		"hitstun_duration": hitstun_duration,
		"attacker_id": attacker_peer_id
	})

func _get_server_weapon_stats(attacker_entity: Node, weapon_id: String) -> Dictionary:
	## SERVER-SIDE: Look up weapon stats from ItemDatabase or the entity's equipped weapon
	## This prevents clients from lying about their weapon's damage

	# Try to get ItemDatabase for authoritative weapon stats
	var item_db = get_node_or_null("/root/ItemDatabase")

	# First try: Look up by weapon_id in ItemDatabase
	if item_db and not weapon_id.is_empty():
		var stats = item_db.get_weapon_stats(weapon_id) if item_db.has_method("get_weapon_stats") else {}
		if not stats.is_empty():
			return stats

	# Second try: Get weapon from attacker's EquipmentManager
	var equipment = attacker_entity.get_node_or_null("EquipmentManager")
	if equipment:
		var melee_component = equipment.get_current_melee_component() if equipment.has_method("get_current_melee_component") else null
		if melee_component:
			# Get stats directly from the server's copy of the weapon component
			return {
				"damage": melee_component.damage if "damage" in melee_component else 30.0,
				"knockback_force": melee_component.knockback_force if "knockback_force" in melee_component else 5.0,
				"hitstun_duration": melee_component.hitstun_duration if "hitstun_duration" in melee_component else 0.3,
				"damage_type": melee_component.damage_type if "damage_type" in melee_component else "melee"
			}

		# Try getting the current weapon's item_id and looking it up
		var current_weapon = equipment.current_weapon if "current_weapon" in equipment else null
		if current_weapon and "item_id" in current_weapon:
			var item_id = current_weapon.item_id
			if item_db and item_db.has_method("get_weapon_stats"):
				var stats = item_db.get_weapon_stats(item_id)
				if not stats.is_empty():
					return stats

	# Fallback: empty dict triggers bare-handed damage
	return {}

func _find_server_entity_by_id(entity_id: int) -> Node:
	## Find non-player server entities (NPCs, punching bags, etc)
	## Uses entity_id which could be a custom network ID or instance_id
	for entity in get_tree().get_nodes_in_group("server_entities"):
		if entity.has_method("get_network_id") and entity.get_network_id() == entity_id:
			return entity
		if entity.get_instance_id() == entity_id:
			return entity
	
	# Also check "enemies" and "hittable" groups as fallback
	for entity in get_tree().get_nodes_in_group("enemies"):
		if entity.has_method("get_network_id") and entity.get_network_id() == entity_id:
			return entity
		if entity.get_instance_id() == entity_id:
			return entity
	
	return null

func find_server_entity_by_name(entity_name: String) -> Node:
	## Find server entity by node name (more reliable than instance_id)
	for entity in get_tree().get_nodes_in_group("server_entities"):
		if entity.name == entity_name:
			return entity
	for entity in get_tree().get_nodes_in_group("enemies"):
		if entity.name == entity_name:
			return entity
	for entity in get_tree().get_nodes_in_group("players"):
		if entity.name == entity_name:
			return entity
	return null

func _broadcast_melee_hit_result(target_id: int, hit_result: Dictionary):
	## Server broadcasts hit result to all clients
	for peer_id in connected_peers:
		if peer_id == 1:  # Skip server
			continue
		_rpc_melee_hit_result.rpc_id(peer_id, target_id, hit_result)

@rpc("authority", "call_remote", "reliable")
func _rpc_melee_hit_result(target_id: int, hit_result: Dictionary):
	## Client receives hit result from server - apply knockback/hitstun
	if is_server:
		return
	
	# Find target entity locally
	var target_entity = _find_entity_by_peer_id(target_id)
	if not target_entity:
		target_entity = _find_local_entity_by_id(target_id)
	
	if not target_entity:
		return
	
	# Apply knockback (server authoritative)
	var kb_force = hit_result.get("knockback_force", 0.0)
	var kb_dir: Vector3 = hit_result.get("knockback_direction", Vector3.ZERO)
	if kb_force > 0 and kb_dir.length_squared() > 0.01 and target_entity.has_method("apply_knockback"):
		target_entity.apply_knockback(kb_dir.normalized() * kb_force)
	
	# Apply hitstun
	var hitstun = hit_result.get("hitstun_duration", 0.0)
	if hitstun > 0 and target_entity.has_method("apply_hitstun"):
		target_entity.apply_hitstun(hitstun)

func _find_local_entity_by_id(entity_id: int) -> Node:
	## Find entities by custom ID on client side
	for entity in get_tree().get_nodes_in_group("server_entities"):
		if entity.has_method("get_network_id") and entity.get_network_id() == entity_id:
			return entity
		if entity.get_instance_id() == entity_id:
			return entity
	return null
#endregion

#region Server-Authoritative Dialogue System
## Dialogue state (client-side)
var _dialogue_ui: Control = null
var _current_dialogue_node_id: String = ""
var _dialogue_ui_scene: PackedScene = preload("res://scenes/ui/dialogue_ui.tscn")

## Client requests to start dialogue with an NPC
func request_dialogue(npc_tree_id: String):
	if is_server:
		# Server player - process locally
		_handle_dialogue_request(1, npc_tree_id)
	else:
		# Send request to server
		_rpc_request_dialogue.rpc_id(1, npc_tree_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_dialogue(tree_id: String):
	if not is_server:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_dialogue_request(sender_id, tree_id)

func _handle_dialogue_request(peer_id: int, tree_id: String):
	## Server-side: Look up dialogue and send first node to client
	if not connected_peers.has(peer_id):
		return
	
	var player_data = connected_peers[peer_id] as PlayerData
	var steam_id = player_data.steam_id
	
	# Get DialogueDatabase (server-side only)
	var dialogue_db = _get_dialogue_database()
	if not dialogue_db:
		# Database may still be initializing - this is normal on first request
		print("[NetworkManager] DialogueDatabase not ready yet, try again later")
		return
	
	# Get the dialogue tree
	var tree = dialogue_db.get_dialogue_tree(tree_id)
	if tree.is_empty():
		print("[NetworkManager] Dialogue tree not found: ", tree_id)
		return
	
	# Get first node
	var first_node = dialogue_db.get_first_node(tree_id)
	if first_node.is_empty():
		print("[NetworkManager] No nodes in dialogue tree: ", tree_id)
		return
	
	# Get choices for the node
	var choices = dialogue_db.get_node_choices(first_node.node_id, steam_id)
	
	# Build dialogue data to send
	var dialogue_data = _build_dialogue_node_data(first_node, choices, tree)
	
	# Track that this player is now in dialogue (server-authoritative - blocks movement)
	_set_player_dialogue_node(peer_id, first_node.node_id)
	
	# Send to client
	if peer_id == 1:
		# Server's local player
		_receive_dialogue_node(dialogue_data)
	else:
		_rpc_dialogue_node.rpc_id(peer_id, dialogue_data)

func _build_dialogue_node_data(node: Dictionary, choices: Array, tree: Dictionary) -> Dictionary:
	## Build a client-friendly dialogue data packet
	var choice_data = []
	for choice in choices:
		choice_data.append({
			"text": choice.get("choice_text", "..."),
			"available": choice.get("available", true),
			"style": choice.get("style", "normal")
		})
	
	return {
		"node_id": node.get("node_id", ""),
		"tree_id": node.get("tree_id", ""),
		"speaker": node.get("speaker", ""),
		"npc_name": tree.get("tree_name", tree.get("npc_id", "")),
		"text": node.get("text", ""),
		"choices": choice_data,
		"has_next": not node.get("next_node_id", "").is_empty() or choice_data.size() > 0
	}

@rpc("authority", "call_remote", "reliable")
func _rpc_dialogue_node(dialogue_data: Dictionary):
	## Client receives dialogue node from server
	if is_server:
		return
	_receive_dialogue_node(dialogue_data)

var _dialogue_canvas: CanvasLayer = null  # High layer for dialogue UI

func _receive_dialogue_node(dialogue_data: Dictionary):
	## Display dialogue node (both server player and client)
	_current_dialogue_node_id = dialogue_data.get("node_id", "")
	
	# Enter talking state and show cursor
	_enter_dialogue_mode()
	
	# Show dialogue UI in high-layer canvas (above HUD)
	if not _dialogue_ui or not is_instance_valid(_dialogue_ui):
		# Create canvas layer if needed
		if not _dialogue_canvas or not is_instance_valid(_dialogue_canvas):
			_dialogue_canvas = CanvasLayer.new()
			_dialogue_canvas.layer = 200  # Higher than WeaponHUD (default layer)
			get_tree().root.add_child(_dialogue_canvas)
		
		_dialogue_ui = _dialogue_ui_scene.instantiate()
		_dialogue_canvas.add_child(_dialogue_ui)
		_dialogue_ui.choice_pressed.connect(_on_dialogue_choice_pressed)
		_dialogue_ui.next_pressed.connect(_on_dialogue_next_pressed)
	
	_dialogue_ui.visible = true
	
	# Set speaker name
	var speaker = dialogue_data.get("speaker", "")
	if speaker == "npc":
		speaker = dialogue_data.get("npc_name", "")
	_dialogue_ui.set_speaker(speaker)
	
	# Set text
	_dialogue_ui.set_text(dialogue_data.get("text", ""))
	
	# Set choices if any
	var choices = dialogue_data.get("choices", [])
	if choices.size() > 0:
		_dialogue_ui.set_choices(choices)
	else:
		_dialogue_ui.hide_choices()

func _on_dialogue_choice_pressed(choice_index: int):
	## Client selected a dialogue choice
	if is_server:
		_handle_dialogue_choice(1, choice_index)
	else:
		_rpc_dialogue_choice.rpc_id(1, choice_index)

func _on_dialogue_next_pressed():
	## Client pressed next (no choices)
	if is_server:
		_handle_dialogue_advance(1)
	else:
		_rpc_dialogue_advance.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dialogue_choice(choice_index: int):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_dialogue_choice(sender_id, choice_index)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dialogue_advance():
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_dialogue_advance(sender_id)

func _handle_dialogue_choice(peer_id: int, choice_index: int):
	## Server processes player's dialogue choice
	print("[NetworkManager] Handling dialogue choice: peer=%d index=%d" % [peer_id, choice_index])
	
	if not connected_peers.has(peer_id):
		print("[NetworkManager] Peer not found: ", peer_id)
		return
	
	var player_data = connected_peers[peer_id] as PlayerData
	var steam_id = player_data.steam_id
	
	var dialogue_db = _get_dialogue_database()
	if not dialogue_db:
		print("[NetworkManager] No dialogue database!")
		return
	
	# Get current node's choices
	var current_node_id = _get_player_dialogue_node(peer_id)
	if current_node_id.is_empty():
		print("[NetworkManager] No current dialogue node for peer!")
		return
	
	print("[NetworkManager] Current node: ", current_node_id)
	
	var choices = dialogue_db.get_node_choices(current_node_id, steam_id)
	print("[NetworkManager] Available choices: ", choices.size())
	
	if choice_index < 0 or choice_index >= choices.size():
		print("[NetworkManager] Invalid choice index: %d (have %d)" % [choice_index, choices.size()])
		return
	
	var choice = choices[choice_index]
	print("[NetworkManager] Selected choice: ", choice.get("choice_text", "?"), " -> target: ", choice.get("target_node_id", "NONE"))
	
	# Check availability
	if not choice.get("available", true):
		print("[NetworkManager] Choice not available!")
		return
	
	# Record history
	dialogue_db.record_dialogue_history(steam_id, 
		dialogue_db.get_dialogue_node(current_node_id).get("tree_id", ""),
		current_node_id, choice.get("choice_id", ""))
	
	# Execute choice events (server-side)
	var events = choice.get("events", [])
	if events.size() > 0:
		print("[NetworkManager] Executing %d events" % events.size())
		_execute_dialogue_events(events, peer_id)
	
	# Navigate to target node
	var target_id = choice.get("target_node_id", "")
	if target_id and not target_id.is_empty():
		var target_node = dialogue_db.get_dialogue_node(target_id)
		print("[NetworkManager] Looking up target node: ", target_id, " found: ", not target_node.is_empty())
		if not target_node.is_empty():
			# Execute on_enter_events for the target node (server-side)
			var enter_events = target_node.get("on_enter_events", [])
			if enter_events.size() > 0:
				print("[NetworkManager] Executing %d on_enter events for node: %s" % [enter_events.size(), target_id])
				_execute_dialogue_events(enter_events, peer_id)

			var tree = dialogue_db.get_dialogue_tree(target_node.get("tree_id", ""))
			var next_choices = dialogue_db.get_node_choices(target_id, steam_id)
			var dialogue_data = _build_dialogue_node_data(target_node, next_choices, tree)

			_set_player_dialogue_node(peer_id, target_id)

			if peer_id == 1:
				_receive_dialogue_node(dialogue_data)
			else:
				_rpc_dialogue_node.rpc_id(peer_id, dialogue_data)
			return
		else:
			print("[NetworkManager] Target node not found in database!")
	else:
		print("[NetworkManager] No target_node_id - ending dialogue")
	
	# No target = end dialogue
	_end_dialogue_for_peer(peer_id)

func _handle_dialogue_advance(peer_id: int):
	## Server advances dialogue to next node (no choice selected)
	if not connected_peers.has(peer_id):
		return
	
	var player_data = connected_peers[peer_id] as PlayerData
	var steam_id = player_data.steam_id
	
	var dialogue_db = _get_dialogue_database()
	if not dialogue_db:
		return
	
	var current_node_id = _get_player_dialogue_node(peer_id)
	if current_node_id.is_empty():
		return
	
	var current_node = dialogue_db.get_dialogue_node(current_node_id)
	var tree_id = current_node.get("tree_id", "")
	
	# Execute on_exit events (already an array, not JSON string)
	var exit_events = current_node.get("on_exit_events", [])
	if exit_events.size() > 0:
		_execute_dialogue_events(exit_events, peer_id)
	
	# Get next valid node
	var next_node = dialogue_db.get_next_valid_node(current_node_id, steam_id)

	if not next_node.is_empty():
		# Execute on_enter_events for the next node (server-side)
		var enter_events = next_node.get("on_enter_events", [])
		if enter_events.size() > 0:
			print("[NetworkManager] Executing %d on_enter events for node: %s" % [enter_events.size(), next_node.node_id])
			_execute_dialogue_events(enter_events, peer_id)

		var tree = dialogue_db.get_dialogue_tree(tree_id)
		var next_choices = dialogue_db.get_node_choices(next_node.node_id, steam_id)
		var dialogue_data = _build_dialogue_node_data(next_node, next_choices, tree)

		_set_player_dialogue_node(peer_id, next_node.node_id)

		if peer_id == 1:
			_receive_dialogue_node(dialogue_data)
		else:
			_rpc_dialogue_node.rpc_id(peer_id, dialogue_data)
		return

	# No next node = end dialogue
	_end_dialogue_for_peer(peer_id)

func _end_dialogue_for_peer(peer_id: int):
	## End dialogue session for a player
	_set_player_dialogue_node(peer_id, "")
	
	if peer_id == 1:
		_close_dialogue_ui()
	else:
		_rpc_end_dialogue.rpc_id(peer_id)

@rpc("authority", "call_remote", "reliable")
func _rpc_end_dialogue():
	if is_server:
		return
	_close_dialogue_ui()

func cancel_dialogue():
	## Called by client to cancel dialogue (e.g., pressing ESC)
	## This notifies the server to end the dialogue session
	if is_server:
		# Server player - end directly
		_end_dialogue_for_peer(1)
	else:
		# Client - notify server
		_rpc_cancel_dialogue.rpc_id(1)
		# Also close UI locally immediately for responsiveness
		_close_dialogue_ui()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_cancel_dialogue():
	## Client requests to cancel their dialogue
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	print("[NetworkManager] Player %d cancelled dialogue" % sender_id)
	_end_dialogue_for_peer(sender_id)

func _close_dialogue_ui():
	if _dialogue_ui and is_instance_valid(_dialogue_ui):
		_dialogue_ui.visible = false
	_current_dialogue_node_id = ""
	
	# Exit dialogue mode and restore cursor
	_exit_dialogue_mode()

func _enter_dialogue_mode():
	## Put local player in talking state (which handles mouse visibility)
	## The talking state is the SINGLE SOURCE OF TRUTH for mouse capture
	
	# Find local player and enter talking state
	var local_player = _get_local_player()
	if local_player:
		var state_manager = local_player.get_node_or_null("StateManager")
		if state_manager and state_manager.has_method("change_state"):
			var current_state = ""
			if state_manager.has_method("get_current_state_name"):
				current_state = state_manager.get_current_state_name()
			
			# Already in talking state - nothing to do (mouse already visible)
			if current_state == "talking":
				return
			
			# Only allow dialogue from idle or moving state
			if current_state not in ["idle", "moving", ""]:
				print("[NetworkManager] Cannot enter dialogue from state: ", current_state)
				return
			
			# Add talking state dynamically if it doesn't exist
			if state_manager.has_method("has_state") and not state_manager.has_state("talking"):
				var TalkingStateScript = load("res://addons/gsg-godot-plugins/action_entities/scripts/states/state_talking.gd")
				if TalkingStateScript:
					var talking_state = Node.new()
					talking_state.set_script(TalkingStateScript)
					talking_state.name = "talking"
					state_manager.add_state("talking", talking_state)
			
			if state_manager.has_state("talking"):
				state_manager.change_state("talking", true)
				print("[NetworkManager] Entered dialogue mode")

func _exit_dialogue_mode():
	## Return local player to idle state
	## The talking state's on_exit will handle mouse capture (checking if other UIs need it)
	
	var local_player = _get_local_player()
	if local_player:
		var state_manager = local_player.get_node_or_null("StateManager")
		if state_manager and state_manager.has_method("change_state"):
			if state_manager.has_method("get_current_state_name"):
				if state_manager.get_current_state_name() == "talking":
					# Clear any buffered inputs to prevent attacks on dialogue close
					if state_manager.has_method("clear_input_buffers"):
						state_manager.clear_input_buffers()
					state_manager.change_state("idle", true)
					print("[NetworkManager] Exited dialogue mode")

func _get_local_player() -> Node:
	## Get the local player node
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if "can_receive_input" in player and player.can_receive_input:
			return player
	return null

## Track each player's current dialogue node (server-side)
var _player_dialogue_nodes: Dictionary = {}  # peer_id -> node_id

func _get_player_dialogue_node(peer_id: int) -> String:
	return _player_dialogue_nodes.get(peer_id, "")

func _set_player_dialogue_node(peer_id: int, node_id: String):
	if node_id.is_empty():
		_player_dialogue_nodes.erase(peer_id)
	else:
		_player_dialogue_nodes[peer_id] = node_id

func _get_dialogue_database() -> Node:
	## Get or create DialogueDatabase (server-side only)
	## Returns null if database is not ready for queries
	if not is_server:
		return null
	
	# Look for existing DialogueDatabase
	var db = get_node_or_null("DialogueDatabase")
	if not db:
		# Create one if needed
		var DialogueDatabaseClass = load("res://addons/gsg-godot-plugins/database_manager/dialogue_database.gd")
		if DialogueDatabaseClass:
			db = DialogueDatabaseClass.new()
			db.name = "DialogueDatabase"
			add_child(db)
	
	# Check if the database is actually ready for queries
	if db and db.has_method("is_ready") and not db.is_ready():
		# Database exists but tables not initialized yet
		return null
	
	return db

func _execute_dialogue_events(events: Variant, peer_id: int):
	## Execute dialogue events on server
	if not events is Array:
		return
	
	var player_data = connected_peers.get(peer_id) as PlayerData
	if not player_data:
		return
	
	for event in events:
		if not event is Dictionary:
			continue
		
		var event_type = event.get("type", "")
		var params = event.get("params", {})
		
		match event_type:
			"start_mission":
				if has_node("/root/MissionManager"):
					var mission_id = params.get("mission_id", "")
					get_node("/root/MissionManager").start_mission(mission_id, [])
			"set_flag":
				var dialogue_db = _get_dialogue_database()
				if dialogue_db:
					var flag_key = params.get("flag_key", "")
					var value = params.get("value", true)
					dialogue_db.set_dialogue_flag(player_data.steam_id, flag_key, value)
			"open_shop":
				# Send open_shop event to client
				var shop_id = params.get("shop_id", "supply_officer")
				if peer_id == 1:
					_open_shop_local(shop_id, player_data.character_id, player_data.steam_id)
				else:
					_rpc_open_shop.rpc_id(peer_id, shop_id, player_data.character_id, player_data.steam_id)
			"give_credits":
				var item_db = get_node_or_null("/root/ItemDatabase")
				if item_db:
					var amount = int(params.get("amount", 0))
					if amount > 0 and player_data.character_id > 0:
						item_db.add_credits(player_data.character_id, amount)
						print("[NetworkManager] Gave %d credits to character %d" % [amount, player_data.character_id])
			"descend_planet", "descend_rental":
				# Teleporter NPC events - forward to NPC handler
				_forward_event_to_npc(event, peer_id, player_data)
			_:
				# Try to forward unhandled events to the NPC
				if not _forward_event_to_npc(event, peer_id, player_data):
					print("[NetworkManager] Unhandled dialogue event: ", event_type)

func _forward_event_to_npc(event: Dictionary, peer_id: int, player_data: PlayerData) -> bool:
	## Forward a dialogue event to the NPC that initiated the dialogue
	## Returns true if event was handled

	# Get current dialogue node to find the tree_id
	var current_node_id = _get_player_dialogue_node(peer_id)
	if current_node_id.is_empty():
		return false

	# Extract tree_id from node_id (format: "tree_id_node_local_id")
	var dialogue_db = _get_dialogue_database()
	if not dialogue_db:
		return false

	var node = dialogue_db.get_dialogue_node(current_node_id)
	if node.is_empty():
		return false

	var tree_id = node.get("tree_id", "")
	if tree_id.is_empty():
		return false

	var tree = dialogue_db.get_dialogue_tree(tree_id)
	var npc_id = tree.get("npc_id", "")
	if npc_id.is_empty():
		return false

	# Find the NPC in scene
	var npc = _find_npc_by_id(npc_id)
	if not npc:
		print("[NetworkManager] Could not find NPC: ", npc_id)
		return false

	# Get player entity
	var player_entity = player_data.entity if player_data else null

	# Forward to NPC
	if npc.has_method("handle_dialogue_event"):
		npc.handle_dialogue_event(event, player_entity)
		return true

	return false

func _find_npc_by_id(npc_id: String) -> Node:
	## Find an NPC in the scene by its npc_id
	for npc in get_tree().get_nodes_in_group("npcs"):
		if not is_instance_valid(npc):
			continue

		# Check by dialogue_tree_id prefix (e.g., "teleporter" matches "teleporter_main")
		if npc.has_method("get_dialogue_tree_id"):
			var tree_id = npc.get_dialogue_tree_id()
			if tree_id.begins_with(npc_id) or npc_id.begins_with(tree_id.get_slice("_", 0)):
				return npc

		# Check by npc_id method
		if npc.has_method("get_npc_id"):
			if npc.get_npc_id() == npc_id:
				return npc

		# Check by entity_id property
		if "entity_id" in npc and npc.entity_id == npc_id:
			return npc

		# Check by node name
		if npc.name.to_lower().contains(npc_id.to_lower()):
			return npc

	return null

#region Shop System
@rpc("authority", "call_remote", "reliable")
func _rpc_open_shop(shop_id: String, character_id: int, steam_id: int):
	## Client receives shop open command from server
	if is_server:
		return
	_open_shop_local(shop_id, character_id, steam_id)

func _open_shop_local(shop_id: String, character_id: int, steam_id: int):
	## Open shop UI for the local player
	var player = _get_local_player()
	if not player:
		push_warning("[NetworkManager] Cannot open shop - no local player")
		return

	# First close dialogue
	_close_dialogue_ui()

	# Get or create shop panel
	var shop_panel = _get_or_create_shop_panel(player)
	if not shop_panel:
		return

	# Disable player input while shop is open (same as inventory)
	if "can_receive_input" in player:
		player.can_receive_input = false

	# Show mouse cursor
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Open shop
	shop_panel.open(shop_id, character_id, steam_id)

	print("[NetworkManager] Opened shop: %s" % shop_id)

func _get_or_create_shop_panel(player: Node) -> Control:
	## Get existing shop panel or create one
	var existing = player.get_node_or_null("ShopUILayer/ShopPanel")
	if existing:
		return existing
	
	var shop_scene = load("res://scenes/ui/shop/shop_panel.tscn")
	if not shop_scene:
		push_error("[NetworkManager] Could not load shop_panel.tscn")
		return null
	
	var shop_panel = shop_scene.instantiate()
	
	var canvas = CanvasLayer.new()
	canvas.name = "ShopUILayer"
	canvas.layer = 100
	player.add_child(canvas)
	canvas.add_child(shop_panel)
	
	# Connect shop closed to exit talking state
	shop_panel.shop_closed.connect(_on_shop_closed)
	
	return shop_panel

func _on_shop_closed():
	## Called when shop panel is closed
	var player = _get_local_player()
	if player:
		# Re-enable player input
		if "can_receive_input" in player:
			player.can_receive_input = true
		# Recapture mouse
		var camera = player.get_node_or_null("PlayerCamera")
		if camera and camera.has_method("set_mouse_captured"):
			camera.set_mouse_captured(true)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_exit_dialogue_mode()
	print("[NetworkManager] Shop closed, input re-enabled")
#endregion

#region Heartbeat / Latency
func _process_heartbeats(delta: float):
	var current_time = Time.get_ticks_msec() / 1000.0
	
	if is_server:
		# Check for timed out clients
		for peer_id in connected_peers.keys():
			var player_data = connected_peers[peer_id] as PlayerData
			if peer_id == 1:
				continue  # Skip local server player
			
			var time_since_heartbeat = current_time - player_data.last_heartbeat
			if time_since_heartbeat > heartbeat_interval * max_missed_heartbeats:
				print("[NetworkManager] Peer ", peer_id, " timed out")
				_kick_peer(peer_id, "Connection timeout")
	else:
		# Send heartbeat to server
		_rpc_heartbeat.rpc_id(1, Time.get_ticks_msec())

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_heartbeat(client_time: int):
	if not is_server:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if not connected_peers.has(sender_id):
		return
	
	var player_data = connected_peers[sender_id] as PlayerData
	player_data.last_heartbeat = Time.get_ticks_msec() / 1000.0
	
	# Respond with server time for latency calculation
	# Also include the sender_id so client can track their latency
	_rpc_heartbeat_response.rpc_id(sender_id, client_time, Time.get_ticks_msec())
	
	# On server: request latency report from client
	_rpc_request_latency.rpc_id(sender_id, Time.get_ticks_msec())

# Server sends this to measure RTT to each client
@rpc("authority", "call_remote", "unreliable")
func _rpc_request_latency(server_time: int):
	if is_server:
		return
	# Respond immediately so server can measure RTT
	_rpc_latency_response.rpc_id(1, server_time)

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_latency_response(original_server_time: int):
	if not is_server:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var current_time = Time.get_ticks_msec()
	var round_trip = current_time - original_server_time
	var latency = round_trip / 2
	
	# Update server-side latency tracking for this peer
	if not latency_samples.has(sender_id):
		latency_samples[sender_id] = []
	
	latency_samples[sender_id].append(latency)
	if latency_samples[sender_id].size() > LATENCY_SAMPLE_COUNT:
		latency_samples[sender_id].pop_front()
	
	# Calculate average
	var avg = 0
	for sample in latency_samples[sender_id]:
		avg += sample
	avg /= latency_samples[sender_id].size()
	
	current_latency[sender_id] = avg
	
	# Update PlayerData
	if connected_peers.has(sender_id):
		var player_data = connected_peers[sender_id] as PlayerData
		player_data.latency_ms = avg
	
	latency_updated.emit(sender_id, avg)

@rpc("authority", "call_remote", "unreliable")
func _rpc_heartbeat_response(original_client_time: int, _server_time: int):
	if is_server:
		return
	
	var current_time = Time.get_ticks_msec()
	var round_trip = current_time - original_client_time
	var latency = round_trip / 2
	
	# Update latency tracking
	if not latency_samples.has(1):
		latency_samples[1] = []
	
	latency_samples[1].append(latency)
	if latency_samples[1].size() > LATENCY_SAMPLE_COUNT:
		latency_samples[1].pop_front()
	
	# Calculate average
	var avg = 0
	for sample in latency_samples[1]:
		avg += sample
	avg /= latency_samples[1].size()
	
	current_latency[1] = avg
	latency_updated.emit(1, avg)

@rpc("authority", "call_remote", "reliable")
func _rpc_kicked(reason: String):
	print("[NetworkManager] Kicked from server: ", reason)
	_cleanup_network()
	disconnected_from_server.emit("Kicked: " + reason)
#endregion

#region Utility
func get_peer_count() -> int:
	return connected_peers.size()

func get_peer_ids() -> Array:
	return connected_peers.keys()

func get_peer_latency(peer_id: int) -> int:
	return current_latency.get(peer_id, 0)

func get_player_data(peer_id: int) -> PlayerData:
	return connected_peers.get(peer_id, null)

func get_peer_for_entity(entity: Node) -> int:
	## Look up the peer_id for a given player entity
	if not entity or not is_instance_valid(entity):
		return 0
	for peer_id in connected_peers:
		var pd = connected_peers[peer_id] as PlayerData
		if pd.entity == entity:
			return peer_id
	return 0

func is_connected_or_hosting() -> bool:
	return state == NetworkState.CONNECTED or state == NetworkState.HOSTING

func is_offline() -> bool:
	return state == NetworkState.OFFLINE

func get_local_peer_id() -> int:
	return local_peer_id if local_peer_id > 0 else 1

func get_all_players_info() -> Array:
	## Get info about all connected players for the player list UI
	var players = []
	for peer_id in connected_peers:
		var pd = connected_peers[peer_id] as PlayerData
		players.append({
			"peer_id": peer_id,
			"steam_id": pd.steam_id,
			"display_name": pd.display_name,
			"latency_ms": get_peer_latency(peer_id),
			"squad_id": _get_player_squad(peer_id),
			"is_squad_leader": _is_player_squad_leader(peer_id)
		})
	return players
#endregion

#region Zone Management
func set_player_zone(peer_id: int, zone_id: String):
	## Set the zone a player is currently in (server-side)
	if connected_peers.has(peer_id):
		var old_zone = connected_peers[peer_id].zone_id
		connected_peers[peer_id].zone_id = zone_id
		print("[NetworkManager] Player %d zone: %s -> %s" % [peer_id, old_zone, zone_id])

func get_player_zone(peer_id: int) -> String:
	## Get the zone a player is in
	if connected_peers.has(peer_id):
		return connected_peers[peer_id].zone_id
	return ""

func get_peers_in_zone(zone_id: String) -> Array[int]:
	## Get all peer IDs in a specific zone
	var peers: Array[int] = []
	for peer_id in connected_peers:
		if connected_peers[peer_id].zone_id == zone_id:
			peers.append(peer_id)
	return peers

func get_other_peers_in_zone(zone_id: String, exclude_peer: int = -1) -> Array[int]:
	## Get all peer IDs in a zone, optionally excluding one
	var peers: Array[int] = []
	for peer_id in connected_peers:
		if peer_id == exclude_peer:
			continue
		if connected_peers[peer_id].zone_id == zone_id:
			peers.append(peer_id)
	return peers

func is_peer_in_same_zone(peer_id_1: int, peer_id_2: int) -> bool:
	## Check if two peers are in the same zone
	var zone_1 = get_player_zone(peer_id_1)
	var zone_2 = get_player_zone(peer_id_2)
	return zone_1 == zone_2 and not zone_1.is_empty()

func get_entity_zone_id(entity: Node) -> String:
	## Get the zone ID for an entity by walking up the scene tree
	var node = entity
	while node:
		if node.has_meta("zone_id"):
			return node.get_meta("zone_id")
		node = node.get_parent()
	return ""

signal zone_scene_loading(zone_id: String, scene_path: String)
signal zone_scene_loaded(zone_id: String)

func notify_client_zone_change(peer_id: int, zone_id: String, scene_path: String):
	## Server tells client to load a specific zone scene
	if not is_server:
		return

	print("[NetworkManager] Telling peer %d to load zone %s (%s)" % [peer_id, zone_id, scene_path])

	if peer_id == 1:
		# Local server player (listen server)
		_client_load_zone(scene_path, zone_id)
	else:
		_rpc_client_load_zone.rpc_id(peer_id, scene_path, zone_id)

@rpc("authority", "call_remote", "reliable")
func _rpc_client_load_zone(scene_path: String, zone_id: String):
	_client_load_zone(scene_path, zone_id)

func _client_load_zone(scene_path: String, zone_id: String):
	## Client-side: Load the zone scene, mirroring server's node path structure
	## Server has: /root/ServerRoot/Zones/zone_id/...
	## Client must match for RPCs to work
	print("[NetworkManager] Client loading zone: %s (%s)" % [zone_id, scene_path])
	zone_scene_loading.emit(zone_id, scene_path)

	# Get or create the ServerRoot/Zones structure
	var server_root = get_tree().root.get_node_or_null("ServerRoot")
	if not server_root:
		# First time - clear current scene and create structure
		var current_scene = get_tree().current_scene
		if current_scene:
			current_scene.queue_free()

		server_root = Node.new()
		server_root.name = "ServerRoot"
		get_tree().root.add_child(server_root)
		get_tree().current_scene = server_root

		var zones_container = Node.new()
		zones_container.name = "Zones"
		server_root.add_child(zones_container)

	var zones_container = server_root.get_node("Zones")

	# Remove old zone if changing zones
	for child in zones_container.get_children():
		child.queue_free()

	# Load and add zone scene with zone_id as name (matches server)
	var scene = load(scene_path)
	if scene:
		var zone_node = scene.instantiate()
		zone_node.name = zone_id  # Critical: must match server's zone node name
		zones_container.add_child(zone_node)
		print("[NetworkManager] Client zone loaded at path: /root/ServerRoot/Zones/%s" % zone_id)
	else:
		push_error("[NetworkManager] Failed to load zone scene: %s" % scene_path)

	# Emit after scene is loaded
	call_deferred("_emit_zone_loaded", zone_id)

func _emit_zone_loaded(zone_id: String):
	zone_scene_loaded.emit(zone_id)
#endregion

#region Server-Side Squad System
# Squad data: squad_id -> { leader: peer_id, members: [peer_ids] }
var _squads: Dictionary = {}
# Invitations: invited_peer_id -> { from_peer_id: squad_id, ... }
var _pending_invites: Dictionary = {}

signal squad_updated(squad_id: int)
signal squad_invite_received(from_peer_id: int, from_name: String)
signal squad_invite_cancelled(from_peer_id: int)
signal player_list_updated()

func _get_player_squad(peer_id: int) -> int:
	## Get the squad ID a player belongs to (peer_id is also their default squad_id)
	for squad_id in _squads:
		var squad = _squads[squad_id]
		if peer_id in squad.members:
			return squad_id
	# Default: player is in their own solo squad
	return peer_id

func _is_player_squad_leader(peer_id: int) -> bool:
	var squad_id = _get_player_squad(peer_id)
	if _squads.has(squad_id):
		return _squads[squad_id].leader == peer_id
	# If in solo squad, they're the leader
	return true

func _ensure_player_has_squad(peer_id: int):
	## Ensure player has a squad (creates solo squad if needed)
	if not is_server:
		return
	
	var current_squad = _get_player_squad(peer_id)
	if not _squads.has(current_squad):
		# Create solo squad for this player
		_squads[peer_id] = {
			"leader": peer_id,
			"members": [peer_id]
		}

func _on_player_joined_server(peer_id: int):
	## Called when a player joins - give them their own squad
	_ensure_player_has_squad(peer_id)
	_broadcast_player_list()

func _on_player_left_server(peer_id: int):
	## Called when a player leaves - clean up squad data
	# Remove from any squad they're in
	var squad_id = _get_player_squad(peer_id)
	if _squads.has(squad_id):
		_squads[squad_id].members.erase(peer_id)
		
		# If they were the leader, promote someone else or disband
		if _squads[squad_id].leader == peer_id:
			if _squads[squad_id].members.size() > 0:
				_squads[squad_id].leader = _squads[squad_id].members[0]
			else:
				_squads.erase(squad_id)
	
	# Remove their solo squad if it exists
	if _squads.has(peer_id):
		_squads.erase(peer_id)
	
	# Clear any pending invites involving them
	_pending_invites.erase(peer_id)
	for invited_id in _pending_invites:
		_pending_invites[invited_id].erase(peer_id)
	
	_broadcast_player_list()

func invite_to_squad(target_peer_id: int):
	## Invite another player to your squad (anyone can invite)
	if is_server:
		_handle_squad_invite(local_peer_id, target_peer_id)
	else:
		_rpc_squad_invite.rpc_id(1, target_peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_squad_invite(target_peer_id: int):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_squad_invite(sender_id, target_peer_id)

func _handle_squad_invite(from_peer_id: int, to_peer_id: int):
	## Server: Process squad invitation
	if from_peer_id == to_peer_id:
		return  # Can't invite yourself
	
	if not connected_peers.has(to_peer_id):
		return  # Target not connected
	
	# Check if target is already in the same squad
	var from_squad = _get_player_squad(from_peer_id)
	var to_squad = _get_player_squad(to_peer_id)
	if from_squad == to_squad:
		return  # Already in same squad
	
	# Create pending invite
	if not _pending_invites.has(to_peer_id):
		_pending_invites[to_peer_id] = {}
	
	_pending_invites[to_peer_id][from_peer_id] = from_squad
	
	# Notify target of invite
	var from_name = connected_peers[from_peer_id].display_name
	if to_peer_id == 1:
		squad_invite_received.emit(from_peer_id, from_name)
	else:
		_rpc_squad_invite_notify.rpc_id(to_peer_id, from_peer_id, from_name)
	
	print("[NetworkManager] Squad invite: %s -> %s" % [from_name, connected_peers[to_peer_id].display_name])
	_broadcast_player_list()

@rpc("authority", "call_remote", "reliable")
func _rpc_squad_invite_notify(from_peer_id: int, from_name: String):
	if is_server:
		return
	squad_invite_received.emit(from_peer_id, from_name)

func accept_squad_invite(from_peer_id: int):
	## Accept a pending squad invite
	if is_server:
		_handle_squad_accept(local_peer_id, from_peer_id)
	else:
		_rpc_squad_accept.rpc_id(1, from_peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_squad_accept(from_peer_id: int):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_squad_accept(sender_id, from_peer_id)

func _handle_squad_accept(accepter_id: int, inviter_id: int):
	## Server: Process squad invite acceptance
	if not _pending_invites.has(accepter_id):
		return
	if not _pending_invites[accepter_id].has(inviter_id):
		return
	
	var target_squad_id = _pending_invites[accepter_id][inviter_id]
	
	# Remove accepter from their current squad
	var old_squad = _get_player_squad(accepter_id)
	if _squads.has(old_squad):
		_squads[old_squad].members.erase(accepter_id)
		if _squads[old_squad].members.size() == 0:
			_squads.erase(old_squad)
	
	# Add to new squad
	_ensure_player_has_squad(inviter_id)
	target_squad_id = _get_player_squad(inviter_id)
	if _squads.has(target_squad_id):
		_squads[target_squad_id].members.append(accepter_id)
	
	# Clear all pending invites for this player
	_pending_invites.erase(accepter_id)
	
	var accepter_name = connected_peers[accepter_id].display_name
	var inviter_name = connected_peers[inviter_id].display_name
	print("[NetworkManager] %s joined %s's squad" % [accepter_name, inviter_name])
	
	_broadcast_player_list()
	squad_updated.emit(target_squad_id)

func decline_squad_invite(from_peer_id: int):
	## Decline a pending squad invite
	if is_server:
		_handle_squad_decline(local_peer_id, from_peer_id)
	else:
		_rpc_squad_decline.rpc_id(1, from_peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_squad_decline(from_peer_id: int):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_squad_decline(sender_id, from_peer_id)

func _handle_squad_decline(decliner_id: int, inviter_id: int):
	if _pending_invites.has(decliner_id):
		_pending_invites[decliner_id].erase(inviter_id)
	_broadcast_player_list()

func kick_from_squad(target_peer_id: int):
	## Kick a player from your squad (leader only)
	if is_server:
		_handle_squad_kick(local_peer_id, target_peer_id)
	else:
		_rpc_squad_kick.rpc_id(1, target_peer_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_squad_kick(target_peer_id: int):
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_squad_kick(sender_id, target_peer_id)

func _handle_squad_kick(kicker_id: int, target_id: int):
	## Server: Process squad kick
	if kicker_id == target_id:
		return  # Can't kick yourself
	
	var squad_id = _get_player_squad(kicker_id)
	if not _squads.has(squad_id):
		return
	
	# Only leader can kick
	if _squads[squad_id].leader != kicker_id:
		return
	
	# Target must be in same squad
	if target_id not in _squads[squad_id].members:
		return
	
	# Remove from squad
	_squads[squad_id].members.erase(target_id)
	
	# Give them their own squad
	_squads[target_id] = {
		"leader": target_id,
		"members": [target_id]
	}
	
	print("[NetworkManager] %s was kicked from squad" % connected_peers[target_id].display_name)
	_broadcast_player_list()
	squad_updated.emit(squad_id)

func leave_squad():
	## Leave current squad and become solo
	if is_server:
		_handle_squad_leave(local_peer_id)
	else:
		_rpc_squad_leave.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_squad_leave():
	if not is_server:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	_handle_squad_leave(sender_id)

func _handle_squad_leave(peer_id: int):
	var squad_id = _get_player_squad(peer_id)
	if not _squads.has(squad_id):
		return
	
	# If leader is leaving, promote someone else
	if _squads[squad_id].leader == peer_id and _squads[squad_id].members.size() > 1:
		_squads[squad_id].members.erase(peer_id)
		_squads[squad_id].leader = _squads[squad_id].members[0]
	else:
		_squads[squad_id].members.erase(peer_id)
		if _squads[squad_id].members.size() == 0:
			_squads.erase(squad_id)
	
	# Give them their own squad
	_squads[peer_id] = {
		"leader": peer_id,
		"members": [peer_id]
	}
	
	_broadcast_player_list()
	squad_updated.emit(squad_id)

func get_pending_invites() -> Array:
	## Get list of peer_ids who have invited you
	var my_peer = local_peer_id if local_peer_id > 0 else 1
	if _pending_invites.has(my_peer):
		return _pending_invites[my_peer].keys()
	return []

func has_pending_invite_from(peer_id: int) -> bool:
	var my_peer = local_peer_id if local_peer_id > 0 else 1
	if _pending_invites.has(my_peer):
		return _pending_invites[my_peer].has(peer_id)
	return false

func get_my_squad_members() -> Array:
	## Get peer_ids of players in your squad
	var my_peer = local_peer_id if local_peer_id > 0 else 1
	
	# On server, use authoritative squad data
	if is_server:
		var squad_id = _get_player_squad(my_peer)
		if _squads.has(squad_id):
			return _squads[squad_id].members.duplicate()
		return [my_peer]
	
	# On client, use cached player info
	var my_squad_id = -1
	for p in _cached_players_info:
		if p.peer_id == my_peer:
			my_squad_id = p.squad_id
			break
	
	if my_squad_id < 0:
		return [my_peer]
	
	var members = []
	for p in _cached_players_info:
		if p.squad_id == my_squad_id:
			members.append(p.peer_id)
	
	return members if members.size() > 0 else [my_peer]

func am_i_squad_leader() -> bool:
	var my_peer = local_peer_id if local_peer_id > 0 else 1
	
	# On server, use authoritative squad data
	if is_server:
		return _is_player_squad_leader(my_peer)
	
	# On client, use cached player info
	for p in _cached_players_info:
		if p.peer_id == my_peer:
			return p.is_squad_leader
	
	# Default to true if not found (solo player)
	return true

func _broadcast_player_list():
	## Broadcast updated player/squad info to all clients
	var players_info = get_all_players_info()
	var invites_info = _pending_invites.duplicate(true)
	
	for peer_id in connected_peers:
		if peer_id == 1:
			player_list_updated.emit()
		else:
			_rpc_player_list_update.rpc_id(peer_id, players_info, invites_info)

@rpc("authority", "call_remote", "reliable")
func _rpc_player_list_update(players_info: Array, invites_info: Dictionary):
	if is_server:
		return
	
	# Update local cache
	_cached_players_info = players_info
	_pending_invites = invites_info
	player_list_updated.emit()

var _cached_players_info: Array = []

func get_cached_players_info() -> Array:
	## Get cached player info (for clients)
	if is_server:
		return get_all_players_info()
	return _cached_players_info
#endregion

#region Steam Integration
var _steam_manager: Node = null
var _pending_steam_join_lobby: int = 0
var _pending_steam_join_friend: int = 0

func _connect_steam_signals():
	_steam_manager = get_node_or_null("/root/SteamManager")
	if not _steam_manager:
		return
	
	# When someone accepts our Steam invite and joins our lobby
	if _steam_manager.has_signal("lobby_member_joined"):
		_steam_manager.lobby_member_joined.connect(_on_steam_lobby_member_joined)
	
	# When we click "Join Game" on a friend's invite
	if _steam_manager.has_signal("lobby_join_requested"):
		_steam_manager.lobby_join_requested.connect(_on_steam_join_requested)
	
	# When we successfully join a lobby
	if _steam_manager.has_signal("lobby_joined"):
		_steam_manager.lobby_joined.connect(_on_steam_lobby_joined)

func invite_player_via_steam(steam_id: int):
	## Send both a Steam lobby invite and a squad invite
	## This is called when using the player list to invite someone
	if not _steam_manager:
		return
	
	# Find peer_id for this steam_id
	var peer_id = _get_peer_id_for_steam_id(steam_id)
	
	# Send squad invite if they're already connected
	if peer_id > 0:
		invite_to_squad(peer_id)
	
	# Also send Steam lobby invite (they may not be in our game instance yet)
	if _steam_manager.has_method("invite_to_lobby"):
		_steam_manager.invite_to_lobby(steam_id)

func _get_peer_id_for_steam_id(target_steam_id: int) -> int:
	for peer_id in connected_peers:
		var pd = connected_peers[peer_id] as PlayerData
		if pd.steam_id == target_steam_id:
			return peer_id
	return -1

func _get_steam_id_for_peer_id(peer_id: int) -> int:
	if connected_peers.has(peer_id):
		return (connected_peers[peer_id] as PlayerData).steam_id
	return 0

func _on_steam_lobby_member_joined(steam_id: int):
	## Called when someone joins our Steam lobby
	## Auto-send them a squad invite
	print("[NetworkManager] Steam lobby member joined: ", steam_id)
	
	# Wait a moment for them to connect to the game server
	await get_tree().create_timer(1.0).timeout
	
	var peer_id = _get_peer_id_for_steam_id(steam_id)
	if peer_id > 0:
		# They're now connected - send squad invite
		invite_to_squad(peer_id)

func _on_steam_join_requested(lobby_id: int, friend_id: int):
	## Called when user clicks "Join Game" on a Steam friend's invite
	print("[NetworkManager] Steam join requested - lobby: ", lobby_id, " friend: ", friend_id)
	
	if not _steam_manager:
		return
	
	var current_lobby = _steam_manager.get_current_lobby_id() if _steam_manager.has_method("get_current_lobby_id") else 0
	
	if current_lobby == lobby_id:
		# We're already in the same lobby - just accept their squad invite
		var peer_id = _get_peer_id_for_steam_id(friend_id)
		if peer_id > 0 and has_pending_invite_from(peer_id):
			accept_squad_invite(peer_id)
			_show_notification("Joined " + _get_player_name(peer_id) + "'s squad!")
		else:
			# No pending invite - send them one
			if peer_id > 0:
				invite_to_squad(peer_id)
				_show_notification("Invited " + _get_player_name(peer_id) + " to your squad")
	else:
		# Different lobby - try to join it
		_pending_steam_join_lobby = lobby_id
		_pending_steam_join_friend = friend_id
		
		# Check if lobby is full first
		# For now, just try to join and handle failure in lobby_joined
		_steam_manager.join_lobby(lobby_id)

func _on_steam_lobby_joined(lobby_id: int, response: int):
	## Called when we finish joining a Steam lobby
	if _pending_steam_join_lobby == 0:
		return  # Not a pending join request
	
	if lobby_id != _pending_steam_join_lobby:
		return
	
	_pending_steam_join_lobby = 0
	
	# Check response - 1 = success for Steam
	if response != 1:
		# Join failed - likely full
		var reason = "Unknown error"
		match response:
			2: reason = "Lobby doesn't exist"
			3: reason = "Lobby is not accepting new members"
			4: reason = "Lobby is full"
			5: reason = "Unexpected error"
			6: reason = "Access denied"
			7: reason = "Banned from this lobby"
			_: reason = "Failed to join (code: " + str(response) + ")"
		
		_show_notification("Friend's instance is full!" if response == 4 else reason)
		_pending_steam_join_friend = 0
		return
	
	# Successfully joined - now we need to connect to their game server
	# The connection will be handled by whatever scene manages lobby -> game transitions
	_show_notification("Joined friend's game!")
	
	# Auto-accept squad invite from the friend who invited us
	if _pending_steam_join_friend > 0:
		# Wait for us to connect and receive player list
		await get_tree().create_timer(2.0).timeout
		
		var peer_id = _get_peer_id_for_steam_id(_pending_steam_join_friend)
		if peer_id > 0 and has_pending_invite_from(peer_id):
			accept_squad_invite(peer_id)
		
		_pending_steam_join_friend = 0

func _get_player_name(peer_id: int) -> String:
	if connected_peers.has(peer_id):
		return (connected_peers[peer_id] as PlayerData).display_name
	return "Unknown"

func _show_notification(message: String):
	## Show a notification popup
	var notification_manager = get_node_or_null("/root/NotificationManager")
	if notification_manager and notification_manager.has_method("show_notification"):
		notification_manager.show_notification(message)
	else:
		print("[NetworkManager] Notification: ", message)
#endregion

