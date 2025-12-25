extends Node
class_name StateSync

## StateSync - Handles entity state synchronization with interpolation and prediction
## Attach to entities that need network sync (alternative to NetworkIdentity)

signal state_received(tick: int, state: Dictionary)
signal prediction_corrected(correction_delta: Vector3)

#region Configuration
@export var sync_position: bool = true
@export var sync_rotation: bool = true
@export var sync_velocity: bool = true
@export var sync_custom_properties: Array[String] = []

@export_group("Interpolation")
@export var interpolation_enabled: bool = true
@export var interpolation_delay: float = 0.1  # Seconds behind server
@export var max_extrapolation_time: float = 0.25

@export_group("Prediction")
@export var prediction_enabled: bool = true
@export var max_prediction_error: float = 0.5  # Max position error before snap
@export var correction_smoothing: float = 0.1  # How fast to correct predictions
#endregion

#region State Buffer
class StateSnapshot:
	var tick: int = 0
	var timestamp: float = 0.0
	var position: Vector3 = Vector3.ZERO
	var rotation: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var custom: Dictionary = {}

var state_buffer: Array[StateSnapshot] = []
const MAX_BUFFER_SIZE: int = 64

# Prediction state
var predicted_states: Array[StateSnapshot] = []
var last_confirmed_tick: int = 0
var pending_inputs: Array[Dictionary] = []
#endregion

#region References
var parent: Node3D = null
var network_manager: Node = null
var is_local_player: bool = false
#endregion

func _ready():
	parent = get_parent() as Node3D
	if not parent:
		push_error("[StateSync] Parent must be Node3D")
		return
	
	# Get NetworkManager reference
	if has_node("/root/NetworkManager"):
		network_manager = get_node("/root/NetworkManager")

func _physics_process(delta: float):
	if not parent:
		return
	
	if is_local_player and prediction_enabled:
		_process_prediction(delta)
	elif interpolation_enabled and state_buffer.size() >= 2:
		_process_interpolation(delta)

#region State Reception
func receive_state(tick: int, state: Dictionary):
	var snapshot = StateSnapshot.new()
	snapshot.tick = tick
	snapshot.timestamp = Time.get_ticks_msec() / 1000.0
	
	if state.has("position"):
		snapshot.position = state.position
	if state.has("rotation"):
		snapshot.rotation = state.rotation
	if state.has("velocity"):
		snapshot.velocity = state.velocity
	
	for prop in sync_custom_properties:
		if state.has(prop):
			snapshot.custom[prop] = state[prop]
	
	# Insert in order
	var inserted = false
	for i in range(state_buffer.size()):
		if state_buffer[i].tick > tick:
			state_buffer.insert(i, snapshot)
			inserted = true
			break
	
	if not inserted:
		state_buffer.append(snapshot)
	
	# Trim old states
	while state_buffer.size() > MAX_BUFFER_SIZE:
		state_buffer.pop_front()
	
	state_received.emit(tick, state)
	
	# Reconciliation for local player
	if is_local_player and prediction_enabled:
		_reconcile_prediction(tick, snapshot)

func get_current_state() -> Dictionary:
	if not parent:
		return {}
	
	var state = {}
	
	if sync_position:
		state["position"] = parent.global_position
	if sync_rotation:
		state["rotation"] = parent.rotation
	if sync_velocity and parent is CharacterBody3D:
		state["velocity"] = parent.velocity
	
	for prop in sync_custom_properties:
		if prop in parent:
			state[prop] = parent.get(prop)
	
	return state
#endregion

