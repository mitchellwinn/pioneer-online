@tool
extends EditorPlugin

func _enter_tree():
	# Add MenuManager as autoload
	add_autoload_singleton("MenuManager", "res://addons/gsg-godot-plugins/menu_manager/menu_manager.gd")
	print("[MenuManager Plugin] Enabled")

func _exit_tree():
	# Remove MenuManager autoload
	remove_autoload_singleton("MenuManager")
	print("[MenuManager Plugin] Disabled")
