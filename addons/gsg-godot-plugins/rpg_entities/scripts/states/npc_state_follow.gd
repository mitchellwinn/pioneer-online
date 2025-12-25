extends NPCState
class_name NPCStateFollow

# Follow state - NPC follows the player, positioning behind them

# Follow parameters
@export var follow_distance: float = .8 # Target distance behind player
@export var run_distance: float = 1.60 # Distance at which NPC starts running
@export var player_move_threshold: float = .35 # How far player must move before updating position
@export var nav_update_cooldown: float = 0.1 # Minimum time between navigation updates
@export var idle_look_min_time: float = 0.2 # Min time between idle look behaviors
@export var idle_look_max_time: float = 4.0 # Max time between idle look behaviors
@export var reposition_chance: float = 0.15 # Chance to pick a new spot instead of looking

var last_player_position: Vector3
var claimed_position: Vector3
var idle_timer: float = 0.0
var idle_wait_time: float = 0.0
var is_at_target: bool = false
var nav_update_timer: float = 0.0

# Track other following NPCs to avoid position conflicts
static var follow_positions: Dictionary = {} # npc_id -> position

func on_start():
	# Register this NPC's follow position
	if npc.entity_id != "":
		follow_positions[npc.entity_id] = npc.global_position
	
	# Store initial player position
	if GameManager.player:
		last_player_position = GameManager.player.global_position
	
	# Stagger navigation updates across NPCs to spread CPU load
	nav_update_timer = randf() * nav_update_cooldown
	
	# Check if there are any aggressive NPCs - if so, enter retreat state immediately
	var aggro_state_script = load("res://addons/gsg-godot-plugins/rpg_entities/scripts/states/npc_state_aggro.gd")
	if aggro_state_script and aggro_state_script.aggressive_npcs.size() > 0:
		print("[FOLLOW] Aggressive NPCs detected, entering retreat_inside state")
		if state_manager.states.has("retreat_inside"):
			state_manager.change_state("retreat_inside")
			return
	
	# Immediately calculate follow position
	_update_follow_position()

func on_end():
	# Unregister follow position
	if npc.entity_id != "" and follow_positions.has(npc.entity_id):
		follow_positions.erase(npc.entity_id)
	
	# Stop navigation and running
	if npc.is_navigating:
		npc.stop_navigation()
	npc.is_running = false

func on_process(_delta: float):
	pass

func on_physics_process(delta: float):
	# Don't process if we're not the active state
	if npc.state_manager and npc.state_manager.current_state != self:
		return
	
	if not GameManager.player:
		return
	
	# Check if any aggressive NPCs appeared - if so, retreat
	var aggro_state_script = load("res://addons/gsg-godot-plugins/rpg_entities/scripts/states/npc_state_aggro.gd")
	if aggro_state_script and aggro_state_script.aggressive_npcs.size() > 0:
		print("[FOLLOW] Aggressive NPCs detected during follow, entering retreat_inside state")
		if state_manager.states.has("retreat_inside"):
			state_manager.change_state("retreat_inside")
			return
	
	# Update navigation cooldown timer
	nav_update_timer -= delta
	
	var player_pos = GameManager.player.global_position
	var player_moved_distance = player_pos.distance_to(last_player_position)
	
	# Update when player moves far enough
	if player_moved_distance > player_move_threshold and nav_update_timer <= 0:
		last_player_position = player_pos
		_update_follow_position()
		is_at_target = false
		idle_timer = 0.0
		nav_update_timer = nav_update_cooldown
	
	# Check if we've reached our target
	if not is_at_target and not npc.is_navigating:
		is_at_target = true
		# Immediately look at player when arriving
		if GameManager.player:
			_look_at_target(GameManager.player.global_position)
		# Start idle behavior timer
		idle_wait_time = randf_range(idle_look_min_time, idle_look_max_time)
		idle_timer = 0.0
		print("[FOLLOW] ", npc.entity_id, " reached target, starting idle behaviors")
	
	# Handle idle behaviors when at target
	if is_at_target:
		idle_timer += delta
		if idle_timer >= idle_wait_time:
			_do_idle_behavior()
			idle_wait_time = randf_range(idle_look_min_time, idle_look_max_time)
			idle_timer = 0.0
	
	# Manage running based on distance
	var distance_to_player = npc.global_position.distance_to(player_pos)
	
	# Run if far away (and has stamina and not panting)
	if distance_to_player > run_distance and npc.stamina > 0 and not npc.is_panting:
		npc.is_running = true
	else:
		npc.is_running = false

