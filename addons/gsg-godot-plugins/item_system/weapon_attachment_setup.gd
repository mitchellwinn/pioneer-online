@tool
extends Node
class_name WeaponAttachmentSetup

## Weapon attachment and hand IK system.
##
## HOW IT WORKS:
## - Held weapons are parented to spine/chest (stable anchor)
## - Weapon position changes based on pose (lowered, ready, aiming)
## - Hand IK moves the hands TO reach the weapon's grip points (using SkeletonIK3D)
## - Holstered weapons attach to their respective holster bones
##
## NETWORK ARCHITECTURE:
## - This script runs on ALL players (local and remote)
## - IK is calculated CLIENT-SIDE for visual smoothness
## - What IS synced: equipped weapon, aiming state, holster state, animation
## - What is NOT synced: IK bone positions, visual recoil (calculated locally)
## - Each client calculates IK for all visible players based on synced state
##
## SETUP:
## 1. Add this to your player scene
## 2. Click "Create Attachment Points" in inspector  
## 3. Adjust holster marker positions as needed
## 4. Adjust weapon pose offsets for your character

#region Configuration
@export_group("Skeleton")
@export var skeleton_path: NodePath

@export_group("Bones")
@export var weapon_anchor_bone: String = "spine_03.x" # Where held weapons attach
@export var right_hand_bone: String = "hand.r"
@export var left_hand_bone: String = "hand.l"
@export var right_upper_arm_bone: String = "arm_stretch.r"
@export var right_forearm_bone: String = "forearm_stretch.r"
@export var left_upper_arm_bone: String = "arm_stretch.l"
@export var left_forearm_bone: String = "forearm_stretch.l"

@export_group("Holster Bones")
@export var back_bone: String = "spine_03.x"
@export var hip_bone: String = "pelvis.x" # Belt/hip area
@export var thigh_bone: String = "thigh_stretch.l"

## NOTE: Holster positions are now defined by Marker3D nodes in the scene!
## Look for "BackHolster/RifleHolsterPoint" and "HipHolsterRight/PistolHolsterPoint"
## Position those markers visually in the editor with preview guns for exact placement.

@export_group("Weapon Poses - Rifle")
## Idle/walk: gun pointing mostly forward, compact stance
@export var rifle_lowered_offset: Vector3 = Vector3(-0.08, 0.02, 0.45)
@export var rifle_lowered_rotation: Vector3 = Vector3(-8, 180, 5)
## Ready: gun forward, slightly raised
@export var rifle_ready_offset: Vector3 = Vector3(-0.06, 0.04, 0.42)
@export var rifle_ready_rotation: Vector3 = Vector3(-5, 180, 3)
## Aiming: brought up to shoulder, looking through sights
@export var rifle_aim_offset: Vector3 = Vector3(0, 0.14, 0.38)
@export var rifle_aim_rotation: Vector3 = Vector3(0, 180, 0)

@export_group("Weapon Poses - Pistol")
## Idle/walk: pistol pointing mostly forward
@export var pistol_lowered_offset: Vector3 = Vector3(0.15, -0.02, 0.38)
@export var pistol_lowered_rotation: Vector3 = Vector3(-12, 180, 0)
## Ready: pistol forward, slightly raised
@export var pistol_ready_offset: Vector3 = Vector3(0.12, 0.02, 0.36)
@export var pistol_ready_rotation: Vector3 = Vector3(-8, 180, 0)
## Aiming: raised to eye level, looking through sights
@export var pistol_aim_offset: Vector3 = Vector3(0.08, 0.14, 0.35)
@export var pistol_aim_rotation: Vector3 = Vector3(0, 180, 0)

@export_group("Weapon Poses - Saber/Melee")
## Idle: lowered at side
@export var saber_lowered_offset: Vector3 = Vector3(0.2, -0.2, 0.3)
@export var saber_lowered_rotation: Vector3 = Vector3(-60, 180, 90)
## Ready: guard position - sword held forward
@export var saber_ready_offset: Vector3 = Vector3(0.15, 0.05, 0.35)
@export var saber_ready_rotation: Vector3 = Vector3(-15, 180, 30)
## Block stance: diagonal guard covering body (right-click hold)
@export var saber_block_offset: Vector3 = Vector3(0.05, 0.2, 0.25)
@export var saber_block_rotation: Vector3 = Vector3(25, 200, -45)
## Attack stance: raised for overhead or ready to swing
@export var saber_aim_offset: Vector3 = Vector3(0.1, 0.15, 0.4)
@export var saber_aim_rotation: Vector3 = Vector3(0, 180, 30)

@export_group("IK Settings")
@export var ik_blend_speed: float = 15.0 # How fast IK blends in
@export var lowered_ik_blend: float = 1.0 # Full IK always
@export var ready_ik_blend: float = 1.0 # Full IK always
@export var aim_ik_blend: float = 1.0 # Full IK always
@export var pose_blend_speed: float = 12.0 # How fast poses transition

@export_group("Camera Tracking")
@export var camera_track_amount: float = 0.4 # How much gun follows camera (0-1)
@export var camera_track_speed: float = 8.0 # How fast gun tracks camera

@export_group("Aim Tracking")
@export var aim_at_target: bool = true # Enable weapon pitch tracking with camera
@export var aim_track_speed: float = 15.0 # How fast weapon tracks aim point
@export var max_aim_pitch: float = 45.0 # Max up/down rotation when aiming

@export_group("Actions")
@export var create_attachment_points: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			_create_all_attachments()
			
@export var show_previews: bool = true:
	set(v):
		show_previews = v
		_update_preview_visibility()
#endregion

#region Generated References
var weapon_anchor_attach: BoneAttachment3D # Where held ranged weapons parent to (spine)
var melee_hand_attach: BoneAttachment3D # Where melee weapons parent to (right hand)

