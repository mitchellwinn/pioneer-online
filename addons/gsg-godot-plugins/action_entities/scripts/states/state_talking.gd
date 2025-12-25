extends EntityState
class_name StateTalking

## Talking state - player is in UI mode (dialogue, shop, inventory, etc.)
## No movement, no attacks, no actions until all UIs close
## THIS IS THE SINGLE SOURCE OF TRUTH FOR MOUSE CAPTURE STATE

@export var max_npc_distance: float = 6.0

var npc_target: Node3D = null
var _player_camera: Node = null
var _exiting: bool = false  # Prevents recursive calls

func _ready():
	can_be_interrupted = false  # Can't be interrupted by other states
	priority = 100  # High priority
	allows_movement = false
	allows_rotation = false
	state_animation = "idle"

func on_enter(previous_state = null):
	super.on_enter(previous_state)
	
	_exiting = false
	
	# Show cursor - THIS IS THE ONLY PLACE MOUSE SHOULD BE MADE VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	# Stop any movement
	if entity is CharacterBody3D:
		entity.velocity = Vector3.ZERO
	
	# Find player camera reference
	_player_camera = entity.get_node_or_null("PlayerCamera")
	
	print("[StateTalking] Entered talking state, cursor visible")

func on_exit(next_state = null):
	# Prevent recursive calls
	if _exiting:
		return
	_exiting = true
	
	# Cancel dialogue via NetworkManager (notifies server to end session)
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("cancel_dialogue"):
		network.cancel_dialogue()
	
	# Clear any buffered inputs to prevent attacks from triggering on dialogue close
	if state_manager and state_manager.has_method("clear_input_buffers"):
		state_manager.clear_input_buffers()
	
	# Only re-capture mouse if NO UI panels need it visible
	# This is the SINGLE SOURCE OF TRUTH for mouse capture
	if not _any_ui_needs_mouse():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		print("[StateTalking] Exited talking state, cursor hidden")
	else:
		print("[StateTalking] Exited talking state, but UI still open - cursor stays visible")
	
	# Clear references
	npc_target = null
	_player_camera = null

func _any_ui_needs_mouse() -> bool:
	## Check if any UI panel is open that needs mouse visible
	## This prevents race conditions when transitioning between UIs
	
	# Check shop panel
	var shop = _find_node_in_tree("ShopPanel")
	if shop and shop.visible:
		return true
	
	# Check inventory panel
	var inventory = _find_node_in_tree("InventoryPanel")
	if inventory and inventory.visible:
		return true
	
	# Check player list
	var player_list = _find_node_in_tree("PlayerListUI")
	if player_list and player_list.visible:
		return true
	
	# Check dialogue UI
	var dialogue = _find_node_in_tree("DialogueUI")
	if dialogue and dialogue.visible:
		return true
	
	# Check notification popup
	var notification = _find_node_in_tree("NotificationPopup")
	if notification and notification.visible:
		return true
	
	return false

func _find_node_in_tree(node_name: String) -> Node:
	## Helper to find a node by name in the scene tree
	var tree = get_tree()
	if not tree:
		return null
	var nodes = tree.get_nodes_in_group("ui_needs_mouse")
	for node in nodes:
		if node.name == node_name:
			return node
	# Fallback: search by name
	return tree.root.find_child(node_name, true, false)

func on_physics_process(_delta: float):
	# Check distance from NPC - close dialogue if too far
	if npc_target and is_instance_valid(npc_target):
		var distance = entity.global_position.distance_to(npc_target.global_position)
		if distance > max_npc_distance:
			print("[StateTalking] Too far from NPC (%.1f > %.1f), ending dialogue" % [distance, max_npc_distance])
			_end_dialogue_and_exit()
			return
	
	# Escape to cancel dialogue
	if Input.is_action_just_pressed("ui_cancel"):
		_end_dialogue_and_exit()
		return

func _end_dialogue_and_exit():
	# Cancel dialogue via NetworkManager (notifies server)
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("cancel_dialogue"):
		network.cancel_dialogue()
	
	# Return to idle (this will trigger on_exit which also calls cancel_dialogue,
	# but the _exiting flag will prevent double-cancellation)
	transition_to("idle")

## Call this to set the NPC we're talking to
func set_npc(npc: Node3D):
	npc_target = npc

## Call this when dialogue ends externally
func dialogue_ended():
	if state_manager.get_current_state_name() == "talking":
		transition_to("idle")
