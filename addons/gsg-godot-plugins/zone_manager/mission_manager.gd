extends Node

## MissionManager - Singleton handling all mission logic
## NPCs just trigger dialogue, dialogue events route here

#region Signals
signal missions_updated()
signal mission_started(mission_id: String, squad: Array)
signal mission_completed(mission_id: String, result: Dictionary)
signal mission_failed(mission_id: String, reason: String)
signal mission_abandoned(mission_id: String)
signal rewards_granted(mission_id: String, rewards: Dictionary)
signal step_changed(step_index: int)
signal objective_updated(objective_id: String, completed: bool)
signal deployment_synced(mission_id: String, step_index: int)
#endregion

#region Configuration
@export var missions_data_path: String = "res://data/missions/missions.json"
#endregion

#region State
# All mission definitions: mission_id -> MissionData
var missions: Dictionary = {}

# Player's active missions: mission_id -> ActiveMission
var active_missions: Dictionary = {}

# Current mission (if in one)
var current_mission_id: String = ""
var current_zone_id: String = ""
#endregion

#region Data Structures
class MissionData:
	var id: String = ""
	var name: String = ""
	var description: String = ""
	var difficulty: String = "normal" # easy, normal, hard, extreme
	var recommended_level: int = 1
	var min_players: int = 1
	var max_players: int = 4
	var scene_path: String = ""
	var planet: String = ""  # Planet/location this mission takes place on
	var objectives: Array = []
	var rewards: Dictionary = {} # {currency: int, exp: int, items: []}
	var unlock_conditions: Dictionary = {}
	
	static func from_dict(data: Dictionary) -> MissionData:
		var m = MissionData.new()
		m.id = data.get("id", "")
		m.name = data.get("name", m.id)
		m.description = data.get("description", "")
		m.difficulty = data.get("difficulty", "normal")
		m.recommended_level = data.get("recommended_level", 1)
		m.min_players = data.get("min_players", 1)
		m.max_players = data.get("max_players", 4)
		m.scene_path = data.get("scene_path", "res://scenes/missions/" + m.id + ".tscn")
		m.planet = data.get("planet", "")
		m.objectives = data.get("objectives", [])
		m.rewards = data.get("rewards", {})
		m.unlock_conditions = data.get("unlock_conditions", {})
		return m

class ActiveMission:
	var mission_id: String = ""
	var zone_id: String = ""
	var squad: Array = []
	var squad_leader: int = 0  # Steam ID of squad leader
	var started_at: float = 0.0
	var current_step_index: int = 0
	var objectives_completed: Array = []
	var loot_collected: Array = []

# Current deployment (synced across squad)
var current_deployment: Dictionary = {}  # mission_id, step_index, leader
#endregion

func _ready():
	_load_missions_data()

#region Data Loading
func _load_missions_data():
	# Load from JSON file
	if FileAccess.file_exists(missions_data_path):
		var file = FileAccess.open(missions_data_path, FileAccess.READ)
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			for mission_id in data:
				var mission_data = data[mission_id]
				mission_data["id"] = mission_id
				missions[mission_id] = MissionData.from_dict(mission_data)
			print("[MissionManager] Loaded ", missions.size(), " missions")

func register_mission(mission_id: String, data: Dictionary):
	data["id"] = mission_id
	missions[mission_id] = MissionData.from_dict(data)
	missions_updated.emit()
#endregion

#region Mission Queries
func get_mission(mission_id: String) -> MissionData:
	return missions.get(mission_id, null)

func get_all_missions() -> Array:
	return missions.values()

func get_available_missions(steam_id: int = 0) -> Array:
	var available = []
	for mission in missions.values():
		if _is_mission_available(mission, steam_id):
			available.append(mission)
	return available

func get_available_mission_ids(steam_id: int = 0) -> Array[String]:
	var ids: Array[String] = []
	for mission in get_available_missions(steam_id):
		ids.append(mission.id)
	return ids

func _is_mission_available(mission: MissionData, steam_id: int) -> bool:
	if mission.unlock_conditions.is_empty():
		return true
	
	# Check conditions via DialogueDatabase flags
	if has_node("/root/DatabaseManager"):
		var db = get_node("/root/DatabaseManager")
		for flag_key in mission.unlock_conditions:
			var required = mission.unlock_conditions[flag_key]
			# This would need DialogueDatabase integration
			# For now, return true
	
	return true

func get_mission_info(mission_id: String) -> Dictionary:
	var mission = get_mission(mission_id)
	if not mission:
		return {}
	
	return {
		"id": mission.id,
		"name": mission.name,
		"description": mission.description,
		"difficulty": mission.difficulty,
		"recommended_level": mission.recommended_level,
		"rewards": mission.rewards
	}
#endregion

