extends Node

## ZoneManager - Manages zone instances with dynamic spawning and player routing
## Handles both hub zones (persistent social spaces) and mission zones (instanced gameplay)

#region Signals
signal zone_created(zone_id: String, zone_type: String)
signal zone_destroyed(zone_id: String)
signal player_joined_zone(peer_id: int, zone_id: String)
signal player_left_zone(peer_id: int, zone_id: String)
signal zone_capacity_changed(zone_id: String, current: int, max: int)
signal zone_status_changed(zone_id: String, status: String)
signal transfer_requested(peer_id: int, from_zone: String, to_zone: String)
signal transfer_completed(peer_id: int, zone_id: String)
#endregion

#region Configuration
@export_group("Hub Zones")
@export var hub_scene_path: String = "res://scenes/hub/hub.tscn"
@export var hub_max_players: int = 32
@export var hub_min_instances: int = 1 # Always keep at least this many hubs
@export var hub_spawn_threshold: float = 0.8 # Spawn new when 80% full

@export_group("Mission Zones")
@export var mission_max_players: int = 32 # 8 squads of 4
@export var mission_squad_size: int = 4
@export var mission_timeout_empty: float = 60.0 # Seconds before empty mission closes

@export_group("Instance Management")
@export var instance_check_interval: float = 5.0
@export var graceful_shutdown_time: float = 30.0
#endregion

#region Zone Data Structures
class ZoneInstance:
	var zone_id: String = ""
	var zone_type: String = "" # "hub" or "mission"
	var scene_path: String = ""
	var status: String = "initializing" # initializing, active, closing, closed
	var players: Array[int] = [] # Peer IDs currently in zone
	var squads: Array[Array] = [] # For missions: [[peer_id, ...], ...]
	var max_players: int = 32
	var created_at: float = 0.0
	var last_activity: float = 0.0
	var metadata: Dictionary = {}
	var scene_instance: Node = null
	
	# Squad slot reservations: { squad_leader_peer_id: { "slots": count, "members": [peer_ids], "expires": timestamp } }
	var reserved_slots: Dictionary = {}
	const RESERVATION_TIMEOUT: float = 120.0  # 2 minutes to join before reservation expires
	
	func get_player_count() -> int:
		return players.size()
	
	func get_reserved_slot_count() -> int:
		## Count slots reserved for squad members who haven't joined yet
		var reserved = 0
		for squad_id in reserved_slots:
			var reservation = reserved_slots[squad_id]
			# Count members who haven't joined yet
			for member_id in reservation.members:
				if member_id not in players:
					reserved += 1
		return reserved
	
	func get_effective_player_count() -> int:
		## Players + reserved slots (for capacity calculation)
		return players.size() + get_reserved_slot_count()
	
	func get_capacity_percent() -> float:
		return float(get_effective_player_count()) / float(max_players) if max_players > 0 else 1.0
	
	func has_space(count: int = 1) -> bool:
		return get_effective_player_count() + count <= max_players
	
	func has_space_for_squad(squad_size: int) -> bool:
		## Check if zone has space for an entire squad (including reservations)
		return get_effective_player_count() + squad_size <= max_players
	
	func is_empty() -> bool:
		return players.size() == 0 and get_reserved_slot_count() == 0
	
	func reserve_squad_slots(leader_peer_id: int, squad_member_ids: Array) -> bool:
		## Reserve slots for an entire squad when the leader beams down
		if not has_space_for_squad(squad_member_ids.size()):
			return false
		
		reserved_slots[leader_peer_id] = {
			"slots": squad_member_ids.size(),
			"members": squad_member_ids.duplicate(),
			"expires": Time.get_unix_time_from_system() + RESERVATION_TIMEOUT
		}
		return true
	
	func release_squad_reservation(leader_peer_id: int):
		## Release reservation when squad disbands or leader leaves
		reserved_slots.erase(leader_peer_id)
	
	func player_joined_with_reservation(peer_id: int):
		## Called when a player joins - check if they're part of a reservation
		# If this player is a reserved member, they don't need to consume extra slots
		# (they were already counted in reserved_slots)
		pass  # The reservation tracking handles this automatically
	
	func has_reservation_for_player(peer_id: int) -> bool:
		## Check if this player has a reserved slot
		for squad_id in reserved_slots:
			if peer_id in reserved_slots[squad_id].members:
				return true
		return false
	
	func check_expired_reservations():
		## Remove expired reservations
		var now = Time.get_unix_time_from_system()
		var expired = []
		for squad_id in reserved_slots:
			if reserved_slots[squad_id].expires < now:
				expired.append(squad_id)
		for squad_id in expired:
			reserved_slots.erase(squad_id)
	
	func to_dict() -> Dictionary:
		return {
			"zone_id": zone_id,
			"zone_type": zone_type,
			"status": status,
			"player_count": players.size(),
			"reserved_slots": get_reserved_slot_count(),
			"effective_count": get_effective_player_count(),
			"max_players": max_players,
			"squad_count": squads.size(),
			"metadata": metadata
		}
