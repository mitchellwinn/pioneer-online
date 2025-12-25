extends "res://addons/gsg-godot-plugins/action_entities/scripts/action_entity.gd"
class_name ActionPlayer

## ActionPlayer - Player-controlled entity with input handling and camera integration

signal aim_direction_changed(direction: Vector3)
signal player_died()
signal player_respawned()

#region Configuration
@export_group("Camera")
@export var player_camera: Node3D  # PlayerCamera - untyped to avoid circular dependency
@export var use_camera_relative_movement: bool = true

@export_group("Input")
## Internal flag for whether this player can receive input (network authority)
## Default to FALSE for safety - set to TRUE only when confirmed as local player
var _can_receive_input_base: bool = false
## Property that checks both authority AND window focus
var can_receive_input: bool:
	get:
		# Must have authority AND window must be focused
		return _can_receive_input_base and DisplayServer.window_is_focused()
	set(value):
		_can_receive_input_base = value

@export_group("Controller Look")
@export var controller_sensitivity: float = 2.0

@export_group("Body Rotation")
## How fast body smoothly rotates to face camera direction
@export var body_rotation_speed: float = 12.0
## If true, body snaps instantly to camera. If false, smoothly lerps.
@export var instant_body_rotation: bool = true  # Instant rotation feels better
#endregion

#region Runtime State
var input_direction: Vector3 = Vector3.ZERO
var aim_direction: Vector3 = Vector3.FORWARD
var is_aiming: bool = false

# Local player flag - persistent, not affected by hitlag disabling input
var _is_local: bool = false

# Player identity (for database queries)
var steam_id: int = 0
var character_id: int = 0

# Squad reference for spectating
var squad_members: Array[Node3D] = []

# Interaction
var nearby_interactables: Array[Node] = []
var current_interaction_target: Node = null

# Zone permissions (e.g., combat disabled in hub)
var zone_permissions: Dictionary = {
	"combat": true,
	"jumping": true,
	"dodging": true,
	"sprinting": true,
	"pvp": false
}

#region Encumbrance System
## Maximum weight before heavy penalties (kg)
@export var max_carry_weight: float = 25.0
## Current encumbrance (0.0 = no penalty, 1.0 = max penalty at max weight)
var current_encumbrance: float = 0.0
## Cached total weight of equipped weapons
var _total_equipped_weight: float = 0.0
#endregion

# Legacy combat_enabled (for backwards compatibility)
var combat_enabled: bool:
	get: return zone_permissions.get("combat", true)
	set(value):
		zone_permissions["combat"] = value
		_set_combat_enabled_internal(value)

# Remote player interpolation (for other players on this client)
var _is_remote_player: bool = false
var _received_first_state: bool = false
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: Vector3 = Vector3.ZERO
var _interpolation_speed: float = 12.0 # Smoother interpolation
var _snap_distance: float = 5.0 # Snap if really far away (teleport)

# State sync (local player -> server)
var _state_sync_timer: float = 0.0
var _state_sync_rate: float = 20.0 # Send state 20 times per second

# Synced camera angles for remote player IK
var synced_camera_yaw: float = 0.0
var synced_camera_pitch: float = 0.0
#endregion

func _ready():
	super._ready()

	# Always add to players group (for NPC interaction detection, music zones, etc.)
	add_to_group("players")

	# Check if this is the local player
	_setup_local_authority()
	
	# Setup camera only for local player
	if can_receive_input:
		if not player_camera:
			player_camera = get_node_or_null("PlayerCamera")
		
		if player_camera:
			player_camera.set_target(self)
		
		# Setup inventory input action (Tab key)
		_ensure_inventory_action()
		# Setup dash input action (Alt key)
		_ensure_dash_action()
	else:
		# Disable camera for remote players
		var cam = get_node_or_null("PlayerCamera")
		if cam:
			cam.queue_free()
	
	# Connect to state changes for reconciliation grace period
	if state_manager and state_manager.has_signal("state_changed"):
		if not state_manager.state_changed.is_connected(_on_state_changed_for_reconcile):
			state_manager.state_changed.connect(_on_state_changed_for_reconcile)
	
	# Connect to death (check if not already connected)
	if combat and not combat.died.is_connected(_on_died):
		combat.died.connect(_on_died)

func _setup_local_authority():
	# Determine if this is the local player based on network identity
	var local_id = 1 # Default for server/solo
	var has_multiplayer = multiplayer and multiplayer.has_multiplayer_peer()
	
	if has_multiplayer:
		local_id = multiplayer.get_unique_id()
	
	if network_identity:
		# Check if this player belongs to us
		var owner_id = network_identity.owner_peer_id
		
		# We control this player if:
		# 1. owner_peer_id matches our local_id
		# 2. OR owner_peer_id is 0/1 and we're the server (peer_id 1)
		# 3. OR no multiplayer peer (solo mode)
		if not has_multiplayer:
			# Solo mode - always control
			can_receive_input = true
			_is_local = true
		elif owner_id == local_id:
			# Our player
			can_receive_input = true
			_is_local = true
		elif owner_id <= 1 and local_id == 1:
			# Server's player and we are the server
			can_receive_input = true
			_is_local = true
		else:
			# Remote player - do NOT control
			can_receive_input = false
			_is_local = false
			_is_remote_player = true
		
		print("[ActionPlayer] Authority - Owner: ", owner_id, " Local: ", local_id,
			  " HasMP: ", has_multiplayer, " CanInput: ", can_receive_input)
	else:
		# No network identity - check if we're in multiplayer mode
		if has_multiplayer:
			# In multiplayer but no NetworkIdentity - this is an error, disable input
			can_receive_input = false
			_is_local = false
			_is_remote_player = true  # Also mark as remote to prevent local state processing
			push_warning("[ActionPlayer] In multiplayer mode but no NetworkIdentity found - disabling input")
		else:
			# Solo mode - assume local control
			can_receive_input = true
			_is_local = true
		print("[ActionPlayer] NetworkIdentity: ", network_identity, " HasMP: ", has_multiplayer, " CanInput: ", can_receive_input)

