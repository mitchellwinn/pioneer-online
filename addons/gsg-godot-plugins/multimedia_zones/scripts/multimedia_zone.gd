extends Area3D
class_name MultimediaZone

## Defines an area where camera and music behavior can change
## Higher priority zones override lower priority ones when overlapping

@export var prio: int = 0 ## Higher priority zones take precedence
@export var follow_target: Node3D ## What the camera should follow (defaults to player)
@export var camera_to_activate: BaseCamera ## Optional: pre-made camera (needed for look_only fixed cameras)

@export_group("Music Settings")
@export var music_track: String = "" ## Music track key from songs.json to play in this zone
@export var fade_duration: float = 6.0 ## Duration for music crossfade transitions (longer = smoother blend)
@export var stem_volumes: Dictionary = {} ## Optional: Override volumes for specific stems (stem_name -> volume_db)

@export_group("Auto Camera Settings")
## If camera_to_activate is null, a camera will be auto-generated with these settings
@export_enum("Follow", "ThirdPerson") var camera_type: String = "Follow" ## Camera type to auto-generate
@export var distance: float = 10.0 ## Distance from target
@export var vantage_angle: float = -35.0 ## Vertical viewing angle
@export var height_offset: float = 0.0 ## Additional height offset (negative = lower)
@export var side_offset: float = 0.0 ## Horizontal offset from center
@export var camera_fov: float = 70.0 ## Field of view
@export var constrain_angles: bool = false ## Enable 180-degree rule
@export var max_yaw: float = 90.0 ## Max horizontal angle
@export var max_pitch: float = 45.0 ## Max vertical angle up
@export var min_pitch: float = -45.0 ## Min vertical angle down
@export var use_deadzone: bool = false ## Enable camera deadzone
@export var deadzone_width: float = 2.0 ## Horizontal deadzone size
@export var deadzone_height: float = 1.5 ## Vertical deadzone size
@export var deadzone_depth: float = 3.0 ## Depth deadzone size (forward/back)
@export var deadzone_gradient: float = 1.0 ## Transition zone radius for smooth blend

var auto_generated_camera: BaseCamera = null
var is_occupied: bool = false ## Is player currently in this zone

func _ready():
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	# Hide the zone visualizer at runtime (only visible in editor)
	if not Engine.is_editor_hint():
		for child in get_children():
			if child is CSGBox3D:
				child.visible = false
	
	# Auto-generate camera if none provided
	if not camera_to_activate:
		await _generate_camera()

func _on_body_entered(body: Node3D) -> void:
	if body == GameManager.player:
		is_occupied = true
		
		# Register this zone with CameraManager for priority evaluation
		if CameraManager:
			CameraManager.register_zone(self)
		
		# Register this zone with MusicManager for music playback
		if MusicManager and not music_track.is_empty():
			MusicManager.register_zone(self)

func _on_body_exited(body: Node3D) -> void:
	if body == GameManager.player:
		is_occupied = false
		
		# Unregister this zone from CameraManager
		if CameraManager:
			CameraManager.unregister_zone(self)
		
		# Unregister this zone from MusicManager
		if MusicManager and not music_track.is_empty():
			MusicManager.unregister_zone(self)

func _generate_camera() -> void:
	# Wait for player to spawn if it doesn't exist yet
	if not follow_target and not GameManager.player:
		await GameManager.player_spawned
	
	# Create camera based on type
	if camera_type == "ThirdPerson":
		auto_generated_camera = ThirdPersonCamera.new()
	else: # Default to Follow
		auto_generated_camera = FollowCamera.new()
	
	auto_generated_camera.name = name + "_AutoCamera"
	auto_generated_camera.enabled = true # Enable camera processing
	auto_generated_camera.is_prebuilt = false  # Mark as auto-generated
	
	# Apply common settings from zone
	auto_generated_camera.distance = distance
	auto_generated_camera.height_offset = height_offset
	auto_generated_camera.side_offset = side_offset
	auto_generated_camera.camera_fov = camera_fov
	
	# Apply follow-camera specific settings
	if auto_generated_camera is FollowCamera:
		auto_generated_camera.vantage_angle = vantage_angle
		auto_generated_camera.constrain_look_angles = constrain_angles
		auto_generated_camera.max_yaw_angle = max_yaw
		auto_generated_camera.max_pitch_angle = max_pitch
		auto_generated_camera.min_pitch_angle = min_pitch
		auto_generated_camera.use_deadzone = use_deadzone
		auto_generated_camera.deadzone_width = deadzone_width
		auto_generated_camera.deadzone_height = deadzone_height
		auto_generated_camera.deadzone_depth = deadzone_depth
		auto_generated_camera.deadzone_gradient = deadzone_gradient

	# Set follow target (defaults to player if not specified)
	if follow_target:
		auto_generated_camera.follow_target = follow_target
	else:
		auto_generated_camera.follow_target = GameManager.player
	
	# Add as child of this zone
	add_child(auto_generated_camera)
	
	# Position camera at player location initially
	if auto_generated_camera.follow_target:
		auto_generated_camera.global_position = auto_generated_camera.follow_target.global_position
	
	
	# If player is already in this zone, make camera current
	if is_occupied:
		auto_generated_camera.make_current()



