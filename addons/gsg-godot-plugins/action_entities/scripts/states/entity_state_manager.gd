extends Node
class_name EntityStateManager

## Manages entity states and transitions
## Supports state queuing for ability chains/combos

signal state_changed(old_state, new_state)
signal state_completed(state)
signal combo_started(states: Array[String])
signal combo_completed()
signal combo_dropped()

# Reference to the parent entity
var entity: Node3D

# Current active state
var current_state = null  # EntityState

# Previous state (for state memory)
var previous_state = null  # EntityState

# Dictionary of all available states (name -> EntityState)
var states: Dictionary = {}

# Default state to return to
@export var default_state_name: String = "idle"

# Debug logging
@export var debug_state_changes: bool = false

# State queue for combos/ability chains
var state_queue: Array[String] = []

# Time window to continue a combo
@export var combo_window: float = 0.5
var combo_timer: float = 0.0
var in_combo: bool = false

# Input buffer for responsive controls
var input_buffer: Array[Dictionary] = []
@export var input_buffer_time: float = 0.3  # Increased for better jump responsiveness
const MAX_INPUT_BUFFER: int = 5

# Server-side action buffer (simpler string-based for network inputs)
var server_action_buffer: Array[Dictionary] = []

func _ready():
	# Get reference to parent entity
	entity = get_parent() as Node3D
	if not entity:
		push_error("[EntityStateManager] Parent must be a Node3D")
		return
	
	# Initialize all child states
	_discover_states(self)
	
	# Start in default state
	call_deferred("_enter_default_state")

func _discover_states(node: Node):
	for child in node.get_children():
		if child is EntityState:
			child.entity = entity
			child.state_manager = self
			var state_name = child.name.to_lower()
			states[state_name] = child
			print("[EntityStateManager] Registered state: ", state_name)
		# Recursively check children (allows organizing states in folders)
		_discover_states(child)

func _enter_default_state():
	if states.has(default_state_name):
		change_state(default_state_name, true)
	elif states.size() > 0:
		change_state(states.keys()[0], true)

func _process(delta: float):
	# Skip state logic for remote players - they receive state updates via network
	if not _should_process_state_logic():
		return

	# Update combo timer
	if in_combo:
		combo_timer -= delta
		if combo_timer <= 0:
			_drop_combo()

	# Update input buffer
	var current_time = Time.get_ticks_msec() / 1000.0
	input_buffer = input_buffer.filter(func(i): return current_time - i.time < input_buffer_time)

	# Process current state
	if current_state:
		current_state.on_process(delta)

func _physics_process(delta: float):
	# Skip state logic for remote players - they receive state updates via network
	if not _should_process_state_logic():
		return

	if current_state:
		# Skip if entity already processed this state (velocity-controlling states)
		var state_name = current_state.name.to_lower() if current_state.name else ""
		if state_name in ["dash", "dodging", "air_slash", "airslash"]:
			return  # Already processed by entity before move_and_slide
		current_state.on_physics_process(delta)

func _should_process_state_logic() -> bool:
	## Returns true if we should process state logic for this entity
	## Only process for: local player, server-controlled entities, or on the server
	## Remote players on clients should NEVER process state logic - they receive state via network
	if not entity:
		return false

	# Remote players on client - NEVER process state logic locally
	# Their state comes from network sync, not local processing
	if "_is_remote_player" in entity and entity._is_remote_player:
		return false

	# Server processes all entities (server-authoritative)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return true

	# Local player processes their own states
	# Use _can_receive_input_base to avoid window focus check
	if "_can_receive_input_base" in entity and entity._can_receive_input_base:
		return true

	# Server-controlled entities (NPCs) on server
	if "is_server_entity" in entity and entity.is_server_entity:
		return true

	# Default: don't process (remote player or unknown entity type)
	return false

func _input(event: InputEvent):
	# Skip input if window doesn't have focus (prevents input bleeding between test windows)
	if not DisplayServer.window_is_focused():
		return

	# Only process input for player-controlled entities
	if not _is_local_player():
		return

	# Buffer the input (include "fire" as alias for attack_primary)
	if event.is_action_pressed("attack_primary") or event.is_action_pressed("fire") \
		or event.is_action_pressed("attack_secondary") \
		or event.is_action_pressed("dodge") or event.is_action_pressed("jump") \
		or event.is_action_pressed("ability_1") or event.is_action_pressed("ability_2") \
		or event.is_action_pressed("ability_3") or event.is_action_pressed("ability_4"):
		_buffer_input(event)

	# Pass to current state
	if current_state:
		current_state.on_input(event)

