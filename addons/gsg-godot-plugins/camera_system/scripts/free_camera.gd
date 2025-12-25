extends BaseCamera
class_name FreeCamera

const MOUSE_SENSITIVITY = 0.002
const JOY_SENSITIVITY = 2.0
const FOV_STEP = 5.0
const FOV_MIN = 20.0
const FOV_MAX = 120.0

# Adjustable settings
var move_speed: float = 10.0
var fast_move_speed: float = 20.0
var zoom_speed: float = 2.0
var pos_smooth: float = 0.15
var rot_smooth: float = 0.2

# Auto-cam constants
const AUTO_TARGET_SWITCH_MIN = 5.0
const AUTO_TARGET_SWITCH_MAX = 15.0
const AUTO_ORBIT_SPEED = 0.3
const AUTO_DISTANCE_MIN = 4.0
const AUTO_DISTANCE_MAX = 12.0
const AUTO_HEIGHT_MIN = 1.5
const AUTO_HEIGHT_MAX = 5.0
const AUTO_WANDER_CHANCE = 0.3  # 30% chance to wander
const AUTO_MOVE_SMOOTH = 0.08
const AUTO_LOOK_SMOOTH = 0.12

# Wander behavior constants
const WANDER_SPEED_MIN = 2.0
const WANDER_SPEED_MAX = 6.0
const WANDER_SPEED_OSCILLATION = 0.5  # Hz
const WANDER_ROTATION_SPEED_MIN = 0.1
const WANDER_ROTATION_SPEED_MAX = 0.4
const WANDER_RAYCAST_DISTANCE = 8.0
const WANDER_SIDE_RAYCAST_DISTANCE = 5.0
const WANDER_SUBJECT_DETECT_RANGE = 15.0
const WANDER_MIN_DURATION = 8.0
const WANDER_MAX_DURATION = 20.0
const WANDER_TURN_THRESHOLD = 2.0  # Distance to obstacle before turning

enum Mode { NORMAL, CINEMATIC, AUTO }

var _was_current: bool = false
var current_mode: Mode = Mode.NORMAL
var yaw: float
var pitch: float
var desired_position: Vector3
var zoom_amount: float = 0.0

# Auto-cam state
var auto_target: Node3D = null
var auto_orbit_angle: float = 0.0
var auto_orbit_distance: float = 8.0
var auto_orbit_height: float = 3.0
var auto_time_until_switch: float = 10.0
var auto_is_wandering: bool = false
var auto_wander_target: Vector3 = Vector3.ZERO

# Wander state
var wander_direction: Vector3 = Vector3.FORWARD
var wander_speed: float = 4.0
var wander_rotation_speed: float = 0.2
var wander_time_accumulator: float = 0.0
var wander_duration: float = 10.0
var wander_yaw: float = 0.0
var wander_pitch: float = 0.0

func _ready() -> void:
	super._ready()
	name = "FreeCamera"
	# Initialize orientation/targets
	yaw = rotation.y
	pitch = rotation.x
	desired_position = global_position

func _physics_process(delta: float) -> void:
	# Handle mouse capture state changes
	if current and not _was_current:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif not current and _was_current:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_was_current = current
	
	if not enabled:
		return
	update_camera(delta)

