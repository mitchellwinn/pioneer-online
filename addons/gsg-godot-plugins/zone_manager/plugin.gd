@tool
extends EditorPlugin

func _enter_tree():
	print("[Zone Manager Plugin] Initializing...")
	add_autoload_singleton("ZoneManager", "res://addons/gsg-godot-plugins/zone_manager/zone_manager.gd")
	print("[Zone Manager Plugin] Initialized successfully")

func _exit_tree():
	remove_autoload_singleton("ZoneManager")
	print("[Zone Manager Plugin] Cleanup complete")

