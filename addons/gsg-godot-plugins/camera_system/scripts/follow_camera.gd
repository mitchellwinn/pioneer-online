extends BaseCamera
class_name FollowCamera

## Follow camera with vantage angle, deadzone support, and look constraints
## This is the default camera type used by MultimediaZones

@export var look_only: bool = false ## If true, camera stays at fixed position but rotates to look at target

# Camera parameters (set by MultimediaZone when auto-generated)
var distance: float = 10.0
var vantage_angle: float = -35.0
var height_offset: float = 0.0
var side_offset: float = 0.0
var camera_fov: float = 70.0
var constrain_look_angles: bool = false
var max_yaw_angle: float = 90.0
var max_pitch_angle: float = 45.0
var min_pitch_angle: float = -45.0
var look_forward_reference: Vector3 = Vector3(0, 0, -1)
var use_deadzone: bool = false
var deadzone_width: float = 2.0
var deadzone_height: float = 1.5
var deadzone_depth: float = 3.0
var deadzone_gradient: float = 1.0  # Transition zone radius
var rotation_smooth_speed: float = 5.0
var deadzone_snap_threshold: float = 15.0  # Distance at which camera snaps instantly instead of smoothing

func update_camera(delta: float) -> void:
	# Prebuilt cameras never change position from their initial transform
	if is_prebuilt:
		if look_only:
			# If we have a target, only rotate to look at it
			var t = get_zone_target()
			if t:
				var tp = get_target_position(t)
				global_position = initial_position
				look_at(tp, Vector3.UP)
			return
		# Not look_only: remain completely fixed and do nothing
		return
	
	# Auto-generated camera behavior below
	var target = get_zone_target()
	if not target:
		return
	
	# Get target position
	var target_pos = get_target_position(target)
	
	# Handle look_only mode: stay in place but rotate to look at target
	if look_only:
		# Keep camera at fixed position (don't move it)
		global_position = initial_position
		# Look at target
		look_at(target_pos + Vector3.UP * 1.5, Vector3.UP)
		# Don't do anything else - just look at target
		return
	
	# If distance is 0, this is a stationary camera - don't move it
	if distance == 0.0:
		return
	
	# Default: follow camera with vantage angle
	# Calculate camera position using spherical coordinates
	var angle_rad = deg_to_rad(vantage_angle)
	
	# Convert to spherical coordinates (distance, vertical angle)
	# Negative angle = looking down from above
	var horizontal_dist = distance * cos(angle_rad) # Distance on XZ plane behind target
	var vertical_dist = distance * sin(angle_rad) # Height (negative angle = positive height)
	
	# Position camera behind target (on Z axis) with side offset and height offset
	var offset = Vector3(side_offset, -vertical_dist + height_offset, horizontal_dist)
	
	# Calculate desired position
	var desired_pos = target_pos + offset
	
	# Apply deadzone if enabled
	if use_deadzone:
		# Calculate where camera should be vs where it is on XZ plane
		var cam_pos_flat = Vector3(global_position.x, 0, global_position.z)
		var desired_pos_flat = Vector3(desired_pos.x, 0, desired_pos.z)
		var offset_from_ideal = cam_pos_flat - desired_pos_flat
		var offset_distance = offset_from_ideal.length()
		
		# Check if we're too far away - snap instantly if so (e.g., after a warp)
		if offset_distance > deadzone_snap_threshold:
			# Snap directly to target position
			global_position = desired_pos
		# Only move camera horizontally if we're outside deadzone from ideal position
		elif offset_distance > deadzone_width / 2.0:
			# Move toward ideal position
			var excess_distance = offset_distance - (deadzone_width / 2.0)
			var move_dir = -offset_from_ideal.normalized()  # Negative because offset points away
			var move_speed = 5.0
			
			# Move camera horizontally
			var horizontal_movement = move_dir * excess_distance * move_speed * delta
			global_position.x += horizontal_movement.x
			global_position.z += horizontal_movement.z
		
		# Always match Y position (height) directly
		global_position.y = desired_pos.y
	else:
		# No deadzone, move directly to desired position
		global_position = desired_pos
	
	# Look at target position (their feet/origin)
	if use_deadzone:
		# Check if target is outside the deadzone (using same offset_distance from movement logic)
		var cam_pos_flat = Vector3(global_position.x, 0, global_position.z)
		var desired_pos_flat = Vector3(desired_pos.x, 0, desired_pos.z)
		var offset_from_ideal = cam_pos_flat - desired_pos_flat
		var offset_distance = offset_from_ideal.length()
		
		var current_forward = -global_transform.basis.z
		
		# Calculate gradient blend factor (0 = center, 1 = edge/outside)
		var deadzone_radius = deadzone_width / 2.0
		var gradient_start = deadzone_radius - deadzone_gradient
		var blend_factor = 0.0
		
		if offset_distance < gradient_start:
			# Fully in center deadzone
			blend_factor = 0.0
		elif offset_distance > deadzone_radius:
			# Fully outside deadzone
			blend_factor = 1.0
		else:
			# In gradient transition zone
			blend_factor = (offset_distance - gradient_start) / deadzone_gradient
		
		# Calculate look directions on horizontal plane only
		var cam_flat = Vector3(global_position.x, 0, global_position.z)
		var target_flat = Vector3(target_pos.x, 0, target_pos.z)
		
		# Forward direction (negative Z in world space)
		var forward_flat = Vector3(0, 0, -1)
		
		# Direction to player (horizontal only)
		var to_player_flat = (target_flat - cam_flat).normalized()
		
		# Blend between forward and player direction
		var blended_flat_dir = forward_flat.lerp(to_player_flat, blend_factor).normalized()
		
		# Calculate pitch angle to look at player's feet from camera position
		var horizontal_distance = cam_flat.distance_to(target_flat)
		var vertical_offset = target_pos.y - global_position.y
		var pitch_angle = atan2(vertical_offset, horizontal_distance)
		
		# Apply pitch to the blended horizontal direction
		var desired_look_dir = blended_flat_dir.rotated(Vector3.RIGHT, pitch_angle)
		
		# Smooth rotation
		var rotation_speed = rotation_smooth_speed if blend_factor > 0.5 else rotation_smooth_speed * 0.5
		var new_forward = current_forward.slerp(desired_look_dir, rotation_speed * delta)
		var target_point = global_position + new_forward * 10.0
		look_at(target_point, Vector3.UP)
	else:
		constrained_look_at(target_pos, Vector3.UP)
	
	# Apply FOV
	fov = camera_fov

