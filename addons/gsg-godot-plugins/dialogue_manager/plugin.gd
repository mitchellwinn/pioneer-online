@tool
extends EditorPlugin

func _enter_tree():
	# Register the DialogueManager singleton
	add_autoload_singleton("DialogueManager", "res://addons/gsg-godot-plugins/dialogue_manager/dialogue_manager.gd")
	print("[DialogueManager Plugin] Registered DialogueManager autoload")

func _exit_tree():
	# Unregister the DialogueManager singleton
	remove_autoload_singleton("DialogueManager")
	print("[DialogueManager Plugin] Removed DialogueManager autoload")
