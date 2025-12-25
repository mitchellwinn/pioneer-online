@tool
extends EditorPlugin

const REQUIRED_ACTIONS = {
	"move_up": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_W},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": -1.0}
		]
	},
	"move_down": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_S},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_Y, "axis_value": 1.0}
		]
	},
	"move_left": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_A},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": -1.0}
		]
	},
	"move_right": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_D},
			{"type": "joypad_motion", "axis": JOY_AXIS_LEFT_X, "axis_value": 1.0}
		]
	},
	"interact": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_E},
			{"type": "joypad_button", "button_index": JOY_BUTTON_A}
		]
	},
	"sprint": {
		"deadzone": 0.5,
		"events": [
			{"type": "key", "keycode": KEY_SHIFT},
			{"type": "joypad_button", "button_index": JOY_BUTTON_B}
		]
	}
}

func _enter_tree():
	print("[RPG Entities Plugin] Initializing...")
	_register_input_actions()
	print("[RPG Entities Plugin] Initialized successfully")

func _exit_tree():
	print("[RPG Entities Plugin] Cleanup complete")

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
					"key":
						event = InputEventKey.new()
						event.keycode = event_data.keycode
				
				if event:
					InputMap.action_add_event(action_name, event)
			
			print("[RPG Entities Plugin] Registered input action: ", action_name)
		else:
			print("[RPG Entities Plugin] Input action already exists: ", action_name)