## Inventory panel reference
var inventory_panel: Control = null
## Player list UI reference
var player_list_ui: Control = null

func _input(event: InputEvent):
	# Skip input if window doesn't have focus (prevents input bleeding between test windows)
	if not DisplayServer.window_is_focused():
		return

	# Escape key handling
	if event.is_action_pressed("ui_cancel"):
		# If in dialogue, let the talking state handle it
		if _is_in_dialogue():
			return
		# Close inventory if open first
		if inventory_panel and inventory_panel.visible:
			inventory_panel.close()
			return
		# Toggle player list (ESC opens it, pressing again closes)
		if player_list_ui and player_list_ui.visible:
			player_list_ui.close()
			return
		else:
			_toggle_player_list()
			return
	
	# Inventory toggle (Tab) - allow even when input disabled for closing
	if event.is_action_pressed("inventory"):
		if inventory_panel and inventory_panel.visible:
			inventory_panel.close()
		elif can_receive_input:
			_toggle_inventory()
		return
	
	# Click to recapture mouse (but NOT if any UI is open)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if player_camera and not player_camera.is_mouse_captured():
			# Don't recapture if input is disabled (shop, bank, or other UI open)
			if not can_receive_input:
				return
			# Don't recapture if inventory is open
			if inventory_panel and inventory_panel.visible:
				return
			# Don't recapture if player list is open
			if player_list_ui and player_list_ui.visible:
				return
			# Don't recapture if in dialogue (talking state)
			if _is_in_dialogue():
				return
			player_camera.set_mouse_captured(true)
			return
	
	if not can_receive_input:
		return
	
	# Interact with nearby NPC/object
	if event.is_action_pressed("interact"):
		_try_interact()

func _process(delta: float):
	if not can_receive_input:
		return

	# Controller look (camera handles mouse look internally)
	_handle_controller_look(delta)

	# Update aim state
	var was_aiming = is_aiming
	is_aiming = Input.is_action_pressed("aim") if InputMap.has_action("aim") else false
	
	# Notify weapon attachment about aim state change
	if was_aiming != is_aiming:
		_notify_weapon_aim_state(is_aiming)
	
	# Update weapon camera tracking
	_update_weapon_camera_tracking()

func _update_weapon_camera_tracking():
	## Make weapon track camera direction
	if not player_camera:
		return
	
	var attachment = get_node_or_null("WeaponAttachmentSetup")
	if not attachment or not attachment.has_method("set_camera_yaw"):
		return
	
	# Calculate how much camera yaw differs from character rotation
	var camera_yaw = player_camera.yaw
	var char_yaw = rotation.y
	var yaw_diff = camera_yaw - char_yaw
	
	# Normalize to -PI to PI
	while yaw_diff > PI:
		yaw_diff -= TAU
	while yaw_diff < -PI:
		yaw_diff += TAU
	
	attachment.set_camera_yaw(yaw_diff)

func _physics_process(delta: float):
	if can_receive_input and not is_dead():
		_update_input()
		_process_dash_input()  # Check for double-tap dash
		# Local player uses normal physics
		super._physics_process(delta)
		# Send input to server for authoritative processing
		_send_input_to_server(delta)
	elif _is_remote_player and _received_first_state:
		# Remote player: ONLY interpolate, skip physics/move_and_slide
		# This prevents fighting between interpolation and velocity-based movement
		global_position = global_position.lerp(_target_position, _interpolation_speed * delta)
		rotation.y = lerp_angle(rotation.y, _target_rotation.y, _interpolation_speed * delta)
		# Don't call super - we don't want move_and_slide for remote players
	else:
		# Server-side player entity OR dead local player
		# Server runs physics based on received inputs (input_direction set by apply_network_input)
		super._physics_process(delta)

func _send_input_to_server(delta: float):
	_state_sync_timer += delta
	if _state_sync_timer < 1.0 / _state_sync_rate:
		return
	_state_sync_timer = 0.0
	
	# Don't send if we're the server (we already have the state)
	var network = get_node_or_null("/root/NetworkManager")
	if not network or network.is_server:
		return
	
	# Build input packet - CLIENT AUTHORITATIVE: include position/velocity
	var input_data = {
		"move_x": input_direction.x,
		"move_z": input_direction.z,
		"rotation_y": rotation.y,
		"speed_multiplier": current_speed_multiplier,
		"state": state_manager.get_current_state_name() if state_manager else "idle",
		"actions": _get_action_bitmask(),
		# Camera angles for IK sync
		"camera_yaw_offset": get_camera_body_offset() if player_camera else 0.0,
		"camera_pitch": player_camera.pitch if player_camera else 0.0,
		# CLIENT AUTHORITATIVE MOVEMENT: send position/velocity for server to trust
		"pos_x": global_position.x,
		"pos_y": global_position.y,
		"pos_z": global_position.z,
		"vel_x": velocity.x,
		"vel_y": velocity.y,
		"vel_z": velocity.z,
		"is_on_floor": is_on_floor()
	}
	
	# Include wall jumps if pending (send ALL buffered wall jumps)
	if _pending_wall_jumps.size() > 0:
		# Send the count and all wall jump data
		input_data["wall_jump_count"] = _pending_wall_jumps.size()
		for i in range(_pending_wall_jumps.size()):
			var wj = _pending_wall_jumps[i]
			input_data["wj_%d_nx" % i] = wj.wall_normal.x
			input_data["wj_%d_ny" % i] = wj.wall_normal.y
			input_data["wj_%d_nz" % i] = wj.wall_normal.z
		print("[ActionPlayer] Sending %d wall jumps to server" % _pending_wall_jumps.size())
		_pending_wall_jumps.clear()
	
	network.send_input(input_data)

