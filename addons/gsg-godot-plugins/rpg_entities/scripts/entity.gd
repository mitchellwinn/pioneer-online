extends CharacterBody3D
class_name Entity

# Constants
const SPEED = 2.0
const RUN_SPEED = 4.0 # 2x walking speed
const WALK_ACCELERATION = 20.0 # Accelerate to walk speed in 0.1 seconds: 2.0/0.1 = 20.0
const RUN_ACCELERATION = 6.67 # Accelerate from walk (2.0) to run (4.0) in 0.3 seconds: (4.0-2.0)/0.3 = 6.67
const STEP_HEIGHT = 0.3 # Maximum height we can step up
const STEP_TWEEN_DURATION = 0.1 # Duration of vertical step transitions in seconds
const FLOOR_SNAP_DISTANCE = 0.5 # How far down to check for floor

# Animation state
@export var animator: AnimationPlayer
@export var is_asymmetrical: bool = false # Use _asym animations for characters that can't be flipped
@export var is_simple: bool = false # Use simplified animations (only cardinal directions, duplicated for diagonals)
@export var directional_animation: bool = true # Whether this entity uses directional animations
var direction: Vector3 = Vector3.ZERO
var last_direction: Vector3 = Vector3(0, 0, 1) # Store last movement direction (default to down)
var dir_string: String = "down"
var is_running: bool = false
var was_running: bool = false
var speed_multiplier: float = 1.0 # Override multiplier for speed (normally 1.0)

# Stamina system
var stamina: float = 100.0
var max_stamina: float = 100.0 # Dynamic max stamina (calculated for party members)
const BASE_MAX_STAMINA: float = 100.0
const STAMINA_DRAIN_RATE: float = 14.3 # 100 / 7 seconds = ~14.3 per second
const STAMINA_REGEN_IDLE: float = 40.0 # Fast recovery when idle
const STAMINA_REGEN_WALKING: float = 20.0 # Slower recovery when walking
var is_panting: bool = false
var panting_timer: float = 0.0
const PANTING_DURATION: float = 3.0

# Velocity memory for grace period
var last_velocity: Vector2 = Vector2.ZERO
var stopped_timer: float = 0.0
const VELOCITY_GRACE_PERIOD: float = 0.1

# Navigation
var nav_agent: NavigationAgent3D
var is_navigating: bool = false
var navigation_target: Vector3
var last_navigation_direction: Vector3 = Vector3.ZERO
var navigation_target_marker_id: String = "" # Track marker ID if navigating to one
var navigation_start_time: float = 0.0
var last_position: Vector3 = Vector3.ZERO
var stuck_timer: float = 0.0
var stuck_timer_start_position: Vector3 = Vector3.ZERO # Position when stuck timer started
const NAVIGATION_TIMEOUT: float = 10.0 # Max seconds to attempt navigation
const STUCK_THRESHOLD: float = 0.1 # Seconds without progress = stuck (about 6 frames at 60fps)
const MIN_PROGRESS_DISTANCE: float = 0.1 # Minimum distance to move to count as progress
const STUCK_TIMER_RESET_DISTANCE: float = 0.05 # Distance to move to reset stuck timer

# Entity identification
@export var entity_id: String = ""
static var entity_registry: Dictionary = {}

# Conditional visibility based on flags
@export var enable_conditions: Array[String] = [] # All must be true to enable
@export var disable_conditions: Array[String] = [] # Any true will disable
@export var avoid_cliffs: bool = true # Prevent walking off cliffs
const MAX_CLIFF_DROP: float = 2.0 # Max distance to search for ground before considering it a cliff

# Visual components
var sprite: Sprite3D
var sprite_original_y: float = 0.0  # Store original sprite Y position
var animation_override: bool = false  # When true, motion system controls animations
var shadow_sprite: Sprite3D  # Simple sprite shadow on ground

# Step detection
var step_check_ray: RayCast3D # Ray that checks floor height ahead
var floor_ray: RayCast3D # Ray that checks floor beneath us

# Capsule collider info (populated in _ready)
var capsule_radius: float = 0.0
var capsule_height: float = 0.0
var capsule_bottom_offset: float = 0.0

# Vertical movement
var spawn_grace_frames: int = 5 # Frames to wait before enabling floor snap
const SPRITE_LERP_SPEED: float = 100.0 # How fast sprite catches up to body

# Collision backup (used by hide state)
var collision_layer_backup = null
var collision_mask_backup = null