#endregion

#region State
var zones: Dictionary = {} # zone_id -> ZoneInstance
var player_zones: Dictionary = {} # peer_id -> zone_id
var pending_transfers: Dictionary = {} # peer_id -> {from, to, timestamp}
var zone_counter: int = 0
var check_timer: float = 0.0
#endregion

func _ready():
	# Start with minimum hub instances
	for i in range(hub_min_instances):
		create_hub_zone()

func _process(delta: float):
	check_timer += delta
	if check_timer >= instance_check_interval:
		check_timer = 0.0
		_check_instance_capacity()
		_check_empty_missions()
		_check_expired_reservations()

#region Hub Zone Management
func create_hub_zone(channel_name: String = "") -> String:
	zone_counter += 1
	var zone_id = "hub_" + str(zone_counter)
	
	var zone = ZoneInstance.new()
	zone.zone_id = zone_id
	zone.zone_type = "hub"
	zone.scene_path = hub_scene_path
	zone.max_players = hub_max_players
	zone.created_at = Time.get_unix_time_from_system()
	zone.last_activity = zone.created_at
	zone.metadata["channel"] = channel_name if channel_name else "Channel " + str(zone_counter)
	zone.status = "active"
	
	zones[zone_id] = zone
	
	print("[ZoneManager] Created hub zone: ", zone_id)
	zone_created.emit(zone_id, "hub")
	
	return zone_id

func get_or_create_zone(zone_type: String, scene_path: String = "") -> String:
	## Generic function to get an available zone of the given type, or create one
	## scene_path is required for non-standard zone types

	# Resolve scene path from defaults if not provided
	if scene_path.is_empty():
		match zone_type:
			"hub":
				scene_path = hub_scene_path
			"test":
				scene_path = "res://scenes/test.tscn"
			_:
				push_error("[ZoneManager] No scene_path provided for zone type: %s" % zone_type)
				return ""

	# Look for existing zone of this type with space
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == zone_type and zone.status == "active" and zone.has_space():
			return zone_id

	# Create new zone
	return _create_zone(zone_type, scene_path)

func _create_zone(zone_type: String, scene_path: String) -> String:
	## Internal: Create a new zone of any type
	zone_counter += 1
	var zone_id = zone_type + "_" + str(zone_counter)

	var zone = ZoneInstance.new()
	zone.zone_id = zone_id
	zone.zone_type = zone_type
	zone.scene_path = scene_path
	zone.max_players = hub_max_players if zone_type == "hub" else 32
	zone.created_at = Time.get_unix_time_from_system()
	zone.last_activity = zone.created_at
	zone.status = "active"

	zones[zone_id] = zone

	print("[ZoneManager] Created %s zone: %s -> %s" % [zone_type, zone_id, scene_path])
	zone_created.emit(zone_id, zone_type)

	return zone_id