#region Mission Flow
func start_mission(mission_id: String, squad: Array = []) -> bool:
	var mission = get_mission(mission_id)
	if not mission:
		push_error("[MissionManager] Unknown mission: ", mission_id)
		return false
	
	# Validate squad size
	if squad.size() < mission.min_players:
		push_error("[MissionManager] Not enough players for mission")
		return false
	
	if squad.size() > mission.max_players:
		squad = squad.slice(0, mission.max_players)
	
	# Create zone via ZoneManager
	var zone_id = ""
	if has_node("/root/ZoneManager"):
		zone_id = ZoneManager.join_mission_as_squad(mission_id, squad)
	
	# Determine squad leader
	var leader_id = 0
	var squad_manager = get_node_or_null("/root/SquadManager")
	if not squad_manager:
		var hub = get_tree().get_first_node_in_group("hub")
		if hub:
			squad_manager = hub.get_node_or_null("SquadManager")
	
	if squad_manager and squad_manager.squad_members.size() > 0:
		leader_id = squad_manager.squad_members[0]  # First member is usually leader
	elif squad.size() > 0:
		leader_id = squad[0]
	
	# Track active mission
	var active = ActiveMission.new()
	active.mission_id = mission_id
	active.zone_id = zone_id
	active.squad = squad
	active.squad_leader = leader_id
	active.current_step_index = 0
	active.started_at = Time.get_unix_time_from_system()
	active_missions[mission_id] = active
	
	# Set deployment
	set_deployment(mission_id, 0)
	
	current_mission_id = mission_id
	current_zone_id = zone_id
	
	# Record in database
	_record_mission_start(mission_id, squad)
	
	mission_started.emit(mission_id, squad)
	
	# Update rich presence
	if has_node("/root/SteamManager"):
		SteamManager.set_in_mission(mission.name, zone_id)
	
	return true

func complete_mission(mission_id: String, result: Dictionary = {}) -> bool:
	if not active_missions.has(mission_id):
		return false
	
	var active = active_missions[mission_id]
	var mission = get_mission(mission_id)
	
	# Calculate rewards
	var rewards = _calculate_rewards(mission, result)
	
	# Grant rewards to squad
	_grant_rewards(active.squad, rewards)
	
	# Record completion
	_record_mission_complete(mission_id, "completed", result)
	
	# Cleanup
	active_missions.erase(mission_id)
	if current_mission_id == mission_id:
		current_mission_id = ""
		current_zone_id = ""
	
	mission_completed.emit(mission_id, result)
	rewards_granted.emit(mission_id, rewards)
	
	# Return to hub
	_return_squad_to_hub(active.squad)
	
	return true

func fail_mission(mission_id: String, reason: String = "failed"):
	if not active_missions.has(mission_id):
		return
	
	var active = active_missions[mission_id]
	
	# Record failure
	_record_mission_complete(mission_id, "failed", {"reason": reason})
	
	# Cleanup
	active_missions.erase(mission_id)
	if current_mission_id == mission_id:
		current_mission_id = ""
		current_zone_id = ""
	
	mission_failed.emit(mission_id, reason)
	
	# Return to hub (no rewards)
	_return_squad_to_hub(active.squad)

func abandon_mission(mission_id: String):
	if not active_missions.has(mission_id):
		return
	
	var active = active_missions[mission_id]
	
	# Record abandonment
	_record_mission_complete(mission_id, "abandoned", {})
	
	# Cleanup
	active_missions.erase(mission_id)
	if current_mission_id == mission_id:
		current_mission_id = ""
		current_zone_id = ""
	
	mission_abandoned.emit(mission_id)
	
	# Return to hub
	_return_squad_to_hub(active.squad)
#endregion

#region Rewards
func _calculate_rewards(mission: MissionData, result: Dictionary) -> Dictionary:
	var rewards = mission.rewards.duplicate()
	
	# Bonus for performance
	var score = result.get("score", 0)
	var time_bonus = result.get("time_bonus", 1.0)
	
	if rewards.has("currency"):
		rewards.currency = int(rewards.currency * time_bonus)
	
	return rewards

func _grant_rewards(squad: Array, rewards: Dictionary):
	if not has_node("/root/DatabaseManager"):
		return
	
	for peer_id in squad:
		# Get player's steam_id and character_id
		# Grant rewards via DatabaseManager
		pass # TODO: Implement based on your player data structure
#endregion

#region Database Recording
func _record_mission_start(mission_id: String, squad: Array):
	if not has_node("/root/DatabaseManager"):
		return
	
	# Record in match_history table
	# TODO: Get steam_id and character_id from each squad member

func _record_mission_complete(mission_id: String, result: String, data: Dictionary):
	if not has_node("/root/DatabaseManager"):
		return
	
	# Update match_history with result
#endregion

#region Hub Return
func _return_squad_to_hub(squad: Array):
	if not has_node("/root/ZoneManager"):
		return
	
	for peer_id in squad:
		ZoneManager.request_transfer_to_hub(peer_id)
