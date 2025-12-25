extends Node
class_name InputBuffer

## InputBuffer - Buffers player inputs for network transmission and replay
## Helps with client-side prediction and server reconciliation

signal input_recorded(tick: int, input: Dictionary)
signal inputs_sent(count: int)

#region Configuration
@export var buffer_size: int = 64
@export var send_redundancy: int = 3  # How many past inputs to send with each packet
@export var input_sample_rate: float = 60.0  # Inputs per second
#endregion

#region Input State
class InputSnapshot:
	var tick: int = 0
	var timestamp: float = 0.0
	var data: Dictionary = {}
	var sent: bool = false
	var acknowledged: bool = false

var input_history: Array[InputSnapshot] = []
var current_tick: int = 0
var sample_accumulator: float = 0.0
#endregion

#region References
var network_manager: Node = null
#endregion

func _ready():
	if has_node("/root/NetworkManager"):
		network_manager = get_node("/root/NetworkManager")

func _physics_process(delta: float):
	sample_accumulator += delta
	var sample_interval = 1.0 / input_sample_rate
	
	if sample_accumulator >= sample_interval:
		sample_accumulator -= sample_interval
		_sample_input()

#region Input Sampling
func _sample_input():
	current_tick += 1
	
	var input_data = _gather_input()
	
	var snapshot = InputSnapshot.new()
	snapshot.tick = current_tick
	snapshot.timestamp = Time.get_ticks_msec() / 1000.0
	snapshot.data = input_data
	
	input_history.append(snapshot)
	
	# Trim old inputs
	while input_history.size() > buffer_size:
		input_history.pop_front()
	
	input_recorded.emit(current_tick, input_data)
	
	# Send to server
	_send_inputs()

func _gather_input() -> Dictionary:
	var input = {}
	
	# Movement
	input["move_x"] = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input["move_z"] = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	
	# Camera/Aim direction (normalized)
	input["aim_x"] = Input.get_action_strength("camera_rotate_right") - Input.get_action_strength("camera_rotate_left")
	input["aim_y"] = Input.get_action_strength("camera_rotate_down") - Input.get_action_strength("camera_rotate_up")
	
	# Actions (as bitmask for efficiency)
	var actions = 0
	if Input.is_action_pressed("sprint"):
		actions |= 1 << 0
	if Input.is_action_pressed("jump"):
		actions |= 1 << 1
	if Input.is_action_pressed("dodge"):
		actions |= 1 << 2
	if Input.is_action_pressed("attack_primary"):
		actions |= 1 << 3
	if Input.is_action_pressed("attack_secondary"):
		actions |= 1 << 4
	if Input.is_action_pressed("aim"):
		actions |= 1 << 5
	if Input.is_action_pressed("interact"):
		actions |= 1 << 6
	if Input.is_action_pressed("ability_1"):
		actions |= 1 << 7
	if Input.is_action_pressed("ability_2"):
		actions |= 1 << 8
	if Input.is_action_pressed("ability_3"):
		actions |= 1 << 9
	if Input.is_action_pressed("ability_4"):
		actions |= 1 << 10
	
	input["actions"] = actions
	input["tick"] = current_tick
	
	return input

func _send_inputs():
	if not network_manager:
		return
	
	# Gather recent unacknowledged inputs (with redundancy)
	var inputs_to_send = []
	var count = 0
	
	for i in range(input_history.size() - 1, -1, -1):
		if count >= send_redundancy:
			break
		
		var snapshot = input_history[i]
		if not snapshot.acknowledged:
			inputs_to_send.insert(0, snapshot.data)
			snapshot.sent = true
			count += 1
	
	if inputs_to_send.size() > 0:
		# Send via NetworkManager
		for input_data in inputs_to_send:
			network_manager.send_input(input_data)
		
		inputs_sent.emit(inputs_to_send.size())
#endregion

#region Acknowledgment
func acknowledge_tick(tick: int):
	for snapshot in input_history:
		if snapshot.tick <= tick:
			snapshot.acknowledged = true
#endregion

#region Input Replay
func get_inputs_since(tick: int) -> Array[Dictionary]:
	var inputs: Array[Dictionary] = []
	
	for snapshot in input_history:
		if snapshot.tick > tick:
			inputs.append(snapshot.data)
	
	return inputs

func get_input_at_tick(tick: int) -> Dictionary:
	for snapshot in input_history:
		if snapshot.tick == tick:
			return snapshot.data
	
	return {}
#endregion

#region Utility
static func unpack_actions(actions_bitmask: int) -> Dictionary:
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

func get_current_tick() -> int:
	return current_tick

func clear():
	input_history.clear()
	current_tick = 0
#endregion