func _get_action_bitmask() -> int:
	var actions = 0
	if Input.is_action_pressed("sprint"):
		actions |= 1 << 0
	if Input.is_action_just_pressed("jump"):
		actions |= 1 << 1
	if Input.is_action_just_pressed("dodge"):
		actions |= 1 << 2
	# Bit 11 = wall jump (set when we have pending wall jumps)
	if _pending_wall_jumps.size() > 0:
		actions |= 1 << 11
	return actions

## Buffer of wall jumps waiting to be sent (can have multiple per network tick)
var _pending_wall_jumps: Array[Dictionary] = []

#region Double-Tap Dash Detection
var _last_direction_pressed: String = ""
var _last_direction_time: float = 0.0
var _double_tap_window: float = 0.25  # Time window to register double-tap
var _dash_queued: bool = false
var _dash_queued_direction: Vector2 = Vector2.ZERO  # Direction captured when dash was queued

func _check_double_tap_dash() -> bool:
	## Detect double-tap of movement keys for dash
	## Returns true if dash should be triggered
	var current_time = Time.get_ticks_msec() / 1000.0
	var direction_pressed = ""
	
	# Check which direction was just pressed
	if Input.is_action_just_pressed("move_forward"):
		direction_pressed = "forward"
	elif Input.is_action_just_pressed("move_backward"):
		direction_pressed = "backward"
	elif Input.is_action_just_pressed("move_left"):
		direction_pressed = "left"
	elif Input.is_action_just_pressed("move_right"):
		direction_pressed = "right"
	
	if direction_pressed.is_empty():
		return false
	
	# Check if same direction was pressed recently
	if direction_pressed == _last_direction_pressed:
		if current_time - _last_direction_time <= _double_tap_window:
			# Double-tap detected!
			_last_direction_pressed = ""
			_last_direction_time = 0.0
			return true
	
	# Record this press for next check
	_last_direction_pressed = direction_pressed
	_last_direction_time = current_time
	return false

func _process_dash_input():
	## Check for dash input (double-tap or Alt key)
	if not can_receive_input or is_dead():
		return
	
	# Check Alt key
	if Input.is_action_just_pressed("dash"):
		_dash_queued = true
		_dash_queued_direction = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if _dash_queued_direction.length_squared() < 0.01:
			_dash_queued_direction = Vector2(0, -1)  # Default forward
		return
	
	# Check double-tap
	if _check_double_tap_dash():
		_dash_queued = true
		_dash_queued_direction = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if _dash_queued_direction.length_squared() < 0.01:
			_dash_queued_direction = Vector2(0, -1)  # Default forward

func try_dash() -> bool:
	## Called by states to check if dash was requested
	## Sets _buffered_dash_direction metadata with the direction captured at input time
	if _dash_queued:
		_dash_queued = false
		set_meta("_buffered_dash_direction", _dash_queued_direction)
		_dash_queued_direction = Vector2.ZERO
		return true
	return false
#endregion

func queue_wall_jump_for_sync(wall_normal: Vector3):
	## Called by StateAirborne when performing a wall jump
	## This queues the wall jump data to be sent with the next input packet
	## We buffer multiple wall jumps since physics runs faster than network sends
	_pending_wall_jumps.append({
		"wall_normal": wall_normal,
		"time": Time.get_ticks_msec() / 1000.0
	})
	print("[ActionPlayer] Queued wall jump for sync. Buffer size: %d" % _pending_wall_jumps.size())

func _update_input():
	# Check if actions exist
	if not InputMap.has_action("move_forward"):
		push_warning("[ActionPlayer] move_forward action not found!")
		return

	# Get raw input
	var input_x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var input_z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	
	var raw_input = Vector3(input_x, 0, input_z)
	
	if raw_input.length() > 1.0:
		raw_input = raw_input.normalized()
	
	# Apply camera-relative transformation
	if use_camera_relative_movement and player_camera:
		input_direction = _get_camera_relative_direction(raw_input)
	else:
		input_direction = raw_input
	
	# Player always faces camera direction (allows strafing)
	_face_camera_direction()
	
	# Update aim direction from camera
	_update_aim_direction()

func _face_camera_direction():
	## Make the player smoothly face camera direction (horizontal only)
	if not player_camera:
		return
	
	# Target rotation (camera yaw + 180° because model faces +Z)
	var target_yaw = player_camera.yaw + PI
	
	if instant_body_rotation:
		# Snap instantly to camera
		rotation.y = target_yaw
		return
	
	# Smooth interpolation to face camera direction
	rotation.y = lerp_angle(rotation.y, target_yaw, body_rotation_speed * get_physics_process_delta_time())