#endregion

#region Utility
func is_in_mission() -> bool:
	return current_mission_id != ""

func get_current_mission() -> String:
	return current_mission_id

func get_current_zone() -> String:
	return current_zone_id

func get_squad() -> Array:
	if active_missions.has(current_mission_id):
		return active_missions[current_mission_id].squad
	return []
#endregion

#region Step Management
func get_current_step_index() -> int:
	if active_missions.has(current_mission_id):
		return active_missions[current_mission_id].current_step_index
	return 0

func advance_step() -> bool:
	## Advance to the next step (squad leader only)
	if not _is_squad_leader():
		push_warning("[MissionManager] Only squad leader can advance steps")
		return false
	
	if not active_missions.has(current_mission_id):
		return false
	
	var active = active_missions[current_mission_id]
	var mission = get_mission(current_mission_id)
	if not mission:
		return false
	
	var steps = mission.objectives  # Using objectives as steps
	if active.current_step_index < steps.size() - 1:
		active.current_step_index += 1
		step_changed.emit(active.current_step_index)
		_sync_deployment_to_squad()
		return true
	
	return false

func set_step(step_index: int) -> bool:
	## Set to a specific step (squad leader only)
	if not _is_squad_leader():
		return false
	
	if not active_missions.has(current_mission_id):
		return false
	
	var active = active_missions[current_mission_id]
	var mission = get_mission(current_mission_id)
	if not mission:
		return false
	
	var steps = mission.objectives
	if step_index >= 0 and step_index < steps.size():
		active.current_step_index = step_index
		step_changed.emit(step_index)
		_sync_deployment_to_squad()
		return true
	
	return false

func complete_objective(objective_id: String) -> bool:
	## Mark an objective as completed
	if not active_missions.has(current_mission_id):
		return false
	
	var active = active_missions[current_mission_id]
	if objective_id not in active.objectives_completed:
		active.objectives_completed.append(objective_id)
		objective_updated.emit(objective_id, true)
		
		# Auto-advance step if this was the current objective
		var mission = get_mission(current_mission_id)
		if mission:
			var steps = mission.objectives
			if active.current_step_index < steps.size():
				var current_step = steps[active.current_step_index]
				if current_step.get("id", "") == objective_id:
					advance_step()
		
		return true
	return false

func _is_squad_leader() -> bool:
	## Check if local player is the squad leader
	var squad_manager = get_node_or_null("/root/SquadManager")
	if squad_manager and "is_squad_leader" in squad_manager:
		return squad_manager.is_squad_leader
	
	# Check hub SquadManager
	var hub = get_tree().get_first_node_in_group("hub")
	if hub:
		var hub_squad = hub.get_node_or_null("SquadManager")
		if hub_squad and "is_squad_leader" in hub_squad:
			return hub_squad.is_squad_leader
	
	# Default: if solo, you're the leader
	return true
#endregion

#region Deployment Sync (Squad)
func get_deployment_info() -> Dictionary:
	## Get current deployment info for HUD
	if current_mission_id.is_empty():
		return {}
	
	return {
		"mission_id": current_mission_id,
		"step_index": get_current_step_index(),
		"is_leader": _is_squad_leader()
	}

func set_deployment(mission_id: String, step_index: int = 0):
	## Set current deployment (called by squad leader or via sync)
	current_deployment = {
		"mission_id": mission_id,
		"step_index": step_index
	}
	
	deployment_synced.emit(mission_id, step_index)

func clear_deployment():
	## Clear current deployment
	current_deployment = {}
	current_mission_id = ""
	current_zone_id = ""
	deployment_synced.emit("", 0)

func _sync_deployment_to_squad():
	## Sync deployment state to all squad members (leader only)
	if not _is_squad_leader():
		return
	
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("broadcast_deployment_sync"):
		network.broadcast_deployment_sync(current_mission_id, get_current_step_index())

func receive_deployment_sync(mission_id: String, step_index: int, from_leader: bool = true):
	## Receive deployment sync from squad leader
	if not from_leader:
		return
	
	if mission_id.is_empty():
		clear_deployment()
	else:
		current_deployment = {
			"mission_id": mission_id,
			"step_index": step_index
		}
		
		# Update active mission if we have one
		if active_missions.has(mission_id):
			active_missions[mission_id].current_step_index = step_index
		
		deployment_synced.emit(mission_id, step_index)

func on_leave_squad():
	## Called when player leaves a squad
	if not _is_squad_leader():
		# Non-leaders lose their deployment
		clear_deployment()

func on_join_squad(leader_deployment: Dictionary):
	## Called when player joins a squad - receive leader's deployment
	if leader_deployment.has("mission_id"):
		receive_deployment_sync(
			leader_deployment.get("mission_id", ""),
			leader_deployment.get("step_index", 0),
			true
		)
#endregion
