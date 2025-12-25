extends BaseCamera
class_name ThirdPersonCamera

## Third-person over-shoulder camera with right stick rotation
## Orbits around the player with horizontal and vertical rotation control

# Camera parameters
var distance: float = 5.0
var height_offset: float = 1.5
var side_offset: float = 0.5
var camera_fov: float = 70.0

# Rotation state
var yaw: float = 0.0  # Horizontal rotation around player
var pitch: float = -20.0  # Vertical angle

# Rotation settings
var rotation_speed: float = 2.0
var min_pitch: float = -60.0
var max_pitch: float = 30.0
var look_at_height: float = 1.5  # Height offset for look target on player

func update_camera(delta: float) -> void:
	var target = get_zone_target()
	if not target:
		return
	
	var target_pos = get_target_position(target)
	
	# Get right stick input for camera rotation
	var rotate_h = Input.get_action_strength("camera_rotate_right") - Input.get_action_strength("camera_rotate_left")
	var rotate_v = Input.get_action_strength("camera_rotate_down") - Input.get_action_strength("camera_rotate_up")
	
	# Update rotation angles
	yaw += rotate_h * rotation_speed * delta * 60.0
	pitch = clamp(pitch + rotate_v * rotation_speed * delta * 60.0, min_pitch, max_pitch)
	
	# Calculate camera position in spherical coordinates
	var yaw_rad = deg_to_rad(yaw)
	var pitch_rad = deg_to_rad(pitch)
	
	# Calculate offset from target
	var horizontal_distance = distance * cos(pitch_rad)
	var vertical_distance = distance * sin(pitch_rad)
	
	# Apply rotation around target
	var offset = Vector3(
		horizontal_distance * sin(yaw_rad) + side_offset,
		-vertical_distance + height_offset,
		horizontal_distance * cos(yaw_rad)
	)
	
	# Set camera position
	global_position = target_pos + offset
	
	# Look at target with height offset
	var look_target = target_pos + Vector3.UP * look_at_height
	look_at(look_target, Vector3.UP)
	
	# Apply FOV
	fov = camera_fov