func update_camera(delta: float) -> void:
	if current_mode == Mode.AUTO:
		update_auto_camera(delta)
		return
	
	# Movement
	var speed = fast_move_speed if Input.is_action_pressed("run") else move_speed
	var input_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	
	# Build an orientation basis from desired yaw/pitch
	var orient_basis: Basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))
	
	var velocity = Vector3.ZERO
	velocity += orient_basis.z * input_dir.y
	velocity += orient_basis.x * input_dir.x
	
	# Vertical movement (world-space up/down)
	if Input.is_action_pressed("fly_up"):
		velocity += Vector3.UP
	if Input.is_action_pressed("fly_down"):
		velocity += Vector3.DOWN
	
	if velocity.length() > 0:
		velocity = velocity.normalized() * speed
		if current_mode == Mode.CINEMATIC:
			desired_position += velocity * delta
		else:
			global_position += velocity * delta
	
	# Joystick Look (right stick)
	var look_dir = Input.get_vector("camera_rotate_left", "camera_rotate_right", "camera_rotate_up", "camera_rotate_down")
	if look_dir.length() > 0:
		yaw -= look_dir.x * JOY_SENSITIVITY * delta
		pitch -= look_dir.y * JOY_SENSITIVITY * delta
		pitch = clamp(pitch, -PI/2, PI/2)
	
	# Apply rotation based on mode
	if current_mode == Mode.NORMAL:
		# Apply rotation immediately in physics process
		rotation.y = yaw
		rotation.x = pitch
	elif current_mode == Mode.CINEMATIC:
		# Apply cinematic smoothing (position and rotation)
		var pos_alpha := 1.0 - pow(1.0 - pos_smooth, delta * 60.0)
		global_position = global_position.lerp(desired_position, pos_alpha)
		
		var current_q: Quaternion = global_transform.basis.get_rotation_quaternion()
		var target_q: Quaternion = Basis.from_euler(Vector3(pitch, yaw, 0.0)).get_rotation_quaternion()
		var rot_alpha := 1.0 - pow(1.0 - rot_smooth, delta * 60.0)
		var new_q: Quaternion = current_q.slerp(target_q, rot_alpha)
		global_transform.basis = Basis(new_q)

func update_auto_camera(delta: float) -> void:
	if auto_is_wandering:
		_update_wander_mode(delta)
	else:
		_update_tracking_mode(delta)

# Enhanced wander mode with raycast-based navigation
func _update_wander_mode(delta: float) -> void:
	wander_time_accumulator += delta
	
	# Check if wander duration expired
	if wander_time_accumulator >= wander_duration:
		# Look for nearby subjects to track
		var nearby_subject = _find_nearby_subject()
		if nearby_subject:
			_transition_to_tracking(nearby_subject)
			return
		else:
			# Continue wandering with new parameters
			_initialize_wander()
	
	# Oscillating speed for more organic movement
	var speed_oscillation = sin(wander_time_accumulator * WANDER_SPEED_OSCILLATION * TAU)
	var current_speed = lerp(WANDER_SPEED_MIN, WANDER_SPEED_MAX, (speed_oscillation + 1.0) / 2.0)
	
	# Cast rays to detect obstacles and walls
	var forward_hit = _cast_wander_ray(wander_direction, WANDER_RAYCAST_DISTANCE)
	var left_hit = _cast_wander_ray(wander_direction.rotated(Vector3.UP, PI / 4), WANDER_SIDE_RAYCAST_DISTANCE)
	var right_hit = _cast_wander_ray(wander_direction.rotated(Vector3.UP, -PI / 4), WANDER_SIDE_RAYCAST_DISTANCE)
	
	# Determine turn direction based on obstacles
	var should_turn = false
	var turn_direction = 0.0
	
	if forward_hit and forward_hit.distance < WANDER_TURN_THRESHOLD:
		should_turn = true
		# Turn away from obstacle - prefer more open side
		if left_hit and right_hit:
			turn_direction = 1.0 if left_hit.distance > right_hit.distance else -1.0
		elif left_hit:
			turn_direction = -1.0
		elif right_hit:
			turn_direction = 1.0
		else:
			turn_direction = randf_range(-1.0, 1.0)
	else:
		# Gentle random turning when no obstacles
		if randf() < 0.02:  # 2% chance per frame to initiate turn
			turn_direction = randf_range(-0.3, 0.3)
	
	# Apply rotation
	if should_turn:
		wander_yaw += turn_direction * wander_rotation_speed * 3.0 * delta
	else:
		wander_yaw += turn_direction * wander_rotation_speed * delta
	
	# Evolving pitch for more dynamic camera angles
	wander_pitch = sin(wander_time_accumulator * 0.3) * 0.15 - 0.1  # Slight downward tilt
	
	# Update direction from yaw
	wander_direction = Vector3(
		sin(wander_yaw),
		0,
		cos(wander_yaw)
	).normalized()
	
	# Move camera
	desired_position = global_position + wander_direction * current_speed * delta
	
	# Check for subjects while wandering
	var spotted_subject = _find_nearby_subject()
	if spotted_subject and randf() < 0.05:  # 5% chance per frame to notice subject
		_transition_to_tracking(spotted_subject)
		return
	
	# Apply movement and rotation
	var pos_alpha := 1.0 - pow(1.0 - AUTO_MOVE_SMOOTH, delta * 60.0)
	global_position = global_position.lerp(desired_position, pos_alpha)
	
	# Smooth rotation based on wander direction
	var current_q: Quaternion = global_transform.basis.get_rotation_quaternion()
	var target_q: Quaternion = Basis.from_euler(Vector3(wander_pitch, wander_yaw, 0.0)).get_rotation_quaternion()
	var rot_alpha := 1.0 - pow(1.0 - AUTO_LOOK_SMOOTH, delta * 60.0)
	var new_q: Quaternion = current_q.slerp(target_q, rot_alpha)
	global_transform.basis = Basis(new_q)