func get_available_hub() -> String:
	## Find hub with space, preferring less full ones
	## This uses special logic to prefer emptier hubs, otherwise use get_or_create_zone("hub")
	var best_hub: ZoneInstance = null
	var best_capacity: float = 1.0

	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type != "hub":
			continue
		if zone.status != "active":
			continue
		if not zone.has_space():
			continue

		var capacity = zone.get_capacity_percent()
		if capacity < best_capacity:
			best_capacity = capacity
			best_hub = zone

	if best_hub:
		return best_hub.zone_id

	# All hubs full - create new one
	return _create_zone("hub", hub_scene_path)

func get_hub_list() -> Array:
	var hubs = []
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == "hub" and zone.status == "active":
			hubs.append(zone.to_dict())
	return hubs
#endregion

#region Mission Zone Management
func create_mission_zone(mission_id: String, squad_steam_ids: Array = []) -> String:
	zone_counter += 1
	var zone_id = "mission_" + str(zone_counter) + "_" + mission_id
	
	var zone = ZoneInstance.new()
	zone.zone_id = zone_id
	zone.zone_type = "mission"
	zone.scene_path = _get_mission_scene_path(mission_id)
	zone.max_players = mission_max_players
	zone.created_at = Time.get_unix_time_from_system()
	zone.last_activity = zone.created_at
	zone.metadata["mission_id"] = mission_id
	zone.metadata["started_at"] = zone.created_at
	zone.status = "active"
	
	# Initialize with requesting squad
	if squad_steam_ids.size() > 0:
		zone.squads.append(squad_steam_ids)
	
	zones[zone_id] = zone
	
	print("[ZoneManager] Created mission zone: ", zone_id, " for mission: ", mission_id)
	zone_created.emit(zone_id, "mission")
	
	return zone_id

func find_mission_zone(mission_id: String, squad_size: int = 4) -> String:
	# Find existing mission zone with space for this squad
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type != "mission":
			continue
		if zone.status != "active":
			continue
		if zone.metadata.get("mission_id") != mission_id:
			continue
		if not zone.has_space_for_squad(squad_size):
			continue
		
		# Found suitable zone
		return zone_id
	
	# No suitable zone - create new one
	return create_mission_zone(mission_id)

func join_mission_as_squad(mission_id: String, squad_peer_ids: Array) -> String:
	## Deprecated: Use beam_down_squad instead for proper slot reservation
	var zone_id = find_mission_zone(mission_id, squad_peer_ids.size())
	var zone = zones[zone_id] as ZoneInstance
	
	# Add squad to zone
	zone.squads.append(squad_peer_ids)
	
	# Add each player
	for peer_id in squad_peer_ids:
		_add_player_to_zone(peer_id, zone_id)
	
	return zone_id

func beam_down_squad(mission_id: String, leader_peer_id: int, squad_member_ids: Array) -> Dictionary:
	## Called when squad leader initiates beam down - reserves slots for entire squad
	## Returns { "success": bool, "zone_id": String, "error": String }
	
	# Ensure leader is in the member list
	if leader_peer_id not in squad_member_ids:
		squad_member_ids = [leader_peer_id] + squad_member_ids
	
	var squad_size = squad_member_ids.size()
	var zone_id = find_mission_zone(mission_id, squad_size)
	
	if zone_id.is_empty():
		return {"success": false, "zone_id": "", "error": "Failed to find or create mission zone"}
	
	var zone = zones[zone_id] as ZoneInstance
	
	# Reserve slots for entire squad
	if not zone.reserve_squad_slots(leader_peer_id, squad_member_ids):
		return {"success": false, "zone_id": "", "error": "Instance is full"}
	
	# Register squad in zone
	zone.squads.append(squad_member_ids)
	
	print("[ZoneManager] Reserved %d slots for squad (leader: %d) in zone %s" % [squad_size, leader_peer_id, zone_id])
	
	return {"success": true, "zone_id": zone_id, "error": ""}

func beam_down_player(peer_id: int, zone_id: String) -> bool:
	## Called when individual player beams down - checks for reservation
	if not zones.has(zone_id):
		return false
	
	var zone = zones[zone_id] as ZoneInstance
	
	# Check if player has a reservation
	if zone.has_reservation_for_player(peer_id):
		# Player has reserved slot - add them
		return _add_player_to_zone(peer_id, zone_id)
	
	# No reservation - check if there's general space
	if not zone.has_space(1):
		return false
	
	return _add_player_to_zone(peer_id, zone_id)

