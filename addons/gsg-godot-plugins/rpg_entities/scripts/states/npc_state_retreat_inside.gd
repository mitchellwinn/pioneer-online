extends NPCState
class_name NPCStateRetreatInside

# Retreat Inside state - Party member NPCs run at 2x speed back to player during encounters
# When close enough to player, transition to hide state

@export var retreat_distance: float = 0.3 # How close to get to player before hiding
@export var speed_multiplier: float = 2.0 # Run at double speed

func on_start():
	print("[RETREAT_INSIDE] ", npc.entity_id, " entering retreat state")
	
	# Force running at 2x speed
	npc.is_running = true
	npc.speed_multiplier = speed_multiplier
	
	# Navigate to position in front of player
	if GameManager.player:
		var player_forward = GameManager.player.direction
		if player_forward.length() < 0.01:
			player_forward = GameManager.player.last_direction
		if player_forward.length() < 0.01:
			player_forward = Vector3.FORWARD
		player_forward = player_forward.normalized()
		
		# Position 1.5 units in front of player
		var target_pos = GameManager.player.global_position + player_forward * 1.5
		npc.navigate_to_position(target_pos)
		print("[RETREAT_INSIDE] ", npc.entity_id, " navigating to front of player")

func on_end():
	# Stop navigation and running
	if npc.is_navigating:
		npc.stop_navigation()
	npc.is_running = false
	npc.speed_multiplier = 1.0
	
	print("[RETREAT_INSIDE] ", npc.entity_id, " exiting retreat state")

func on_process(_delta: float):
	pass

func on_physics_process(delta: float):
	if not GameManager.player:
		return
	
	# Check distance to player
	var distance = npc.global_position.distance_to(GameManager.player.global_position)
	
	# If we're close enough, transition to hide
	if distance <= retreat_distance:
		print("[RETREAT_INSIDE] ", npc.entity_id, " reached player, transitioning to hide")
		state_manager.change_state("hide")
		return
	
	# Keep navigating to position past player in straight line from NPC
	var to_player = (GameManager.player.global_position - npc.global_position).normalized()
	to_player.y = 0 # Keep horizontal
	
	if to_player.length() < 0.01:
		to_player = Vector3.FORWARD
	else:
		to_player = to_player.normalized()
	
	var target_pos = GameManager.player.global_position + to_player * 1.5
	
	if not npc.is_navigating or npc.navigation_target.distance_to(target_pos) > 0.5:
		npc.navigate_to_position(target_pos)
	
	# Force running (ignore stamina during retreat)
	npc.is_running = true



