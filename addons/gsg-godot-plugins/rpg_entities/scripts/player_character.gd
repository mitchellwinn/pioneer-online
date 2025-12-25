extends Entity

signal warp_target_changed(new_target)

# Interaction targets
var interaction_target # NPC or interactable
var warp_target:
	set(value):
		if warp_target != value:
			warp_target = value
			warp_target_changed.emit(value)

# Movement state
var is_moving: bool = false

# Called when the node enters the scene tree
func _ready():
	print("[PLAYER] ========== _ready() CALLED ==========")
	print("[PLAYER] Current scene: ", get_tree().current_scene.name if get_tree().current_scene else "NULL")
	print("[PLAYER] Is in tree: ", is_inside_tree())
	print("[PLAYER] Process mode: ", process_mode)
	print("[PLAYER] Stack trace:")
	print_stack()
	print("[PLAYER] ==========================================")
	super._ready()
	GameManager.get_scene_references()
	GameManager.player = self
	print("[PLAYER] Player registered with GameManager")
	_load_player_state_from_data()
	_start_input_loops()
	
	# Party NPC spawning is handled by:
	# 1. title_load_window.gd after loading a save
	# 2. warp_zone.gd after cross-scene warps
	# 3. title_main_window.gd after starting a new game
	# Don't spawn here to avoid duplicates

# Override physics process to add player input
func _physics_process(delta):
	# Always call parent physics processing first (handles navigation)
	super._physics_process(delta)
	
	# Only handle player input if they have control
	if has_control():
		# Handle player input
		handle_input()
		
		# Handle warp
		if warp_target:
			if warp_target.button_triggered:
				if Input.is_action_just_pressed("confirm"):
					warp_target.trigger_warp(self)
			else:
				warp_target.trigger_warp(self)
	else:
		# No control - stop movement and clear input state
		stop()
		is_moving = false
	
	# Continuously mirror player state into DataManager.general_data.player_data
	_update_player_state_in_data()

# Override process to add camera following
func _process(delta):
	super._process(delta)
	# Camera following is now handled by BetterCamera
	# if GameManager.main_camera and sprite:
	# 	var sprite_world_pos = sprite.global_position
	# 	GameManager.main_camera.global_position = sprite_world_pos + Vector3(0, 3, 5)

# Handle player input
func handle_input():
	# Get input vector using Godot's helper (handles keyboard and analog stick automatically)
	var input_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	
	# Calculate camera-relative movement direction
	var move_direction = Vector3.ZERO
	if input_dir.length() > 0:
		if CameraManager.active_camera:
			var cam = CameraManager.active_camera
			# Check if camera has use_deadzone (deadzone cameras use world-space)
			if "use_deadzone" in cam and cam.use_deadzone:
				move_direction = Vector3(input_dir.x, 0, input_dir.y)
			else:
				# Transform input to camera space for free cameras
				move_direction = cam.basis * Vector3(input_dir.x, 0, input_dir.y)
				move_direction.y = 0
		else:
			# No camera - use world space
			move_direction = Vector3(input_dir.x, 0, input_dir.y)
		
		move_direction = move_direction.normalized()
		is_moving = true
		# Only allow running if stamina is available and not panting
		is_running = Input.is_action_pressed("run") and stamina > 0 and not is_panting
		move(move_direction)
	else:
		is_moving = false
		is_running = false
		move(Vector3.ZERO)

# Load saved player position (and scene) from DataManager.general_data if a save exists
func _load_player_state_from_data():
	if not DataManager:
		return
	# Only attempt to restore if there is save data for the current slot
	if DataManager.has_method("has_save_data") and not DataManager.has_save_data(DataManager.current_save_slot):
		return
	if DataManager.general_data == null:
		return
	if not DataManager.general_data.has("player_data"):
		return
	var state = DataManager.general_data["player_data"]
	var pos = state.get("position", null)
	if pos != null:
		# If default sentinel (-777) is stored, don't override prefab position
		if pos.x == -777 and pos.y == -777 and pos.z == -777:
			return
		global_position = Vector3(pos.x, pos.y, pos.z)
	
	# Optionally restore facing direction if present and not sentinel
	var dir = state.get("direction", null)
	if dir != null and "direction" in self:
		if not (dir.x == -777 and dir.y == -777 and dir.z == -777):
			direction = Vector3(dir.x, dir.y, dir.z)
	