# Holster markers - Back (3 slots for large guns like rifles)
var back_1_marker: Marker3D   # Primary back slot
var back_2_marker: Marker3D   # Secondary back slot
var back_3_marker: Marker3D   # Tertiary back slot

# Holster markers - Hip/Thigh (3 slots for small guns like SMGs, pistols)
var hip_1_marker: Marker3D    # Right hip/thigh
var hip_2_marker: Marker3D    # Left hip/thigh
var hip_3_marker: Marker3D    # Additional hip slot

# Holster markers - Melee Small (3 slots for small melee like sabers, daggers)
var melee_small_1_marker: Marker3D  # Primary small melee holster
var melee_small_2_marker: Marker3D  # Secondary small melee holster
var melee_small_3_marker: Marker3D  # Tertiary small melee holster

# Holster markers - Melee Large (3 slots for large melee like swords, axes)
var melee_large_1_marker: Marker3D  # Primary large melee holster
var melee_large_2_marker: Marker3D  # Secondary large melee holster
var melee_large_3_marker: Marker3D  # Tertiary large melee holster

# Legacy compatibility aliases
var back_primary_marker: Marker3D:
	get: return back_1_marker
	set(v): back_1_marker = v
var back_secondary_marker: Marker3D:
	get: return back_2_marker
	set(v): back_2_marker = v
var hip_right_marker: Marker3D:
	get: return hip_1_marker
	set(v): hip_1_marker = v
var hip_left_marker: Marker3D:
	get: return hip_2_marker
	set(v): hip_2_marker = v
var saber_holster_marker: Marker3D:
	get: return melee_small_1_marker
	set(v): melee_small_1_marker = v
var thigh_right_marker: Marker3D:
	get: return hip_1_marker
var thigh_left_marker: Marker3D:
	get: return hip_2_marker
var melee_1_marker: Marker3D:
	get: return melee_small_1_marker
	set(v): melee_small_1_marker = v

var melee_grip_marker: Marker3D # Position marker for melee weapon in hand
#endregion

#region Runtime State
var _skeleton: Skeleton3D
var _previews: Dictionary = {}

# IK nodes (Godot's built-in SkeletonIK3D)
var _right_arm_ik: SkeletonIK3D
var _left_arm_ik: SkeletonIK3D
var _right_ik_target: Node3D # Where right hand should go
var _left_ik_target: Node3D # Where left hand should go
var _right_pole: Node3D # Where right elbow should point
var _left_pole: Node3D # Where left elbow should point

# Weapon state
var _current_weapon: Node3D = null
var _weapon_component = null # WeaponComponent - untyped to avoid load order issues
var _weapon_type: String = "none" # "rifle", "pistol"
var _camera_yaw_offset: float = 0.0 # How much camera is rotated from character

# Pose state
enum WeaponPose {NONE, LOWERED, READY, AIMING, BLOCKING}
var _current_pose: WeaponPose = WeaponPose.NONE
var _pose_blend: float = 0.0 # 0=lowered, 0.5=ready, 1=aiming
var _target_pose_blend: float = 0.0
var _ik_blend: float = 0.0
var _target_ik_blend: float = 0.0

# Fire snap - briefly snap to aim position when firing
var _fire_snap_blend: float = 0.0 # Additional pose blend from firing (0-1)
var _fire_snap_decay: float = 8.0 # How fast fire snap decays
var _fire_snap_amount: float = 0.5 # How much to add to pose blend (0.5 = go to aim if at ready)

# Movement state
var _is_moving: bool = false
var _is_sprinting: bool = false

# Aim tracking state
var _aim_pitch_offset: float = 0.0 # Current pitch adjustment for aiming
var _aim_yaw_offset: float = 0.0 # Current yaw adjustment for aiming
var _owner_entity: Node3D = null

#endregion

func _ready():
	_find_skeleton()
	_owner_entity = get_parent() # Should be the player

	print("[WeaponAttachmentSetup] _ready called, skeleton: ", _skeleton, " owner: ", _owner_entity)

	if _skeleton:
		_find_existing_attachments()

		# Auto-create attachments at runtime if they don't exist
		if not Engine.is_editor_hint():
			_ensure_runtime_attachments()
			_setup_skeleton_ik()
			print("[WeaponAttachmentSetup] Setup complete - weapon_anchor: ", weapon_anchor_attach, " melee_grip: ", melee_grip_marker)
	else:
		push_error("[WeaponAttachmentSetup] No skeleton found!")

func _process(delta: float):
	if Engine.is_editor_hint():
		return
	
	# MELEE WEAPONS: No procedural animation at all - animations handle everything
	if _weapon_type == "saber":
		return
	
	# Decay fire snap
	if _fire_snap_blend > 0.01:
		_fire_snap_blend = lerp(_fire_snap_blend, 0.0, _fire_snap_decay * delta)
	else:
		_fire_snap_blend = 0.0
	
	# Blend pose (add fire snap for brief aim-up when firing)
	var effective_target = minf(_target_pose_blend + _fire_snap_blend, 1.0)
	_pose_blend = lerp(_pose_blend, effective_target, pose_blend_speed * delta)
	
	# Blend IK
	_ik_blend = lerp(_ik_blend, _target_ik_blend, ik_blend_speed * delta)
	
	# Update weapon position based on pose (ranged only)
	if _current_weapon and weapon_anchor_attach:
		_update_weapon_pose()
	
	# Update IK targets to follow grip points (ranged only)
	_update_ik_targets()

#region Skeleton Setup
func _find_skeleton() -> Skeleton3D:
	if skeleton_path:
		_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if not _skeleton:
		_skeleton = _search_for_skeleton(get_parent())
	return _skeleton

func _search_for_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _search_for_skeleton(child)
		if found:
			return found
	return null

