extends NPCState
class_name NPCStateAggro

# Aggro state - NPC runs towards target and triggers dialogue on contact
# Switches to idle after reaching target and starting dialogue

# Static dictionary to track aggressive NPCs
# Key: npc entity_id, Value: true if aggressive
static var aggressive_npcs: Dictionary = {}

# Battle transition delay system
static var battle_delay_frames: int = 0 # Frames to wait before battle
static var battle_delay_frames_per_enemy: int = 30 # Each enemy adds 0.5s (30 frames at 60fps)
static var first_contact_npc: Node = null # The first NPC to catch the player
static var battle_sfx_played: bool = false # Track if SFX was played for this encounter

# Aggro parameters
@export var aggression: float = 1.0 # Future: affects behavior (0.0 = passive, 1.0 = aggressive)
@export var nature: String = "hostile" # Future: "hostile", "friendly", "curious", etc.
@export var contact_distance: float = 0.2 # How close to get before triggering dialogue
@export var nav_update_cooldown: float = 0.1 # Minimum time between navigation updates
@export var target_move_threshold: float = 0.05 # How far target must move before updating path
@export var target_overshoot: float = 0.0 # How far beyond target to navigate (set to 0 to reach exact position)
@export var chase_speed: float = 4.0 # Movement speed while chasing (default matches player run speed)
@export var max_chase_distance: float = 0.0 # Max distance to chase target (0 = infinite)
@export var max_stray_distance: float = 0.0 # Max distance from spawn point (0 = infinite)

# Target tracking
var target = null
var has_triggered_dialogue: bool = false
var last_target_position: Vector3
var nav_update_timer: float = 0.0
var spawn_position: Vector3 # Store initial position when aggro starts

func on_start():
	# Target should already be set by patrol state before switching
	if not target or not is_instance_valid(target):
		print("[AGGRO] No valid target, returning to patrol")
		state_manager.change_state("patrol")
		return
	
	print("[AGGRO] Started chasing target: ", target.name)
	has_triggered_dialogue = false
	npc.is_running = true
	last_target_position = target.global_position
	# Stagger navigation updates to spread CPU load
	nav_update_timer = randf() * nav_update_cooldown
	spawn_position = npc.global_position # Store spawn point
	
	# Apply chase speed override
	npc.speed_multiplier = chase_speed / npc.RUN_SPEED
	
	# Add this NPC to the aggressive NPCs dictionary
	if npc.entity_id != "":
		aggressive_npcs[npc.entity_id] = true
		print("[AGGRO] Added ", npc.entity_id, " to aggressive NPCs")
		
	# Trigger all party member NPCs to retreat
	_trigger_party_retreat()

func on_end():
	# Stop navigation and running
	if npc.is_navigating:
		npc.stop_navigation()
	npc.is_running = false
	# Reset speed multiplier
	npc.speed_multiplier = 1.0
	target = null
	has_triggered_dialogue = false
	
	# DON'T remove from aggressive_npcs here - keep them tracked until battle starts
	# This allows the delay timer to work correctly (it checks aggressive_npcs.size())
	# BattleManager will clear aggressive_npcs when the battle ends

func on_process(_delta: float):
	pass