# Called when the node enters the scene tree
func _ready():
	# Get sprite reference
	sprite = get_node_or_null("Sprite3D")
	if sprite:
		sprite_original_y = sprite.position.y
	
	# Setup shadow
	_setup_shadow()
	
	# Get navigation agent reference
	nav_agent = get_node_or_null("NavigationAgent3D")
	if nav_agent:
		nav_agent.target_reached.connect(_on_navigation_target_reached)
	
	# Register this entity if it has an ID
	if entity_id != "":
		entity_registry[entity_id] = self
		
		# Calculate max stamina for party member NPCs
		_calculate_party_member_stamina()
	
	# Connect to flag changes if we have conditions
	if (enable_conditions.size() > 0 or disable_conditions.size() > 0) and DataManager:
		DataManager.conditional_flag_changed.connect(_on_flag_changed)
		# Evaluate initial visibility
		call_deferred("_evaluate_visibility")
	
	# Defer setup to ensure all child nodes are in the tree
	call_deferred("_setup_step_detection")

# Physics processing
func _physics_process(delta):
	# Update stamina
	_update_stamina(delta)
	
	# Count down spawn grace period
	if spawn_grace_frames > 0:
		spawn_grace_frames -= 1
	
	# Handle navigation movement (skip if panting)
	if is_navigating and nav_agent and not is_panting:
		# Check for timeout
		var navigation_time = Time.get_ticks_msec() / 1000.0 - navigation_start_time
		if navigation_time > NAVIGATION_TIMEOUT:
			stop_navigation()
			return
		
		# Stuck detection disabled for now
		# TODO: Re-implement stuck detection with better heuristics
		last_position = global_position
		
		# Check horizontal distance to target (ignore Y)
		var horizontal_pos = Vector2(global_position.x, global_position.z)
		var target_horizontal = Vector2(navigation_target.x, navigation_target.z)
		var horizontal_distance = horizontal_pos.distance_to(target_horizontal)
		
		if horizontal_distance <= nav_agent.target_desired_distance:
			# Target reached horizontally - stop navigating
			stop_navigation()
		else:
			# Still navigating - move toward next path position
			var next_position = nav_agent.get_next_path_position()
			
			# Calculate full 3D direction to next waypoint
			var nav_direction = (next_position - global_position).normalized()
			
			# Extract horizontal component for animation direction
			var horizontal_nav_direction = Vector3(nav_direction.x, 0, nav_direction.z).normalized()
			
			# Update direction for animation (horizontal only)
			if horizontal_nav_direction.length() > 0.01:
				last_navigation_direction = horizontal_nav_direction
				direction = horizontal_nav_direction
			
			# Set velocity to follow the navmesh path (including Y component for slopes)
			var target_speed = RUN_SPEED if is_running else SPEED
			target_speed *= speed_multiplier
			velocity = nav_direction * target_speed
			
			# Let move_and_slide handle the actual movement with proper floor detection
			# No manual floor snapping needed - the navmesh Y is already in nav_direction
	else:
		# Not navigating - use physical step logic
		_try_step_up()
		# Always snap to floor beneath when idle (no direction)
		if direction.length() < 0.01 and not is_on_floor() and spawn_grace_frames <= 0:
			_snap_to_floor_beneath()
	
	# Always allow horizontal movement
	_handle_cliff_avoidance()
	move_and_slide()
	
	# Align sprite to ground instantly unless a motion is actively controlling it
	if sprite and not animation_override:
		_align_sprite_to_ground()
	
	# Update shadow
	_update_shadow()

# Process animation updates
func _process(_delta):
	if directional_animation:
		animate()

# Animation system
func animate():
	if not animator:
		return
	
	# Skip animation if motion system has control
	if animation_override:
		return
	
	# Handle panting animation
	if is_panting:
		animator.speed_scale = 1.0
		animator.play("panting")
		return
	
	# Update animation speed based on velocity
	var horizontal_velocity = Vector2(velocity.x, velocity.z).length()
	var speed_ratio = horizontal_velocity / SPEED if SPEED > 0 else 1.0
	animator.speed_scale = clamp(speed_ratio, 0.5, 2.0) # Clamp between 0.5x and 2x speed
	
	# Check if we're moving OR navigating
	var is_moving = velocity.length() > 0.1 or is_navigating
	
	if is_moving:
		# Update direction string based on current direction
		# ALWAYS recalculate direction string each frame when moving
		if direction.length() > 0.01:
			# Store as last_direction for idle facing updates
			last_direction = direction
			var temp_dir_string = get_string_dir()
			# Check if direction OR run state changed
			if dir_string != temp_dir_string or is_running != was_running:
				var current_time = animator.current_animation_position
				dir_string = temp_dir_string
				var anim_prefix = "run_" if is_running else "walk_"
				var anim_name = anim_prefix + dir_string
				# Use _asym version if asymmetrical and animation exists
				if is_asymmetrical:
					var asym_anim_name = anim_name + "_asym"
					if animator.has_animation(asym_anim_name):
						anim_name = asym_anim_name
				animator.play(anim_name)
				animator.seek(current_time, true) # Update = true to process immediately
				was_running = is_running
			else:
				# Same direction and run state, just ensure animation is playing
				var anim_prefix = "run_" if is_running else "walk_"
				var anim_name = anim_prefix + dir_string
				# Use _asym version if asymmetrical and animation exists
				if is_asymmetrical:
					var asym_anim_name = anim_name + "_asym"
					if animator.has_animation(asym_anim_name):
						anim_name = asym_anim_name
				animator.play(anim_name)
		else:
			# Moving but no direction set (shouldn't happen but fallback)
			var anim_prefix = "run_" if is_running else "walk_"
			var anim_name = anim_prefix + dir_string
			# Use _asym version if asymmetrical and animation exists
			if is_asymmetrical:
				var asym_anim_name = anim_name + "_asym"
				if animator.has_animation(asym_anim_name):
					anim_name = asym_anim_name
			animator.play(anim_name)
			was_running = is_running
	else:
		# Not moving - recalculate facing based on camera angle and last_direction
		var temp_dir_string = get_string_dir()
		if dir_string != temp_dir_string:
			dir_string = temp_dir_string
		var anim_name = "idle_" + dir_string
		# Use _asym version if asymmetrical and animation exists
		if is_asymmetrical:
			var asym_anim_name = anim_name + "_asym"
			if animator.has_animation(asym_anim_name):
				anim_name = asym_anim_name
		animator.play(anim_name)
		was_running = false