## Look at target with optional angle constraints
## Use this instead of look_at() to respect 180-degree rule
func constrained_look_at(target_pos: Vector3, up: Vector3 = Vector3.UP) -> void:
	if not constrain_look_angles:
		# No constraints, just look at target
		look_at(target_pos, up)
		return
	
	# Calculate desired look direction
	var desired_dir = (target_pos - global_position).normalized()
	
	# Get reference forward in world space
	var reference_forward = global_transform.basis * look_forward_reference
	reference_forward.y = 0
	reference_forward = reference_forward.normalized()
	
	# Calculate yaw (horizontal angle from reference forward)
	var desired_dir_flat = Vector3(desired_dir.x, 0, desired_dir.z).normalized()
	var yaw_angle = rad_to_deg(reference_forward.signed_angle_to(desired_dir_flat, Vector3.UP))
	
	# Clamp yaw to max angle (180-degree rule)
	yaw_angle = clamp(yaw_angle, -max_yaw_angle, max_yaw_angle)
	
	# Calculate constrained horizontal direction
	var constrained_yaw_rad = deg_to_rad(yaw_angle)
	var constrained_forward = reference_forward.rotated(Vector3.UP, constrained_yaw_rad)
	
	# Calculate pitch (vertical angle)
	var distance_horizontal = Vector2(desired_dir.x, desired_dir.z).length()
	var pitch_angle = rad_to_deg(atan2(-desired_dir.y, distance_horizontal))
	
	# Clamp pitch
	pitch_angle = clamp(pitch_angle, min_pitch_angle, max_pitch_angle)
	
	# Calculate final constrained direction
	var pitch_rad = deg_to_rad(pitch_angle)
	var constrained_dir = constrained_forward.rotated(constrained_forward.cross(Vector3.UP), -pitch_rad)
	
	# Look in the constrained direction
	var final_target = global_position + constrained_dir * 10.0
	look_at(final_target, up)
