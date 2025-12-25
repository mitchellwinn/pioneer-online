@tool
extends EditorPlugin

func _enter_tree():
	print("[Database Manager Plugin] Initializing...")
	add_autoload_singleton("DatabaseManager", "res://addons/gsg-godot-plugins/database_manager/database_manager.gd")
	print("[Database Manager Plugin] Initialized successfully")

func _exit_tree():
	remove_autoload_singleton("DatabaseManager")
	print("[Database Manager Plugin] Cleanup complete")