# Get direction string for animation
func get_string_dir() -> String:
	# Use last_direction if currently idle (so camera rotation still updates facing)
	var active_direction = direction if direction.length() > 0.01 else last_direction
	
	# If no direction at all (never moved), keep current facing
	if active_direction.length() < 0.01:
		return dir_string
	
	# Get camera-relative direction
	var camera_relative_dir = active_direction
	# Use active camera from CameraManager if available (for freecam support)
	# Otherwise fall back to main camera
	var cam = null
	if CameraManager and CameraManager.active_camera and is_instance_valid(CameraManager.active_camera):
		cam = CameraManager.active_camera
	elif GameManager.main_camera and is_instance_valid(GameManager.main_camera):
		cam = GameManager.main_camera
	
	if cam and is_instance_valid(cam):
		var camera_y_rotation = cam.global_rotation.y
		# Rotate direction by inverse of camera's Y rotation
		camera_relative_dir = active_direction.rotated(Vector3.UP, -camera_y_rotation)
	
	# Normalize to 2D for angle calculation
	var dir_2d = Vector2(camera_relative_dir.x, camera_relative_dir.z).normalized()
	
	# Calculate angle in radians (-PI to PI)
	# atan2(z, x) where:
	# - Right (x+) = 0°
	# - Down (z+) = 90° (PI/2)
	# - Left (x-) = 180° (PI)
	# - Up (z-) = -90° (-PI/2)
	var angle = atan2(dir_2d.y, dir_2d.x)
	
	# Convert to degrees for easier understanding (0 to 360)
	var angle_deg = rad_to_deg(angle)
	if angle_deg < 0:
		angle_deg += 360
	
	# Simple mode: uses down_right, down, down_left, and up animations only
	# Right uses down_right, Left uses down_left, no up diagonals
	if is_simple:
		if angle_deg >= 315 or angle_deg < 67.5:
			# Right and down-right both use down_right
			return "down_right"
		elif angle_deg >= 67.5 and angle_deg < 112.5:
			# Down uses down
			return "down"
		elif angle_deg >= 112.5 and angle_deg < 247.5:
			# Left and down-left both use down_left
			return "down_left"
		else: # 247.5 to 315 (up-left, up, up-right)
			# All upward directions use up
			return "up"
	
	# 8-directional cone system with 45° cones each
	# Cardinals get priority with ±22.5° from their axis
	if angle_deg >= 337.5 or angle_deg < 22.5:
		return "right"
	elif angle_deg >= 22.5 and angle_deg < 67.5:
		return "down_right"
	elif angle_deg >= 67.5 and angle_deg < 112.5:
		return "down"
	elif angle_deg >= 112.5 and angle_deg < 157.5:
		return "down_left"
	elif angle_deg >= 157.5 and angle_deg < 202.5:
		return "left"
	elif angle_deg >= 202.5 and angle_deg < 247.5:
		return "up_left"
	elif angle_deg >= 247.5 and angle_deg < 292.5:
		return "up"
	else: # 292.5 to 337.5
		return "up_right"
	
	return "down"

