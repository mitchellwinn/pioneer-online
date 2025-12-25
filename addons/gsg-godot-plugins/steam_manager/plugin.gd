@tool
extends EditorPlugin

func _enter_tree():
	print("[Steam Manager Plugin] Initializing...")
	add_autoload_singleton("SteamManager", "res://addons/gsg-godot-plugins/steam_manager/steam_manager.gd")
	print("[Steam Manager Plugin] Initialized successfully")

func _exit_tree():
	remove_autoload_singleton("SteamManager")
	print("[Steam Manager Plugin] Cleanup complete")

