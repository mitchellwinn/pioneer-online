extends Node3D
class_name ProceduralIKController

## Procedural IK Controller - Handles foot placement, head look-at, and hand IK
## Attach to the player and configure bone names to match your skeleton

#region Configuration
@export_group("Skeleton")
@export var skeleton_path: NodePath  # Path to Skeleton3D (auto-detected if empty)

@export_group("Bone Names")
## These should match your model's bone names (printed by PlayerAnimationController)
@export var head_bone: String = "head.x"
@export var neck_bone: String = "neck.x"
@export var spine_upper_bone: String = "spine_03.x"  # Upper spine (near shoulders)
@export var spine_mid_bone: String = "spine_02.x"    # Middle spine
@export var spine_lower_bone: String = "spine_01.x"  # Lower spine (near hips)
@export var left_foot_bone: String = "foot.l"
@export var right_foot_bone: String = "foot.r"
@export var left_hand_bone: String = "hand.l"
@export var right_hand_bone: String = "hand.r"
@export var left_leg_bone: String = "leg_stretch.l"
@export var right_leg_bone: String = "leg_stretch.r"
@export var left_thigh_bone: String = "thigh_stretch.l"
@export var right_thigh_bone: String = "thigh_stretch.r"

@export_group("Foot IK")
@export var enable_foot_ik: bool = true
@export var foot_ray_length: float = 1.5  # How far down to cast rays
@export var foot_offset: float = 0.05  # Height offset from ground
@export var foot_ik_speed: float = 15.0  # How fast feet adapt
@export var max_foot_adjustment: float = 0.3  # Max height adjustment
@export var ground_layer_mask: int = 1  # Physics layer for ground

@export_group("Footstep Sounds")
@export var enable_footstep_sounds: bool = true
@export var footstep_sound_path: String = "res://sounds/step.wav"  # Base path for step sounds
@export var footstep_height_threshold: float = 0.02  # Min height change to detect step
@export var footstep_volume_db: float = -8.0  # Volume for footstep sounds

@export_group("Look At IK")
@export var enable_look_at: bool = true
@export var look_at_speed: float = 8.0  # How fast head turns
@export var max_head_yaw: float = 70.0  # Max horizontal head turn (degrees)
@export var max_head_pitch: float = 40.0  # Max vertical head turn (degrees)
@export var look_at_blend: float = 1.0  # 0-1 blend with animation

@export_group("Camera Head Tracking")
@export var enable_camera_head_tracking: bool = true
@export var head_track_speed: float = 5.0  # How fast head follows camera (lower = smoother)
@export var max_head_turn_before_body: float = 45.0  # Head turns this much before body starts
@export var body_rotation_speed: float = 5.0  # How fast body catches up
@export var body_deadzone: float = 15.0  # Body won't rotate within this angle
@export var head_smoothing: float = 0.15  # Extra smoothing (0 = none, higher = smoother)
@export var neck_yaw_ratio: float = 0.5  # How much neck twists (0-1)
@export var spine_yaw_ratio: float = 0.4  # How much spine twists before body (0-1)

@export_group("Vertical Look (Pitch)")
@export var enable_vertical_look: bool = true
@export var max_head_pitch_up: float = 35.0  # Max degrees head looks up
@export var max_head_pitch_down: float = 45.0  # Max degrees head looks down
@export var spine_pitch_ratio: float = 0.3  # How much spine contributes (0-1)
@export var lean_back_amount: float = 0.15  # How much to lean back when looking up
@export var bend_forward_amount: float = 0.2  # How much to bend forward when looking down

@export_group("Hand IK")
@export var enable_hand_ik: bool = false
@export var hand_ik_speed: float = 10.0

@export_group("Strafe IK")
@export var enable_strafe_ik: bool = false
## How much the spine counter-rotates to keep upper body facing forward while model rotates
@export var spine_counter_twist: float = 20.0
@export var strafe_ik_speed: float = 8.0
#endregion

#region Runtime
var skeleton: Skeleton3D
var parent_entity: Node3D

