@tool
extends EditorPlugin

const AUTOLOAD_NAME = "SceneTransition"
const AUTOLOAD_PATH = "res://addons/gsg-godot-plugins/scene_transitions/prefabs/scene_transition.tscn"

func _enter_tree():
	# Register autoload
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)

func _exit_tree():
	# Unregister autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