# Original tracking/orbit mode
func _update_tracking_mode(delta: float) -> void:
	# Count down to next target switch
	auto_time_until_switch -= delta
	if auto_time_until_switch <= 0:
		_pick_new_auto_target()
	
	# Slowly orbit
	auto_orbit_angle += AUTO_ORBIT_SPEED * delta
	
	# Calculate desired position
	var target_pos: Vector3
	if is_instance_valid(auto_target):
		target_pos = auto_target.global_position
		if auto_target.has_node("Sprite3D"):
			target_pos = auto_target.get_node("Sprite3D").global_position
	else:
		# Target gone, pick new one
		_pick_new_auto_target()
		return
	
	# Orbit position around target
	var offset = Vector3(
		cos(auto_orbit_angle) * auto_orbit_distance,
		auto_orbit_height,
		sin(auto_orbit_angle) * auto_orbit_distance
	)
	desired_position = target_pos + offset
	
	# Raycast to avoid obstacles
	desired_position = _adjust_for_obstacles(target_pos, desired_position)
	
	# Smoothly move to desired position
	var pos_alpha := 1.0 - pow(1.0 - AUTO_MOVE_SMOOTH, delta * 60.0)
	global_position = global_position.lerp(desired_position, pos_alpha)
	
	# Look at target
	var look_target = auto_target.global_position
	if auto_target.has_node("Sprite3D"):
		look_target = auto_target.get_node("Sprite3D").global_position
	
	var direction = (look_target - global_position).normalized()
	if direction.length() > 0.01:
		var target_yaw = atan2(-direction.x, -direction.z)
		var target_pitch = asin(direction.y)
		
		var current_q: Quaternion = global_transform.basis.get_rotation_quaternion()
		var target_q: Quaternion = Basis.from_euler(Vector3(target_pitch, target_yaw, 0.0)).get_rotation_quaternion()
		var rot_alpha := 1.0 - pow(1.0 - AUTO_LOOK_SMOOTH, delta * 60.0)
		var new_q: Quaternion = current_q.slerp(target_q, rot_alpha)
		global_transform.basis = Basis(new_q)

