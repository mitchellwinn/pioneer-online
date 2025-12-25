@tool
extends EditorPlugin

func _enter_tree():
	print("[Network Manager Plugin] Initializing...")
	add_autoload_singleton("NetworkManager", "res://addons/gsg-godot-plugins/network_manager/network_manager.gd")
	print("[Network Manager Plugin] Initialized successfully")

func _exit_tree():
	remove_autoload_singleton("NetworkManager")
	print("[Network Manager Plugin] Cleanup complete")