func cancel_squad_beam_down(leader_peer_id: int, zone_id: String):
	## Cancel a squad beam down and release reservations
	if not zones.has(zone_id):
		return
	
	var zone = zones[zone_id] as ZoneInstance
	zone.release_squad_reservation(leader_peer_id)
	
	# Remove squad from zone's squad list
	for i in range(zone.squads.size() - 1, -1, -1):
		if leader_peer_id in zone.squads[i]:
			zone.squads.remove_at(i)
			break
	
	print("[ZoneManager] Cancelled squad reservation for leader %d in zone %s" % [leader_peer_id, zone_id])

func end_mission(zone_id: String, result: String = "completed"):
	if not zones.has(zone_id):
		return
	
	var zone = zones[zone_id] as ZoneInstance
	zone.status = "closing"
	zone.metadata["result"] = result
	zone.metadata["ended_at"] = Time.get_unix_time_from_system()
	
	zone_status_changed.emit(zone_id, "closing")
	
	# Transfer all players back to hub
	for peer_id in zone.players.duplicate():
		request_transfer_to_hub(peer_id)

func _get_mission_scene_path(mission_id: String) -> String:
	# Override this or use a mission registry
	return "res://scenes/missions/" + mission_id + ".tscn"
#endregion

#region Player Management
func add_player_to_zone(peer_id: int, zone_id: String) -> bool:
	if not zones.has(zone_id):
		return false
	
	var zone = zones[zone_id] as ZoneInstance
	if not zone.has_space():
		return false
	
	return _add_player_to_zone(peer_id, zone_id)

func _add_player_to_zone(peer_id: int, zone_id: String) -> bool:
	var zone = zones[zone_id] as ZoneInstance

	# Remove from current zone if any
	if player_zones.has(peer_id):
		remove_player_from_zone(peer_id)

	zone.players.append(peer_id)
	zone.last_activity = Time.get_unix_time_from_system()
	player_zones[peer_id] = zone_id

	# Update NetworkManager's player data with zone
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("set_player_zone"):
		network.set_player_zone(peer_id, zone_id)

	# Update Steam rich presence for local player
	_update_steam_presence(peer_id, zone)

	player_joined_zone.emit(peer_id, zone_id)
	zone_capacity_changed.emit(zone_id, zone.get_player_count(), zone.max_players)
	
	return true

func remove_player_from_zone(peer_id: int):
	if not player_zones.has(peer_id):
		return

	var zone_id = player_zones[peer_id]
	player_zones.erase(peer_id)

	# Clear NetworkManager's player zone data
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("set_player_zone"):
		network.set_player_zone(peer_id, "")

	if zones.has(zone_id):
		var zone = zones[zone_id] as ZoneInstance
		zone.players.erase(peer_id)
		zone.last_activity = Time.get_unix_time_from_system()

		# If this player was a squad leader with reservations, release them
		if zone.reserved_slots.has(peer_id):
			print("[ZoneManager] Squad leader %d left - releasing reservations" % peer_id)
			zone.release_squad_reservation(peer_id)

		# Check if any squad members remain - if not, free ALL squad slots
		_check_squad_presence_in_zone(zone, peer_id)

		# Remove from squad if in mission
		for squad in zone.squads:
			if peer_id in squad:
				squad.erase(peer_id)
				break

		player_left_zone.emit(peer_id, zone_id)
		zone_capacity_changed.emit(zone_id, zone.get_player_count(), zone.max_players)

	# Update Steam presence to menu if this was the local player
	_clear_steam_presence(peer_id)

