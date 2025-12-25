@tool
extends Node3D
class_name WeaponAttachmentConfig

## Visual editor tool for configuring weapon attachment points
## Add this as a child of your player scene and position the markers in the editor.
## The markers show WHERE weapons will be positioned - rotate them to orient the weapon.
## At runtime, these transforms are applied to bone attachments.
##
## RED CONE on preview = barrel direction (where weapon points)

#region Hand Grip Configuration
@export_group("Held Weapon (Right Hand)")
## Marker showing where weapon is held - position and rotate to orient weapon in hand
@export var hand_grip_point: Marker3D

@export var show_hand_preview: bool = true:
	set(v):
		show_hand_preview = v
		_update_preview_visibility("hand", v)
#endregion

#region Holster Slot Configuration  
@export_group("Back Primary (Rifle)")
## Marker for rifle holster on back - barrel direction shown by red cone
@export var back_primary_point: Marker3D

@export var show_back_primary_preview: bool = true:
	set(v):
		show_back_primary_preview = v
		_update_preview_visibility("back_primary", v)

@export_group("Back Secondary")
@export var back_secondary_point: Marker3D

@export var show_back_secondary_preview: bool = true:
	set(v):
		show_back_secondary_preview = v
		_update_preview_visibility("back_secondary", v)

@export_group("Hip Right (Pistol)")
@export var hip_right_point: Marker3D

@export var show_hip_right_preview: bool = true:
	set(v):
		show_hip_right_preview = v
		_update_preview_visibility("hip_right", v)

@export_group("Hip Left")
@export var hip_left_point: Marker3D

@export var show_hip_left_preview: bool = true:
	set(v):
		show_hip_left_preview = v
		_update_preview_visibility("hip_left", v)

@export_group("Thigh Right")
@export var thigh_right_point: Marker3D

@export var show_thigh_right_preview: bool = true:
	set(v):
		show_thigh_right_preview = v
		_update_preview_visibility("thigh_right", v)

@export_group("Thigh Left")
@export var thigh_left_point: Marker3D

@export var show_thigh_left_preview: bool = true:
	set(v):
		show_thigh_left_preview = v
		_update_preview_visibility("thigh_left", v)
#endregion

#region Preview Settings
@export_group("Preview Weapons (Optional)")
## Custom rifle preview scene - if not set, uses simple box
@export var rifle_preview_scene: PackedScene
## Custom pistol preview scene - if not set, uses simple box  
@export var pistol_preview_scene: PackedScene

@export_group("Preview Colors")
@export var hand_preview_color: Color = Color(0.2, 0.8, 0.2, 0.6)
@export var holster_preview_color: Color = Color(0.2, 0.2, 0.8, 0.6)

@export_group("Actions")
@export var refresh_previews: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			_setup_all_previews()
#endregion

#region Runtime
var _preview_meshes: Dictionary = {}
var _slot_markers: Dictionary = {}
var _slot_types: Dictionary = {
	"hand": "rifle",
	"back_primary": "rifle", 
	"back_secondary": "rifle",
	"hip_right": "pistol",
	"hip_left": "pistol",
	"thigh_right": "pistol",
	"thigh_left": "pistol"
}
#endregion

func _ready():
	_cache_markers()
	if Engine.is_editor_hint():
		_setup_all_previews()

func _cache_markers():
	_slot_markers = {
		"hand": hand_grip_point,
		"back_primary": back_primary_point,
		"back_secondary": back_secondary_point,
		"hip_right": hip_right_point,
		"hip_left": hip_left_point,
		"thigh_right": thigh_right_point,
		"thigh_left": thigh_left_point
	}

func _setup_all_previews():
	_cache_markers()
	for slot in _slot_markers:
		var marker = _slot_markers[slot]
		if marker:
			var show = _get_show_preview(slot)
			_create_preview_for_marker(slot, marker, show)

func _get_show_preview(slot: String) -> bool:
	match slot:
		"hand": return show_hand_preview
		"back_primary": return show_back_primary_preview
		"back_secondary": return show_back_secondary_preview
		"hip_right": return show_hip_right_preview
		"hip_left": return show_hip_left_preview
		"thigh_right": return show_thigh_right_preview
		"thigh_left": return show_thigh_left_preview
	return true

