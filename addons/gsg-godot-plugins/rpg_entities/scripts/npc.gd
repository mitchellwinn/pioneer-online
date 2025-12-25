extends Entity
class_name NPC

# NPC-specific properties
@export var dialogue: String
@export var troop: String = ""
@export var look_at_player: bool = false
@export var animates: bool = true

# State configuration
@export_enum("idle", "wander", "follow", "patrol") var initial_state: String = "idle"
@export_group("Wander Settings")
@export var wander_radius: float = 5.0
@export var wander_wait_min: float = 2.0
@export var wander_wait_max: float = 5.0
@export_group("Patrol Settings")
@export var run_detection_radius: float = 3.0
@export var walk_detection_radius: float = 1.5
@export var fov_angle: float = 90.0
@export var fov_scan_speed: float = 2.0
@export var detection_chance: float = 0.05
@export_group("Aggro Settings")
@export var chase_speed: float = 4.0
@export var max_chase_distance: float = 0.0
@export var max_stray_distance: float = 0.0

# State machine
var state_manager: NPCStateManager = null

var look_dir = Vector3.DOWN

# Override ready
func _ready():
	super._ready()
	
	# Get state manager reference
	state_manager = get_node_or_null("StateManager")
	if state_manager:
		# Wait for state manager to initialize its children
		await get_tree().process_frame
		
		# Pass wander settings to wander state if it exists
		if state_manager.states.has("wander"):
			var wander_state = state_manager.states["wander"]
			wander_state.wander_radius = wander_radius
			wander_state.min_wait_time = wander_wait_min
			wander_state.max_wait_time = wander_wait_max
		
		# Pass patrol settings to patrol state if it exists
		if state_manager.states.has("patrol"):
			var patrol_state = state_manager.states["patrol"]
			patrol_state.run_detection_radius = run_detection_radius
			patrol_state.walk_detection_radius = walk_detection_radius
			patrol_state.fov_angle = fov_angle
			patrol_state.fov_scan_speed = fov_scan_speed
			patrol_state.detection_chance = detection_chance
		
		# Pass aggro settings to aggro state if it exists
		if state_manager.states.has("aggro"):
			var aggro_state = state_manager.states["aggro"]
			aggro_state.chase_speed = chase_speed
			aggro_state.max_chase_distance = max_chase_distance
			aggro_state.max_stray_distance = max_stray_distance
		
		# Set initial state if available (keys normalized to lowercase)
		var init_key = initial_state.to_lower()
		if state_manager.states.has(init_key):
			state_manager.change_state(init_key)
	
	# Re-evaluate visibility now that state manager is ready
	# This ensures NPCs can properly transition to hide state if needed
	if (enable_conditions.size() > 0 or disable_conditions.size() > 0) and DataManager:
		_evaluate_visibility()
	
	# Note: NPC state during dialogue is now managed directly by the initiator
	# (character_controller for player-initiated, aggro state for combat-initiated)

# Override physics process for NPC behavior
func _physics_process(delta):
	# If state machine is active and in a non-idle state, let it handle behavior
	var has_active_state = state_manager and state_manager.current_state and state_manager.get_current_state_name() != "idle"
	
	if not has_active_state:
		# Handle look at player (only when in idle or no state machine)
		if look_at_player and GameManager.player:
			look_dir = look_to(GameManager.player)
			# Update direction if it changed significantly
			if look_dir.length() > 0.01:
				direction = look_dir.normalized()
				direction.y = 0
				last_direction = direction  # Store for camera-relative facing updates
		elif not is_navigating:
			# If not looking at player and not navigating, keep current direction
			pass
	
	# Always call parent for physics (stamina, navigation, movement)
	super._physics_process(delta)

# Override process to handle animation
func _process(delta):
	if animates:
		super._process(delta)
	else:
		animator.play("idle_down")

# Set dialogue path
func set_dialogue(xml_file_path):
	dialogue = xml_file_path

# Look towards target
func look_to(target) -> Vector3:
	var dir = (target.position - self.position).normalized()
	dir.y = 0
	return dir

# NPCs use the same camera-relative cone system as the parent Entity class
# No override needed - parent get_string_dir() handles it properly