func on_physics_process(delta: float):
	# Don't process if we're not the active state
	if npc.state_manager and npc.state_manager.current_state != self:
		return
	
	if not target or not is_instance_valid(target):
		print("[AGGRO] Target lost, returning to patrol")
		_return_to_patrol()
		return
	
	# Don't chase or trigger if dialogue is open
	if DialogueManager and DialogueManager.is_open:
		# Stop moving if we were moving
		if npc.is_navigating:
			npc.stop_navigation()
		npc.is_running = false
		return
	
	# Update navigation cooldown timer
	nav_update_timer -= delta
	
	# Cannot chase while panting
	if npc.is_panting:
		if npc.is_navigating:
			npc.stop_navigation()
		npc.is_running = false
		return
	
	# Check distance to target
	var distance = npc.global_position.distance_to(target.global_position)
	
	# Check if target is too far away (give up chase)
	if max_chase_distance > 0.0 and distance > max_chase_distance:
		print("[AGGRO] Target too far (", distance, " > ", max_chase_distance, "), returning to patrol")
		_return_to_patrol()
		return
	
	# Check if we've strayed too far from spawn point
	if max_stray_distance > 0.0:
		var distance_from_spawn = npc.global_position.distance_to(spawn_position)
		if distance_from_spawn > max_stray_distance:
			print("[AGGRO] Strayed too far from spawn (", distance_from_spawn, " > ", max_stray_distance, "), returning to patrol")
			_return_to_patrol()
			return
	
	# If we're close enough and haven't triggered dialogue yet
	if distance <= contact_distance and not has_triggered_dialogue:
		# Don't trigger if battle is already in progress
		if BattleManager and BattleManager.in_battle:
			print("[AGGRO] Cannot trigger - battle already in progress")
			return
		
		print("[AGGRO] Enemy caught player: ", npc.entity_id)
		has_triggered_dialogue = true
		
		# Check if this is the first enemy to catch the player
		# Use is_instance_valid to handle freed NPC references
		if first_contact_npc == null or not is_instance_valid(first_contact_npc):
			# This is the first enemy - freeze player, start dialogue immediately
			first_contact_npc = npc
			battle_delay_frames = battle_delay_frames_per_enemy
			battle_sfx_played = false # Reset for new encounter
			print("[AGGRO] First enemy contact! Freezing player, delay frames: ", battle_delay_frames)
			
			# Immediately freeze the player
			if GameManager and GameManager.player:
				GameManager.player.is_panting = true
				GameManager.player.stop()
				print("[AGGRO] Player frozen (panting)")
			
			# Close menus immediately
			_close_all_menus()
			
			# Play battle start sound immediately (ONLY ONCE)
			if SoundManager and not battle_sfx_played:
				SoundManager.play_sound("res://sounds/battle_start.wav")
				battle_sfx_played = true
				print("[AGGRO] Played battle SFX")
			
			# Trigger dialogue immediately (no delay here)
			_trigger_dialogue()
		else:
			# Additional enemy - add their troop to pending troops directly
			print("[AGGRO] Additional enemy caught player")
			
			# Add this NPC's troop to pending troops if it has one
			if npc is NPC and npc.troop != "":
				BattleManager.pending_troops.append(npc.troop)
				print("[AGGRO] Added troop to pending: ", npc.troop)
				
				# Extend the delay (NO sound here)
				battle_delay_frames += battle_delay_frames_per_enemy
				print("[AGGRO] Extended battle delay to: ", battle_delay_frames, " frames")
			
			# Hide this additional NPC immediately
			if npc.state_manager and npc.state_manager.states.has("hide"):
				print("[AGGRO] Hiding additional NPC: ", npc.entity_id)
				# Mark as battle-related hiding so it auto-restores after battle
				var hide_state = npc.state_manager.states["hide"]
				if "is_battle_hide" in hide_state:
					hide_state.is_battle_hide = true
				npc.state_manager.change_state("hide")
		return
	
	# Check if target moved significantly
	var target_moved_distance = target.global_position.distance_to(last_target_position)
	
	# Update navigation when target moves far enough and cooldown expired
	if target_moved_distance > target_move_threshold and nav_update_timer <= 0:
		last_target_position = target.global_position
		npc.navigate_to_position(target.global_position)
		nav_update_timer = nav_update_cooldown
	elif not npc.is_navigating and nav_update_timer <= 0:
		# If navigation finished and cooldown expired, update path to current target position
		last_target_position = target.global_position
		npc.navigate_to_position(target.global_position)
		nav_update_timer = nav_update_cooldown
	
	# Always run while chasing (if we have stamina)
	if npc.stamina > 0 and not npc.is_panting:
		npc.is_running = true

func _calculate_overshoot_position() -> Vector3:
	"""Calculate a position beyond the target to prevent slowdown on approach"""
	if not target or not is_instance_valid(target):
		return npc.global_position
	
	# Get direction from NPC to target
	var direction = (target.global_position - npc.global_position).normalized()
	
	# Calculate overshoot position beyond the target
	var overshoot_pos = target.global_position + (direction * target_overshoot)
	
	return overshoot_pos

func _trigger_dialogue():
	# Close any open menus and restore player control
	_close_all_menus()
	
	# Stop navigation and running
	if npc.is_navigating:
		npc.stop_navigation()
	npc.is_running = false
	
	# Look at the target
	if target:
		var look_dir = (target.global_position - npc.global_position).normalized()
		look_dir.y = 0
		if look_dir.length() > 0.01:
			npc.direction = look_dir
			npc.dir_string = npc.get_string_dir()
	
	# Trigger dialogue if NPC has one set
	if npc.dialogue != "":
		# Wait a frame to ensure we're ready
		await npc.get_tree().process_frame
		
		# Set current_npc so the startBattle event can access the NPC's troop property
		if DialogueManager:
			DialogueManager.current_npc = npc
			await DialogueManager.initiate_dialogue(npc.dialogue)
			# After dialogue ends, the battle will start via the dialogue event
	
	# Hide this NPC after dialogue starts (turn off collider for other enemies)
	if npc.state_manager and npc.state_manager.states.has("hide"):
		print("[AGGRO] Hiding NPC after dialogue started: ", npc.entity_id)
		# Mark as battle-related hiding so it auto-restores after battle
		var hide_state = npc.state_manager.states["hide"]
		if "is_battle_hide" in hide_state:
			hide_state.is_battle_hide = true
		npc.state_manager.change_state("hide")
	else:
		print("[AGGRO] WARNING: NPC has no hide state, staying visible")