# Bone indices (cached for performance)
var head_bone_idx: int = -1
var neck_bone_idx: int = -1
var spine_upper_idx: int = -1
var spine_mid_idx: int = -1
var spine_lower_idx: int = -1
var left_foot_bone_idx: int = -1
var right_foot_bone_idx: int = -1
var left_hand_bone_idx: int = -1
var right_hand_bone_idx: int = -1
var left_leg_bone_idx: int = -1
var right_leg_bone_idx: int = -1
var left_thigh_bone_idx: int = -1
var right_thigh_bone_idx: int = -1

# Strafe IK state
var current_strafe_amount: float = 0.0  # -1 = full left, 0 = forward, 1 = full right
var current_spine_counter: float = 0.0  # Counter-rotation to keep upper body facing forward

# Foot IK state
var left_foot_target_offset: float = 0.0
var right_foot_target_offset: float = 0.0
var left_foot_current_offset: float = 0.0
var right_foot_current_offset: float = 0.0
var hip_offset: float = 0.0

# Footstep sound state
var left_foot_prev_height: float = 0.0
var right_foot_prev_height: float = 0.0
var left_foot_was_descending: bool = false
var right_foot_was_descending: bool = false
var footstep_cooldown: float = 0.0  # Prevent rapid footstep sounds
const FOOTSTEP_COOLDOWN_TIME: float = 0.15  # Min time between steps

# Look-at state
var look_at_target: Vector3 = Vector3.ZERO
var has_look_target: bool = false
var current_head_rotation: Vector3 = Vector3.ZERO

# Camera head tracking state
var camera_yaw_offset: float = 0.0  # How much head is turned from body
var camera_pitch_offset: float = 0.0  # How much head is pitched up/down
var target_body_yaw: float = 0.0  # Where body should face
var player_camera: Node = null
var _smooth_yaw: float = 0.0  # For extra smoothing
var _smooth_pitch: float = 0.0  # For extra smoothing

# Hand IK state
var left_hand_target: Vector3 = Vector3.ZERO
var right_hand_target: Vector3 = Vector3.ZERO
var left_hand_active: bool = false
var right_hand_active: bool = false

# Original bone poses (to blend with)
var original_poses: Dictionary = {}
#endregion

func _ready():
	parent_entity = get_parent()
	
	# Find skeleton
	if skeleton_path:
		skeleton = get_node_or_null(skeleton_path)
	
	if not skeleton:
		skeleton = _find_skeleton(parent_entity)
	
	if not skeleton:
		push_warning("[ProceduralIK] No Skeleton3D found!")
		return
	
	print("[ProceduralIK] Found skeleton: ", skeleton.name)
	
	# Cache bone indices
	_cache_bone_indices()
	
	# Store original poses
	_store_original_poses()
	
	# Find player camera for head tracking
	player_camera = parent_entity.get_node_or_null("PlayerCamera")
	if player_camera:
		print("[ProceduralIK] Found PlayerCamera for head tracking")
	
	# Connect to skeleton_updated signal - fires AFTER animation updates bones
	# This is the proper time to apply IK modifications
	if not skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		skeleton.skeleton_updated.connect(_on_skeleton_updated)
		print("[ProceduralIK] Connected to skeleton_updated signal")

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

func _cache_bone_indices():
	if not skeleton:
		return
	
	head_bone_idx = skeleton.find_bone(head_bone)
	neck_bone_idx = skeleton.find_bone(neck_bone)
	spine_upper_idx = skeleton.find_bone(spine_upper_bone)
	spine_mid_idx = skeleton.find_bone(spine_mid_bone)
	spine_lower_idx = skeleton.find_bone(spine_lower_bone)
	left_foot_bone_idx = skeleton.find_bone(left_foot_bone)
	right_foot_bone_idx = skeleton.find_bone(right_foot_bone)
	left_hand_bone_idx = skeleton.find_bone(left_hand_bone)
	right_hand_bone_idx = skeleton.find_bone(right_hand_bone)
	left_leg_bone_idx = skeleton.find_bone(left_leg_bone)
	right_leg_bone_idx = skeleton.find_bone(right_leg_bone)
	left_thigh_bone_idx = skeleton.find_bone(left_thigh_bone)
	right_thigh_bone_idx = skeleton.find_bone(right_thigh_bone)
	
	print("[ProceduralIK] Bone indices:")
	print("  Head: %d (%s), Neck: %d (%s)" % [head_bone_idx, head_bone, neck_bone_idx, neck_bone])
	print("  Spine - Upper: %d (%s), Mid: %d (%s), Lower: %d (%s)" % [spine_upper_idx, spine_upper_bone, spine_mid_idx, spine_mid_bone, spine_lower_idx, spine_lower_bone])
	print("  LeftFoot: %d (%s), RightFoot: %d (%s)" % [left_foot_bone_idx, left_foot_bone, right_foot_bone_idx, right_foot_bone])
	print("  LeftLeg: %d, RightLeg: %d, LeftThigh: %d, RightThigh: %d" % [left_leg_bone_idx, right_leg_bone_idx, left_thigh_bone_idx, right_thigh_bone_idx])
	print("  LeftHand: %d (%s), RightHand: %d (%s)" % [left_hand_bone_idx, left_hand_bone, right_hand_bone_idx, right_hand_bone])

