@tool
extends EditorPlugin

const AUTOLOAD_NAME = "EventManager"

func _enter_tree():
	# Add autoload
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gsg-godot-plugins/event_manager/event_manager.gd")
	print("[EventManager Plugin] Registered autoload: ", AUTOLOAD_NAME)

func _exit_tree():
	# Remove autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[EventManager Plugin] Removed autoload: ", AUTOLOAD_NAME)
