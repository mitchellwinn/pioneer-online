extends Node3D
class_name HolsterSystem

## HolsterSystem - Manages weapon attachment points on player body
## Handles holstering and drawing weapons with smooth transitions
##
## You can either:
## 1. Use WeaponAttachmentConfig with visual Marker3D points (recommended)
## 2. Configure bone names and offsets manually below

#region Signals
signal weapon_holstered(weapon: Node3D, slot: String)
signal weapon_drawn(weapon: Node3D)
signal transition_started(weapon: Node3D, from_slot: String, to_slot: String)
signal transition_completed(weapon: Node3D)
#endregion

#region Configuration
@export_group("Visual Config (Recommended)")
## Reference to WeaponAttachmentConfig for visual positioning
@export var attachment_config: Node

@export_group("Skeleton")
@export var skeleton: Skeleton3D

@export_group("Attachment Bones (Manual Config)")
## Bone names for each holster slot
@export var back_primary_bone: String = "spine_03.x"
@export var back_secondary_bone: String = "spine_02.x"
@export var back_lower_bone: String = "spine_01.x"
@export var hip_right_bone: String = "thigh_stretch.r"
@export var hip_left_bone: String = "thigh_stretch.l"
@export var thigh_right_bone: String = "thigh_stretch.r"
@export var thigh_left_bone: String = "thigh_stretch.l"
@export var chest_bone: String = "spine_03.x"

@export_group("Slot Offsets")
## Position offset for back primary (large weapons - rifles)
## Rifle lays diagonally across back, barrel pointing down-right
@export var back_primary_offset: Vector3 = Vector3(0.15, 0.1, 0.1)
@export var back_primary_rotation: Vector3 = Vector3(15, 90, -160)  # Diagonal across back
## Position offset for back secondary
@export var back_secondary_offset: Vector3 = Vector3(-0.15, 0.0, 0.1)
@export var back_secondary_rotation: Vector3 = Vector3(-15, -90, 160)
## Position offset for hip slots (pistols) - in holster pointing down
@export var hip_right_offset: Vector3 = Vector3(0.15, 0.0, 0.08)
@export var hip_right_rotation: Vector3 = Vector3(0, 90, 180)  # Grip up, barrel down
@export var hip_left_offset: Vector3 = Vector3(-0.15, 0.0, 0.08)
@export var hip_left_rotation: Vector3 = Vector3(0, -90, 180)
## Position offset for thigh slots (small weapons)
@export var thigh_right_offset: Vector3 = Vector3(0.1, -0.15, 0.06)
@export var thigh_right_rotation: Vector3 = Vector3(0, 90, 180)
@export var thigh_left_offset: Vector3 = Vector3(-0.1, -0.15, 0.06)
@export var thigh_left_rotation: Vector3 = Vector3(0, -90, 180)

@export_group("Transition")
@export var transition_time: float = 0.2
#endregion

#region Runtime State
var _bone_attachments: Dictionary = {}  # bone_name -> BoneAttachment3D
var _holstered_weapons: Dictionary = {}  # slot_name -> weapon_node
var _slot_bone_map: Dictionary = {}
var _slot_offset_map: Dictionary = {}
var _slot_rotation_map: Dictionary = {}

var _transitioning_weapons: Array = []  # Weapons currently in transition
#endregion

func _ready():
	# Find skeleton if not set
	if not skeleton:
		skeleton = _find_skeleton(get_parent())
	
	if not skeleton:
		push_warning("[HolsterSystem] No skeleton found - holstering disabled")
		return
	
	# Build slot maps
	_build_slot_maps()
	
	# Create bone attachments for each slot
	_create_bone_attachments()

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

func _build_slot_maps():
	# Map slot names to bones
	_slot_bone_map = {
		"back_primary": back_primary_bone,
		"back_secondary": back_secondary_bone,
		"back_lower": back_lower_bone,
		"hip_right": hip_right_bone,
		"hip_left": hip_left_bone,
		"thigh_right": thigh_right_bone,
		"thigh_left": thigh_left_bone,
		"chest": chest_bone
	}
	
	# Map slot names to position offsets
	_slot_offset_map = {
		"back_primary": back_primary_offset,
		"back_secondary": back_secondary_offset,
		"back_lower": back_secondary_offset,
		"hip_right": hip_right_offset,
		"hip_left": hip_left_offset,
		"thigh_right": thigh_right_offset,
		"thigh_left": thigh_left_offset,
		"chest": Vector3(0, 0.1, 0.1)
	}
	
	# Map slot names to rotation offsets
	_slot_rotation_map = {
		"back_primary": back_primary_rotation,
		"back_secondary": back_secondary_rotation,
		"back_lower": back_secondary_rotation,
		"hip_right": hip_right_rotation,
		"hip_left": hip_left_rotation,
		"thigh_right": thigh_right_rotation,
		"thigh_left": thigh_left_rotation,
		"chest": Vector3(90, 0, 0)
	}