func _store_original_poses():
	if not skeleton:
		return
	
	for i in skeleton.get_bone_count():
		original_poses[i] = skeleton.get_bone_pose(i)

func _process(delta: float):
	if not skeleton:
		return
	
	# Store delta for skeleton_updated callback
	_last_delta = delta
	
	# Update strafe target values (actual bone changes happen in _on_skeleton_updated)
	if enable_strafe_ik:
		_update_strafe_values(delta)
	
	# Update camera head tracking values
	var is_local_player = player_camera != null
	var is_remote_player = parent_entity and "synced_camera_yaw" in parent_entity
	if enable_camera_head_tracking and (is_local_player or is_remote_player):
		_update_camera_head_tracking(delta)

var _last_delta: float = 0.0

func _on_skeleton_updated():
	## Called AFTER animation has updated bone poses - perfect time for IK
	if not skeleton:
		return

	var delta = _last_delta
	if delta <= 0:
		delta = get_process_delta_time()

	# Check if airborne - disable foot IK completely during jump/fall
	var is_airborne = _check_if_airborne()

	if enable_foot_ik and not is_airborne:
		_process_foot_ik(delta)
	elif is_airborne:
		# Reset foot offsets when airborne so they don't pop when landing
		left_foot_current_offset = lerp(left_foot_current_offset, 0.0, 10.0 * delta)
		right_foot_current_offset = lerp(right_foot_current_offset, 0.0, 10.0 * delta)
		hip_offset = lerp(hip_offset, 0.0, 10.0 * delta)

	# Apply strafe IK (spine counter-rotation)
	if enable_strafe_ik:
		_apply_strafe_ik()

	# Apply camera head tracking (head/neck/spine look)
	if enable_camera_head_tracking:
		_apply_camera_head_tracking()

	# Apply look-at IK if we have a target
	if enable_look_at and has_look_target:
		_process_look_at_ik(delta)

func _check_if_airborne() -> bool:
	## Check if parent entity is in the air (jumping/falling)
	if not parent_entity:
		return false
	
	# Check state manager first
	if parent_entity.has_node("StateManager"):
		var state_mgr = parent_entity.get_node("StateManager")
		if state_mgr.has_method("get_current_state_name"):
			var state_name = state_mgr.get_current_state_name()
			if state_name in ["jumping", "airborne"]:
				return true
	
	# Fallback: check CharacterBody3D floor status
	if parent_entity is CharacterBody3D:
		return not (parent_entity as CharacterBody3D).is_on_floor()
	
	return false

#region Foot IK
func _process_foot_ik(delta: float):
	if not parent_entity or left_foot_bone_idx < 0 or right_foot_bone_idx < 0:
		return
	
	var space_state = get_world_3d().direct_space_state
	
	# Get foot positions in world space
	var left_foot_pos = skeleton.global_transform * skeleton.get_bone_global_pose(left_foot_bone_idx).origin
	var right_foot_pos = skeleton.global_transform * skeleton.get_bone_global_pose(right_foot_bone_idx).origin
	
	# Footstep sound detection (before IK modifies positions)
	if enable_footstep_sounds:
		_process_footstep_sounds(delta, left_foot_pos, right_foot_pos)

	# Cast rays down from each foot
	left_foot_target_offset = _cast_foot_ray(space_state, left_foot_pos)
	right_foot_target_offset = _cast_foot_ray(space_state, right_foot_pos)
	
	# Smooth interpolation
	left_foot_current_offset = lerp(left_foot_current_offset, left_foot_target_offset, foot_ik_speed * delta)
	right_foot_current_offset = lerp(right_foot_current_offset, right_foot_target_offset, foot_ik_speed * delta)
	
	# Calculate hip offset (lower hip to match lowest foot)
	var target_hip_offset = min(left_foot_current_offset, right_foot_current_offset)
	hip_offset = lerp(hip_offset, target_hip_offset, foot_ik_speed * delta)
	
	# Apply foot offsets via bone pose override
	_apply_foot_offset(left_foot_bone_idx, left_foot_current_offset - hip_offset)
	_apply_foot_offset(right_foot_bone_idx, right_foot_current_offset - hip_offset)

