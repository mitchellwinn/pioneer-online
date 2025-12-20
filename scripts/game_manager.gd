extends Node

## Minimal GameManager for pioneer-online
## Provides the properties that gsg-godot-plugins expect

# Player reference
var player: Node = null

# Camera reference
var main_camera: Camera3D = null

# Party system (for multiplayer, this might be empty or contain squad members)
var party: Array = []

# UI references
var dialogue_label: RichTextLabel = null
var main_dialogue_box: Control = null
var shop_window: Control = null

# Game state
var is_transitioning: bool = false
var game_language: String = "english"

# Flags dictionary (for conditional spawning, etc.)
var flags: Dictionary = {}

# Signals
signal player_spawned

func _ready():
	print("[GameManager] Initialized")

## Get scene references (called by player when it spawns)
func get_scene_references() -> void:
	# Try to find main camera in scene
	if not main_camera:
		var cameras = get_tree().get_nodes_in_group("cameras")
		if cameras.size() > 0:
			main_camera = cameras[0] as Camera3D
		else:
			# Try to find any Camera3D in scene
			var scene = get_tree().current_scene
			if scene:
				main_camera = _find_camera_recursive(scene)

## Recursively find a camera in the scene tree
func _find_camera_recursive(node: Node) -> Camera3D:
	if node is Camera3D:
		return node as Camera3D
	
	for child in node.get_children():
		var result = _find_camera_recursive(child)
		if result:
			return result
	
	return null

## Get a flag value
func get_flag(flag_name: String) -> bool:
	return flags.get(flag_name, false)

## Set a flag value
func set_flag(flag_name: String, value: bool) -> void:
	flags[flag_name] = value

## Get party NPCs (for RPG-style games, returns empty for action games)
func get_party_npcs() -> Array:
	return party.filter(func(member): return member != player)

