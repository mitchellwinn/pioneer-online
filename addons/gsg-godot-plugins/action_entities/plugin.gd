@tool
extends EditorPlugin

const REQUIRED_ACTIONS = {
	# Movement
	"move_forward": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_W},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": -1.0}
		]
	},
	"move_backward": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_S},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": 1.0}
		]
	},
	"move_left": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_A},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": -1.0}
		]
	},
	"move_right": {
		"deadzone": 0.2,
		"events": [
			{"type": "key", "keycode": KEY_D},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": 1.0}
		]
	},
	# Camera
	"camera_rotate_left": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": -1.0}
		]
	},
	"camera_rotate_right": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": 1.0}
		]
	},
	"camera_rotate_up": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_Y, "axis_value": -1.0}
		]
	},
	"camera_rotate_down": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_Y, "axis_value": 1.0}
		]
	},
	# Actions
	"sprint": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_SHIFT},
			{"type": "joypad_button", "button_index": JOY_BUTTON_LEFT_STICK}
		]
	},
	"jump": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_SPACE},
			{"type": "joypad_button", "button_index": JOY_BUTTON_A}
		]
	},
	"dodge": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_CTRL},
			{"type": "joypad_button", "button_index": JOY_BUTTON_B}
		]
	},
	"interact": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_E},
			{"type": "joypad_button", "button_index": JOY_BUTTON_X}
		]
	},
	# Combat
	"attack_primary": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_LEFT},
			{"type": "joypad_button", "button_index": JOY_BUTTON_RIGHT_SHOULDER}
		]
	},
	"attack_secondary": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_RIGHT},
			{"type": "joypad_button", "button_index": JOY_BUTTON_LEFT_SHOULDER}
		]
	},
	"aim": {
		"deadzone": 0.5,
		"events": [
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_RIGHT},
			{"type": "joypad_axis", "axis": JOY_AXIS_TRIGGER_LEFT, "axis_value": 0.5}
		]
	},
	"ability_1": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_1},
			{"type": "joypad_button", "button_index": JOY_BUTTON_DPAD_UP}
		]
	},
	"ability_2": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_2},
			{"type": "joypad_button", "button_index": JOY_BUTTON_DPAD_RIGHT}
		]
	},
	"ability_3": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_3},
			{"type": "joypad_button", "button_index": JOY_BUTTON_DPAD_DOWN}
		]
	},
	"ability_4": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_4},
			{"type": "joypad_button", "button_index": JOY_BUTTON_DPAD_LEFT}
		]
	},
}

func _enter_tree():
	print("[Action Entities Plugin] Initializing...")
	_register_input_actions()
	print("[Action Entities Plugin] Initialized successfully")

func _exit_tree():
	print("[Action Entities Plugin] Cleanup complete")

func _register_input_actions():
	for action_name in REQUIRED_ACTIONS:
		if not InputMap.has_action(action_name):
			var action_data = REQUIRED_ACTIONS[action_name]
			InputMap.add_action(action_name, action_data.get("deadzone", 0.5))
			
			for event_data in action_data.events:
				var event = null
				match event_data.type:
					"joypad_motion":
						event = InputEventJoypadMotion.new()
						event.axis = event_data.axis
						event.axis_value = event_data.axis_value
					"joypad_button":
						event = InputEventJoypadButton.new()
						event.button_index = event_data.button_index
					"joypad_axis":
						event = InputEventJoypadMotion.new()
						event.axis = event_data.axis
						event.axis_value = event_data.axis_value
					"key":
						event = InputEventKey.new()
						event.keycode = event_data.keycode
					"mouse_button":
						event = InputEventMouseButton.new()
						event.button_index = event_data.button_index
				
				if event:
					InputMap.action_add_event(action_name, event)
			
			print("[Action Entities Plugin] Registered input action: ", action_name)