func _process_footstep_sounds(delta: float, left_pos: Vector3, right_pos: Vector3):
	## Detect footstep landing and play sounds
	
	# Update cooldown
	if footstep_cooldown > 0:
		footstep_cooldown -= delta
	
	# Check if character is actually moving
	var is_moving = false
	if parent_entity:
		if "input_direction" in parent_entity:
			var input_dir = parent_entity.input_direction
			is_moving = Vector3(input_dir.x, 0, input_dir.z).length() > 0.1
		elif parent_entity is CharacterBody3D:
			var vel = parent_entity.velocity
			is_moving = Vector3(vel.x, 0, vel.z).length() > 0.5
	
	if not is_moving:
		# Reset state when not moving
		left_foot_prev_height = left_pos.y
		right_foot_prev_height = right_pos.y
		left_foot_was_descending = false
		right_foot_was_descending = false
		return
	
	# Detect left foot landing (was descending, now ascending or at bottom)
	var left_height = left_pos.y
	var left_descending = left_height < left_foot_prev_height - footstep_height_threshold
	var left_ascending = left_height > left_foot_prev_height + footstep_height_threshold
	
	if left_foot_was_descending and (left_ascending or not left_descending):
		# Left foot just landed!
		if footstep_cooldown <= 0:
			_play_footstep_sound(left_pos)
			footstep_cooldown = FOOTSTEP_COOLDOWN_TIME
	
	left_foot_was_descending = left_descending
	left_foot_prev_height = left_height
	
	# Detect right foot landing
	var right_height = right_pos.y
	var right_descending = right_height < right_foot_prev_height - footstep_height_threshold
	var right_ascending = right_height > right_foot_prev_height + footstep_height_threshold
	
	if right_foot_was_descending and (right_ascending or not right_descending):
		# Right foot just landed!
		if footstep_cooldown <= 0:
			_play_footstep_sound(right_pos)
			footstep_cooldown = FOOTSTEP_COOLDOWN_TIME
	
	right_foot_was_descending = right_descending
	right_foot_prev_height = right_height

func _play_footstep_sound(foot_pos: Vector3):
	## Play a footstep sound at the foot position
	var sound_manager = get_node_or_null("/root/SoundManager")
	if sound_manager and sound_manager.has_method("play_sound_3d_with_variation"):
		sound_manager.play_sound_3d_with_variation(
			footstep_sound_path,
			foot_pos,
			null,
			footstep_volume_db,
			0.15  # Slight pitch variation
		)

func _cast_foot_ray(space_state: PhysicsDirectSpaceState3D, foot_pos: Vector3) -> float:
	var ray_start = foot_pos + Vector3.UP * 0.5
	var ray_end = foot_pos - Vector3.UP * foot_ray_length

	var query = PhysicsRayQueryParameters3D.create(ray_start, ray_end, ground_layer_mask)
	query.exclude = [parent_entity.get_rid()] if parent_entity is CollisionObject3D else []

	var result = space_state.intersect_ray(query)

	if result:
		var ground_height = result.position.y
		var foot_height = foot_pos.y
		var offset = ground_height - foot_height + foot_offset
		return clampf(offset, -max_foot_adjustment, max_foot_adjustment)

	return 0.0


func _apply_foot_offset(bone_idx: int, offset: float):
	if bone_idx < 0:
		return
	
	var current_pose = skeleton.get_bone_pose(bone_idx)
	current_pose.origin.y += offset
	skeleton.set_bone_pose_position(bone_idx, current_pose.origin)
#endregion