#region Interpolation
func _process_interpolation(delta: float):
	# Calculate render time (behind real time)
	var render_time = Time.get_ticks_msec() / 1000.0 - interpolation_delay
	
	# Find states to interpolate between
	var before: StateSnapshot = null
	var after: StateSnapshot = null
	
	for i in range(state_buffer.size() - 1):
		if state_buffer[i].timestamp <= render_time and state_buffer[i + 1].timestamp >= render_time:
			before = state_buffer[i]
			after = state_buffer[i + 1]
			break
	
	if not before or not after:
		# Try extrapolation from latest state
		if state_buffer.size() > 0:
			var latest = state_buffer.back()
			var time_since = render_time - latest.timestamp
			
			if time_since <= max_extrapolation_time:
				_extrapolate_from(latest, time_since)
		return
	
	# Calculate interpolation factor
	var time_range = after.timestamp - before.timestamp
	if time_range <= 0:
		_apply_snapshot(after)
		return
	
	var t = (render_time - before.timestamp) / time_range
	t = clampf(t, 0.0, 1.0)
	
	# Interpolate
	if sync_position:
		parent.global_position = before.position.lerp(after.position, t)
	
	if sync_rotation:
		parent.rotation = Vector3(
			lerp_angle(before.rotation.x, after.rotation.x, t),
			lerp_angle(before.rotation.y, after.rotation.y, t),
			lerp_angle(before.rotation.z, after.rotation.z, t)
		)
	
	if sync_velocity and parent is CharacterBody3D:
		parent.velocity = before.velocity.lerp(after.velocity, t)

func _extrapolate_from(state: StateSnapshot, time_delta: float):
	if sync_position and sync_velocity:
		parent.global_position = state.position + state.velocity * time_delta
	
	if sync_rotation:
		parent.rotation = state.rotation

func _apply_snapshot(state: StateSnapshot):
	if sync_position:
		parent.global_position = state.position
	if sync_rotation:
		parent.rotation = state.rotation
	if sync_velocity and parent is CharacterBody3D:
		parent.velocity = state.velocity
#endregion

#region Prediction & Reconciliation
func store_predicted_state(tick: int, input: Dictionary):
	var snapshot = StateSnapshot.new()
	snapshot.tick = tick
	snapshot.timestamp = Time.get_ticks_msec() / 1000.0
	
	if sync_position:
		snapshot.position = parent.global_position
	if sync_rotation:
		snapshot.rotation = parent.rotation
	if sync_velocity and parent is CharacterBody3D:
		snapshot.velocity = parent.velocity
	
	predicted_states.append(snapshot)
	pending_inputs.append(input)
	
	# Limit buffer
	while predicted_states.size() > MAX_BUFFER_SIZE:
		predicted_states.pop_front()
		pending_inputs.pop_front()

func _process_prediction(_delta: float):
	# Prediction runs every physics frame
	# Store current state after processing input
	pass

func _reconcile_prediction(server_tick: int, server_state: StateSnapshot):
	# Find matching predicted state
	var match_index = -1
	for i in range(predicted_states.size()):
		if predicted_states[i].tick == server_tick:
			match_index = i
			break
	
	if match_index < 0:
		return  # No matching prediction
	
	var predicted = predicted_states[match_index]
	
	# Check prediction error
	var position_error = predicted.position.distance_to(server_state.position)
	
	if position_error > max_prediction_error:
		# Significant mismatch - need to resimulate
		_resimulate_from(match_index, server_state)
	elif position_error > 0.01:
		# Small error - smoothly correct
		var correction = server_state.position - predicted.position
		parent.global_position += correction * correction_smoothing
		prediction_corrected.emit(correction)
	
	# Remove old predictions
	predicted_states = predicted_states.slice(match_index + 1)
	pending_inputs = pending_inputs.slice(match_index + 1)
	last_confirmed_tick = server_tick

func _resimulate_from(index: int, server_state: StateSnapshot):
	# Reset to server state
	parent.global_position = server_state.position
	parent.rotation = server_state.rotation
	if parent is CharacterBody3D:
		parent.velocity = server_state.velocity
	
	# Replay all inputs since then
	for i in range(index + 1, pending_inputs.size()):
		var input = pending_inputs[i]
		if parent.has_method("apply_network_input"):
			parent.apply_network_input(input)
		
		# Update predicted state
		predicted_states[i].position = parent.global_position
		predicted_states[i].rotation = parent.rotation
		if parent is CharacterBody3D:
			predicted_states[i].velocity = parent.velocity
#endregion

#region Utility
func set_is_local_player(value: bool):
	is_local_player = value

func clear_buffers():
	state_buffer.clear()
	predicted_states.clear()
	pending_inputs.clear()
#endregion

