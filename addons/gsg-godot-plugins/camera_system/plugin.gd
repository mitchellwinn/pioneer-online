@tool
extends EditorPlugin

const REQUIRED_ACTIONS = {
	"camera_rotate_right": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": 1.0}
		]
	},
	"camera_rotate_left": {
		"deadzone": 0.2,
		"events": [
			{"type": "joypad_motion", "axis": JOY_AXIS_RIGHT_X, "axis_value": -1.0}
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
	}
}

func _enter_tree():
	# Register CameraManager as autoload
	add_autoload_singleton("CameraManager", "res://addons/gsg-godot-plugins/camera_system/scripts/camera_manager.gd")
	print("[CameraSystem Plugin] Initialized")

func _exit_tree():
	# Remove CameraManager autoload
	remove_autoload_singleton("CameraManager")
	print("[CameraSystem Plugin] Cleanup complete")