# Continuously write player position into DataManager.general_data.player_data
func _update_player_state_in_data():
	if not DataManager:
		return
	if DataManager.general_data == null:
		DataManager.general_data = {}
	if not DataManager.general_data.has("player_data"):
		DataManager.general_data["player_data"] = {}
	var player_data = DataManager.general_data["player_data"]
	var pos = global_position
	player_data["position"] = {
		"x": pos.x,
		"y": pos.y,
		"z": pos.z
	}
	var current_scene = get_tree().current_scene
	if current_scene:
		player_data["scene_path"] = current_scene.scene_file_path
	# Optionally store facing direction if available
	if "direction" in self:
		player_data["direction"] = {
			"x": direction.x,
			"y": direction.y,
			"z": direction.z
		}
	DataManager.general_data["player_data"] = player_data

# Check if player has control
func has_control() -> bool:
	if GameManager.is_transitioning:
		return false
	if BattleManager.is_transitioning_to_battle:
		return false
	if DialogueManager.is_open:
		return false
	if GameManager.shop_window and GameManager.shop_window.active:
		return false
	# Check if any menu window is open
	if MenuManager.get_active_window():
		return false
	if DialogueManager.is_open:
		return false
	# Disable control when being moved by navigation events
	if is_navigating:
		return false
	return true

# Start async input loops
func _start_input_loops():
	_interaction_loop()

func _unhandled_input(event):
	# Handle menu opening with back button
	if event.is_action_pressed("back") and has_control() and not DialogueManager.is_open and not GameManager.is_transitioning:
		var active_window = MenuManager.get_active_window()
		if not active_window:
			# Stop player movement
			stop()
			is_moving = false
			
			# Open the main menu (auto-creates/attaches if needed)
			MenuManager.open_window("main")
			get_viewport().set_input_as_handled()
	
	# Handle NPC interaction with unhandled input (only on press, not echo)
	if event.is_action_pressed("confirm") and not event.is_echo() and interaction_target and has_control() and not MenuManager.get_active_window() and not warp_target:
		var target = interaction_target
		
		# Don't interact with NPCs in hide state
		if target is NPC:
			var npc = target as NPC
			if npc.state_manager and npc.state_manager.get_current_state_name() == "hide":
				print("[Player] Cannot interact with hidden NPC")
				return
		
		print("try talk")
		stop()
		get_viewport().set_input_as_handled()
		
		var npc_target: NPC = null
		if is_instance_valid(target):
			# If target is an NPC with state manager, set to idle during dialogue
			if target is NPC:
				npc_target = target as NPC
				if npc_target.state_manager:
					print("[Player] Setting NPC to idle state for dialogue")
					npc_target.state_manager.change_state("idle", true) # Save previous state
				else:
					print("[Player] NPC has no state manager")
			
			# Set current NPC reference for battle events
			DialogueManager.current_npc = npc_target
			
			# Start dialogue
			DialogueManager.initiate_dialogue(target.dialogue)
		
		# Wait for dialogue to actually finish
		await DialogueManager.dialogue_finished
		
		# After dialogue, re-evaluate NPC visibility in case flags changed
		if is_instance_valid(npc_target):
			# First check if NPC should be hidden based on current conditions
			if npc_target.has_method("_evaluate_visibility"):
				npc_target._evaluate_visibility()
				print("[Player] Re-evaluated NPC visibility after dialogue")
				# If NPC is now in hide state, don't restore previous state
				if npc_target.state_manager and npc_target.state_manager.get_current_state_name() == "hide":
					print("[Player] NPC is now hidden, skipping state restoration")
					return
			
			# If not hidden, restore previous state
			if npc_target.state_manager:
				print("[Player] Restoring NPC state after dialogue")
				npc_target.state_manager.restore_previous_state()

# Handle NPC interaction input
# Note: Interaction is now handled in _unhandled_input to prevent conflicts with dialogue advancement
func _interaction_loop():
	pass  # No longer needed - using _unhandled_input instead

# Signal handlers
func _on_area_3d_body_entered(body):
	if body is NPC:
		interaction_target = body
		print("NPC")

func _on_area_3d_body_exited(body):
	if interaction_target == body:
		interaction_target = null