#region Strafe IK
func _update_strafe_values(delta: float):
	## Update strafe target values (called in _process)
	## Actual bone modifications happen in _apply_strafe_ik after animation
	if not parent_entity:
		return
	
	# Get movement input direction (local to entity)
	var input_dir = Vector3.ZERO
	if parent_entity.has_method("get_movement_input"):
		input_dir = parent_entity.get_movement_input()
	
	# Convert to local space (relative to player facing)
	var local_input = parent_entity.global_transform.basis.inverse() * input_dir
	
	# Calculate strafe amount (-1 = left, 0 = forward/back, 1 = right)
	var target_strafe: float = 0.0
	if input_dir.length() > 0.1:
		target_strafe = clampf(local_input.x, -1.0, 1.0)
	
	# Smooth interpolation
	current_strafe_amount = lerp(current_strafe_amount, target_strafe, strafe_ik_speed * delta)
	
	# Only apply if moving
	var movement_blend = 1.0 if input_dir.length() > 0.1 else 0.0
	
	# Calculate target spine counter-rotation
	var target_spine_counter = current_strafe_amount * deg_to_rad(spine_counter_twist) * movement_blend
	current_spine_counter = lerp(current_spine_counter, target_spine_counter, strafe_ik_speed * delta)

func _apply_strafe_ik():
	## Apply spine counter-rotation AFTER animation (called from skeleton_updated)
	# Distribute across spine bones (lower does more work)
	if spine_lower_idx >= 0:
		var lower_rot = Quaternion.from_euler(Vector3(0, current_spine_counter * 0.5, 0))
		skeleton.set_bone_pose_rotation(spine_lower_idx, skeleton.get_bone_pose_rotation(spine_lower_idx) * lower_rot)
	
	if spine_mid_idx >= 0:
		var mid_rot = Quaternion.from_euler(Vector3(0, current_spine_counter * 0.3, 0))
		skeleton.set_bone_pose_rotation(spine_mid_idx, skeleton.get_bone_pose_rotation(spine_mid_idx) * mid_rot)
	
	if spine_upper_idx >= 0:
		var upper_rot = Quaternion.from_euler(Vector3(0, current_spine_counter * 0.2, 0))
		skeleton.set_bone_pose_rotation(spine_upper_idx, skeleton.get_bone_pose_rotation(spine_upper_idx) * upper_rot)
#endregion

#region Camera Head Tracking
# Cached values for applying after animation
var _head_tracking_spine_pitch_base: float = 0.0
var _head_tracking_spine_yaw_base: float = 0.0

func _update_camera_head_tracking(delta: float):
	## Calculate head tracking values (called in _process)
	## Actual bone modifications happen in _apply_camera_head_tracking
	if head_bone_idx < 0:
		return
	
	# === GET OFFSETS FROM PLAYER ===
	var yaw_offset: float = 0.0
	var camera_pitch: float = 0.0
	
	var is_local = player_camera != null
	
	if is_local:
		# Local player: use actual camera
		if parent_entity.has_method("get_camera_body_offset"):
			yaw_offset = parent_entity.get_camera_body_offset()
		if "pitch" in player_camera:
			camera_pitch = player_camera.pitch
	else:
		# Remote player: use synced values (yaw is already an offset)
		if "synced_camera_yaw" in parent_entity:
			yaw_offset = parent_entity.synced_camera_yaw
		if "synced_camera_pitch" in parent_entity:
			camera_pitch = parent_entity.synced_camera_pitch
	
	# === HORIZONTAL (YAW) - Head compensates for body lag ===
	# Clamp to max head turn
	var target_head_yaw = clampf(yaw_offset, deg_to_rad(-max_head_turn_before_body), deg_to_rad(max_head_turn_before_body))
	
	# Smooth interpolation with extra smoothing
	_smooth_yaw = lerp(_smooth_yaw, target_head_yaw, head_track_speed * delta)
	camera_yaw_offset = lerp(camera_yaw_offset, _smooth_yaw, (1.0 - head_smoothing))
	
	# === VERTICAL (PITCH) ===
	var target_head_pitch: float = 0.0
	var spine_pitch: float = 0.0
	
	if enable_vertical_look:
		# Invert pitch (camera pitch convention is opposite of what we want)
		var inverted_pitch = -camera_pitch
		
		# Clamp pitch to our limits
		if inverted_pitch < 0:
			# Looking down (negative after invert)
			target_head_pitch = clampf(inverted_pitch, deg_to_rad(-max_head_pitch_down), 0)
		else:
			# Looking up (positive after invert)
			target_head_pitch = clampf(inverted_pitch, 0, deg_to_rad(max_head_pitch_up))
		
		# Spine contribution
		spine_pitch = target_head_pitch * spine_pitch_ratio
	
	# Smooth pitch
	_smooth_pitch = lerp(_smooth_pitch, target_head_pitch, head_track_speed * delta)
	camera_pitch_offset = lerp(camera_pitch_offset, _smooth_pitch, (1.0 - head_smoothing))
	var smooth_spine_pitch = spine_pitch * (1.0 - head_smoothing)
	
	# Cache spine values for _apply_camera_head_tracking
	_head_tracking_spine_yaw_base = camera_yaw_offset * spine_yaw_ratio
	_head_tracking_spine_pitch_base = smooth_spine_pitch
	
	# Add extra lean/bend
	if camera_pitch_offset < 0:
		_head_tracking_spine_pitch_base += camera_pitch_offset * lean_back_amount
	else:
		_head_tracking_spine_pitch_base += camera_pitch_offset * bend_forward_amount