func _is_local_player() -> bool:
	## Check if this state manager belongs to a local player-controlled entity
	if not entity:
		return false

	# Remote players are never local
	if "_is_remote_player" in entity and entity._is_remote_player:
		return false

	# Check if entity has input authority flag (ActionPlayer)
	# Use _can_receive_input_base to avoid window focus affecting this check
	if "_can_receive_input_base" in entity:
		return entity._can_receive_input_base

	# Not a player entity (NPC) - don't process global input
	return false

func _buffer_input(event: InputEvent):
	if input_buffer.size() >= MAX_INPUT_BUFFER:
		input_buffer.pop_front()
	
	# Capture movement direction at the time of input (important for dash/dodge)
	var input_direction := Vector2.ZERO
	if entity and entity.has_method("get_input_direction"):
		input_direction = entity.get_input_direction()
	else:
		# Fallback: read input directly
		input_direction = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Default to forward if no direction pressed
	if input_direction.length_squared() < 0.01:
		input_direction = Vector2(0, -1)  # Forward (-Z in world)
	
	input_buffer.append({
		"event": event,
		"time": Time.get_ticks_msec() / 1000.0,
		"direction": input_direction  # Store direction at time of input!
	})

func get_buffered_input(action: String) -> bool:
	# First check server action buffer (for network inputs)
	for buffered in server_action_buffer:
		if buffered.action == action:
			server_action_buffer.erase(buffered)
			if debug_state_changes:
				print("[StateManager] Consumed SERVER buffered action: ", action)
			return true

	# Then check regular input buffer (for local inputs)
	# Also check "fire" as alias for "attack_primary"
	for buffered in input_buffer:
		var matches = buffered.event.is_action_pressed(action)
		# Special case: "fire" and "attack_primary" are interchangeable for attacks
		if not matches and action == "attack_primary":
			matches = buffered.event.is_action_pressed("fire")
		if matches:
			input_buffer.erase(buffered)
			if debug_state_changes:
				print("[StateManager] Consumed LOCAL buffered input: ", action)
			return true
	return false

func consume_buffered_input(action: String) -> bool:
	return get_buffered_input(action)

func consume_buffered_input_with_data(action: String) -> Dictionary:
	## Consume a buffered input and return its data (or empty dict if not found)
	## Returns: {"found": bool, "data": Dictionary}
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Check server action buffer first (has "action" key and optional "data")
	for i in range(server_action_buffer.size()):
		var buffered = server_action_buffer[i]
		if buffered.get("action", "") == action:
			server_action_buffer.remove_at(i)
			if debug_state_changes:
				print("[StateManager] Consumed server action with data: ", action)
			return {"found": true, "data": buffered.get("data", {})}
	
	# Check regular input buffer (has "event" key - InputEvent based)
	# Only check if the action exists in InputMap (avoids errors for server-only actions like "wall_jump")
	if InputMap.has_action(action):
		for i in range(input_buffer.size()):
			var buffered = input_buffer[i]
			if buffered.has("event") and buffered.event.is_action_pressed(action):
				if current_time - buffered.get("time", 0.0) < input_buffer_time:
					var dir = buffered.get("direction", Vector2(0, -1))  # Default forward
					input_buffer.remove_at(i)
					return {"found": true, "data": {"direction": dir}}
	
	return {"found": false, "data": {}}

func buffer_server_action(action: String, data: Dictionary = {}):
	## Buffer an action from network input (server-side)
	## data: optional dictionary with action-specific data (e.g., wall_normal for wall_jump)
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Remove expired server actions
	server_action_buffer = server_action_buffer.filter(func(a): return current_time - a.time < input_buffer_time)
	
	# Don't buffer duplicate actions within short window (unless it has different data)
	for buffered in server_action_buffer:
		if buffered.action == action and data.is_empty():
			return  # Already buffered
	
	if server_action_buffer.size() >= MAX_INPUT_BUFFER:
		server_action_buffer.pop_front()
	
	server_action_buffer.append({
		"action": action,
		"time": current_time,
		"data": data
	})
	
	if debug_state_changes:
		print("[StateManager] Buffered server action: ", action, " data=", data, " (buffer size: ", server_action_buffer.size(), ")")

func clear_input_buffers():
	## Clear all buffered inputs (used when transitioning out of dialogue, etc.)
	input_buffer.clear()
	server_action_buffer.clear()
	if debug_state_changes:
		print("[StateManager] Cleared all input buffers")