func _angle_difference(from_angle: float, to_angle: float) -> float:
	## Returns shortest angular difference between two angles (in radians)
	var diff = fmod(to_angle - from_angle + PI, TAU) - PI
	return diff

func get_camera_body_offset() -> float:
	## Returns how much camera is rotated from body (in radians, for IK)
	if not player_camera:
		return 0.0
	var target_yaw = player_camera.yaw + PI
	return _angle_difference(rotation.y, target_yaw)

func _get_camera_relative_direction(raw_input: Vector3) -> Vector3:
	if not player_camera:
		return raw_input
	
	var camera = player_camera.get_camera()
	if not camera:
		return raw_input
	
	# Get camera's forward and right vectors (flattened to XZ plane)
	var cam_forward = - camera.global_transform.basis.z
	cam_forward.y = 0
	cam_forward = cam_forward.normalized()
	
	var cam_right = camera.global_transform.basis.x
	cam_right.y = 0
	cam_right = cam_right.normalized()
	
	# Transform input to camera space
	return (cam_right * raw_input.x + cam_forward * -raw_input.z).normalized() * raw_input.length()

func _handle_controller_look(delta: float):
	if not player_camera:
		return
	
	# Check if controller look actions exist
	if not InputMap.has_action("camera_rotate_right"):
		return
	
	var look_x = Input.get_action_strength("camera_rotate_right") - Input.get_action_strength("camera_rotate_left")
	var look_y = Input.get_action_strength("camera_rotate_down") - Input.get_action_strength("camera_rotate_up")
	
	if abs(look_x) > 0.1 or abs(look_y) > 0.1:
		player_camera.yaw -= look_x * controller_sensitivity * delta
		player_camera.pitch -= look_y * controller_sensitivity * delta
		player_camera.pitch = clamp(player_camera.pitch, deg_to_rad(-80), deg_to_rad(80))

func _update_aim_direction():
	if player_camera:
		aim_direction = player_camera.get_aim_direction()
		aim_direction.y = 0
		aim_direction = aim_direction.normalized()
		aim_direction_changed.emit(aim_direction)

#region Override Entity Methods
func get_movement_input() -> Vector3:
	## Returns player input direction (zero if no keys pressed)
	return input_direction

func face_aim_direction():
	set_facing(aim_direction)
#endregion

#region Movement Overrides
func _update_rotation(_delta: float):
	# Override parent - player rotation is handled by _face_camera_direction()
	# This prevents the default "face movement direction" behavior
	pass
#endregion

#region Camera Integration
func set_camera(cam: Node3D):  # cam is PlayerCamera
	player_camera = cam
	if player_camera:
		player_camera.set_target(self)

func get_aim_ray_origin() -> Vector3:
	if player_camera:
		return player_camera.get_aim_origin()
	return global_position + Vector3.UP * 1.5

func get_aim_ray_direction() -> Vector3:
	if player_camera:
		return player_camera.get_aim_direction()
	return face_direction

func get_aim_target(max_distance: float = 100.0) -> Vector3:
	var origin = get_aim_ray_origin()
	var direction = get_aim_ray_direction()
	
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance)
	query.exclude = [self]
	# Mask: Environment (1) + Players (2) + Enemies (4) = 7
	# This ensures we can aim at both world geometry AND entities
	query.collision_mask = 7
	
	var result = space_state.intersect_ray(query)
	if result:
		return result.position
	
	return origin + direction * max_distance
#endregion

#region Death & Spectating
func _on_died(killer: Node):
	can_receive_input = false
	input_direction = Vector3.ZERO
	player_died.emit()
	
	# Start spectating squad members
	if player_camera and squad_members.size() > 0:
		var alive_squad = squad_members.filter(func(m): return is_instance_valid(m) and not m.is_dead())
		if alive_squad.size() > 0:
			player_camera.start_spectating(alive_squad)

func set_squad(members: Array[Node3D]):
	squad_members = members
	# Remove self from list
	if self in squad_members:
		squad_members.erase(self)
	
	# Update camera's spectate targets if already spectating
	if player_camera and player_camera.is_spectating:
		var alive = squad_members.filter(func(m): return is_instance_valid(m) and not m.is_dead())
		player_camera.update_spectate_targets(alive)

func respawn(spawn_position: Vector3):
	global_position = spawn_position
	
	# Stop spectating
	if player_camera:
		player_camera.stop_spectating()
		player_camera.set_target(self)
	
	# Reset state
	if combat:
		combat.reset_health()
	
	can_receive_input = true
	player_respawned.emit()
#endregion

#region Input Control
func enable_input():
	can_receive_input = true

func disable_input():
	can_receive_input = false
	input_direction = Vector3.ZERO
#endregion

#region Inventory
func _ensure_inventory_action():
	## Register Tab key for inventory toggle
	if not InputMap.has_action("inventory"):
		InputMap.add_action("inventory")
		var event = InputEventKey.new()
		event.keycode = KEY_TAB
		InputMap.action_add_event("inventory", event)

func _ensure_dash_action():
	## Register Alt key for dash
	if not InputMap.has_action("dash"):
		InputMap.add_action("dash")
		var event = InputEventKey.new()
		event.keycode = KEY_ALT
		InputMap.action_add_event("dash", event)
	
	# Also ensure dodge action exists (fallback)
	if not InputMap.has_action("dodge"):
		InputMap.add_action("dodge")
		var event = InputEventKey.new()
		event.keycode = KEY_ALT
		InputMap.action_add_event("dodge", event)

