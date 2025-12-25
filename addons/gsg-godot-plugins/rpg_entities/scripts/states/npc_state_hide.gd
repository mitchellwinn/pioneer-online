extends NPCState
class_name NPCStateHide

# Hide state - Party member NPCs become invisible and disabled during encounters
# When encounter ends, position is restored to player and NPC transitions back to follow

var stored_position: Vector3
var stored_visibility: bool
var is_battle_hide: bool = false # Track if hiding was due to battle (for auto-restore)

func on_start():
	print("[HIDE] ", npc.entity_id, " entering hide state")
	
	# Store original visibility
	stored_visibility = npc.visible
	
	# Make NPC invisible and disable collision
	npc.visible = false
	npc.set_physics_process(false)
	
	# Disable collision layer/mask to avoid any physics interactions
	if npc.collision_layer_backup == null:
		npc.collision_layer_backup = npc.collision_layer
		npc.collision_mask_backup = npc.collision_mask
	npc.collision_layer = 0
	npc.collision_mask = 0
	
	print("[HIDE] ", npc.entity_id, " is now hidden")

func on_end():
	print("[HIDE] ", npc.entity_id, " exiting hide state")
	
	# Restore position to player if this was battle-related hiding OR if it's a party member
	# Party members should always teleport back to player when unhiding to avoid being left behind
	var should_teleport = is_battle_hide
	if npc.entity_id.begins_with("party_npc_"):
		should_teleport = true
		
	if should_teleport and GameManager.player and is_instance_valid(GameManager.player):
		npc.global_position = GameManager.player.global_position
		print("[HIDE] ", npc.entity_id, " position restored to player")
	
	# Restore visibility and physics
	npc.visible = stored_visibility
	npc.set_physics_process(true)
	
	# Restore collision layer/mask
	if npc.collision_layer_backup != null:
		npc.collision_layer = npc.collision_layer_backup
		npc.collision_mask = npc.collision_mask_backup
		npc.collision_layer_backup = null
		npc.collision_mask_backup = null
	
	# Reset battle hide flag
	is_battle_hide = false
	
	print("[HIDE] ", npc.entity_id, " is now visible and enabled")

func on_process(_delta: float):
	# Check if we should unhide (no more aggressive NPCs and not in battle)
	# Using on_process instead of on_physics_process because NPC's physics might be disabled
	# IMPORTANT: Only auto-restore if this was battle-related hiding (is_battle_hide)
	# NPCs hidden for other reasons (flags, party joining) should stay hidden
	if not is_battle_hide:
		return
	
	var aggro_state_script = load("res://addons/gsg-godot-plugins/rpg_entities/scripts/states/npc_state_aggro.gd")
	if aggro_state_script and aggro_state_script.aggressive_npcs.is_empty() and BattleManager.in_battle == false:
		# Party NPCs should return to follow state
		if npc.entity_id.begins_with("party_npc_"):
			print("[HIDE] No aggressive NPCs and not in battle, returning to follow")
			if state_manager.states.has("follow"):
				state_manager.change_state("follow")
			elif state_manager.states.has("idle"):
				state_manager.change_state("idle")
		else:
			# Enemy NPCs should return to their initial state (patrol, wander, idle)
			# This fixes invisible/stuck NPCs after battle ends
			print("[HIDE] Battle ended, restoring enemy NPC to initial state: ", npc.entity_id)
			var init_state = npc.initial_state.to_lower() if "initial_state" in npc else "idle"
			if state_manager.states.has(init_state):
				state_manager.change_state(init_state)
			elif state_manager.states.has("idle"):
				state_manager.change_state("idle")

func on_physics_process(_delta: float):
	pass