func _setup_skeleton_ik():
	## Setup Godot's built-in SkeletonIK3D for proper arm IK
	if not _skeleton:
		return
	
	print("[WeaponAttachmentSetup] Setting up SkeletonIK3D...")
	
	# Create IK targets (where hands should go)
	_right_ik_target = Node3D.new()
	_right_ik_target.name = "RightHandIKTarget"
	_skeleton.add_child(_right_ik_target)
	
	_left_ik_target = Node3D.new()
	_left_ik_target.name = "LeftHandIKTarget"
	_skeleton.add_child(_left_ik_target)
	
	# Create pole targets (where elbows should point - behind and outside)
	_right_pole = Node3D.new()
	_right_pole.name = "RightElbowPole"
	_skeleton.add_child(_right_pole)
	
	_left_pole = Node3D.new()
	_left_pole.name = "LeftElbowPole"
	_skeleton.add_child(_left_pole)
	
	# Setup right arm IK
	_right_arm_ik = SkeletonIK3D.new()
	_right_arm_ik.name = "RightArmIK"
	_skeleton.add_child(_right_arm_ik)
	_right_arm_ik.root_bone = right_upper_arm_bone
	_right_arm_ik.tip_bone = right_hand_bone
	_right_arm_ik.target_node = _right_ik_target.get_path()
	_right_arm_ik.use_magnet = true
	_right_arm_ik.magnet = Vector3(0.3, -0.2, 0.4) # Initial pole hint (right, down, back)
	_right_arm_ik.override_tip_basis = false # Keep hand rotation from animation
	_right_arm_ik.interpolation = 1.0
	
	# Setup left arm IK
	_left_arm_ik = SkeletonIK3D.new()
	_left_arm_ik.name = "LeftArmIK"
	_skeleton.add_child(_left_arm_ik)
	_left_arm_ik.root_bone = left_upper_arm_bone
	_left_arm_ik.tip_bone = left_hand_bone
	_left_arm_ik.target_node = _left_ik_target.get_path()
	_left_arm_ik.use_magnet = true
	_left_arm_ik.magnet = Vector3(-0.3, -0.2, 0.4) # Initial pole hint (left, down, back)
	_left_arm_ik.override_tip_basis = false
	_left_arm_ik.interpolation = 1.0
	
	print("[WeaponAttachmentSetup] SkeletonIK3D setup complete")

func _find_existing_attachments():
	if not _skeleton:
		return
	print("[WeaponAttachmentSetup] Finding existing attachments in skeleton: ", _skeleton.name)
	for child in _skeleton.get_children():
		if child is BoneAttachment3D:
			print("[WeaponAttachmentSetup] Found BoneAttachment3D: ", child.name)
			if child.name == "WeaponAnchor":
				weapon_anchor_attach = child
			elif child.name == "RightHandGrip":
				# Melee weapon hand attachment from scene
				melee_hand_attach = child
				print("[WeaponAttachmentSetup] Found RightHandGrip, looking for MeleeGripPoint")
				var marker = child.get_node_or_null("MeleeGripPoint") as Marker3D
				if marker:
					melee_grip_marker = marker
					print("[WeaponAttachmentSetup] Found MeleeGripPoint marker: ", marker.transform)
					_remove_preview_children(marker)
				else:
					print("[WeaponAttachmentSetup] MeleeGripPoint NOT found in RightHandGrip!")
			# New holster system: Back slots
			elif child.name == "BackHolster1":
				_assign_marker_from_child(child, "HolsterPoint", "back_1")
			elif child.name == "BackHolster2":
				_assign_marker_from_child(child, "HolsterPoint", "back_2")
			elif child.name == "BackHolster3":
				_assign_marker_from_child(child, "HolsterPoint", "back_3")
			# New holster system: Hip/Thigh slots
			elif child.name == "HipHolster1":
				_assign_marker_from_child(child, "HolsterPoint", "hip_1")
			elif child.name == "HipHolster2":
				_assign_marker_from_child(child, "HolsterPoint", "hip_2")
			elif child.name == "HipHolster3":
				_assign_marker_from_child(child, "HolsterPoint", "hip_3")
			# New holster system: Small Melee slots
			elif child.name == "MeleeSmallHolster1":
				_assign_marker_from_child(child, "HolsterPoint", "melee_small_1")
			elif child.name == "MeleeSmallHolster2":
				_assign_marker_from_child(child, "HolsterPoint", "melee_small_2")
			elif child.name == "MeleeSmallHolster3":
				_assign_marker_from_child(child, "HolsterPoint", "melee_small_3")
			# New holster system: Large Melee slots
			elif child.name == "MeleeLargeHolster1":
				_assign_marker_from_child(child, "HolsterPoint", "melee_large_1")
			elif child.name == "MeleeLargeHolster2":
				_assign_marker_from_child(child, "HolsterPoint", "melee_large_2")
			elif child.name == "MeleeLargeHolster3":
				_assign_marker_from_child(child, "HolsterPoint", "melee_large_3")
			# Legacy names support
			elif child.name == "BackHolster":
				var marker = child.get_node_or_null("RifleHolsterPoint") as Marker3D
				if marker:
					back_1_marker = marker
					print("[WeaponAttachmentSetup] Found back_1_marker (legacy BackHolster): %s" % marker)
					_remove_preview_children(marker)
			elif child.name == "HipHolsterRight":
				var marker = child.get_node_or_null("PistolHolsterPoint") as Marker3D
				if marker:
					hip_1_marker = marker
					_remove_preview_children(marker)
			elif child.name == "HipHolsterLeft":
				var marker = child.get_node_or_null("SaberHolsterPoint") as Marker3D
				if marker:
					melee_1_marker = marker
					_remove_preview_children(marker)
			# Check for markers directly in bone attachments
			for marker in child.get_children():
				if marker is Marker3D:
					match marker.name:
						"BackPrimaryPoint":
							back_1_marker = marker
							_remove_preview_children(marker)
						"BackSecondaryPoint":
							back_2_marker = marker
							_remove_preview_children(marker)
						"HipRightPoint":
							hip_1_marker = marker
							_remove_preview_children(marker)
						"HipLeftPoint":
							hip_2_marker = marker
							_remove_preview_children(marker)
						"SaberHolsterPoint":
							melee_1_marker = marker
							_remove_preview_children(marker)
						"MeleeGripPoint":
							melee_grip_marker = marker
							_remove_preview_children(marker)