# Move in a direction
func move(move_direction: Vector3):
	# Cannot move while panting
	if is_panting:
		velocity.x = 0
		velocity.z = 0
		return
	
	# Normalize and clean up direction
	if move_direction.length() > 0.01:
		direction = move_direction.normalized()
		direction.y = 0
		last_direction = direction # Store for step detection when standing
	else:
		direction = Vector3.ZERO
	
	basis.y = Vector3.UP
	
	var base_speed = RUN_SPEED if is_running else SPEED
	var target_speed = base_speed * speed_multiplier
	var delta = get_physics_process_delta_time()
	
	if direction.length() > 0.01:
		look_at(self.position + direction * 100)
		
		# Check if we're resuming movement within grace period
		var current_speed: float
		if stopped_timer > 0 and stopped_timer <= VELOCITY_GRACE_PERIOD:
			# Restore last velocity
			current_speed = last_velocity.length()
			stopped_timer = 0.0
		else:
			current_speed = Vector2(velocity.x, velocity.z).length()
		
		# Calculate direction change penalty (50% reduction on full turnaround)
		if current_speed > 0.01:
			var current_vel_dir = Vector2(velocity.x, velocity.z).normalized()
			var new_dir_2d = Vector2(direction.x, direction.z).normalized()
			var dot_product = current_vel_dir.dot(new_dir_2d) # 1.0 = same direction, -1.0 = opposite
			# Map dot product to speed multiplier: 1.0 stays same, -1.0 becomes 0.5
			var direction_alignment = 0.5 + (dot_product * 0.5) # 0.5 to 1.0
			current_speed *= direction_alignment
		
		# Smooth acceleration
		var effective_run_speed = RUN_SPEED * speed_multiplier
		var effective_walk_speed = SPEED * speed_multiplier
		if is_running and current_speed < effective_run_speed:
			# Accelerate from walk speed to run speed over 0.5 seconds
			current_speed = move_toward(current_speed, effective_run_speed, RUN_ACCELERATION * speed_multiplier * delta)
		elif not is_running and current_speed < effective_walk_speed:
			# Accelerate to walk speed in 0.1 seconds
			current_speed = move_toward(current_speed, effective_walk_speed, WALK_ACCELERATION * speed_multiplier * delta)
		else:
			# Decelerate to target speed if above it
			current_speed = move_toward(current_speed, target_speed, WALK_ACCELERATION * delta)
		
		# Apply speed in movement direction
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
		
		# Store velocity for grace period
		last_velocity = Vector2(velocity.x, velocity.z)
		stopped_timer = 0.0
	else:
		# Start/continue stopped timer for grace period
		if stopped_timer <= VELOCITY_GRACE_PERIOD:
			stopped_timer += delta
		
		# Stop movement
		velocity.x = 0
		velocity.z = 0

# Update stamina based on movement state
func _update_stamina(delta: float):
	# Handle panting state
	if is_panting:
		panting_timer += delta
		if panting_timer >= PANTING_DURATION:
			# Recovery complete
			is_panting = false
			panting_timer = 0.0
			stamina = max_stamina
		return
	
	# Determine if this entity should drain stamina while running
	var should_drain_stamina = false
	
	# Check if this is the player being chased by aggressive NPCs
	var aggro_state_script = load("res://addons/gsg-godot-plugins/rpg_entities/scripts/states/npc_state_aggro.gd")
	var is_being_chased = aggro_state_script and aggro_state_script.aggressive_npcs.size() > 0
	if is_being_chased:
		should_drain_stamina = true
	
	# Check if this is an NPC in aggro state (chasing the player)
	# Don't drain for follow NPCs (party members following player)
	if self is NPC:
		var npc_self = self as NPC
		if npc_self.state_manager and npc_self.state_manager.current_state and npc_self.state_manager.current_state.get_script() == aggro_state_script:
			should_drain_stamina = true
	
	if is_running and stamina > 0 and should_drain_stamina:
		# Drain stamina while running in chase situations
		stamina -= STAMINA_DRAIN_RATE * delta
		stamina = max(0, stamina)
		# Force stop running and enter panting state if stamina depleted
		if stamina <= 0:
			is_running = false
			is_panting = true
			panting_timer = 0.0
	elif direction.length() > 0.01:
		# Regenerate slower while walking
		stamina += STAMINA_REGEN_WALKING * delta
		stamina = min(max_stamina, stamina)
	else:
		# Regenerate faster while idle
		stamina += STAMINA_REGEN_IDLE * delta
		stamina = min(max_stamina, stamina)

# Stop movement
func stop():
	velocity = Vector3.ZERO
	direction = Vector3.ZERO
	# Don't clear last_direction - preserve facing for camera-relative updates
	is_running = false