func _create_bone_attachments():
	if not skeleton:
		return
	
	for slot_name in _slot_bone_map:
		var bone_name = _slot_bone_map[slot_name]
		var bone_idx = skeleton.find_bone(bone_name)
		
		if bone_idx < 0:
			push_warning("[HolsterSystem] Bone not found: ", bone_name, " for slot: ", slot_name)
			continue
		
		# Check if we already have an attachment for this bone
		if _bone_attachments.has(bone_name):
			continue
		
		# Create bone attachment
		var attachment = BoneAttachment3D.new()
		attachment.name = "HolsterAttach_" + bone_name.replace(".", "_")
		attachment.bone_name = bone_name
		skeleton.add_child(attachment)
		
		_bone_attachments[bone_name] = attachment

#region Holster Operations
func holster_weapon(weapon: Node3D, slot: String = ""):
	## Attach weapon to a holster slot
	
	# Determine best slot if not specified
	if slot.is_empty():
		slot = _get_best_slot_for_weapon(weapon)
	
	# Remove any existing weapon in this slot first
	if _holstered_weapons.has(slot):
		var old_weapon = _holstered_weapons[slot]
		if is_instance_valid(old_weapon) and old_weapon != weapon:
			# Remove from parent but don't free - equipment manager handles that
			if old_weapon.get_parent():
				old_weapon.get_parent().remove_child(old_weapon)
			old_weapon.visible = false
		_holstered_weapons.erase(slot)
	
	# Try using visual config first (recommended method)
	if attachment_config and attachment_config.has_method("has_slot_config") and attachment_config.has_slot_config(slot):
		_holster_using_config(weapon, slot)
		return
	
	# Fall back to bone attachment method
	if not skeleton:
		weapon.visible = false
		return
	
	if not _slot_bone_map.has(slot):
		push_error("[HolsterSystem] Invalid holster slot: ", slot)
		weapon.visible = false
		return
	
	var bone_name = _slot_bone_map[slot]
	var attachment = _bone_attachments.get(bone_name)
	
	if not attachment:
		push_error("[HolsterSystem] No attachment for bone: ", bone_name)
		weapon.visible = false
		return
	
	# Reparent weapon to attachment
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	attachment.add_child(weapon)
	
	# Apply offset and rotation
	weapon.position = _slot_offset_map.get(slot, Vector3.ZERO)
	weapon.rotation_degrees = _slot_rotation_map.get(slot, Vector3.ZERO)
	weapon.visible = true
	
	_holstered_weapons[slot] = weapon
	weapon_holstered.emit(weapon, slot)

func _holster_using_config(weapon: Node3D, slot: String):
	## Holster using the visual WeaponAttachmentConfig
	## Marker = where weapon should be on body. Weapon is placed at marker's position.
	var marker: Marker3D = null
	var bone_name: String = ""
	match slot:
		"back_primary": 
			marker = attachment_config.back_primary_point
			bone_name = back_primary_bone
		"back_secondary": 
			marker = attachment_config.back_secondary_point
			bone_name = back_secondary_bone
		"hip_right": 
			marker = attachment_config.hip_right_point
			bone_name = hip_right_bone
		"hip_left": 
			marker = attachment_config.hip_left_point
			bone_name = hip_left_bone
		"thigh_right": 
			marker = attachment_config.thigh_right_point
			bone_name = thigh_right_bone
		"thigh_left": 
			marker = attachment_config.thigh_left_point
			bone_name = thigh_left_bone
	
	if not marker:
		push_error("[HolsterSystem] No marker for slot: ", slot)
		weapon.visible = false
		return
	
	# Get or create bone attachment for this slot
	var attachment = _bone_attachments.get(bone_name)
	if not attachment and skeleton:
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx >= 0:
			attachment = BoneAttachment3D.new()
			attachment.name = "HolsterAttach_" + slot
			attachment.bone_name = bone_name
			skeleton.add_child(attachment)
			_bone_attachments[bone_name] = attachment
	
	if not attachment:
		push_error("[HolsterSystem] No bone attachment for: ", bone_name)
		weapon.visible = false
		return
	
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	# Attach to bone attachment
	attachment.add_child(weapon)
	
	# Calculate marker's transform relative to the bone attachment
	var marker_global = marker.global_transform
	var bone_global = attachment.global_transform
	var relative_transform = bone_global.affine_inverse() * marker_global
	
	# Apply this relative transform to the weapon
	weapon.transform = relative_transform
	weapon.visible = true
	
	_holstered_weapons[slot] = weapon
	weapon_holstered.emit(weapon, slot)

