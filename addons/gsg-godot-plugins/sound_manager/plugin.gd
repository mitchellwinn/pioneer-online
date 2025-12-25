@tool
extends EditorPlugin

const AUTOLOAD_NAME = "SoundManager"

func _enter_tree():
	# Add autoload
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gsg-godot-plugins/sound_manager/sound_manager.gd")
	print("[SoundManager Plugin] Registered autoload: ", AUTOLOAD_NAME)

func _exit_tree():
	# Remove autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[SoundManager Plugin] Removed autoload: ", AUTOLOAD_NAME)