func _pick_new_auto_target() -> void:
	auto_time_until_switch = randf_range(AUTO_TARGET_SWITCH_MIN, AUTO_TARGET_SWITCH_MAX)
	auto_orbit_distance = randf_range(AUTO_DISTANCE_MIN, AUTO_DISTANCE_MAX)
	auto_orbit_height = randf_range(AUTO_HEIGHT_MIN, AUTO_HEIGHT_MAX)
	
	# Chance to just wander
	if randf() < AUTO_WANDER_CHANCE:
		_initialize_wander()
		return
	
	auto_is_wandering = false
	
	# Gather potential targets
	var candidates: Array[Node3D] = []
	
	# Add entities
	var entities = get_tree().get_nodes_in_group("entity")
	for e in entities:
		if e is Node3D:
			candidates.append(e)
	
	# Add player
	if GameManager.player:
		candidates.append(GameManager.player)
	
	# Add markers/POIs
	var markers = get_tree().get_nodes_in_group("marker")
	for m in markers:
		if m is Node3D:
			candidates.append(m)
	
	# Pick a random one (prefer different from current)
	if candidates.size() > 0:
		candidates.shuffle()
		for c in candidates:
			if c != auto_target:
				auto_target = c
				return
		# Fallback to first if all same
		auto_target = candidates[0]

func _initialize_wander() -> void:
	auto_is_wandering = true
	wander_time_accumulator = 0.0
	wander_duration = randf_range(WANDER_MIN_DURATION, WANDER_MAX_DURATION)
	wander_speed = randf_range(WANDER_SPEED_MIN, WANDER_SPEED_MAX)
	wander_rotation_speed = randf_range(WANDER_ROTATION_SPEED_MIN, WANDER_ROTATION_SPEED_MAX)
	
	# Initialize direction from current camera orientation
	wander_yaw = rotation.y
	wander_pitch = rotation.x
	wander_direction = -global_transform.basis.z
	wander_direction.y = 0
	wander_direction = wander_direction.normalized()

func _cast_wander_ray(direction: Vector3, distance: float) -> Dictionary:
	var space_state = get_world_3d().direct_space_state
	if not space_state:
		return {}
	
	var start = global_position
	var end = start + direction * distance
	
	var query = PhysicsRayQueryParameters3D.create(start, end)
	query.collision_mask = 1  # Adjust for your collision layers
	
	var result = space_state.intersect_ray(query)
	if result:
		var hit_distance = start.distance_to(result.position)
		return {"hit": true, "distance": hit_distance, "position": result.position, "normal": result.normal}
	
	return {"hit": false, "distance": distance}