func _check_squad_presence_in_zone(zone: ZoneInstance, leaving_peer_id: int):
	## Check if any squad members are still in the zone after this player leaves
	## If no squad members remain, free all reservations for that squad
	
	# Find which squad the leaving player belongs to
	var leaving_player_squad_leader: int = -1
	
	for leader_id in zone.reserved_slots:
		var reservation = zone.reserved_slots[leader_id]
		if leaving_peer_id in reservation.members:
			leaving_player_squad_leader = leader_id
			break
	
	if leaving_player_squad_leader < 0:
		return  # Player wasn't part of a reserved squad
	
	# Check if ANY members of this squad are still in the zone
	var reservation = zone.reserved_slots[leaving_player_squad_leader]
	var any_member_present = false
	
	for member_id in reservation.members:
		if member_id in zone.players:
			any_member_present = true
			break
	
	if not any_member_present:
		# No squad members left on planet - free ALL slots for this squad
		print("[ZoneManager] No squad members remain in zone - freeing all slots for squad (leader: %d)" % leaving_player_squad_leader)
		zone.release_squad_reservation(leaving_player_squad_leader)
		
		# Also remove the squad from zone.squads
		for i in range(zone.squads.size() - 1, -1, -1):
			var squad = zone.squads[i]
			if leaving_player_squad_leader in squad or leaving_peer_id in squad:
				zone.squads.remove_at(i)
				break

func _clear_steam_presence(peer_id: int):
	if not has_node("/root/NetworkManager"):
		return
	var network = get_node("/root/NetworkManager")
	if peer_id != network.local_peer_id:
		return
	
	if has_node("/root/SteamManager"):
		get_node("/root/SteamManager").set_in_menu()

func get_player_zone(peer_id: int) -> String:
	return player_zones.get(peer_id, "")

func get_zone_players(zone_id: String) -> Array[int]:
	if zones.has(zone_id):
		return zones[zone_id].players.duplicate()
	return []
#endregion

#region Zone Transfers
func request_transfer_to_hub(peer_id: int, preferred_hub: String = "") -> bool:
	var target_zone = preferred_hub if preferred_hub else get_available_hub()
	return request_transfer(peer_id, target_zone)

func request_transfer_to_mission(peer_id: int, mission_id: String) -> bool:
	var zone_id = find_mission_zone(mission_id)
	return request_transfer(peer_id, zone_id)

func request_transfer(peer_id: int, target_zone: String) -> bool:
	if not zones.has(target_zone):
		return false
	
	var current_zone = get_player_zone(peer_id)
	
	pending_transfers[peer_id] = {
		"from": current_zone,
		"to": target_zone,
		"timestamp": Time.get_unix_time_from_system()
	}
	
	transfer_requested.emit(peer_id, current_zone, target_zone)
	return true

func complete_transfer(peer_id: int) -> bool:
	if not pending_transfers.has(peer_id):
		return false
	
	var transfer = pending_transfers[peer_id]
	pending_transfers.erase(peer_id)
	
	var success = _add_player_to_zone(peer_id, transfer.to)
	
	if success:
		transfer_completed.emit(peer_id, transfer.to)
	
	return success

func cancel_transfer(peer_id: int):
	pending_transfers.erase(peer_id)
#endregion

#region Instance Management
func _check_instance_capacity():
	# Check if we need more hub instances
	var hub_count = 0
	var full_hubs = 0
	
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == "hub" and zone.status == "active":
			hub_count += 1
			if zone.get_capacity_percent() >= hub_spawn_threshold:
				full_hubs += 1
	
	# If all hubs are near capacity, spawn a new one
	if hub_count > 0 and full_hubs == hub_count:
		create_hub_zone()
	
	# If we have excess empty hubs, close some (keep minimum)
	var empty_hubs = []
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == "hub" and zone.status == "active" and zone.is_empty():
			empty_hubs.append(zone_id)
	
	while empty_hubs.size() > hub_min_instances:
		var zone_id = empty_hubs.pop_back()
		_close_zone(zone_id)

func _check_empty_missions():
	var now = Time.get_unix_time_from_system()
	
	for zone_id in zones.keys():
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type != "mission":
			continue
		if zone.status != "active":
			continue
		
		if zone.is_empty():
			var empty_time = now - zone.last_activity
			if empty_time >= mission_timeout_empty:
				_close_zone(zone_id)