func _assign_marker_from_child(bone_attach: BoneAttachment3D, marker_name: String, slot: String):
	var marker = bone_attach.get_node_or_null(marker_name) as Marker3D
	if marker:
		match slot:
			"back_1": back_1_marker = marker
			"back_2": back_2_marker = marker
			"back_3": back_3_marker = marker
			"hip_1": hip_1_marker = marker
			"hip_2": hip_2_marker = marker
			"hip_3": hip_3_marker = marker
			"melee_small_1": melee_small_1_marker = marker
			"melee_small_2": melee_small_2_marker = marker
			"melee_small_3": melee_small_3_marker = marker
			"melee_large_1": melee_large_1_marker = marker
			"melee_large_2": melee_large_2_marker = marker
			"melee_large_3": melee_large_3_marker = marker
		print("[WeaponAttachmentSetup] Found %s_marker: %s" % [slot, marker])
		_remove_preview_children(marker)

func _remove_preview_children(marker: Marker3D):
	## Remove editor preview weapons at runtime
	if Engine.is_editor_hint():
		return
	for child in marker.get_children():
		if child.name.begins_with("Preview"):
			child.queue_free()
		elif child is Node3D:
			if child.get_node_or_null("WeaponComponent") or child.has_method("get_grip_transform"):
				child.queue_free()

func _ensure_runtime_attachments():
	## Create bone attachments at runtime if they weren't baked into the scene
	if not _skeleton:
		push_error("[WeaponAttachmentSetup] No skeleton found!")
		return

	print("[WeaponAttachmentSetup] Setting up attachments on skeleton: ", _skeleton.name)
	print("[WeaponAttachmentSetup] Available bones: ", _get_bone_list())
	print("[WeaponAttachmentSetup] Existing markers - back_primary: %s, back_secondary: %s" % [back_primary_marker, back_secondary_marker])
	
	# Always need weapon anchor for held weapons
	if not weapon_anchor_attach:
		weapon_anchor_attach = _create_runtime_bone_attachment("WeaponAnchor", weapon_anchor_bone)
		if weapon_anchor_attach:
			print("[WeaponAttachmentSetup] Created weapon anchor on bone: ", weapon_anchor_bone)
		else:
			push_error("[WeaponAttachmentSetup] Failed to create weapon anchor!")
	
	# Create fallback holster attachments if not found in scene
	# (Prefer using Marker3D nodes in the scene for visual positioning!)
	if not back_primary_marker:
		var back_attach = _create_runtime_bone_attachment("BackHolster", back_bone)
		if back_attach:
			# Rifle on back: barrel pointing down - rotation X=90 points -Z down
			back_primary_marker = _create_runtime_marker(back_attach, "RifleHolsterPoint",
				Vector3(0.08, 0.15, -0.12), Vector3(90, 0, 0))

	if not back_secondary_marker:
		# Secondary weapon on back (offset from primary)
		var back_attach = _create_runtime_bone_attachment("BackHolsterSecondary", back_bone)
		if back_attach:
			back_secondary_marker = _create_runtime_marker(back_attach, "SecondaryHolsterPoint",
				Vector3(-0.08, 0.15, -0.12), Vector3(90, 0, 0))

	if not hip_right_marker:
		var hip_attach = _create_runtime_bone_attachment("HipHolsterRight", hip_bone)
		if hip_attach:
			# Pistol on hip side: barrel pointing down
			hip_right_marker = _create_runtime_marker(hip_attach, "PistolHolsterPoint",
				Vector3(0.2, -0.05, 0), Vector3(90, 90, 0))
	
	if not saber_holster_marker:
		var hip_left_attach = _create_runtime_bone_attachment("HipHolsterLeft", hip_bone)
		if hip_left_attach:
			# Saber on left hip: blade pointing down, handle up
			saber_holster_marker = _create_runtime_marker(hip_left_attach, "SaberHolsterPoint",
				Vector3(-0.2, -0.05, 0), Vector3(90, -90, 0))
			hip_left_marker = saber_holster_marker
	
	print("[WeaponAttachmentSetup] Runtime attachments ready")

func _get_bone_list() -> String:
	if not _skeleton:
		return "no skeleton"
	var bones = []
	for i in range(min(_skeleton.get_bone_count(), 10)): # First 10 bones
		bones.append(_skeleton.get_bone_name(i))
	return ", ".join(bones) + "..."

func _create_runtime_bone_attachment(attach_name: String, bone_name: String) -> BoneAttachment3D:
	var bone_idx = _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		push_warning("[WeaponAttachmentSetup] Bone not found: ", bone_name)
		return null
	
	var attach = BoneAttachment3D.new()
	attach.name = attach_name
	attach.bone_name = bone_name
	_skeleton.add_child(attach)
	return attach

func _create_runtime_marker(parent: BoneAttachment3D, marker_name: String, offset: Vector3, rotation_deg: Vector3) -> Marker3D:
	if not parent:
		return null
	var marker = Marker3D.new()
	marker.name = marker_name
	marker.position = offset
	marker.rotation_degrees = rotation_deg
	parent.add_child(marker)
	return marker
#endregion