func _update_follow_position():
	if not GameManager.player:
		return
	
	var player = GameManager.player
	var player_pos = player.global_position
	
	# Calculate position behind player
	var behind_offset = Vector3.ZERO
	if player.last_direction.length() > 0.01:
		behind_offset = - player.last_direction.normalized()
	elif player.direction.length() > 0.01:
		behind_offset = - player.direction.normalized()
	else:
		match player.dir_string:
			"up": behind_offset = Vector3(0, 0, 1)
			"down": behind_offset = Vector3(0, 0, -1)
			"left": behind_offset = Vector3(1, 0, 0)
			"right": behind_offset = Vector3(-1, 0, 0)
			_: behind_offset = Vector3(0, 0, 1)
	
	var base_follow_pos = player_pos + behind_offset * follow_distance
	
	# Check if position is too close to other following NPCs
	var final_follow_pos = _find_available_position(base_follow_pos)
	
	# Update claimed position
	claimed_position = final_follow_pos
	if npc.entity_id != "":
		follow_positions[npc.entity_id] = claimed_position
	
	# Check if target is reachable before navigating
	if not npc.nav_agent:
		return
	
	var nav_map = npc.nav_agent.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, final_follow_pos)
	var distance_to_navmesh = final_follow_pos.distance_to(closest_point)
	
	# If target is too far from navmesh (player went off-map), don't navigate
	if distance_to_navmesh > 0.5:
		print("[FOLLOW] Target too far from navmesh (", distance_to_navmesh, "), skipping navigation")
		return
	
	# Navigate to nearest valid point on navmesh
	npc.navigate_to_position(closest_point)

func _find_available_position(preferred_pos: Vector3) -> Vector3:
	# Check if preferred position conflicts with other followers
	for other_npc_id in follow_positions.keys():
		if other_npc_id == npc.entity_id:
			continue
		
		var other_pos = follow_positions[other_npc_id]
		var distance = preferred_pos.distance_to(other_pos)
		
		# If too close to another follower, offset position
		if distance < 1.0:
			# Spiral outward to find open position
			for i in range(1, 8):
				var angle = (TAU / 8.0) * i
				var offset = Vector3(cos(angle), 0, sin(angle)) * (1.5 * i * 0.5)
				var test_pos = preferred_pos + offset
				
				# Check if this position is clear
				var is_clear = true
				for check_npc_id in follow_positions.keys():
					if check_npc_id == npc.entity_id:
						continue
					var check_pos = follow_positions[check_npc_id]
					if test_pos.distance_to(check_pos) < 1.0:
						is_clear = false
						break
				
				if is_clear:
					return test_pos
	
	return preferred_pos

# Perform idle behavior when at target position
func _do_idle_behavior():
	if not GameManager.player:
		return
	
	# Sometimes reposition instead of just looking
	if randf() < reposition_chance:
		_reposition_around_player()
		return
	
	# Choose what to look at
	var behavior = randi() % 4
	match behavior:
		0: # Look at player
			_look_at_target(GameManager.player.global_position)
		1: # Look at another party member
			_look_at_other_party_member()
		2: # Look at camera
			_look_at_camera()
		3: # Look in a random direction
			_look_random_direction()

func _look_at_target(target_pos: Vector3):
	var look_dir = (target_pos - npc.global_position).normalized()
	look_dir.y = 0
	if look_dir.length() > 0.01:
		npc.direction = look_dir
		# Update dir_string so animation reflects the new direction
		npc.dir_string = npc.get_string_dir()

func _look_at_other_party_member():
	# Get all other party NPCs
	var other_npcs = []
	for i in range(min(GameManager.party.size(), 4)):
		var member = GameManager.party[i]
		var other_id = "party_npc_" + member.character_key
		if other_id != npc.entity_id:
			var other_npc = TemporalEntityManager.get_entity(other_id)
			if other_npc and is_instance_valid(other_npc):
				other_npcs.append(other_npc)
	
	if other_npcs.size() > 0:
		var random_npc = other_npcs[randi() % other_npcs.size()]
		_look_at_target(random_npc.global_position)
	else:
		# No other party members, look at player instead
		if GameManager.player:
			_look_at_target(GameManager.player.global_position)

func _look_at_camera():
	if CameraManager.active_camera:
		_look_at_target(CameraManager.active_camera.global_position)
	elif GameManager.main_camera:
		_look_at_target(GameManager.main_camera.global_position)

func _look_random_direction():
	var random_angle = randf() * TAU
	var random_dir = Vector3(cos(random_angle), 0, sin(random_angle))
	npc.direction = random_dir
	# Update dir_string so animation reflects the new direction
	npc.dir_string = npc.get_string_dir()

func _reposition_around_player():
	if not GameManager.player:
		return
	
	var player_pos = GameManager.player.global_position
	
	# Pick a random angle around the player
	var angle = randf() * TAU
	var offset = Vector3(cos(angle), 0, sin(angle)) * follow_distance
	var new_pos = player_pos + offset
	
	# Check if position conflicts with other followers
	var final_pos = _find_available_position(new_pos)
	
	# Update claimed position
	claimed_position = final_pos
	if npc.entity_id != "":
		follow_positions[npc.entity_id] = claimed_position
	
	# Check if target is reachable before navigating
	if not npc.nav_agent:
		return
	
	var nav_map = npc.nav_agent.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, final_pos)
	var distance_to_navmesh = final_pos.distance_to(closest_point)
	
	# If target is too far from navmesh, don't navigate
	if distance_to_navmesh > 0.5:
		print("[FOLLOW] Reposition target too far from navmesh, skipping")
		return
	
	# Navigate to nearest valid point on navmesh
	npc.navigate_to_position(closest_point)
	is_at_target = false
	nav_update_timer = nav_update_cooldown # Reset cooldown after repositioning