func _toggle_inventory():
	## Toggle the inventory panel
	if not can_receive_input:
		return
	
	# Create inventory panel if it doesn't exist
	if not inventory_panel:
		var panel_scene = load("res://scenes/ui/inventory/inventory_panel.tscn")
		if panel_scene:
			inventory_panel = panel_scene.instantiate()
			inventory_panel.visible = false
			# Add to CanvasLayer so it's always on top
			var canvas = CanvasLayer.new()
			canvas.layer = 100
			add_child(canvas)
			canvas.add_child(inventory_panel)
			inventory_panel.set_player(self)
			inventory_panel.closed.connect(_on_inventory_closed)
	
	if inventory_panel:
		if inventory_panel.visible:
			inventory_panel.close()
		else:
			inventory_panel.open()
			# Disable player input while inventory is open
			can_receive_input = false

func _on_inventory_closed():
	can_receive_input = true
	if player_camera:
		player_camera.set_mouse_captured(true)

func _toggle_player_list():
	## Toggle the player list UI
	# Create player list UI if it doesn't exist
	if not player_list_ui:
		var panel_scene = load("res://scenes/ui/player_list_ui.tscn")
		if panel_scene:
			player_list_ui = panel_scene.instantiate()
			player_list_ui.visible = false
			# Add to CanvasLayer so it's always on top
			var canvas = CanvasLayer.new()
			canvas.layer = 110  # Above inventory
			add_child(canvas)
			canvas.add_child(player_list_ui)
			player_list_ui.closed.connect(_on_player_list_closed)
	
	if player_list_ui:
		if player_list_ui.visible:
			player_list_ui.close()
		else:
			player_list_ui.open()
			# Disable player input while player list is open
			can_receive_input = false

func _on_player_list_closed():
	can_receive_input = true
	if player_camera:
		player_camera.set_mouse_captured(true)

func _is_in_dialogue() -> bool:
	## Check if player is currently in dialogue state (talking to NPC)
	var state_manager = get_node_or_null("StateManager")
	if state_manager and state_manager.has_method("get_current_state_name"):
		return state_manager.get_current_state_name() == "talking"
	return false
#endregion

#region Combat Control
func is_combat_enabled() -> bool:
	return combat_enabled
#endregion

#region Network Input (Server-side)
## Enable debug logging for player state (set on server to see logs)
var debug_network_input: bool = false
var _last_logged_state: String = ""
var _last_logged_input: Vector3 = Vector3.ZERO
var _log_cooldown: float = 0.0

var _apply_input_count: int = 0
var _last_apply_input_log: float = 0.0

## Cheat detection thresholds
const CHEAT_MAX_SPEED: float = 50.0  # Max units/sec (generous for wall jumps)
const CHEAT_MAX_TELEPORT: float = 20.0  # Max distance per tick to allow
const CHEAT_DETECTION_ENABLED: bool = true  # Set false to disable checks

## Track last known position for cheat detection
var _last_trusted_position: Vector3 = Vector3.ZERO
var _last_position_time: float = 0.0
var _cheat_violations: int = 0

func apply_network_input(input: Dictionary):
	## Called by server to apply player input from network
	## CLIENT AUTHORITATIVE: Trust client position, only validate for cheats
	_apply_input_count += 1
	
	# Extract client-reported position/velocity (CLIENT AUTHORITATIVE)
	var client_pos = Vector3(
		input.get("pos_x", global_position.x),
		input.get("pos_y", global_position.y),
		input.get("pos_z", global_position.z)
	)
	var client_vel = Vector3(
		input.get("vel_x", velocity.x),
		input.get("vel_y", velocity.y),
		input.get("vel_z", velocity.z)
	)
	
	# Cheat detection: validate position is reasonable
	var accept_position = true
	if CHEAT_DETECTION_ENABLED and _last_position_time > 0:
		var now = Time.get_ticks_msec() / 1000.0
		var dt = now - _last_position_time
		if dt > 0.001:  # Avoid division by zero
			var distance = global_position.distance_to(client_pos)
			var speed = distance / dt
			
			# Check for teleport/speed hacks
			if distance > CHEAT_MAX_TELEPORT:
				_cheat_violations += 1
				if _cheat_violations > 5:
					push_warning("[ActionPlayer:Cheat] Possible teleport hack: distance=%.2f from %s to %s" % [distance, global_position, client_pos])
				accept_position = false
			elif speed > CHEAT_MAX_SPEED:
				_cheat_violations += 1
				if _cheat_violations > 5:
					push_warning("[ActionPlayer:Cheat] Possible speed hack: speed=%.2f units/sec" % speed)
				accept_position = false
			else:
				# Position is valid, decay violations
				_cheat_violations = maxi(0, _cheat_violations - 1)
	
	# Apply client position if it passes validation (or first update)
	if accept_position or _last_position_time == 0:
		global_position = client_pos
		velocity = client_vel
		_last_trusted_position = client_pos
	_last_position_time = Time.get_ticks_msec() / 1000.0
	
	# Extract movement direction (for animation/state, not physics)
	var move_x = input.get("move_x", 0.0)
	var move_z = input.get("move_z", 0.0)
	var new_input_dir = Vector3(move_x, 0, move_z)
	if new_input_dir.length() > 1.0:
		new_input_dir = new_input_dir.normalized()
	
	# Update input direction for animation
	input_direction = new_input_dir
	
	# Apply rotation from client (client knows camera direction)
	if input.has("rotation_y"):
		rotation.y = input.get("rotation_y", rotation.y)
	
	# Apply speed multiplier
	current_speed_multiplier = input.get("speed_multiplier", 1.0)
	
	# Sync state if provided
	var client_state = input.get("state", "")
	if client_state != "" and state_manager:
		if state_manager.has_state(client_state) and state_manager.get_current_state_name() != client_state:
			state_manager.change_state(client_state, true)
	
	# Unpack actions bitmask for actions that need server validation
	var actions_mask = input.get("actions", 0)
	
	# Buffer action inputs for state machine consumption
	if state_manager:
		if actions_mask & (1 << 11): # Wall Jump(s) - may have multiple
			var wall_jump_count = input.get("wall_jump_count", 1)
			print("[ActionPlayer:Server] Received %d wall jumps from client" % wall_jump_count)
			for i in range(wall_jump_count):
				var wall_normal = Vector3(
					input.get("wj_%d_nx" % i, 0.0),
					input.get("wj_%d_ny" % i, 0.0),
					input.get("wj_%d_nz" % i, 1.0)
				).normalized()
				state_manager.buffer_server_action("wall_jump", {"wall_normal": wall_normal})
		elif actions_mask & (1 << 1): # Regular Jump
			state_manager.buffer_server_action("jump")
		if actions_mask & (1 << 2): # Dodge
			state_manager.buffer_server_action("dodge")
	
	# Store camera angles for IK sync broadcast
	synced_camera_yaw = input.get("camera_yaw_offset", synced_camera_yaw)
	synced_camera_pitch = input.get("camera_pitch", synced_camera_pitch)
	
	# Debug logging
	if debug_network_input:
		var actions = _unpack_actions_local(actions_mask)
		_log_network_input_debug(input, actions)