func _find_nearby_subject() -> Node3D:
	var candidates: Array[Node3D] = []
	
	# Add entities
	var entities = get_tree().get_nodes_in_group("entity")
	for e in entities:
		if e is Node3D:
			var dist = global_position.distance_to(e.global_position)
			if dist < WANDER_SUBJECT_DETECT_RANGE:
				candidates.append(e)
	
	# Add player
	if GameManager.player:
		var dist = global_position.distance_to(GameManager.player.global_position)
		if dist < WANDER_SUBJECT_DETECT_RANGE:
			candidates.append(GameManager.player)
	
	# Return closest candidate
	if candidates.size() > 0:
		candidates.sort_custom(func(a, b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
		return candidates[0]
	
	return null

func _transition_to_tracking(target: Node3D) -> void:
	auto_is_wandering = false
	auto_target = target
	auto_time_until_switch = randf_range(AUTO_TARGET_SWITCH_MIN, AUTO_TARGET_SWITCH_MAX)
	auto_orbit_distance = randf_range(AUTO_DISTANCE_MIN, AUTO_DISTANCE_MAX)
	auto_orbit_height = randf_range(AUTO_HEIGHT_MIN, AUTO_HEIGHT_MAX)
	auto_orbit_angle = atan2(global_position.x - target.global_position.x, global_position.z - target.global_position.z)

func _adjust_for_obstacles(from: Vector3, to: Vector3) -> Vector3:
	var space_state = get_world_3d().direct_space_state
	if not space_state:
		return to
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = []
	query.collision_mask = 1  # Adjust if your walls are on different layers
	
	var result = space_state.intersect_ray(query)
	if result:
		# Hit something, pull back toward the from point
		var hit_point: Vector3 = result.position
		var pull_back = (from - to).normalized() * 1.0  # 1 unit buffer
		return hit_point + pull_back
	
	return to

func get_mode_name() -> String:
	match current_mode:
		Mode.NORMAL: return "Normal"
		Mode.CINEMATIC: return "Cinematic"
		Mode.AUTO: return "Auto-Cam"
	return "Unknown"

func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return
	
	# F5: exit freecam (return to previous camera)
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F5:
		if CameraManager:
			CameraManager.toggle_free_camera()
		get_viewport().set_input_as_handled()
		return
	
	if event.is_action_pressed("toggle_mode"):
		print("[FreeCamera] toggle_mode pressed - switching modes")
		# Cycle through modes: NORMAL -> CINEMATIC -> AUTO -> NORMAL
		current_mode = (current_mode + 1) % 3 as Mode
		print("[FreeCamera] New mode: ", get_mode_name())
		# Align targets to current state to avoid snapping when toggling
		desired_position = global_position
		yaw = rotation.y
		pitch = rotation.x
		if current_mode == Mode.AUTO:
			_pick_new_auto_target()
		get_viewport().set_input_as_handled()
		return

func _input(event: InputEvent) -> void:
	if not current:
		return
		
	if event is InputEventMouseMotion:
		if current_mode == Mode.AUTO:
			return  # Ignore mouse in auto mode
		# Only update yaw/pitch here, actual rotation applied in physics_process
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch -= event.relative.y * MOUSE_SENSITIVITY
		pitch = clamp(pitch, -PI/2, PI/2)
		get_viewport().set_input_as_handled()
	
	if event is InputEventMouseButton:
		if current_mode == Mode.AUTO:
			return  # Ignore scroll in auto mode
		var scroll_dir = 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			scroll_dir = 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			scroll_dir = -1
		
		if scroll_dir != 0:
			if Input.is_action_pressed("mod1"):
				if Input.is_key_pressed(KEY_ALT):
					# Alt+Ctrl+Scroll: Adjust smoothing
					var smooth_step = 0.01
					pos_smooth = clamp(pos_smooth + scroll_dir * smooth_step, 0.01, 0.5)
					rot_smooth = clamp(rot_smooth + scroll_dir * smooth_step, 0.01, 0.5)
					print("[FreeCamera] Smoothing: pos=", snappedf(pos_smooth, 0.01), " rot=", snappedf(rot_smooth, 0.01))
				else:
					# Ctrl+Scroll: Adjust FOV
					fov = clamp(fov - scroll_dir * FOV_STEP, FOV_MIN, FOV_MAX)
				get_viewport().set_input_as_handled()
			elif Input.is_key_pressed(KEY_ALT):
				# Alt+Scroll: Adjust smoothing
				var smooth_step = 0.01
				pos_smooth = clamp(pos_smooth + scroll_dir * smooth_step, 0.01, 0.5)
				rot_smooth = clamp(rot_smooth + scroll_dir * smooth_step, 0.01, 0.5)
				print("[FreeCamera] Smoothing: pos=", snappedf(pos_smooth, 0.01), " rot=", snappedf(rot_smooth, 0.01))
				get_viewport().set_input_as_handled()
			elif Input.is_key_pressed(KEY_Z):
				# Z+Scroll: Adjust zoom speed and movement speed
				var speed_step = 0.5
				zoom_speed = clamp(zoom_speed + scroll_dir * speed_step, 0.5, 10.0)
				move_speed = clamp(move_speed + scroll_dir * speed_step, 1.0, 50.0)
				fast_move_speed = move_speed * 2.0
				print("[FreeCamera] Speed: move=", snappedf(move_speed, 0.1), " zoom=", snappedf(zoom_speed, 0.1))
				get_viewport().set_input_as_handled()
			else:
				# Scroll: Dolly (accumulate zoom amount and move along view)
				zoom_amount += scroll_dir * zoom_speed
				if current_mode == Mode.CINEMATIC:
					var orient_basis: Basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))
					desired_position -= orient_basis.z * scroll_dir * zoom_speed
				else:
					global_position -= global_transform.basis.z * scroll_dir * zoom_speed
				get_viewport().set_input_as_handled()
			return