#region Attachment Creation (Editor)
func _create_all_attachments():
	_find_skeleton()
	if not _skeleton:
		push_error("[WeaponAttachmentSetup] No skeleton found!")
		return
	
	print("[WeaponAttachmentSetup] Creating attachments on: ", _skeleton.name)
	
	# Weapon anchor (where held weapons attach)
	weapon_anchor_attach = _get_or_create_bone_attachment("WeaponAnchor", weapon_anchor_bone)
	
	# Holster attachments - barrel pointing down, flat side toward player
	var back_attach = _get_or_create_bone_attachment("HolsterBack", back_bone)
	back_primary_marker = _create_marker_on(back_attach, "BackPrimaryPoint",
		Vector3(0.1, 0.0, 0.1), Vector3(180, 0, -20))
	back_secondary_marker = _create_marker_on(back_attach, "BackSecondaryPoint",
		Vector3(-0.1, 0.0, 0.1), Vector3(180, 0, 20))
	
	# Hip holsters - barrel pointing down
	var hip_attach = _get_or_create_bone_attachment("HolsterHip", hip_bone)
	hip_right_marker = _create_marker_on(hip_attach, "HipRightPoint",
		Vector3(0.1, 0.0, 0.05), Vector3(180, 0, 0))
	hip_left_marker = _create_marker_on(hip_attach, "HipLeftPoint",
		Vector3(-0.1, 0.0, 0.05), Vector3(180, 0, 0))
	
	if show_previews:
		_create_all_previews()
	
	print("[WeaponAttachmentSetup] Done! Adjust holster markers as needed.")

func _get_or_create_bone_attachment(attach_name: String, bone_name: String) -> BoneAttachment3D:
	var bone_idx = _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		push_warning("[WeaponAttachmentSetup] Bone not found: ", bone_name)
		return null
	
	var existing = _skeleton.get_node_or_null(attach_name)
	if existing is BoneAttachment3D:
		return existing
	
	var attach = BoneAttachment3D.new()
	attach.name = attach_name
	attach.bone_name = bone_name
	_skeleton.add_child(attach)
	if Engine.is_editor_hint():
		attach.owner = get_tree().edited_scene_root
	return attach

func _create_marker_on(parent: BoneAttachment3D, marker_name: String, offset: Vector3, rotation_deg: Vector3) -> Marker3D:
	if not parent:
		return null
	
	var existing = parent.get_node_or_null(marker_name)
	if existing is Marker3D:
		return existing
	
	var marker = Marker3D.new()
	marker.name = marker_name
	marker.position = offset
	marker.rotation_degrees = rotation_deg
	marker.gizmo_extents = 0.08
	parent.add_child(marker)
	if Engine.is_editor_hint():
		marker.owner = get_tree().edited_scene_root
	return marker

func _create_all_previews():
	_create_preview_for(back_primary_marker, "rifle", Color(0.2, 0.4, 0.8, 0.5))
	_create_preview_for(back_secondary_marker, "rifle", Color(0.2, 0.4, 0.8, 0.5))
	_create_preview_for(hip_right_marker, "pistol", Color(0.8, 0.6, 0.2, 0.5))
	_create_preview_for(hip_left_marker, "pistol", Color(0.8, 0.6, 0.2, 0.5))
	_create_preview_for(saber_holster_marker, "saber", Color(0.2, 0.9, 1.0, 0.5))

func _create_preview_for(marker: Marker3D, weapon_type: String, color: Color):
	if not marker:
		return
	var old = marker.get_node_or_null("Preview")
	if old:
		old.queue_free()
	
	var preview = Node3D.new()
	preview.name = "Preview"
	
	var mesh = MeshInstance3D.new()
	
	if weapon_type == "saber":
		# Saber shape: thin cylinder for hilt + longer cylinder for blade
		var hilt = CylinderMesh.new()
		hilt.top_radius = 0.02
		hilt.bottom_radius = 0.02
		hilt.height = 0.25
		mesh.mesh = hilt
		
		# Blade
		var blade_mesh = MeshInstance3D.new()
		var blade = CylinderMesh.new()
		blade.top_radius = 0.015
		blade.bottom_radius = 0.015
		blade.height = 0.8
		blade_mesh.mesh = blade
		blade_mesh.position.y = 0.525 # Position blade above hilt
		var blade_mat = StandardMaterial3D.new()
		blade_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		blade_mat.albedo_color = Color(0.2, 0.9, 1.0, 0.7)
		blade_mat.emission_enabled = true
		blade_mat.emission = Color(0.2, 0.8, 1.0)
		blade_mat.emission_energy_multiplier = 2.0
		blade_mesh.material_override = blade_mat
		preview.add_child(blade_mesh)
		if Engine.is_editor_hint():
			blade_mesh.owner = get_tree().edited_scene_root
	else:
		var box = BoxMesh.new()
		box.size = Vector3(0.05, 0.1, 0.5) if weapon_type == "rifle" else Vector3(0.03, 0.08, 0.12)
		mesh.mesh = box
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mesh.material_override = mat
	preview.add_child(mesh)
	
	# Barrel/tip indicator (red = forward/-Z) - only for guns
	if weapon_type != "saber":
		var barrel = MeshInstance3D.new()
		var cone = CylinderMesh.new()
		cone.top_radius = 0
		cone.bottom_radius = 0.015
		cone.height = 0.06
		barrel.mesh = cone
		barrel.rotation_degrees.x = 90
		barrel.position.z = -0.28 if weapon_type == "rifle" else -0.08
		var cone_mat = StandardMaterial3D.new()
		cone_mat.albedo_color = Color.RED
		barrel.material_override = cone_mat
		preview.add_child(barrel)
		if Engine.is_editor_hint():
			barrel.owner = get_tree().edited_scene_root
	
	marker.add_child(preview)
	if Engine.is_editor_hint():
		preview.owner = get_tree().edited_scene_root
		mesh.owner = get_tree().edited_scene_root
	_previews[marker] = preview