func _apply_camera_head_tracking():
	## Apply head/neck/spine rotations AFTER animation (called from skeleton_updated)
	if head_bone_idx < 0:
		return
	
	# === APPLY HEAD ROTATION ===
	var head_rotation_quat = Quaternion.from_euler(Vector3(camera_pitch_offset, camera_yaw_offset, 0))
	var original_head_rot = skeleton.get_bone_pose_rotation(head_bone_idx)
	var blended_head_rot = original_head_rot * head_rotation_quat
	skeleton.set_bone_pose_rotation(head_bone_idx, blended_head_rot)
	
	# === APPLY NECK ROTATION ===
	if neck_bone_idx >= 0:
		var neck_pitch = camera_pitch_offset * 0.3
		var neck_yaw = camera_yaw_offset * neck_yaw_ratio
		var neck_rotation_quat = Quaternion.from_euler(Vector3(neck_pitch, neck_yaw, 0))
		var original_neck_rot = skeleton.get_bone_pose_rotation(neck_bone_idx)
		skeleton.set_bone_pose_rotation(neck_bone_idx, original_neck_rot * neck_rotation_quat)
	
	# === APPLY SPINE ROTATION (distributed across all 3 spine bones) ===
	# Upper spine (50%)
	if spine_upper_idx >= 0:
		var upper_rotation = Quaternion.from_euler(Vector3(_head_tracking_spine_pitch_base * 0.5, _head_tracking_spine_yaw_base * 0.5, 0))
		var original_rot = skeleton.get_bone_pose_rotation(spine_upper_idx)
		skeleton.set_bone_pose_rotation(spine_upper_idx, original_rot * upper_rotation)
	
	# Middle spine (30%)
	if spine_mid_idx >= 0:
		var mid_rotation = Quaternion.from_euler(Vector3(_head_tracking_spine_pitch_base * 0.3, _head_tracking_spine_yaw_base * 0.3, 0))
		var original_rot = skeleton.get_bone_pose_rotation(spine_mid_idx)
		skeleton.set_bone_pose_rotation(spine_mid_idx, original_rot * mid_rotation)
	
	# Lower spine (20%)
	if spine_lower_idx >= 0:
		var lower_rotation = Quaternion.from_euler(Vector3(_head_tracking_spine_pitch_base * 0.2, _head_tracking_spine_yaw_base * 0.2, 0))
		var original_rot = skeleton.get_bone_pose_rotation(spine_lower_idx)
		skeleton.set_bone_pose_rotation(spine_lower_idx, original_rot * lower_rotation)

func angle_difference(from_angle: float, to_angle: float) -> float:
	## Returns the shortest angular difference between two angles
	var diff = fmod(to_angle - from_angle + PI, TAU) - PI
	return diff

func get_head_turn_amount() -> float:
	## Returns how much the head is turned (0-1, where 1 = max turn)
	return abs(camera_yaw_offset) / deg_to_rad(max_head_turn_before_body)