func _create_preview_for_marker(slot: String, marker: Marker3D, visible: bool):
	if not marker:
		return
	
	# Remove existing preview
	if _preview_meshes.has(slot) and is_instance_valid(_preview_meshes[slot]):
		_preview_meshes[slot].queue_free()
	
	var weapon_type = _slot_types.get(slot, "rifle")
	var preview: Node3D = null
	
	# Try custom scene first
	if weapon_type == "rifle" and rifle_preview_scene:
		preview = rifle_preview_scene.instantiate()
	elif weapon_type == "pistol" and pistol_preview_scene:
		preview = pistol_preview_scene.instantiate()
	else:
		preview = _create_simple_preview(weapon_type, slot)
	
	if preview:
		# Check if marker already has a preview child
		for child in marker.get_children():
			if child.name.begins_with("Preview_"):
				child.queue_free()
		
		marker.add_child(preview)
		preview.position = Vector3.ZERO
		preview.rotation = Vector3.ZERO
		preview.visible = visible
		_preview_meshes[slot] = preview

func _create_simple_preview(weapon_type: String, slot: String) -> Node3D:
	var container = Node3D.new()
	container.name = "Preview_" + slot
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "WeaponShape"
	
	var box = BoxMesh.new()
	if weapon_type == "rifle":
		box.size = Vector3(0.06, 0.12, 0.7)  # Rifle shape
	else:
		box.size = Vector3(0.03, 0.1, 0.15)  # Pistol shape
	
	mesh_instance.mesh = box
	
	# Transparent material
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if slot == "hand":
		mat.albedo_color = hand_preview_color
	else:
		mat.albedo_color = holster_preview_color
	mesh_instance.material_override = mat
	container.add_child(mesh_instance)
	
	# Barrel direction indicator (red cone pointing -Z)
	var barrel = MeshInstance3D.new()
	barrel.name = "BarrelIndicator"
	var cone = CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.025
	cone.height = 0.12
	barrel.mesh = cone
	barrel.rotation_degrees = Vector3(90, 0, 0)  # Point along -Z
	
	if weapon_type == "rifle":
		barrel.position = Vector3(0, 0, -0.4)
	else:
		barrel.position = Vector3(0, 0, -0.1)
	
	var cone_mat = StandardMaterial3D.new()
	cone_mat.albedo_color = Color.RED
	barrel.material_override = cone_mat
	container.add_child(barrel)
	
	# Grip indicator (green sphere showing where hand grabs)
	var grip = MeshInstance3D.new()
	grip.name = "GripIndicator"
	var sphere = SphereMesh.new()
	sphere.radius = 0.02
	sphere.height = 0.04
	grip.mesh = sphere
	
	if weapon_type == "rifle":
		grip.position = Vector3(0, -0.04, 0.15)  # Near stock
	else:
		grip.position = Vector3(0, -0.03, 0.04)  # Pistol grip
	
	var grip_mat = StandardMaterial3D.new()
	grip_mat.albedo_color = Color.GREEN
	grip.material_override = grip_mat
	container.add_child(grip)
	
	return container

func _update_preview_visibility(slot: String, visible: bool):
	if _preview_meshes.has(slot) and is_instance_valid(_preview_meshes[slot]):
		_preview_meshes[slot].visible = visible

#region Getters for Runtime Systems
func get_hand_transform() -> Transform3D:
	if hand_grip_point:
		return hand_grip_point.global_transform
	return Transform3D.IDENTITY

func get_slot_transform(slot: String) -> Transform3D:
	_cache_markers()
	if _slot_markers.has(slot) and _slot_markers[slot]:
		return _slot_markers[slot].global_transform
	return Transform3D.IDENTITY

func get_slot_marker(slot: String) -> Marker3D:
	_cache_markers()
	return _slot_markers.get(slot, null)

func has_slot_config(slot: String) -> bool:
	_cache_markers()
	return _slot_markers.has(slot) and _slot_markers[slot] != null

func has_hand_config() -> bool:
	return hand_grip_point != null
#endregion