#region State Management
func change_state(state_name: String, force: bool = false) -> bool:
	var key = state_name.to_lower()
	
	if not states.has(key):
		push_warning("[EntityStateManager] State not found: " + key)
		return false
	
	var new_state = states[key]  # EntityState
	var old_state_name = current_state.name.to_lower() if current_state else "none"
	
	# Check if we can transition
	if current_state and not force:
		if not current_state.can_be_interrupted and new_state.priority <= current_state.priority:
			if debug_state_changes:
				print("[StateManager] BLOCKED: %s -> %s (can't interrupt, priority %d <= %d)" % [
					old_state_name, key, new_state.priority, current_state.priority
				])
			return false
		if not current_state.can_transition_to(key):
			if debug_state_changes:
				print("[StateManager] BLOCKED: %s -> %s (transition not allowed)" % [old_state_name, key])
			return false
	
	# Get exit data from current state
	var exit_data = {}
	if current_state:
		exit_data = current_state.get_exit_data()
	
	# Debug log the transition
	if debug_state_changes:
		var entity_name = entity.name if entity else "unknown"
		var on_floor = entity.is_on_floor() if entity is CharacterBody3D else "N/A"
		print("[StateManager:%s] STATE: %s -> %s (force=%s, floor=%s, exit_data=%s)" % [
			entity_name, old_state_name, key, str(force), str(on_floor), str(exit_data)
		])
	
	# Exit current state
	var old_state = current_state
	if current_state:
		current_state.on_exit(new_state)
		previous_state = current_state
	
	# Enter new state
	current_state = new_state
	current_state.receive_entry_data(exit_data)
	current_state.on_enter(old_state)
	
	state_changed.emit(old_state, new_state)
	
	return true

func complete_current_state():
	if not current_state:
		return
	
	state_completed.emit(current_state)
	
	# Check for queued states (combo chain)
	if state_queue.size() > 0:
		var next_state = state_queue.pop_front()
		combo_timer = combo_window
		change_state(next_state, true)
		
		if state_queue.size() == 0:
			in_combo = false
			combo_completed.emit()
	else:
		# Return to default state
		in_combo = false
		change_state(default_state_name)

func queue_state(state_name: String):
	state_queue.append(state_name)

func start_combo(state_sequence: Array[String]):
	if state_sequence.size() == 0:
		return
	
	# Clear any existing queue
	state_queue.clear()
	
	# Queue all states after the first
	for i in range(1, state_sequence.size()):
		state_queue.append(state_sequence[i])
	
	in_combo = true
	combo_timer = combo_window
	combo_started.emit(state_sequence)
	
	# Start with first state
	change_state(state_sequence[0], true)

func _drop_combo():
	if not in_combo:
		return
	
	in_combo = false
	state_queue.clear()
	combo_dropped.emit()
	
	# Return to default
	change_state(default_state_name)

func get_current_state_name() -> String:
	if current_state:
		return current_state.name.to_lower()
	return ""

func get_previous_state_name() -> String:
	if previous_state:
		return previous_state.name.to_lower()
	return ""

func is_in_state(state_name: String) -> bool:
	return get_current_state_name() == state_name.to_lower()

func has_state(state_name: String) -> bool:
	return states.has(state_name.to_lower())

func get_state(state_name: String):  # Returns EntityState
	var key = state_name.to_lower()
	if states.has(key):
		return states[key]
	return null

func add_state(state_name: String, state: Node) -> bool:  # state is EntityState
	## Dynamically add a state at runtime
	var key = state_name.to_lower()
	if states.has(key):
		push_warning("[EntityStateManager] State already exists: ", key)
		return false
	
	state.entity = entity
	state.state_manager = self
	state.name = state_name
	add_child(state)
	states[key] = state
	
	if debug_state_changes:
		print("[EntityStateManager] Dynamically added state: ", key)
	return true

func remove_state(state_name: String) -> bool:
	## Remove a dynamically added state
	var key = state_name.to_lower()
	if not states.has(key):
		return false
	
	var state = states[key]
	states.erase(key)
	state.queue_free()
	return true
#endregion

#region Movement Helpers
func allows_movement() -> bool:
	if current_state:
		return current_state.allows_movement
	return true

func allows_rotation() -> bool:
	if current_state:
		return current_state.allows_rotation
	return true

func handle_movement_input(input_dir: Vector3) -> bool:
	if current_state:
		return current_state.handle_movement_input(input_dir)
	return false
#endregion

#region Damage Integration
func on_damage_taken(amount: float, source: Node):
	if current_state:
		current_state.on_damage_taken(amount, source)
#endregion