func _unpack_actions_local(actions_bitmask: int) -> Dictionary:
	## Local fallback if InputBuffer class isn't available
	return {
		"sprint": (actions_bitmask & (1 << 0)) != 0,
		"jump": (actions_bitmask & (1 << 1)) != 0,
		"dodge": (actions_bitmask & (1 << 2)) != 0,
		"attack_primary": (actions_bitmask & (1 << 3)) != 0,
		"attack_secondary": (actions_bitmask & (1 << 4)) != 0,
		"aim": (actions_bitmask & (1 << 5)) != 0,
		"interact": (actions_bitmask & (1 << 6)) != 0,
		"ability_1": (actions_bitmask & (1 << 7)) != 0,
		"ability_2": (actions_bitmask & (1 << 8)) != 0,
		"ability_3": (actions_bitmask & (1 << 9)) != 0,
		"ability_4": (actions_bitmask & (1 << 10)) != 0,
	}

func _log_network_input_debug(input: Dictionary, actions: Dictionary):
	## Log network input state changes for debugging
	_log_cooldown -= get_physics_process_delta_time()
	
	var current_state_name = state_manager.get_current_state_name() if state_manager else "no_state"
	var input_changed = input_direction.distance_to(_last_logged_input) > 0.1
	var state_changed = current_state_name != _last_logged_state
	
	# Always log on state change or action, throttle movement logs
	var should_log = state_changed or actions.get("jump", false) or actions.get("dodge", false)
	
	# Also log periodically to confirm inputs are still arriving
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - _last_apply_input_log > 2.0: # Every 2 seconds
		should_log = true
		_last_apply_input_log = current_time
	
	if not should_log and input_changed and _log_cooldown <= 0:
		should_log = true
		_log_cooldown = 0.5 # Log at most every 0.5s for movement
	
	if should_log:
		var active_actions = []
		for action_name in actions:
			if actions[action_name]:
				active_actions.append(action_name)
		
		var server_buffer_size = state_manager.server_action_buffer.size() if state_manager else 0
		
		print("[ActionPlayer:Server] Peer=%d #%d State=%s Input=(%.2f, %.2f) Speed=%.1fx Actions=%s OnFloor=%s ActionBuf=%d" % [
			network_identity.owner_peer_id if network_identity else -1,
			_apply_input_count,
			current_state_name,
			input_direction.x, input_direction.z,
			current_speed_multiplier,
			str(active_actions) if active_actions.size() > 0 else "none",
			str(is_on_floor()),
			server_buffer_size
		])
		
		_last_logged_state = current_state_name
		_last_logged_input = input_direction

func get_network_state() -> Dictionary:
	## Return current state for network synchronization
	var state_data = {
		"position": global_position,
		"rotation": rotation,
		"velocity": velocity,
		"input_direction": input_direction,
		"speed_multiplier": current_speed_multiplier,
		"state": state_manager.get_current_state_name() if state_manager else "idle",
		"is_on_floor": is_on_floor()
	}
	
	# Add camera angles for IK sync
	if player_camera:
		state_data["camera_yaw_offset"] = get_camera_body_offset()
		state_data["camera_pitch"] = player_camera.pitch
	else:
		# Server entity - use synced values from client
		state_data["camera_yaw_offset"] = synced_camera_yaw
		state_data["camera_pitch"] = synced_camera_pitch
	
	# Add equipment state for weapon sync
	var equipment = get_node_or_null("EquipmentManager")
	if equipment:
		state_data["equipped_slot"] = equipment.current_slot
		state_data["is_holstered"] = equipment.is_holstered
		state_data["is_aiming"] = equipment.is_aiming
	
	return state_data