# Calculate max stamina for party member NPCs based on their speed relative to Robby
func _calculate_party_member_stamina():
	# Check if this is a party member NPC
	if not entity_id.begins_with("party_npc_"):
		return
	
	# Extract character key from entity_id (format: "party_npc_characterkey")
	var character_key = entity_id.replace("party_npc_", "")
	
	# Find Robby's stats in the party
	var robby_stats: Stats = null
	for member in GameManager.party:
		if member.character_key == "robby":
			robby_stats = member
			break
	
	if not robby_stats:
		print("[STAMINA] Could not find Robby in party, using default max stamina")
		return
	
	# Find this character's stats in the party
	var character_stats: Stats = null
	for member in GameManager.party:
		if member.character_key == character_key:
			character_stats = member
			break
	
	if not character_stats:
		print("[STAMINA] Could not find ", character_key, " in party, using default max stamina")
		return
	
	# Get speed stats (agility)
	var robby_speed = robby_stats.get_agility()
	var character_speed = character_stats.get_agility()
	
	if robby_speed <= 0:
		print("[STAMINA] Invalid Robby speed, using default max stamina")
		return
	
	# Calculate max stamina based on speed ratio
	# Formula: BASE_MAX_STAMINA * (character_speed / robby_speed)
	# Example: If Robby has 50 speed and Emilio has 100, Emilio gets 200 stamina
	var speed_ratio = float(character_speed) / float(robby_speed)
	max_stamina = BASE_MAX_STAMINA * speed_ratio
	stamina = max_stamina # Initialize stamina to max
	

# Setup step detection raycasts
func _setup_step_detection():
	# Get capsule collider dimensions
	var collision_shape = get_node_or_null("CollisionShape3D")
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		var capsule = collision_shape.shape as CapsuleShape3D
		capsule_radius = capsule.radius
		capsule_height = capsule.height
		# Get the offset of the collision shape (bottom of capsule)
		capsule_bottom_offset = collision_shape.position.y - (capsule_height / 2.0)
	else:
		# Fallback values if no capsule found
		capsule_radius = 0.15
		capsule_height = 0.6
		capsule_bottom_offset = 0.0
		push_warning("Entity: No CapsuleShape3D found, using default values")
	
	# Step check ray - starts above feet, shoots down ahead to find floor height
	step_check_ray = RayCast3D.new()
	step_check_ray.position = Vector3(0, capsule_bottom_offset + STEP_HEIGHT, 0)
	step_check_ray.enabled = true
	step_check_ray.exclude_parent = true
	step_check_ray.collision_mask = 1
	step_check_ray.target_position = Vector3(0, - (STEP_HEIGHT + MAX_CLIFF_DROP), 0) # Cast down deep to check for cliffs
	add_child(step_check_ray)
	
	# Floor raycast - constantly checks for floor beneath us
	# Starts at top of capsule and casts down to avoid starting inside floor
	floor_ray = RayCast3D.new()
	var capsule_top = capsule_bottom_offset + capsule_height
	floor_ray.position = Vector3(0, capsule_top, 0) # At top of capsule
	floor_ray.enabled = true
	floor_ray.exclude_parent = true
	floor_ray.collision_mask = 1
	floor_ray.target_position = Vector3(0, -1000, 0) # Check far down to find any floor
	add_child(floor_ray)

# Snap to floor beneath us when not grounded
func _snap_to_floor_beneath():
	if not step_check_ray or not floor_ray:
		return
	
	# Check floor directly beneath
	floor_ray.global_position = global_position + Vector3(0, capsule_height, 0)
	floor_ray.force_raycast_update()
	
	var floor_beneath_y = -999999.0
	if floor_ray.is_colliding():
		floor_beneath_y = floor_ray.get_collision_point().y
	
	# Check floor ahead if moving
	var floor_ahead_y = -999999.0
	if direction.length() > 0.01:
		var move_dir_2d = Vector3(direction.x, 0, direction.z).normalized()
		var check_distance = capsule_radius + 0.1
		step_check_ray.global_position = global_position + move_dir_2d * check_distance + Vector3(0, STEP_HEIGHT, 0)
		step_check_ray.force_raycast_update()
		
		if step_check_ray.is_colliding():
			floor_ahead_y = step_check_ray.get_collision_point().y
	
	# Use whichever floor is higher (prioritize ahead if it's a step up)
	var target_floor_y = max(floor_beneath_y, floor_ahead_y)
	if target_floor_y > -999999.0:
		# Ensure we don't snap to a cliff bottom if it's too deep
		# Note: _snap_to_floor_beneath is usually called when we are close to floor
		# but with extended rays we must be careful.
		# However, we only want to restrict HORIZONTAL movement over cliffs.
		# If we are already over a cliff (e.g. pushed), maybe we should fall?
		# For now, keep existing snap behavior as it handles staying on ground.
		_tween_to_height(target_floor_y)

