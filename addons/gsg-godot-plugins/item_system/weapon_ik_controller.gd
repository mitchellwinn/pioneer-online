extends Node
class_name WeaponIKController

## WeaponIKController - Attaches weapons to hand bones and provides aim IK
## Simplified approach: weapon follows hand bone, IK only adjusts when aiming
##
## You can either:
## 1. Use WeaponAttachmentConfig with a visual hand grip marker (recommended)
## 2. Configure bone name and offsets manually below

#region Signals
signal pose_changed(pose_name: String)
signal weapon_attached(weapon: Node3D)
signal weapon_detached()
#endregion

#region Configuration
@export_group("Visual Config (Recommended)")
## Reference to WeaponAttachmentSetup (new system) - set via code or inspector
@export var attachment_setup: Node
## Legacy: Reference to WeaponAttachmentConfig (if not using setup)
@export var attachment_config: Node

@export_group("References")
@export var skeleton: Skeleton3D
@export var parent_entity: Node3D

@export_group("Bone Names (Manual Config)")
@export var right_hand_bone: String = "hand.r"
@export var left_hand_bone: String = "hand.l"
@export var spine_bone: String = "spine_03.x"

@export_group("Weapon Grip Offset (Manual Config)")
## Offset from hand bone to weapon grip (adjusts where weapon sits in hand)
@export var grip_position_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
## Rotation offset for how weapon sits in hand (degrees)
## For standard Mixamo-style rigs: try (-90, 180, 0) or adjust as needed
@export var grip_rotation_offset: Vector3 = Vector3(-90, 180, 0)

@export_group("Aim Settings")
## How much spine rotates to aim up/down (0-1)
@export var spine_aim_influence: float = 0.3
## Speed of aim transitions
@export var aim_speed: float = 10.0
#endregion

#region Runtime State
enum WeaponPose { NONE, LOWERED, AIMING }

var current_weapon: Node3D = null
var weapon_component: WeaponComponent = null
var current_pose: WeaponPose = WeaponPose.NONE
var is_aiming: bool = false

var _bone_attachment: BoneAttachment3D = null
var _right_hand_idx: int = -1
var _left_hand_idx: int = -1
var _spine_idx: int = -1

var _aim_pitch: float = 0.0  # Current vertical aim angle
var _target_aim_pitch: float = 0.0
#endregion

func _ready():
	# Find skeleton
	if not skeleton:
		skeleton = _find_skeleton(get_parent())
	
	if not skeleton:
		push_warning("[WeaponIK] No skeleton found")
		set_process(false)
		return
	
	# Cache bone indices
	_right_hand_idx = skeleton.find_bone(right_hand_bone)
	_left_hand_idx = skeleton.find_bone(left_hand_bone)
	_spine_idx = skeleton.find_bone(spine_bone)
	
	if _right_hand_idx < 0:
		push_warning("[WeaponIK] Right hand bone not found: ", right_hand_bone)
	
	# Find parent entity
	if not parent_entity:
		parent_entity = get_parent()
	
	# Create bone attachment for weapon
	_create_bone_attachment()

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

func _create_bone_attachment():
	if not skeleton or _right_hand_idx < 0:
		return
	
	_bone_attachment = BoneAttachment3D.new()
	_bone_attachment.name = "WeaponHandAttachment"
	_bone_attachment.bone_name = right_hand_bone
	skeleton.add_child(_bone_attachment)

func _process(delta: float):
	if not current_weapon or not skeleton:
		return
	
	# Update aim
	_aim_pitch = lerp(_aim_pitch, _target_aim_pitch, aim_speed * delta)
	
	# Apply spine rotation for aiming up/down
	if is_aiming and _spine_idx >= 0:
		_apply_spine_aim()

