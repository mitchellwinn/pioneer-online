extends Node

## ActionEntities Autoload - Registers required input actions at runtime

const REQUIRED_ACTIONS = {
	# Movement
	"move_forward": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_W},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": - 1.0},
		]
	},
	"move_backward": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_S},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": 1.0},
		]
	},
	"move_left": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_A},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": - 1.0},
		]
	},
	"move_right": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_D},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": 1.0},
		]
	},
	# Actions
	"sprint": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_SHIFT},
			{"type": "joypad_button", "button_index": JOY_BUTTON_LEFT_STICK},
		]
	},
	"jump": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_SPACE},
			{"type": "joypad_button", "button_index": JOY_BUTTON_A},
		]
	},
	"dodge": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_CTRL},
			{"type": "joypad_button", "button_index": JOY_BUTTON_B},
		]
	},
	"interact": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_E},
			{"type": "joypad_button", "button_index": JOY_BUTTON_X},
		]
	},
	# Combat
	"attack_primary": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_LEFT},
		]
	},
	"attack_secondary": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_RIGHT},
		]
	},
	"fire": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_LEFT},
		]
	},
	"aim": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_RIGHT},
		]
	},
	"reload": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_R},
		]
	},
	"holster": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_H},
		]
	},
	"ability_1": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_1},
		]
	},
	"ability_2": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_2},
		]
	},
	"ability_3": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_3},
		]
	},
	"ability_4": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_4},
		]
	},
	# Camera
	"shoulder_swap": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_X},
		]
	},
	"camera_rotate_left": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": - 1.0},
		]
	},
	"camera_rotate_right": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": 1.0},
		]
	},
	"camera_rotate_up": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_Y, "axis_value": - 1.0},
		]
	},
	"camera_rotate_down": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_Y, "axis_value": 1.0},
		]
	},
}

func _ready():
	_register_input_actions()

func _register_input_actions():
	var registered_count = 0
	
	for action_name in REQUIRED_ACTIONS:
		if not InputMap.has_action(action_name):
			var action_data = REQUIRED_ACTIONS[action_name]
			InputMap.add_action(action_name, action_data.get("deadzone", 0.5))
			
			for event_data in action_data.events:
				var event = _create_input_event(event_data)
				if event:
					InputMap.action_add_event(action_name, event)
			
			registered_count += 1
	
	if registered_count > 0:
		print("[ActionEntities] Registered ", registered_count, " input actions")

func _create_input_event(event_data: Dictionary) -> InputEvent:
	var event: InputEvent = null
	
	match event_data.get("type", ""):
		"joypad_motion":
			event = InputEventJoypadMotion.new()
			event.axis = event_data.get("axis", 0)
			event.axis_value = event_data.get("axis_value", 1.0)
		"joypad_button":
			event = InputEventJoypadButton.new()
			event.button_index = event_data.get("button_index", 0)
		"key":
			event = InputEventKey.new()
			event.keycode = event_data.get("keycode", KEY_NONE)
		"mouse_button":
			event = InputEventMouseButton.new()
			event.button_index = event_data.get("button_index", MOUSE_BUTTON_LEFT)
	
	return event
