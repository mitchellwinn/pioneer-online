extends Node
class_name NetworkIdentity

## NetworkIdentity - Handles network synchronization for entities
## Attach as a child of any ActionEntity to enable multiplayer sync

signal authority_changed(is_authority: bool)
signal owner_changed(new_owner_id: int)

#region Configuration
## Unique network ID for this entity (assigned by server)
@export var network_id: int = -1

## The peer ID that owns/controls this entity (1 = server, >1 = clients)
@export var owner_peer_id: int = 1

## Whether this entity is authoritative (server controls state)
@export var is_server_authoritative: bool = true

## Sync rate in Hz (how often to send state updates)
@export var sync_rate: float = 20.0

## Enable interpolation for smooth remote entity movement
@export var interpolate: bool = true

## Interpolation delay in seconds (higher = smoother but more latency)
@export var interpolation_delay: float = 0.1
#endregion

#region Sync State
## Properties to synchronize (populated by parent entity)
var sync_properties: Array[String] = ["global_position", "global_rotation", "velocity"]

## State buffer for interpolation (timestamp -> state dict)
var state_buffer: Array[Dictionary] = []
const MAX_BUFFER_SIZE: int = 30

## Last synced state (for delta compression)
var last_synced_state: Dictionary = {}

## Time since last sync
var sync_timer: float = 0.0
#endregion

#region Runtime State
var parent_entity: Node3D = null
var is_local_authority: bool = false
#endregion

func _ready():
	parent_entity = get_parent() as Node3D
	if not parent_entity:
		push_error("[NetworkIdentity] Must be child of a Node3D")
		return
	
	# Determine local authority
	_update_authority()
	
	# Connect to multiplayer signals if available
	if multiplayer:
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _physics_process(delta: float):
	if not parent_entity:
		return
	
	# NOTE: State sync is handled by NetworkManager, not NetworkIdentity RPCs
	# This avoids timing issues where server sends RPCs before client spawns player
	# The interpolation below is for states received via NetworkManager
	
	if not is_local_authority and interpolate and state_buffer.size() >= 2:
		# Remote entity - interpolate between received states
		_interpolate_state()

func _update_authority():
	var old_authority = is_local_authority
	
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		# Offline mode - always local authority
		is_local_authority = true
	elif is_server_authoritative:
		# Server controls this entity
		is_local_authority = multiplayer.is_server()
	else:
		# Client-authoritative (rare) - owner controls
		is_local_authority = multiplayer.get_unique_id() == owner_peer_id
	
	if old_authority != is_local_authority:
		authority_changed.emit(is_local_authority)

func set_network_owner(peer_id: int):
	owner_peer_id = peer_id
	_update_authority()
	owner_changed.emit(peer_id)

func get_current_state() -> Dictionary:
	if not parent_entity:
		return {}
	
	var state = {
		"timestamp": Time.get_ticks_msec(),
		"network_id": network_id
	}
	
	for prop in sync_properties:
		if parent_entity.has_method("get_" + prop):
			state[prop] = parent_entity.call("get_" + prop)
		elif prop in parent_entity:
			state[prop] = parent_entity.get(prop)
		# Special handling for RigidBody3D linear_velocity
		elif parent_entity is RigidBody3D and prop == "linear_velocity":
			state[prop] = parent_entity.linear_velocity
	
	return state

func apply_state(state: Dictionary):
	if not parent_entity:
		return
	
	for prop in sync_properties:
		if prop in state:
			if parent_entity.has_method("set_" + prop):
				parent_entity.call("set_" + prop, state[prop])
			elif prop in parent_entity:
				parent_entity.set(prop, state[prop])
			# Special handling for RigidBody3D linear_velocity
			elif parent_entity is RigidBody3D and prop == "linear_velocity":
				parent_entity.linear_velocity = state[prop]

func receive_state_update(state: Dictionary):
	if is_local_authority:
		return # Ignore updates for entities we control
	
	# Add to interpolation buffer
	state_buffer.append(state)
	
	# Keep buffer size limited
	while state_buffer.size() > MAX_BUFFER_SIZE:
		state_buffer.pop_front()
	
	# Sort by timestamp
	state_buffer.sort_custom(func(a, b): return a.timestamp < b.timestamp)

func _send_state_update():
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		return
	
	var state = get_current_state()
	
	# Delta compression - only send changed values
	var delta_state = {"timestamp": state.timestamp, "network_id": network_id}
	var has_changes = false
	
	for prop in sync_properties:
		if prop in state:
			if not last_synced_state.has(prop) or last_synced_state[prop] != state[prop]:
				delta_state[prop] = state[prop]
				has_changes = true
	
	if has_changes:
		last_synced_state = state.duplicate()
		# RPC to all clients (unreliable for position updates)
		_rpc_state_update.rpc(delta_state)

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state_update(state: Dictionary):
	receive_state_update(state)

func _interpolate_state():
	var render_time = Time.get_ticks_msec() - int(interpolation_delay * 1000)
	
	# Find the two states to interpolate between
	var before_state: Dictionary = {}
	var after_state: Dictionary = {}
	
	for i in range(state_buffer.size() - 1):
		if state_buffer[i].timestamp <= render_time and state_buffer[i + 1].timestamp >= render_time:
			before_state = state_buffer[i]
			after_state = state_buffer[i + 1]
			break
	
	if before_state.is_empty() or after_state.is_empty():
		# No valid interpolation window - use latest state
		if state_buffer.size() > 0:
			apply_state(state_buffer.back())
		return
	
	# Calculate interpolation factor
	var time_diff = after_state.timestamp - before_state.timestamp
	if time_diff <= 0:
		apply_state(after_state)
		return
	
	var t = float(render_time - before_state.timestamp) / float(time_diff)
	t = clampf(t, 0.0, 1.0)
	
	# Interpolate each property
	var interpolated_state = {"timestamp": render_time}
	for prop in sync_properties:
		if prop in before_state and prop in after_state:
			var before_val = before_state[prop]
			var after_val = after_state[prop]
			
			if before_val is Vector3:
				interpolated_state[prop] = before_val.lerp(after_val, t)
			elif before_val is Quaternion:
				interpolated_state[prop] = before_val.slerp(after_val, t)
			elif before_val is float:
				interpolated_state[prop] = lerpf(before_val, after_val, t)
			else:
				# Non-interpolatable - use after value
				interpolated_state[prop] = after_val
	
	apply_state(interpolated_state)

func _on_peer_connected(_id: int):
	_update_authority()

func _on_peer_disconnected(_id: int):
	_update_authority()
