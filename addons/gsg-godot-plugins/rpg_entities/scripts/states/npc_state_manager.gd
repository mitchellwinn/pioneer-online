extends Node
class_name NPCStateManager

# Reference to the NPC
var npc: NPC

# Current active state
var current_state: NPCState = null

# Previous state (for restoring after interruptions)
var previous_state: NPCState = null

# Dictionary of all available states (keys normalized to lowercase)
var states: Dictionary = {}

func _ready():
	# Ensure processing is enabled so we drive active state only
	set_process(true)
	set_physics_process(true)
	
	# Get reference to parent NPC
	npc = get_parent() as NPC
	if not npc:
		push_error("NPCStateManager: Parent is not an NPC")
		return
	
	# Initialize all child states
	for child in get_children():
		if child is NPCState:
			child.npc = npc
			child.state_manager = self
			states[child.name.to_lower()] = child

# Change to a new state
func change_state(state_name: String, save_previous: bool = true):
	var key = state_name.to_lower()
	if not states.has(key):
		print("[StateManager] State not found: " + key)
		return
	var new_state: NPCState = states[key]
	
	var current_name = current_state.name if current_state else "none"
	var prev_name = previous_state.name if previous_state else "none"
	print("[StateManager] Changing state: " + current_name + " -> " + state_name + " (save_previous=" + str(save_previous) + ", previous=" + prev_name + ")")
	
	# If already in the target state, just save previous if needed and return
	if current_state == new_state:
		print("[StateManager] Already in target state, skipping")
		return
	
	# Exit current state
	if current_state:
		current_state.on_end()
		if save_previous:
			previous_state = current_state
			print("[StateManager] Saved previous state: " + previous_state.name)
	# Enter new state
	current_state = new_state
	current_state.on_start()
	print("[StateManager] State changed to: " + current_state.name)

# Restore the previous state
func restore_previous_state():
	if previous_state:
		var state_to_restore = previous_state
		previous_state = null # Clear before changing to avoid recursion
		change_state(state_to_restore.name, false) # Don't save when restoring
		print("[StateManager] Restored state: " + state_to_restore.name)
	else:
		print("[StateManager] No previous state to restore")

# Get the current state name
func get_current_state_name() -> String:
	if current_state:
		return current_state.name
	return ""

# Process the current state
func _process(delta):
	if current_state:
		current_state.on_process(delta)

# Physics process the current state
func _physics_process(delta):
	if current_state:
		current_state.on_physics_process(delta)