# Prevent walking off cliffs by checking for floor ahead
func _handle_cliff_avoidance():
	if not avoid_cliffs:
		return
		
	# Only check if we are trying to move
	if velocity.length() < 0.01:
		return
		
	# Check if the full movement direction is safe
	if _is_position_safe(velocity):
		return
		
	# Full movement is not safe (cliff ahead). Try sliding.
	# Try moving only along X
	var velocity_x = Vector3(velocity.x, 0, 0)
	if abs(velocity.x) > 0.01 and _is_position_safe(velocity_x):
		velocity.z = 0
		return
		
	# Try moving only along Z
	var velocity_z = Vector3(0, 0, velocity.z)
	if abs(velocity.z) > 0.01 and _is_position_safe(velocity_z):
		velocity.x = 0
		return
		
	# Neither direction is safe - stop
	velocity = Vector3.ZERO

# Check if a position in a given direction is safe (has floor within MAX_CLIFF_DROP)
func _is_position_safe(dir_vector: Vector3) -> bool:
	if not step_check_ray:
		return true # Assume safe if no ray (shouldn't happen)
		
	var move_dir_2d = Vector3(dir_vector.x, 0, dir_vector.z).normalized()
	var check_distance = capsule_radius + 0.1
	
	# Position the ray ahead
	step_check_ray.global_position = global_position + move_dir_2d * check_distance + Vector3(0, STEP_HEIGHT, 0)
	step_check_ray.force_raycast_update()
	
	if not step_check_ray.is_colliding():
		return false # No floor found -> Cliff
		
	var floor_point = step_check_ray.get_collision_point()
	var capsule_bottom_world = global_position.y + capsule_bottom_offset
	
	# Check if floor is too far down
	var drop = capsule_bottom_world - floor_point.y
	if drop > MAX_CLIFF_DROP:
		return false # Too deep -> Cliff
		
	return true


# Try to step up when detecting obstacles ahead
func _try_step_up():
	# Check if step_check_ray is ready
	if not step_check_ray:
		return
	
	# Use current direction if moving, otherwise use last direction
	var check_dir = direction if direction.length() > 0.01 else last_direction
	if check_dir.length() < 0.01:
		return # No direction to check
	
	# Orient step check ray ahead in movement direction
	var move_dir_2d = Vector3(check_dir.x, 0, check_dir.z).normalized()
	var check_distance = capsule_radius + 0.1
	
	# Position the ray ahead of us and cast down to find floor
	step_check_ray.global_position = global_position + move_dir_2d * check_distance + Vector3(0, STEP_HEIGHT, 0)
	step_check_ray.force_raycast_update()
	
	# Check if there's a floor ahead
	if not step_check_ray.is_colliding():
	# No floor ahead (very deep), snap to floor beneath if not grounded
		if not is_on_floor() and spawn_grace_frames <= 0:
			_snap_to_floor_beneath()
		return
	
	# Get the floor point ahead
	var floor_ahead = step_check_ray.get_collision_point()
	var capsule_bottom_world = global_position.y + capsule_bottom_offset
	var step_height = floor_ahead.y - capsule_bottom_world
	
	# Step up if floor ahead is higher (within limit)
	if step_height > 0.02 and step_height <= STEP_HEIGHT:
		_tween_to_height(floor_ahead.y, move_dir_2d)
	elif step_height < -0.02:
		# Floor is lower (drop). If we're not on floor, try to snap down (simulate gravity/slope)
		# This handles the case where we walk down a slope or small drop that is within ray range
		if not is_on_floor() and spawn_grace_frames <= 0:
			_snap_to_floor_beneath()

# Align sprite to ground during navigation (body stays on navmesh)
func _align_sprite_to_ground():
	if not sprite or not floor_ray:
		return
	
	# Cast ray down from current position
	floor_ray.global_position = global_position + Vector3(0, capsule_height, 0)
	floor_ray.force_raycast_update()
	
	if floor_ray.is_colliding():
		var floor_y = floor_ray.get_collision_point().y
		var body_bottom_y = global_position.y + capsule_bottom_offset
		var height_diff = floor_y - body_bottom_y
		
		# Sanity check: prevent sprite from moving too far from body
		# This prevents sprites from disappearing if raycast hits something weird
		if height_diff < -2.0 or height_diff > 1.5:
			return
		
		# Adjust sprite position to match ground (instant)
		sprite.position.y = sprite_original_y + height_diff

func _update_sprite_ground_alignment(delta: float):
	if not sprite:
		return
	# If we have a valid floor ray, align smoothly to ground; else ease back to original
	if floor_ray:
		floor_ray.global_position = global_position + Vector3(0, capsule_height, 0)
		floor_ray.force_raycast_update()
		if floor_ray.is_colliding():
			var floor_y = floor_ray.get_collision_point().y
			var body_bottom_y = global_position.y + capsule_bottom_offset
			var target_local_y = sprite_original_y + (floor_y - body_bottom_y)
			var t = clamp(SPRITE_LERP_SPEED * delta, 0.0, 1.0)
			sprite.position.y = lerp(sprite.position.y, target_local_y, t)
			return
	# Fallback to original height smoothly
	var t2 = clamp(SPRITE_LERP_SPEED * delta, 0.0, 1.0)
	sprite.position.y = lerp(sprite.position.y, sprite_original_y, t2)