func _update_preview_visibility():
	for marker in _previews:
		if is_instance_valid(_previews[marker]):
			_previews[marker].visible = show_previews
#endregion

#region Weapon Attachment (Runtime)
func attach_weapon(weapon: Node3D):
	## Attach weapon for holding
	## Melee: parent directly to hand bone, no IK, animations handle everything
	## Ranged: parent to spine anchor with IK and pose system
	print("[WeaponAttachmentSetup] attach_weapon called for: ", weapon.name if weapon else "null")
	_current_weapon = weapon

	# Try to cast directly, then check for child
	if weapon.has_method("get_grip_transform"):
		_weapon_component = weapon
	else:
		_weapon_component = weapon.get_node_or_null("WeaponComponent")

	# Determine weapon type
	_weapon_type = "rifle" # default

	if _weapon_component:
		if _weapon_component.has_method("try_attack") and not _weapon_component.has_method("try_fire"):
			_weapon_type = "saber"
		elif "holster_slot" in _weapon_component:
			var slot = _weapon_component.holster_slot
			if slot == "hip_left":
				_weapon_type = "saber"
			elif slot in ["hip_right", "thigh_right", "thigh_left"]:
				_weapon_type = "pistol"

	print("[WeaponAttachmentSetup] Weapon type determined: ", _weapon_type)

	# MELEE WEAPONS: Simple hand parenting, no IK, no procedural animation
	if _weapon_type == "saber":
		_attach_melee_weapon(weapon)
		return

	# RANGED WEAPONS: Spine anchor with IK and pose system
	if weapon_anchor_attach:
		print("[WeaponAttachmentSetup] Attaching to weapon_anchor_attach: ", weapon_anchor_attach.name)
		if weapon.get_parent():
			weapon.get_parent().remove_child(weapon)
		weapon_anchor_attach.add_child(weapon)
		weapon.visible = true
	else:
		push_warning("[WeaponAttachmentSetup] No weapon anchor attachment! _skeleton: %s" % [_skeleton])
		return
	
	# Start in ready pose
	_current_pose = WeaponPose.READY
	_pose_blend = 0.5
	_target_pose_blend = 0.5
	_ik_blend = 1.0
	_target_ik_blend = 1.0
	
	_update_weapon_pose()
	
	# Connect to weapon's fired signal for fire snap
	if _weapon_component and _weapon_component.has_signal("fired"):
		if not _weapon_component.fired.is_connected(_on_weapon_fired):
			_weapon_component.fired.connect(_on_weapon_fired)
	
	print("[WeaponAttachmentSetup] Attached ranged weapon: ", weapon.name)

func _attach_melee_weapon(weapon: Node3D):
	## Attach melee weapon - EXACTLY replace the preview sword
	## Same parent (MeleeGripPoint), same transform (identity)
	print("[WeaponAttachmentSetup] _attach_melee_weapon called for: ", weapon.name)
	print("[WeaponAttachmentSetup] melee_grip_marker: ", melee_grip_marker, " melee_hand_attach: ", melee_hand_attach, " _skeleton: ", _skeleton)

	# Create runtime attachment if scene doesn't have one
	if not melee_grip_marker and not melee_hand_attach and _skeleton:
		melee_hand_attach = BoneAttachment3D.new()
		melee_hand_attach.name = "MeleeHandAttach"
		melee_hand_attach.bone_name = right_hand_bone
		_skeleton.add_child(melee_hand_attach)
		
		melee_grip_marker = Marker3D.new()
		melee_grip_marker.name = "MeleeGripPoint"
		# Same transform as in player.tscn
		melee_grip_marker.transform = Transform3D(
			Vector3(1, 0, 0),
			Vector3(0, 0, -1),
			Vector3(0, 1, 0),
			Vector3.ZERO
		)
		melee_hand_attach.add_child(melee_grip_marker)
	
	var parent_node = melee_grip_marker if melee_grip_marker else melee_hand_attach
	if not parent_node:
		push_warning("[WeaponAttachmentSetup] No melee attachment point!")
		return
	
	# Remove from current parent (holster)
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	# Parent to grip marker and align grip points
	parent_node.add_child(weapon)

	# Check if weapon has a GripPoint marker for proper alignment
	var grip_point = weapon.get_node_or_null("GripPoint") as Marker3D
	if grip_point:
		# Position weapon so that its GripPoint aligns with the grip marker (identity)
		weapon.transform = grip_point.transform.inverse()
	else:
		# No grip point, use identity transform
		weapon.transform = Transform3D.IDENTITY

	weapon.visible = true
	
	# No IK for melee
	_ik_blend = 0.0
	_target_ik_blend = 0.0
	
	print("[WeaponAttachmentSetup] Attached melee weapon to hand: ", weapon.name)

func detach_weapon():
	# Disconnect fire signal
	if _weapon_component and _weapon_component.has_signal("fired"):
		if _weapon_component.fired.is_connected(_on_weapon_fired):
			_weapon_component.fired.disconnect(_on_weapon_fired)
	
	# Clear IK overrides before detaching
	_clear_hand_ik()
	
	_current_weapon = null
	_weapon_component = null
	_weapon_type = "none"
	_current_pose = WeaponPose.NONE
	_ik_blend = 0.0
	_target_ik_blend = 0.0
	_fire_snap_blend = 0.0

func _on_weapon_fired(_muzzle_pos: Vector3, _direction: Vector3):
	## When weapon fires, briefly snap toward aim position
	# Only snap if not already fully aiming
	if _current_pose != WeaponPose.AIMING:
		_fire_snap_blend = _fire_snap_amount

func _clear_hand_ik():
	## Stop all IK and return to animation control
	_stop_ik()

