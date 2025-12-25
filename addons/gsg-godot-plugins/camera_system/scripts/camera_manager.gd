extends Node

## Singleton that manages all cameras in the scene
## Handles camera registration, switching, and special camera modes

var all_cameras: Array[BaseCamera] = []
var active_camera: BaseCamera = null
var previous_camera: BaseCamera = null
var free_camera: FreeCamera = null

var npc_camera: Node = null  # Will be created at runtime
var active_zones: Array[MultimediaZone] = []  # Zones player is currently in

signal camera_switched(new_camera: BaseCamera)

func _ready():
	# Create NPC dialogue camera at runtime
	pass

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("freecam"):
		toggle_free_camera()

func toggle_free_camera() -> void:
	if is_instance_valid(active_camera) and active_camera is FreeCamera:
		# Switch back from free camera
		if previous_camera and is_instance_valid(previous_camera):
			switch_to_camera(previous_camera)
		else:
			# Fallback to zone-based evaluation
			_evaluate_active_camera()
			
		# Re-enable player control
		if GameManager.player:
			GameManager.player.set_physics_process(true)
			GameManager.player.set_process_unhandled_input(true)
	else:
		# Switch to free camera
		if not free_camera:
			free_camera = FreeCamera.new()
			add_child(free_camera)
		
		# Always adopt settings from current camera when entering freecam
		if is_instance_valid(active_camera):
			free_camera.global_transform = active_camera.global_transform
			free_camera.fov = active_camera.fov
			# Reset freecam state
			free_camera.yaw = active_camera.rotation.y
			free_camera.pitch = active_camera.rotation.x
			free_camera.desired_position = active_camera.global_position
			free_camera.zoom_amount = 0.0
			
		switch_to_camera(free_camera)
		
		# Disable player control
		if GameManager.player:
			GameManager.player.set_physics_process(false)
			GameManager.player.set_process_unhandled_input(false)

## Register a camera (called automatically by BaseCamera)
func register_camera(camera: BaseCamera) -> void:
	if camera not in all_cameras:
		all_cameras.append(camera)

## Unregister a camera
func unregister_camera(camera: BaseCamera) -> void:
	all_cameras.erase(camera)

## Switch to a specific camera
func switch_to_camera(camera: BaseCamera) -> void:
	# Clear freed camera references
	if not is_instance_valid(active_camera):
		active_camera = null
	if not is_instance_valid(previous_camera):
		previous_camera = null
	
	if active_camera == camera:
		return
	
	previous_camera = active_camera
	
	# Disable previous camera
	if active_camera and is_instance_valid(active_camera):
		active_camera.enabled = false
	
	# Enable new camera
	active_camera = camera
	active_camera.enabled = true
	active_camera.make_current()
	
	camera_switched.emit(camera)

## Return to previous camera
func restore_previous_camera() -> void:
	if is_instance_valid(previous_camera):
		switch_to_camera(previous_camera)

## Register a zone (called when player enters)
func register_zone(zone: MultimediaZone) -> void:
	if zone not in active_zones:
		active_zones.append(zone)
		_evaluate_active_camera()

## Unregister a zone (called when player exits)
func unregister_zone(zone: MultimediaZone) -> void:
	active_zones.erase(zone)
	_evaluate_active_camera()

## Determine which camera should be active based on zone priority
func _evaluate_active_camera() -> void:
	if is_instance_valid(active_camera) and active_camera is FreeCamera:
		return

	if active_zones.is_empty():
		return
	
	# Sort zones by priority (highest first)
	var sorted_zones = active_zones.duplicate()
	sorted_zones.sort_custom(func(a, b): return a.prio > b.prio)
	
	var highest_priority_zone = sorted_zones[0]
	
	# Get camera from that zone
	var camera_to_use: BaseCamera = null
	if highest_priority_zone.camera_to_activate:
		camera_to_use = highest_priority_zone.camera_to_activate
	elif highest_priority_zone.auto_generated_camera:
		camera_to_use = highest_priority_zone.auto_generated_camera
	
	if camera_to_use:
		switch_to_camera(camera_to_use)
	else:
		print("[CameraManager] ERROR: No camera found for zone: ", highest_priority_zone.name)

## Get camera by name
func get_camera_by_name(camera_name: String) -> BaseCamera:
	for camera in all_cameras:
		if camera.name == camera_name:
			return camera
	return null

## Activate NPC dialogue camera
func start_dialogue_camera(npc: Node3D, nearby_npcs: Array = []) -> void:
	if npc_camera and npc_camera.has_method("start_dialogue"):
		npc_camera.start_dialogue(npc, nearby_npcs)

## Deactivate NPC dialogue camera
func end_dialogue_camera() -> void:
	if npc_camera and npc_camera.has_method("end_dialogue"):
		npc_camera.end_dialogue()