func _tween_to_height(target_floor_y: float, forward_dir: Vector3 = Vector3.ZERO):
	# Instant snap of body to floor height; sprite alignment handled separately
	var target_height = target_floor_y - capsule_bottom_offset
	if abs(target_height - global_position.y) < 0.001:
		return
	global_position.y = target_height
	velocity.y = 0
	# Align sprite to ground immediately unless a motion is controlling it
	if sprite and not animation_override:
		_align_sprite_to_ground()


# Navigation functions
func navigate_to_position(target_pos: Vector3, marker_id: String = ""):
	if not nav_agent:
		return false
	
	# Use NavigationServer to get the closest valid point on navmesh
	# This is MUCH faster than using raycasts and already has the correct height
	var nav_map = nav_agent.get_navigation_map()
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target_pos)
	
	# If the closest point is too far from the desired target (horizontally),
	# it might be an invalid navigation attempt (e.g. target in void or inside wall).
	var horizontal_distance = Vector2(closest_point.x - target_pos.x, closest_point.z - target_pos.z).length()
	if horizontal_distance > 1.0:
		return false
	
	# Additional validation: Check if destination height is too far from current position
	# This helps prevent navigating to building roofs or other off-limits elevated areas
	var height_diff = abs(closest_point.y - global_position.y)
	if height_diff > 3.0:  # More than 3 units height difference suggests off-limits area
		return false
	
	# Let NavigationAgent handle pathfinding - it's optimized for this
	# We've already validated the point is on navmesh and at reasonable height
	navigation_target = closest_point
	nav_agent.target_position = closest_point
	is_navigating = true
	navigation_target_marker_id = marker_id
	
	# Initialize navigation tracking
	navigation_start_time = Time.get_ticks_msec() / 1000.0
	last_position = global_position
	stuck_timer = 0.0
	stuck_timer_start_position = global_position
	
	return true

func stop_navigation():
	is_navigating = false
	if nav_agent:
		nav_agent.target_position = global_position
	
	# Unregister from marker if we were navigating to one
	if navigation_target_marker_id != "" and entity_id != "":
		var marker_script = load("res://scripts/marker.gd")
		marker_script.unregister_navigation_to_marker(navigation_target_marker_id, entity_id)
		navigation_target_marker_id = ""
	
	stop()

func is_at_target() -> bool:
	if not nav_agent or not is_navigating:
		return true
	# Use NavigationAgent's built-in target reached detection
	return nav_agent.is_navigation_finished()


# Signal handler for when navigation target is reached
func _on_navigation_target_reached():
	var distance = global_position.distance_to(navigation_target)
	is_navigating = false
	
	# Unregister from marker if we were navigating to one
	if navigation_target_marker_id != "" and entity_id != "":
		var marker_script = load("res://scripts/marker.gd")
		marker_script.unregister_navigation_to_marker(navigation_target_marker_id, entity_id)
		navigation_target_marker_id = ""
	
	# Keep last direction for idle animation
	if last_navigation_direction.length() > 0.01:
		direction = last_navigation_direction
	stop()

# Static functions for entity management
static func get_entity_by_id(id: String) -> Entity:
	if entity_registry.has(id):
		return entity_registry[id]
	return null

static func get_all_entities() -> Array[Entity]:
	var entities: Array[Entity] = []
	for entity in entity_registry.values():
		if is_instance_valid(entity):
			entities.append(entity)
	return entities

# Setup shadow sprite
func _setup_shadow():
	# Check if a shadow already exists (e.g., from being duplicated)
	var existing_shadow = get_node_or_null("Shadow")
	if existing_shadow:
		shadow_sprite = existing_shadow
		return
	
	var shadow_texture: Texture2D = load("res://images/overworld/characters/shadow.png")
	if shadow_texture == null:
		push_warning("Entity: Could not load shadow.png")
		return
	
	shadow_sprite = Sprite3D.new()
	shadow_sprite.name = "Shadow"
	shadow_sprite.texture = shadow_texture
	shadow_sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	shadow_sprite.shaded = false
	shadow_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	shadow_sprite.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Start rotated flat on ground (pointing up)
	shadow_sprite.rotation_degrees = Vector3(-90, 0, 0)
	# Make it small and semi-transparent
	shadow_sprite.modulate = Color(1, 1, 1, 0.6)
	shadow_sprite.pixel_size = 0.005
	add_child(shadow_sprite)