func _check_expired_reservations():
	## Clean up expired squad reservations across all zones
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		var had_reservations = zone.reserved_slots.size() > 0
		zone.check_expired_reservations()
		
		if had_reservations and zone.reserved_slots.size() == 0:
			print("[ZoneManager] All reservations expired in zone: ", zone_id)

func _close_zone(zone_id: String):
	if not zones.has(zone_id):
		return
	
	var zone = zones[zone_id] as ZoneInstance
	zone.status = "closed"
	
	# Remove any remaining players
	for peer_id in zone.players.duplicate():
		remove_player_from_zone(peer_id)
	
	# Clean up scene instance
	if zone.scene_instance and is_instance_valid(zone.scene_instance):
		zone.scene_instance.queue_free()
	
	zones.erase(zone_id)
	
	print("[ZoneManager] Closed zone: ", zone_id)
	zone_destroyed.emit(zone_id)
#endregion

#region Zone Queries
func get_zone_info(zone_id: String) -> Dictionary:
	if zones.has(zone_id):
		return zones[zone_id].to_dict()
	return {}

func get_all_zones() -> Array:
	var zone_list = []
	for zone_id in zones:
		zone_list.append(zones[zone_id].to_dict())
	return zone_list

func get_zones_by_type(zone_type: String) -> Array:
	var zone_list = []
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == zone_type:
			zone_list.append(zone.to_dict())
	return zone_list

func get_mission_zones(mission_id: String) -> Array:
	var zone_list = []
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		if zone.zone_type == "mission" and zone.metadata.get("mission_id") == mission_id:
			zone_list.append(zone.to_dict())
	return zone_list

func get_zone_count() -> Dictionary:
	var counts = {"hub": 0, "mission": 0, "total": 0}
	for zone_id in zones:
		var zone = zones[zone_id] as ZoneInstance
		counts[zone.zone_type] = counts.get(zone.zone_type, 0) + 1
		counts.total += 1
	return counts

func get_total_players() -> int:
	return player_zones.size()
#endregion

#region Steam Rich Presence
func _update_steam_presence(peer_id: int, zone: ZoneInstance):
	# Only update for local player
	if not has_node("/root/NetworkManager"):
		return
	var network = get_node("/root/NetworkManager")
	if peer_id != network.local_peer_id:
		return
	
	if not has_node("/root/SteamManager"):
		return
	var steam = get_node("/root/SteamManager")
	
	match zone.zone_type:
		"hub":
			var channel = zone.metadata.get("channel", "")
			steam.set_in_hub(channel)
		"mission":
			var mission_id = zone.metadata.get("mission_id", "Unknown")
			var mission_name = _get_mission_display_name(mission_id)
			steam.set_in_mission(mission_name, zone.zone_id)

func _get_mission_display_name(mission_id: String) -> String:
	# Override this or use a mission registry to get display names
	# For now just capitalize and replace underscores
	return mission_id.replace("_", " ").capitalize()
#endregion

#region Scene Loading (Server-side)
func load_zone_scene(zone_id: String, parent: Node) -> Node:
	if not zones.has(zone_id):
		return null
	
	var zone = zones[zone_id] as ZoneInstance
	
	if zone.scene_instance and is_instance_valid(zone.scene_instance):
		return zone.scene_instance
	
	var scene = load(zone.scene_path)
	if not scene:
		push_error("[ZoneManager] Failed to load scene: ", zone.scene_path)
		return null
	
	zone.scene_instance = scene.instantiate()
	zone.scene_instance.name = zone_id
	parent.add_child(zone.scene_instance)
	
	return zone.scene_instance
#endregion

#region Orbit/Planet Destination Control
signal destination_locked(planet_id: String, mission_id: String)
signal destination_unlocked()

# Track squad's orbit destination: squad_leader_peer_id -> planet_id
var squad_destinations: Dictionary = {}

