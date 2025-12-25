extends NPCState
class_name NPCStateCelebration

# Example state that demonstrates using entity motion sequences
# This shows how NPC states can await motion sequences between actions

# Celebration parameters
@export var celebration_type: String = "jump" # Which motion to play
@export var repeat_count: int = 3 # How many times to celebrate
@export var wait_between: float = 0.5 # Wait time between celebrations

var celebrations_done: int = 0

func on_start():
	# Stop any navigation
	if npc.is_navigating:
		npc.stop_navigation()
	
	# Start the celebration sequence
	celebrations_done = 0
	_perform_celebration_sequence()

func on_end():
	celebrations_done = 0

func on_process(_delta: float):
	pass

func on_physics_process(_delta: float):
	pass

# Perform a sequence of celebrations with motions
func _perform_celebration_sequence():
	print("[Celebration] Starting celebration sequence for: ", npc.name)
	
	# Example 1: Simple repeated motion
	for i in range(repeat_count):
		# Play the motion and wait for it to complete
		await play_motion(celebration_type)
		celebrations_done += 1
		
		# Wait between celebrations
		if celebrations_done < repeat_count:
			await get_tree().create_timer(wait_between).timeout
	
	print("[Celebration] Celebration complete!")
	
	# Return to idle state after celebrating
	if state_manager:
		state_manager.change_state("idle")

# Example function showing different motion sequences
func _example_complex_sequence():
	# Example 2: Multiple different motions in sequence
	print("[Celebration] Excited greeting!")
	await play_motion("surprised")
	await get_tree().create_timer(0.3).timeout
	await play_motion("excited_jump")
	await play_motion("bounce")
	
	# Example 3: Motion with navigation
	print("[Celebration] Dancing around!")
	var original_pos = npc.global_position
	
	# Move forward a bit
	npc.navigate_to_position(original_pos + npc.direction * 2.0)
	await get_tree().create_timer(0.5).timeout
	await play_motion("spin_jump")
	
	# Move back
	npc.navigate_to_position(original_pos)
	while npc.is_navigating:
		await get_tree().process_frame
	
	# Finish with celebration
	await play_motion("celebrate")
	
	# Example 4: Motion during dialogue (would be called from dialogue system)
	# await play_motion("nod") # Character nods during dialogue
	# await play_motion("shake") # Character shakes head "no"
	# await play_motion("jump") # Character jumps excitedly