func draw_weapon(weapon: Node3D):
	## Remove weapon from holster (for hand attachment by IK)
	# Find which slot this weapon is in
	var found_slot = ""
	for slot in _holstered_weapons:
		if _holstered_weapons[slot] == weapon:
			found_slot = slot
			break
	
	if found_slot.is_empty():
		return
	
	_holstered_weapons.erase(found_slot)
	
	# Weapon will be reparented by WeaponIKController
	# Just emit signal for now
	weapon_drawn.emit(weapon)

func get_holster_slot(weapon: Node3D) -> String:
	for slot in _holstered_weapons:
		if _holstered_weapons[slot] == weapon:
			return slot
	return ""

func is_slot_occupied(slot: String) -> bool:
	return _holstered_weapons.has(slot)

func get_weapon_in_slot(slot: String) -> Node3D:
	return _holstered_weapons.get(slot, null)

func remove_weapon(weapon: Node3D):
	## Remove a weapon from whatever holster slot it's in
	var found_slot = ""
	for slot in _holstered_weapons:
		if _holstered_weapons[slot] == weapon:
			found_slot = slot
			break
	
	if found_slot.is_empty():
		return
	
	if is_instance_valid(weapon) and weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	
	_holstered_weapons.erase(found_slot)
	print("[HolsterSystem] Removed weapon from slot: ", found_slot)

func _get_best_slot_for_weapon(weapon: Node3D) -> String:
	## Determine best holster slot based on weapon size
	var size = "medium"
	
	# Try to get size from weapon component
	if weapon is WeaponComponent:
		size = "large"  # Rifles are large
	elif weapon.has_method("get_size"):
		size = weapon.get_size()
	
	# Get slots for this size from database or use defaults
	var slots_for_size = _get_slots_for_size(size)
	
	# Find first unoccupied slot
	for slot in slots_for_size:
		if not is_slot_occupied(slot):
			return slot
	
	# All slots full, return first slot (will replace)
	return slots_for_size[0] if slots_for_size.size() > 0 else "back_primary"

func _get_slots_for_size(size: String) -> Array:
	match size:
		"large":
			return ["back_primary", "back_secondary"]
		"medium":
			return ["hip_right", "hip_left", "back_lower"]
		"small":
			return ["thigh_right", "thigh_left", "chest"]
		_:
			return ["back_primary"]
#endregion

#region Smooth Transitions
func transition_weapon(weapon: Node3D, from_slot: String, to_transform: Transform3D, duration: float = -1):
	## Smoothly move weapon from holster to target position (e.g., to hand)
	if duration < 0:
		duration = transition_time
	
	transition_started.emit(weapon, from_slot, "hand")
	
	# Remove from holster tracking
	if _holstered_weapons.has(from_slot):
		_holstered_weapons.erase(from_slot)
	
	# Reparent to scene root for transition
	var start_transform = weapon.global_transform
	if weapon.get_parent():
		weapon.get_parent().remove_child(weapon)
	get_tree().current_scene.add_child(weapon)
	weapon.global_transform = start_transform
	
	# Animate transition
	var tween = create_tween()
	tween.tween_property(weapon, "global_transform", to_transform, duration)
	tween.tween_callback(_on_transition_complete.bind(weapon))
	
	_transitioning_weapons.append(weapon)

func _on_transition_complete(weapon: Node3D):
	_transitioning_weapons.erase(weapon)
	transition_completed.emit(weapon)
#endregion

#region Slot Information
func get_slot_transform(slot: String) -> Transform3D:
	## Get the world transform for a holster slot
	if not _slot_bone_map.has(slot):
		return Transform3D.IDENTITY
	
	var bone_name = _slot_bone_map[slot]
	var attachment = _bone_attachments.get(bone_name)
	
	if not attachment:
		return Transform3D.IDENTITY
	
	var offset = _slot_offset_map.get(slot, Vector3.ZERO)
	var rotation = _slot_rotation_map.get(slot, Vector3.ZERO)
	
	var rotation_rad = Vector3(deg_to_rad(rotation.x), deg_to_rad(rotation.y), deg_to_rad(rotation.z))
	var local_transform = Transform3D(
		Basis.from_euler(rotation_rad),
		offset
	)
	
	return attachment.global_transform * local_transform

func get_available_slots() -> Array[String]:
	var available: Array[String] = []
	for slot in _slot_bone_map:
		if not is_slot_occupied(slot):
			available.append(slot)
	return available

func get_all_slots() -> Array[String]:
	var slots: Array[String] = []
	for slot in _slot_bone_map:
		slots.append(slot)
	return slots
#endregion

