@tool
extends EditorPlugin

const AUTOLOAD_NAME = "MusicManager"

func _enter_tree():
	# Add autoload
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gsg-godot-plugins/music_manager/music_manager.gd")
	print("[MusicManager Plugin] Registered autoload: ", AUTOLOAD_NAME)

func _exit_tree():
	# Remove autoload
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[MusicManager Plugin] Removed autoload: ", AUTOLOAD_NAME)