func is_head_at_limit() -> bool:
	## Returns true if head is turned to its limit (body should rotate)
	return get_head_turn_amount() > 0.9
#endregion

#region Look At IK
func set_look_at_target(target: Vector3):
	look_at_target = target
	has_look_target = true

func clear_look_at_target():
	has_look_target = false

func _process_look_at_ik(delta: float):
	if head_bone_idx < 0:
		return
	
	# Get head position in world space
	var head_global_pose = skeleton.global_transform * skeleton.get_bone_global_pose(head_bone_idx)
	var head_pos = head_global_pose.origin
	
	# Calculate direction to target
	var to_target = (look_at_target - head_pos).normalized()
	
	# Convert to local space relative to parent bone (neck or spine)
	var parent_idx = skeleton.get_bone_parent(head_bone_idx)
	var parent_global = skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx) if parent_idx >= 0 else skeleton.global_transform
	var local_target_dir = parent_global.basis.inverse() * to_target
	
	# Calculate yaw and pitch
	var target_yaw = atan2(local_target_dir.x, -local_target_dir.z)
	var target_pitch = asin(clampf(-local_target_dir.y, -1.0, 1.0))
	
	# Clamp to limits
	target_yaw = clampf(target_yaw, deg_to_rad(-max_head_yaw), deg_to_rad(max_head_yaw))
	target_pitch = clampf(target_pitch, deg_to_rad(-max_head_pitch), deg_to_rad(max_head_pitch))
	
	# Smooth interpolation
	current_head_rotation.y = lerp_angle(current_head_rotation.y, target_yaw, look_at_speed * delta)
	current_head_rotation.x = lerp_angle(current_head_rotation.x, target_pitch, look_at_speed * delta)
	
	# Apply rotation
	var look_rotation = Basis.from_euler(Vector3(current_head_rotation.x, current_head_rotation.y, 0))
	
	# Blend with original animation pose
	var original_rotation = skeleton.get_bone_pose_rotation(head_bone_idx)
	var blended_rotation = original_rotation.slerp(Quaternion(look_rotation), look_at_blend)
	
	skeleton.set_bone_pose_rotation(head_bone_idx, blended_rotation)
#endregion

#region Hand IK
func set_left_hand_target(target: Vector3):
	left_hand_target = target
	left_hand_active = true

func set_right_hand_target(target: Vector3):
	right_hand_target = target
	right_hand_active = true

func clear_left_hand_target():
	left_hand_active = false

func clear_right_hand_target():
	right_hand_active = false

func _process_hand_ik(_delta: float):
	# Basic two-bone IK for hands
	# This is a placeholder - full implementation requires knowing arm bone structure
	if left_hand_active and left_hand_bone_idx >= 0:
		_solve_hand_ik(left_hand_bone_idx, left_hand_target)

	if right_hand_active and right_hand_bone_idx >= 0:
		_solve_hand_ik(right_hand_bone_idx, right_hand_target)

func _solve_hand_ik(hand_bone_idx: int, target: Vector3):
	# Simple position-based IK (proper two-bone IK would need elbow bone)
	# For now, just move the hand toward the target
	var hand_global_pose = skeleton.global_transform * skeleton.get_bone_global_pose(hand_bone_idx)
	var current_pos = hand_global_pose.origin
	
	# Get parent bone (forearm/lower arm)
	var parent_idx = skeleton.get_bone_parent(hand_bone_idx)
	if parent_idx < 0:
		return
	
	# Calculate offset needed
	var offset = target - current_pos
	
	# Apply to hand bone local position
	var local_offset = skeleton.get_bone_global_pose(parent_idx).basis.inverse() * offset
	var current_local_pos = skeleton.get_bone_pose_position(hand_bone_idx)
	skeleton.set_bone_pose_position(hand_bone_idx, current_local_pos + local_offset * 0.5)
#endregion

#region Utility
func get_bone_world_position(bone_name: String) -> Vector3:
	var idx = skeleton.find_bone(bone_name) if skeleton else -1
	if idx >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(idx).origin
	return Vector3.ZERO

func get_bone_world_transform(bone_name: String) -> Transform3D:
	var idx = skeleton.find_bone(bone_name) if skeleton else -1
	if idx >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(idx)
	return Transform3D.IDENTITY
#endregion

