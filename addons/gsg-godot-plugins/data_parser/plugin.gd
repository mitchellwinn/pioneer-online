@tool
extends EditorPlugin

const AUTOLOAD_NAME = "DataParser"

func _enter_tree():
	# Add autoload
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gsg-godot-plugins/data_parser/data_parser.gd")
	print("[DataParser Plugin] Registered autoload: ", AUTOLOAD_NAME)

func _exit_tree():
	# Remove autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[DataParser Plugin] Removed autoload: ", AUTOLOAD_NAME)