var _last_state_log_time: float = 0.0
var _reconcile_threshold: float = 1.0 # Reconcile if more than 1 unit off
var _reconcile_threshold_airborne: float = 5.0 # Very lenient during airborne (wall jumps!)
var _smooth_reconcile_threshold: float = 0.3 # Smoothly correct smaller errors
var _smooth_reconcile_speed: float = 5.0 # Speed of smooth correction
var _reconcile_grace_time: float = 0.0 # Seconds to skip reconciliation after state change
var _reconcile_grace_duration: float = 0.25 # Base grace period after jump/action

## Track rapid actions for extended grace
var _recent_jump_count: int = 0
var _last_jump_time: float = 0.0
var _rapid_action_window: float = 0.5 # Count jumps within this window as "rapid"
var _post_jump_grace_time: float = 0.0 # Extra grace after landing from jumps

## States that cause big position changes and need reconciliation grace period
const RECONCILE_GRACE_STATES: Array[String] = ["jumping", "airborne", "dodging"]

func _on_state_changed_for_reconcile(old_state, new_state):
	## When entering states that cause big position changes, give grace period
	## This prevents snapping back before the server has processed our input
	if not can_receive_input:
		return  # Only for local player
	
	var new_state_name = new_state.name.to_lower() if new_state else ""
	var current_time = Time.get_ticks_msec() / 1000.0
	
	if new_state_name == "jumping" or new_state_name == "airborne":
		_register_jump_for_grace()
	elif new_state_name in RECONCILE_GRACE_STATES:
		_reconcile_grace_time = _reconcile_grace_duration

func _register_jump_for_grace():
	## Called when a jump occurs (regular or wall jump) to extend reconciliation grace
	if not can_receive_input:
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Track rapid jumps (wall jump chains)
	if current_time - _last_jump_time < _rapid_action_window:
		_recent_jump_count += 1
	else:
		_recent_jump_count = 1
	_last_jump_time = current_time
	
	# More grace for rapid jumps (wall jump chains need more time)
	# Each additional rapid jump adds 0.3s grace, up to 2 seconds total
	var grace_multiplier = minf(_recent_jump_count, 6)
	_reconcile_grace_time = _reconcile_grace_duration + (grace_multiplier - 1) * 0.3
	
	# Also set a "landing grace" that persists after landing
	# This prevents snapping right after a wall jump sequence
	_post_jump_grace_time = 1.0  # 1 second of grace after last jump

func _on_wall_jump():
	## Called by StateAirborne when a wall jump is performed
	## Wall jumps don't trigger state change (airborne->airborne) so we need this
	_register_jump_for_grace()

func apply_network_state(state: Dictionary):
	## Apply state received from server
	## CLIENT AUTHORITATIVE: Local player ignores server position (we are the authority)
	## For REMOTE players: interpolation to show their movement
	
	# Extract state
	var server_pos = state.get("position", global_position)
	var server_rot = state.get("rotation", rotation)
	var server_velocity = state.get("velocity", Vector3.ZERO)
	var server_state = state.get("state", "idle")
	var server_input = state.get("input_direction", Vector3.ZERO)
	var server_speed_mult = state.get("speed_multiplier", 1.0)
	
	# Use _is_local flag (not can_receive_input which can be temporarily disabled during hitlag)
	if _is_local:
		# LOCAL PLAYER - CLIENT AUTHORITATIVE
		# We trust our own position, ignore server's position entirely
		# Server only validates for cheats (it will kick us if we cheat)
		# This eliminates all reconciliation jitter!
		return  # Nothing to do - we are the authority
	else:
		# REMOTE PLAYER - Interpolation
		_is_remote_player = true
		
		# Debug logging (throttled)
		var now = Time.get_ticks_msec() / 1000.0
		if now - _last_state_log_time > 1.0:
			print("[ActionPlayer:Remote] Received state: pos=%s target=%s" % [global_position, server_pos])
			_last_state_log_time = now
		
		# First state or large teleport - snap immediately
		if not _received_first_state or global_position.distance_to(server_pos) > _snap_distance:
			global_position = server_pos
			rotation = server_rot
			velocity = server_velocity
			_received_first_state = true
			_target_position = server_pos
			_target_rotation = server_rot
		else:
			# Set targets for interpolation
			_target_position = server_pos
			_target_rotation = server_rot
			velocity = server_velocity
		
		# Update movement state for animation
		input_direction = server_input
		current_speed_multiplier = server_speed_mult
		
		# Sync state machine state (for animation)
		if state_manager and state_manager.get_current_state_name() != server_state:
			if state_manager.has_state(server_state):
				state_manager.change_state(server_state, true)
		
		# Sync camera angles for IK
		synced_camera_yaw = state.get("camera_yaw_offset", synced_camera_yaw)
		synced_camera_pitch = state.get("camera_pitch", synced_camera_pitch)
		
		# Sync equipment state
		_apply_remote_equipment_state(state)
#endregion