func _update_shadow():
	if not shadow_sprite or not sprite:
		return
	
	# Raycast down from entity body position (not sprite, to avoid jump offset)
	var space_state = get_world_3d().direct_space_state
	var raycast_start = global_position + Vector3(0, 0.1, 0) # Start slightly above entity center
	var query = PhysicsRayQueryParameters3D.create(
		raycast_start,
		raycast_start + Vector3(0, -10, 0)
	)
	query.collision_mask = 1
	query.exclude = [self]
	
	var result = space_state.intersect_ray(query)
	
	if result:
		# Position shadow on ground
		shadow_sprite.global_position = result.position + result.normal * 0.01 # Slightly above to avoid z-fighting
		
		# Align shadow to ground normal
		# Sprite3D renders in XY plane, so we need normal pointing toward camera (Z)
		var forward = result.normal # Normal becomes forward (Z)
		var right = Vector3(1, 0, 0)
		# Make right perpendicular to forward
		right = right - forward * right.dot(forward)
		if right.length() > 0.001:
			right = right.normalized()
		else:
			right = Vector3(0, 0, 1)
		var up = right.cross(forward).normalized()
		
		# Build rotation from basis (XYZ = right, up, forward)
		var basis = Basis(right, up, forward)
		shadow_sprite.global_transform.basis = basis
		
		# Calculate height above ground for scaling
		var height_above_ground = sprite.global_position.y - result.position.y
		
		# Scale and fade shadow based on height
		# Shadow gets BIGGER and MORE TRANSPARENT when higher (simulating light spread)
		var max_height = 2.0 # Max height to consider for shadow scaling
		var height_ratio = clamp(height_above_ground / max_height, 0.0, 1.0)
		var base_size = 1.2
		var size_multiplier = base_size + (height_ratio * 0.8) # Grows from base_size to base_size+0.8
		var base_opacity = 0.5
		var opacity_multiplier = 1.0 - (height_ratio * 0.7) # Fades from 1.0 to 0.3
		
		shadow_sprite.scale = Vector3.ONE * size_multiplier
		shadow_sprite.modulate.a = base_opacity * opacity_multiplier
	else:
		# No ground found, hide shadow
		shadow_sprite.visible = false
		return
	
	shadow_sprite.visible = true

func _exit_tree():
	# Unregister entity when it's removed from the scene
	if entity_id != "" and entity_registry.has(entity_id):
		entity_registry.erase(entity_id)

# Conditional visibility functions
func _on_flag_changed(_flag_key: String):
	"""Called when any flag changes. Re-evaluate visibility."""
	# Debug: log which entity is reevaluating for which flag
	print("[Entity] ", entity_id, " received flag change: ", _flag_key)
	_evaluate_visibility()

static func recheck_visibility_for_all():
	"""Force all entities to re-evaluate their conditional visibility now."""
	var entities = get_all_entities()
	for e in entities:
		if e and is_instance_valid(e):
			e._evaluate_visibility()

func _evaluate_visibility():
	"""Evaluate enable/disable conditions and show/hide entity accordingly."""
	if not DataManager:
		return
	
	var should_be_visible = true
	
	# Check enable conditions - all must be true
	for condition in enable_conditions:
		if not DataManager.evaluate_flag_condition(condition):
			# Enable condition failed
			should_be_visible = false
			break
	
	# Check disable conditions - any true will disable
	if should_be_visible:
		for condition in disable_conditions:
			if DataManager.evaluate_flag_condition(condition):
				# Disable condition met
				should_be_visible = false
				break
	
	# Apply visibility
	if not should_be_visible:
		# Entity should be hidden
		if self is NPC and has_node("StateManager"):
			# For NPCs with state machine, transition to hide state
			var state_manager = get_node("StateManager")
			if state_manager.states.has("hide"):
				state_manager.change_state("hide")
			else:
				# No hide state, just make invisible
				visible = false
				process_mode = Node.PROCESS_MODE_DISABLED
		else:
			# Not an NPC or no state manager, just make invisible
			visible = false
			process_mode = Node.PROCESS_MODE_DISABLED
	else:
		# Entity should be visible - only transition out of hide state if conditions allow
		if self is NPC and has_node("StateManager"):
			var state_manager = get_node("StateManager")
			# Only transition out of hide state if NPC is currently hidden
			if state_manager.get_current_state_name() == "hide":
				# Return to initial state (idle, wander, patrol, etc.)
				if state_manager.states.has(self.initial_state.to_lower()):
					state_manager.change_state(self.initial_state.to_lower())
				else:
					state_manager.change_state("idle")
		else:
			# Not an NPC, just make visible
			visible = true
			process_mode = Node.PROCESS_MODE_INHERIT
