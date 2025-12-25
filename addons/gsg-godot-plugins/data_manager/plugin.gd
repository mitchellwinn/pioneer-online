@tool
extends EditorPlugin

const AUTOLOAD_NAME = "DataManager"

func _enter_tree():
	# Add autoload
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gsg-godot-plugins/data_manager/data_manager.gd")
	print("[DataManager Plugin] Registered autoload: ", AUTOLOAD_NAME)

func _exit_tree():
	# Remove autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[DataManager Plugin] Removed autoload: ", AUTOLOAD_NAME)