#region Remote Equipment Sync
func _apply_remote_equipment_state(state: Dictionary):
	## Apply equipment state from network for remote players
	## Uses direct state application (no timers) to avoid sync issues
	var equipment = get_node_or_null("EquipmentManager")
	if not equipment:
		return

	var target_slot = state.get("equipped_slot", "")
	var target_holstered = state.get("is_holstered", true)
	var target_aiming = state.get("is_aiming", false)

	# Use the direct remote state application (bypasses timers)
	if equipment.has_method("apply_remote_state"):
		equipment.apply_remote_state(target_slot, target_holstered)
	else:
		# Fallback to old method
		if not target_slot.is_empty() and equipment.is_weapon_equipped(target_slot):
			if equipment.current_slot != target_slot:
				equipment.switch_to_slot(target_slot)
		if equipment.is_holstered != target_holstered:
			if target_holstered:
				equipment.holster_current()
			else:
				equipment.draw_current()

	# Apply aiming state
	if equipment.is_aiming != target_aiming:
		equipment.is_aiming = target_aiming
		var attach_setup = get_node_or_null("WeaponAttachmentSetup")
		if attach_setup and attach_setup.has_method("set_aiming"):
			attach_setup.set_aiming(target_aiming)

func _notify_weapon_aim_state(aiming: bool):
	## Notify weapon attachment systems about aim state change
	var attach_setup = get_node_or_null("WeaponAttachmentSetup")
	if attach_setup and attach_setup.has_method("set_aiming"):
		attach_setup.set_aiming(aiming)
	
	# Also notify equipment manager
	var equipment = get_node_or_null("EquipmentManager")
	if equipment and equipment.has_method("set_aiming"):
		equipment.set_aiming(aiming)

func get_equipment_manager():
	return get_node_or_null("EquipmentManager")

#region Interaction
var interaction_prompt: Control = null
var _prompt_target: Node = null

## States that allow NPC/object interaction
const INTERACTION_ALLOWED_STATES: Array[String] = ["idle", "moving"]

func _try_interact():
	# Only allow interaction in idle or moving states (not during combat, jumping, etc.)
	if state_manager:
		var current_state = state_manager.get_current_state_name()
		if current_state not in INTERACTION_ALLOWED_STATES:
			return
	
	# Find nearest interactable NPC/object
	var nearest = _get_nearest_interactable()
	if nearest and nearest.has_method("start_interaction"):
		hide_interaction_prompt()  # Hide prompt when interacting
		nearest.start_interaction(self)

func _get_nearest_interactable() -> Node:
	var nearest: Node = null
	var nearest_dist: float = INF
	
	# Check all interactables in range
	for interactable in get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(interactable):
			continue
		if interactable.has_method("can_interact") and not interactable.can_interact():
			continue
		
		var dist = global_position.distance_to(interactable.global_position)
		if dist < nearest_dist and dist < 3.0: # 3m interaction range
			nearest_dist = dist
			nearest = interactable
	
	return nearest

func register_nearby_interactable(interactable: Node):
	if interactable not in nearby_interactables:
		nearby_interactables.append(interactable)

func unregister_nearby_interactable(interactable: Node):
	nearby_interactables.erase(interactable)

func show_interaction_prompt(prompt_text: String, target: Node):
	## Show the floating [E] interaction prompt near a target
	if not can_receive_input:
		return  # Don't show prompts for remote players
	
	# Don't show prompts during combat/action states
	if state_manager:
		var current_state = state_manager.get_current_state_name()
		if current_state not in INTERACTION_ALLOWED_STATES:
			hide_interaction_prompt()
			return
	
	_prompt_target = target
	
	# Create prompt if needed
	if not interaction_prompt:
		var prompt_scene = load("res://scenes/ui/interaction_prompt.tscn")
		if prompt_scene:
			interaction_prompt = prompt_scene.instantiate()
			# Add to CanvasLayer so it's always on top
			var canvas = CanvasLayer.new()
			canvas.name = "InteractionPromptLayer"
			canvas.layer = 50  # Below inventory (100) but above game HUD
			add_child(canvas)
			canvas.add_child(interaction_prompt)
	
	if interaction_prompt and interaction_prompt.has_method("show_prompt"):
		var cam = player_camera.get_camera() if player_camera else null
		if cam and target is Node3D:
			interaction_prompt.show_prompt(target, cam, prompt_text)

func hide_interaction_prompt():
	## Hide the interaction prompt
	_prompt_target = null
	if interaction_prompt and interaction_prompt.has_method("hide_prompt"):
		interaction_prompt.hide_prompt()

func get_prompt_target() -> Node:
	## Get the current interaction prompt target (used for checking if prompt should be hidden)
	return _prompt_target
#endregion

#region Zone Permissions
func set_zone_permissions(permissions: Dictionary):
	## Apply zone permissions (called when spawning in a zone)
	for key in permissions:
		zone_permissions[key] = permissions[key]
	print("[ActionPlayer] Zone permissions updated: ", zone_permissions)

func _set_combat_enabled_internal(enabled: bool):
	## Internal method for enabling/disabling combat systems
	if combat:
		combat.set_process(enabled)
		combat.set_physics_process(enabled)

func can_jump() -> bool:
	return zone_permissions.get("jumping", true)

func can_dodge() -> bool:
	return zone_permissions.get("dodging", true)

func can_sprint() -> bool:
	return zone_permissions.get("sprinting", true)

func can_attack() -> bool:
	return zone_permissions.get("combat", true)

func can_damage_player(_target: Node) -> bool:
	## Check if this player can damage the target (PvP check)
	if not zone_permissions.get("combat", true):
		return false
	if _target is ActionPlayer:
		return zone_permissions.get("pvp", false)
	return true
#endregion