func can_change_destination(squad_leader_peer_id: int) -> Dictionary:
	## Check if squad can freely change their orbit destination
	## Returns: { "can_change": bool, "reason": String, "locked_planet": String }
	
	var mission_manager = get_node_or_null("/root/MissionManager")
	if not mission_manager:
		return {"can_change": true, "reason": "", "locked_planet": ""}
	
	# Check if squad has active deployment
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("get_my_squad_members"):
		var squad_members = network.get_my_squad_members()
		
		# Check if any squad member is currently on a mission planet
		for member_id in squad_members:
			var zone_id = get_player_zone(member_id)
			if zone_id and zones.has(zone_id):
				var zone = zones[zone_id] as ZoneInstance
				if zone.zone_type == "mission":
					var mission_id = zone.metadata.get("mission_id", "")
					var planet_id = _get_planet_for_mission(mission_id)
					return {
						"can_change": false,
						"reason": "Squad member on planet",
						"locked_planet": planet_id,
						"mission_id": mission_id
					}
	
	# Check if squad is on deployment (even if not on planet yet)
	if mission_manager.has_method("get_deployment_info"):
		var deployment = mission_manager.get_deployment_info()
		if deployment.has("mission_id") and not deployment.mission_id.is_empty():
			var mission_id = deployment.mission_id
			var planet_id = _get_planet_for_mission(mission_id)
			return {
				"can_change": false,
				"reason": "On deployment",
				"locked_planet": planet_id,
				"mission_id": mission_id
			}
	
	# No deployment, can change freely
	return {"can_change": true, "reason": "", "locked_planet": ""}

func set_squad_destination(squad_leader_peer_id: int, planet_id: String) -> bool:
	## Set squad's orbit destination (leader only, when not on deployment)
	var check = can_change_destination(squad_leader_peer_id)
	if not check.can_change:
		print("[ZoneManager] Cannot change destination: %s (locked to %s)" % [check.reason, check.locked_planet])
		return false
	
	squad_destinations[squad_leader_peer_id] = planet_id
	print("[ZoneManager] Squad %d destination set to: %s" % [squad_leader_peer_id, planet_id])
	return true

func get_squad_destination(squad_leader_peer_id: int) -> String:
	## Get squad's current orbit destination
	var check = can_change_destination(squad_leader_peer_id)
	if not check.can_change:
		# On deployment - destination is locked to mission planet
		return check.locked_planet
	
	# Return freely chosen destination
	return squad_destinations.get(squad_leader_peer_id, "")

func get_allowed_destinations(squad_leader_peer_id: int) -> Array:
	## Get list of planets squad can travel to
	var check = can_change_destination(squad_leader_peer_id)
	if not check.can_change:
		# On deployment - only mission planet is allowed
		return [check.locked_planet]
	
	# Not on deployment - return all available planets
	return _get_all_planets()

func _get_planet_for_mission(mission_id: String) -> String:
	## Get the planet/location associated with a mission
	## Override this or use mission data
	var mission_manager = get_node_or_null("/root/MissionManager")
	if mission_manager and mission_manager.has_method("get_mission"):
		var mission = mission_manager.get_mission(mission_id)
		if mission and "planet" in mission:
			return mission.planet
		# Fallback: extract from scene path or mission ID
		# e.g., "planet_alpha_mission_01" -> "planet_alpha"
		if "_" in mission_id:
			var parts = mission_id.split("_")
			if parts.size() >= 2:
				return parts[0] + "_" + parts[1]
	
	return mission_id  # Fallback to mission_id as planet

func _get_all_planets() -> Array:
	## Get list of all available planets
	## Override this with your planet registry
	return ["planet_alpha", "planet_beta", "planet_gamma", "asteroid_belt"]

func is_squad_on_planet(squad_leader_peer_id: int) -> bool:
	## Check if any squad member is currently on a mission planet
	var network = get_node_or_null("/root/NetworkManager")
	if not network or not network.has_method("get_my_squad_members"):
		return false
	
	var squad_members = network.get_my_squad_members()
	for member_id in squad_members:
		var zone_id = get_player_zone(member_id)
		if zone_id and zones.has(zone_id):
			var zone = zones[zone_id] as ZoneInstance
			if zone.zone_type == "mission":
				return true
	
	return false
#endregion