#region Weapon Management
func set_weapon(weapon: Node3D):
	## Attach a weapon to the hand
	if current_weapon == weapon:
		return
	
	if current_weapon:
		detach_weapon()
	
	if not weapon:
		return
	
	current_weapon = weapon
	
	# Get weapon component
	weapon_component = weapon as WeaponComponent
	if not weapon_component:
		weapon_component = weapon.get_node_or_null("WeaponComponent")
	
	# Try using visual config first (recommended method)
	if attachment_config and "hand_grip_point" in attachment_config and attachment_config.hand_grip_point:
		_attach_using_config(weapon)
	elif _bone_attachment:
		_attach_using_bone(weapon)
	else:
		push_warning("[WeaponIK] No attachment method available")
	
	current_pose = WeaponPose.LOWERED
	weapon_attached.emit(weapon)

func _attach_using_config(weapon: Node3D):
	## Attach weapon using the visual WeaponAttachmentConfig marker
	## Marker = hand position & rotation. Weapon is offset so its GripPoint aligns with the marker.
	var marker = attachment_config.hand_grip_point
	if not marker:
		push_warning("[WeaponIK] No hand grip marker in config")
		_attach_using_bone(weapon)
		return
	
	# Ensure we have a bone attachment
	if not _bone_attachment:
		_create_bone_attachment()
	
	if not _bone_attachment:
		push_warning("[WeaponIK] No bone attachment available")
		return
	
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	# Attach to the bone attachment (follows hand bone)
	_bone_attachment.add_child(weapon)
	
	# Calculate marker's transform RELATIVE to the bone attachment
	# This converts the marker's world position to the bone's local space
	var marker_global = marker.global_transform
	var bone_global = _bone_attachment.global_transform
	var relative_transform = bone_global.affine_inverse() * marker_global
	
	# Apply this relative transform to the weapon
	weapon.transform = relative_transform
	
	# Now offset by grip point so the grip aligns with where the marker is
	if weapon_component and weapon_component.grip_point:
		var grip_local = weapon_component.grip_point.position
		weapon.position -= weapon.basis * grip_local
	
	weapon.visible = true

func _attach_using_bone(weapon: Node3D):
	## Attach weapon using bone attachment (manual config)
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	_bone_attachment.add_child(weapon)
	
	# Position weapon relative to hand
	if weapon_component and weapon_component.grip_point:
		var grip_local = weapon_component.grip_point.position
		weapon.position = -grip_local + grip_position_offset
	else:
		weapon.position = grip_position_offset
	
	weapon.rotation_degrees = grip_rotation_offset
	weapon.visible = true

func detach_weapon():
	if not current_weapon:
		return
	
	# Weapon will be reparented by holster system
	current_weapon = null
	weapon_component = null
	current_pose = WeaponPose.NONE
	
	weapon_detached.emit()

func set_aiming(aiming: bool):
	is_aiming = aiming
	current_pose = WeaponPose.AIMING if aiming else WeaponPose.LOWERED
	pose_changed.emit("aiming" if aiming else "lowered")

func set_sprinting(sprinting: bool):
	# Sprinting doesn't change weapon attachment, just animation
	pass

func set_aim_pitch(pitch: float):
	## Set target vertical aim angle (from camera pitch)
	_target_aim_pitch = pitch
#endregion

#region Aim IK
func _apply_spine_aim():
	## Rotate spine to help aim up/down
	if _spine_idx < 0:
		return
	
	var spine_pose = skeleton.get_bone_pose(_spine_idx)
	var aim_rotation = _aim_pitch * spine_aim_influence
	
	# Apply pitch rotation to spine
	var aim_basis = Basis.from_euler(Vector3(aim_rotation, 0, 0))
	var new_basis = spine_pose.basis * aim_basis
	
	skeleton.set_bone_pose_rotation(_spine_idx, new_basis.orthonormalized().get_rotation_quaternion())
#endregion

#region Getters
func get_current_pose() -> WeaponPose:
	return current_pose

func has_weapon() -> bool:
	return current_weapon != null

func get_muzzle_position() -> Vector3:
	if weapon_component and weapon_component.muzzle_point:
		return weapon_component.muzzle_point.global_position
	elif current_weapon:
		return current_weapon.global_position
	return Vector3.ZERO

func get_aim_direction() -> Vector3:
	if weapon_component and weapon_component.muzzle_point:
		return -weapon_component.muzzle_point.global_transform.basis.z
	elif current_weapon:
		return -current_weapon.global_transform.basis.z
	return Vector3.FORWARD
#endregion
