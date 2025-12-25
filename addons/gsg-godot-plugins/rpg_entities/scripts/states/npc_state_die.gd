extends NPCState
class_name NPCStateDie

# Die state - NPC spins, flashes, and oscillates before disappearing
# Uses the "die" entity motion sequence

func on_start():
	# Stop any navigation
	if npc.is_navigating:
		npc.stop_navigation()
	
	# Disable collision so player can walk through dying NPC
	if npc is CharacterBody3D:
		npc.collision_layer = 0
		npc.collision_mask = 0
	
	# Play the die motion and destroy when finished
	_play_die_motion()

func on_end():
	pass

func on_process(_delta: float):
	pass

func on_physics_process(_delta: float):
	pass

func _play_die_motion():
	# Wait for dialogue to finish if it's still open
	if DialogueManager and DialogueManager.is_open:
		await DialogueManager.dialogue_finished
	
	# Play the die motion sequence
	await play_motion("die")
	
	# After motion completes, destroy the NPC
	if npc:
		npc.queue_free()
