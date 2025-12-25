extends Node
class_name NPCState

# Reference to the NPC this state belongs to
var npc: NPC

# Reference to the state manager
var state_manager

# Called when this state becomes active
func on_start():
	pass

# Called when this state stops being active
func on_end():
	pass

# Called every frame while this state is active
func on_process(_delta: float):
	pass

# Called every physics frame while this state is active
func on_physics_process(_delta: float):
	pass

# Helper function to play a motion sequence and await its completion
# Usage: await play_motion("jump")
func play_motion(motion_name: String):
	if not npc:
		push_error("NPCState.play_motion: npc reference is null")
		return
	
	# Get or create EntityMotions node
	var motions = npc.get_node_or_null("EntityMotions")
	if not motions:
		push_warning("NPCState.play_motion: EntityMotions node not found on NPC, attempting to create one")
		motions = EntityMotions.new()
		motions.name = "EntityMotions"
		npc.add_child(motions)
		# Wait for it to be ready
		await npc.get_tree().process_frame
	
	# Play the motion and wait for completion with timeout
	var motion_signal = motions.play_motion(motion_name)
	
	# Create a safety timeout to prevent hanging if motion fails
	var tree = npc.get_tree()
	if tree:
		var timer = tree.create_timer(3.0) # 3 seconds max for any motion
		timer.timeout.connect(func(): 
			if motions.is_playing_motion and motions.current_motion_name == motion_name:
				push_warning("NPCState: Motion timed out: " + motion_name)
				motions.stop_motion() # This will emit motion_completed
		)
	
	await motion_signal
	
# Helper function to check if NPC has EntityMotions
func has_entity_motions() -> bool:
	if not npc:
		return false
	return npc.get_node_or_null("EntityMotions") != null