func _trigger_party_retreat():
	"""Trigger all party member NPCs on the map to enter retreat_inside state"""
	if not GameManager or not GameManager.party:
		return
	
	print("[AGGRO] Triggering party member retreat")
	
	# Get all party member NPCs
	for i in range(min(GameManager.party.size(), 4)):
		var member = GameManager.party[i]
		var party_npc_id = "party_npc_" + member.character_key
		
		# Get the party NPC from TemporalEntityManager
		if TemporalEntityManager:
			var party_npc = TemporalEntityManager.get_entity(party_npc_id)
			if party_npc and is_instance_valid(party_npc):
				# Check if NPC has a state manager
				if party_npc.state_manager:
					# Don't re-trigger retreat if already hidden or retreating
					var current_state = party_npc.state_manager.get_current_state_name()
					if current_state == "hide" or current_state == "retreat_inside":
						continue
						
					# Check if retreat_inside state exists
					if party_npc.state_manager.states.has("retreat_inside"):
						print("[AGGRO] Triggering retreat for ", party_npc_id)
						party_npc.state_manager.change_state("retreat_inside")
					else:
						print("[AGGRO] Party NPC ", party_npc_id, " has no retreat_inside state")

func _close_all_menus():
	"""Close all open menus and restore player control"""
	print("[AGGRO] Closing all menus for enemy encounter")
	
	# Close all menu windows via MenuManager
	if MenuManager:
		print("[AGGRO] Closing all menu windows")
		while MenuManager.window_stack.size() > 0:
			var window = MenuManager.window_stack[0]
			if window and is_instance_valid(window) and window.has_method("close_window"):
				print("[AGGRO] Closing menu window: ", window.menu_name if "menu_name" in window else "unknown")
				window.close_window()
			else:
				MenuManager.window_stack.pop_front()
	
	# Close shop window if open
	if GameManager.shop_window and GameManager.shop_window.active:
		print("[AGGRO] Closing shop window")
		GameManager.shop_window.active = false
		GameManager.shop_window.visible = false
	
	# Restore player control
	if GameManager.player:
		print("[AGGRO] Restoring player control")
		GameManager.player.stop()
		GameManager.player.is_moving = false

func _return_to_patrol():
	_remove_from_aggressive_and_check_restore()
	state_manager.change_state("patrol")

func _remove_from_aggressive_and_check_restore():
	if aggressive_npcs.has(npc.entity_id):
		aggressive_npcs.erase(npc.entity_id)
		print("[AGGRO] Removed ", npc.entity_id, " from aggressive NPCs. Remaining: ", aggressive_npcs.size())
	
	# Validate dictionary - clean up stale entries
	var current_keys = aggressive_npcs.keys()
	for id in current_keys:
		# Check if entity exists in registry/tree
		var entity = Entity.get_entity_by_id(id)
		if not entity or not is_instance_valid(entity):
			aggressive_npcs.erase(id)
			print("[AGGRO] Cleaned up stale entry: ", id)
	
	if aggressive_npcs.is_empty():
		print("[AGGRO] No aggressive NPCs remaining, restoring party members")
		restore_party_members()

func _exit_tree():
	# Ensure we're removed from the static dictionary when destroyed
	if npc and aggressive_npcs.has(npc.entity_id):
		aggressive_npcs.erase(npc.entity_id)
		# Check if this was the last one
		if aggressive_npcs.is_empty():
			# We can't easily call restore_party_members here because _exit_tree 
			# might be called during scene transition or shutdown.
			# But ensuring the list is clean is the most important part.
			pass

static func restore_party_members():
	if not GameManager or not GameManager.party:
		return
	
	for member in GameManager.party:
		var party_npc_id = "party_npc_" + member.character_key
		
		# We need to find the entity
		if TemporalEntityManager:
			var party_npc = TemporalEntityManager.get_entity(party_npc_id)
			if party_npc and is_instance_valid(party_npc) and party_npc.state_manager:
				var current_state = party_npc.state_manager.get_current_state_name()
				# If in hide or retreat_inside state, return to follow
				if current_state == "hide" or current_state == "retreat_inside":
					if party_npc.state_manager.states.has("follow"):
						print("[AGGRO] Restoring ", party_npc_id, " to follow state")
						party_npc.state_manager.change_state("follow")
						
						# Force visibility just in case it was hidden
						party_npc.visible = true
						party_npc.set_process(true)
						party_npc.set_physics_process(true)
