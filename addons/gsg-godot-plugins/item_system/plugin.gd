@tool
extends EditorPlugin

func _enter_tree():
	add_autoload_singleton("ItemDatabase", "res://addons/gsg-godot-plugins/item_system/item_database.gd")

func _exit_tree():
	remove_autoload_singleton("ItemDatabase")