func set_pose(pose: WeaponPose):
	_current_pose = pose
	match pose:
		WeaponPose.LOWERED:
			_target_pose_blend = 0.0
			_target_ik_blend = lowered_ik_blend
		WeaponPose.BLOCKING:
			_target_pose_blend = 0.75 # Between ready and aim for blocking
			_target_ik_blend = 1.0 # Full IK for blocking
		WeaponPose.READY:
			_target_pose_blend = 0.5
			_target_ik_blend = ready_ik_blend
		WeaponPose.AIMING:
			_target_pose_blend = 1.0
			_target_ik_blend = aim_ik_blend

func set_aiming(aiming: bool):
	set_pose(WeaponPose.AIMING if aiming else WeaponPose.READY)

func set_blocking(_blocking: bool):
	## Blocking is handled by animations for melee weapons
	## This is a no-op stub for compatibility
	pass

func set_swing_arc_rotation(_yaw_degrees: float, _pitch_degrees: float):
	## No-op - melee attacks use animations now
	pass

func clear_swing_arc():
	## No-op - melee attacks use animations now
	pass

func set_moving(moving: bool):
	_is_moving = moving
	# When moving and not aiming, use lowered pose
	if moving and _current_pose != WeaponPose.AIMING:
		set_pose(WeaponPose.LOWERED)
	elif not moving and _current_pose == WeaponPose.LOWERED:
		set_pose(WeaponPose.READY)

func set_sprinting(sprinting: bool):
	_is_sprinting = sprinting
	if sprinting:
		set_pose(WeaponPose.LOWERED)

func set_camera_yaw(yaw_offset: float):
	## Set how much the camera is rotated from character forward (in radians)
	_camera_yaw_offset = yaw_offset
#endregion

#region Weapon Pose Updates
func _update_weapon_pose():
	if not _current_weapon or not weapon_anchor_attach:
		return
	
	# Get pose offsets based on weapon type
	# These are LOCAL to the bone: just simple offsets
	var lowered_offset: Vector3
	var lowered_rot: Vector3
	var ready_offset: Vector3
	var ready_rot: Vector3
	var aim_offset: Vector3
	var aim_rot: Vector3
	
	if _weapon_type == "pistol":
		lowered_offset = pistol_lowered_offset
		lowered_rot = pistol_lowered_rotation
		ready_offset = pistol_ready_offset
		ready_rot = pistol_ready_rotation
		aim_offset = pistol_aim_offset
		aim_rot = pistol_aim_rotation
	else: # rifle (saber is handled by animations, not this function)
		lowered_offset = rifle_lowered_offset
		lowered_rot = rifle_lowered_rotation
		ready_offset = rifle_ready_offset
		ready_rot = rifle_ready_rotation
		aim_offset = rifle_aim_offset
		aim_rot = rifle_aim_rotation
	
	# Blend between poses
	var target_offset: Vector3
	var target_rot: Vector3
	
	if _pose_blend <= 0.5:
		var t = _pose_blend * 2.0
		target_offset = lowered_offset.lerp(ready_offset, t)
		target_rot = lowered_rot.lerp(ready_rot, t)
	else:
		var t = (_pose_blend - 0.5) * 2.0
		target_offset = ready_offset.lerp(aim_offset, t)
		target_rot = ready_rot.lerp(aim_rot, t)
	
	# Apply aim tracking - rotate weapon toward aim point
	if aim_at_target and _owner_entity and _current_pose != WeaponPose.LOWERED:
		_update_aim_tracking(get_process_delta_time())
		# Add aim offset to rotation (pitch = X rotation for up/down)
		target_rot.x += _aim_pitch_offset
	
	# Apply weapon recoil from WeaponComponent
	if _weapon_component:
		var recoil_pos = _weapon_component.recoil_offset if "recoil_offset" in _weapon_component else Vector3.ZERO
		var recoil_rot = _weapon_component.recoil_rotation if "recoil_rotation" in _weapon_component else Vector3.ZERO
		target_offset += recoil_pos
		target_rot += recoil_rot
	
	# Apply LOCAL transform to weapon (relative to bone attachment parent)
	_current_weapon.position = target_offset
	_current_weapon.rotation_degrees = target_rot
#endregion

func _update_aim_tracking(delta: float):
	## Make weapon follow camera pitch (up/down aim)
	if not _owner_entity or not _current_weapon:
		return

	# Get camera pitch from player
	var camera_pitch: float = 0.0
	if _owner_entity.has_node("PlayerCamera"):
		# Local player: read from actual camera
		var cam = _owner_entity.get_node("PlayerCamera")
		if cam.has_method("get_pitch"):
			camera_pitch = cam.get_pitch()
		elif "pitch" in cam:
			camera_pitch = cam.pitch
	elif "synced_camera_pitch" in _owner_entity:
		# Remote player: use synced pitch from network
		camera_pitch = _owner_entity.synced_camera_pitch

	# Convert to degrees and apply to weapon
	var target_pitch = rad_to_deg(camera_pitch)
	target_pitch = clampf(target_pitch, -max_aim_pitch, max_aim_pitch)

	# Smooth the pitch
	_aim_pitch_offset = lerp(_aim_pitch_offset, target_pitch, aim_track_speed * delta)

#region Hand IK (using Godot's SkeletonIK3D)

func _update_ik_targets():
	## Update IK target positions to follow weapon grip points
	if not _skeleton or not _weapon_component:
		_stop_ik()
		return
	
	if _ik_blend < 0.01:
		_stop_ik()
		return
	
	# Get grip world positions
	var right_grip = _weapon_component.get_grip_transform()
	
	# Update right hand target
	if _right_ik_target and _right_arm_ik:
		_right_ik_target.global_transform = right_grip
		
		# Update pole target (elbow should point back and out)
		if _right_pole:
			var shoulder_pos = _get_bone_world_position(right_upper_arm_bone)
			# Pole is behind and to the right of the arm
			var right_dir = _owner_entity.global_transform.basis.x if _owner_entity else Vector3.RIGHT
			var back_dir = _owner_entity.global_transform.basis.z if _owner_entity else Vector3.BACK
			var pole_pos = shoulder_pos + right_dir * 0.3 + back_dir * 0.4 + Vector3.DOWN * 0.2
			_right_pole.global_position = pole_pos
			# Update magnet in skeleton-local space
			_right_arm_ik.magnet = _skeleton.global_transform.affine_inverse() * pole_pos
		
		# Start IK if not running
		if not _right_arm_ik.is_running():
			_right_arm_ik.interpolation = _ik_blend
			_right_arm_ik.start()
		else:
			_right_arm_ik.interpolation = _ik_blend
	
	# Left hand - only for two-handed weapons
	if _weapon_type == "rifle" and _weapon_component.foregrip_point:
		var left_grip = _weapon_component.get_foregrip_transform()
		
		if _left_ik_target and _left_arm_ik:
			_left_ik_target.global_transform = left_grip
			
			# Update pole target (elbow should point back and out to the left)
			if _left_pole:
				var shoulder_pos = _get_bone_world_position(left_upper_arm_bone)
				var left_dir = - _owner_entity.global_transform.basis.x if _owner_entity else Vector3.LEFT
				var back_dir = _owner_entity.global_transform.basis.z if _owner_entity else Vector3.BACK
				var pole_pos = shoulder_pos + left_dir * 0.3 + back_dir * 0.4 + Vector3.DOWN * 0.2
				_left_pole.global_position = pole_pos
				# Update magnet in skeleton-local space
				_left_arm_ik.magnet = _skeleton.global_transform.affine_inverse() * pole_pos
			
			if not _left_arm_ik.is_running():
				_left_arm_ik.interpolation = _ik_blend
				_left_arm_ik.start()
			else:
				_left_arm_ik.interpolation = _ik_blend
	else:
		# Stop left arm IK for single-handed weapons
		if _left_arm_ik and _left_arm_ik.is_running():
			_left_arm_ik.stop()

func _get_bone_world_position(bone_name: String) -> Vector3:
	## Get a bone's position in world space
	if not _skeleton:
		return Vector3.ZERO
	var bone_idx = _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return Vector3.ZERO
	var bone_pose = _skeleton.get_bone_global_pose(bone_idx)
	return _skeleton.global_transform * bone_pose.origin

func _stop_ik():
	## Stop all IK chains
	if _right_arm_ik and _right_arm_ik.is_running():
		_right_arm_ik.stop()
	if _left_arm_ik and _left_arm_ik.is_running():
		_left_arm_ik.stop()

#endregion

#region Holster
func holster_weapon(weapon: Node3D, slot: String):
	print("[WeaponAttachmentSetup] Holstering weapon %s to slot: %s" % [weapon.name, slot])

	var marker = get_holster_marker(slot)
	print("[WeaponAttachmentSetup] Got marker: %s for slot %s" % [marker, slot])
	if not marker:
		push_warning("[WeaponAttachmentSetup] Unknown holster slot: %s, hiding weapon" % slot)
		weapon.visible = false
		return
	
	var bone_attach = marker.get_parent() as BoneAttachment3D
	if not bone_attach:
		push_warning("[WeaponAttachmentSetup] Marker has no bone attachment parent")
		weapon.visible = false
		return
	
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	# Parent to bone attachment and position correctly
	bone_attach.add_child(weapon)

	# Check if weapon has a GripPoint marker for proper alignment
	var grip_point = weapon.get_node_or_null("GripPoint") as Marker3D
	if grip_point:
		# Position weapon so that its GripPoint aligns with the holster marker
		var grip_transform = grip_point.transform
		weapon.transform = marker.transform * grip_transform.inverse()
	else:
		# No grip point, use marker's transform directly
		weapon.transform = marker.transform

	weapon.visible = true

func get_holster_marker(slot: String) -> Marker3D:
	var result: Marker3D = null
	match slot:
		# Large gun slots (back)
		"back_1":
			result = back_1_marker
		"back_2":
			result = back_2_marker if back_2_marker else back_1_marker
		"back_3":
			result = back_3_marker if back_3_marker else back_1_marker
		# Small gun slots (hip/thigh)
		"hip_1":
			result = hip_1_marker
		"hip_2":
			result = hip_2_marker if hip_2_marker else hip_1_marker
		"hip_3":
			result = hip_3_marker if hip_3_marker else hip_1_marker
		# Small melee slots
		"melee_small_1":
			result = melee_small_1_marker
		"melee_small_2":
			result = melee_small_2_marker if melee_small_2_marker else melee_small_1_marker
		"melee_small_3":
			result = melee_small_3_marker if melee_small_3_marker else melee_small_1_marker
		# Large melee slots
		"melee_large_1":
			result = melee_large_1_marker
		"melee_large_2":
			result = melee_large_2_marker if melee_large_2_marker else melee_large_1_marker
		"melee_large_3":
			result = melee_large_3_marker if melee_large_3_marker else melee_large_1_marker
		# Legacy slots (map to new system)
		"back_primary":
			result = back_1_marker
		"back_secondary":
			result = back_2_marker if back_2_marker else back_1_marker
		"hip_right", "thigh_right":
			result = hip_1_marker
		"hip_left", "thigh_left":
			result = hip_2_marker if hip_2_marker else hip_1_marker
		"saber", "melee", "hip_left_melee":
			result = melee_small_1_marker

	if not result:
		print("[WeaponAttachmentSetup] WARNING: No marker found for slot '%s'" % slot)
	return result
#endregion
