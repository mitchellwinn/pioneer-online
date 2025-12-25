extends "res://addons/gsg-godot-plugins/action_entities/scripts/action_entity.gd"
class_name ActionNPC

## ActionNPC - AI-controlled entity with navigation, behavior states, and interaction

signal target_acquired(target)
signal target_lost()
signal destination_reached()
signal path_failed()
signal interaction_started(player: Node)
signal interaction_ended(player: Node)
signal dialogue_requested(player: Node)

#region Configuration
@export_group("NPC Identity")
@export var npc_name: String = "NPC"
@export var dialogue_tree_id: String = ""  # Points to dialogue in database

@export_group("AI Behavior")
@export var behavior_type: String = "idle"  # idle, patrol, guard, aggressive
@export var detection_range: float = 15.0
@export var attack_range: float = 2.0
@export var lose_target_range: float = 25.0
@export var field_of_view: float = 120.0  # degrees

@export_group("Navigation")
@export var nav_agent: NavigationAgent3D
@export var patrol_points: Array[Marker3D] = []
@export var patrol_wait_time: float = 2.0
@export var wander_radius: float = 10.0

@export_group("Combat")
@export var aggression: float = 0.5  # 0 = passive, 1 = always attacks
@export var flee_health_threshold: float = 0.2  # Flee when health below this %

@export_group("Interaction")
@export var is_interactable: bool = true
@export var interaction_range: float = 3.0
@export var interaction_prompt: String = "Press E to talk"
@export var face_player_on_interact: bool = true
## Extra buffer for interaction area to prevent jittery prompt (area = range + buffer)
const INTERACTION_BUFFER: float = 0.5
@export var fallback_dialogue: Array[String] = ["..."]
## Height offset for interaction prompt (0 = ground, 1.5 = head height)
@export var prompt_height_offset: float = 1.5

@export_group("Invisible Mode")
## When true, hides model and disables collision - just an interact trigger
@export var invisible_mode: bool = false
## When true, hides the model but keeps collision
@export var hide_model_only: bool = false

@export_group("Shop")
## Shop ID for vendor NPCs (points to data/shops/{shop_id}.json)
@export var shop_id: String = ""

@export_group("Bank")
## Bank name displayed in UI
@export var bank_name: String = "Storage"

@export_group("Teleporter")
## Destination zone scene path
@export var destination_zone: String = ""
## Planet name for dialogue
@export var planet_name: String = ""
## Rental loadout weapon IDs
@export var rental_weapon_1: String = ""
@export var rental_weapon_2: String = ""
@export var rental_weapon_3: String = ""
#endregion

#region Runtime State
var current_target = null  # ActionEntity
var nav_destination: Vector3 = Vector3.ZERO
var is_navigating: bool = false
var patrol_index: int = 0
var wander_origin: Vector3 = Vector3.ZERO
var ai_think_timer: float = 0.0
const AI_THINK_INTERVAL: float = 0.2  # How often to update AI decisions

# Interaction state
var interaction_area: Area3D
var nearby_players: Array[Node] = []
var interacting_player: Node = null
var is_in_dialogue: bool = false
#endregion

func _ready():
	super._ready()

	wander_origin = global_position

	# Apply invisible mode
	if invisible_mode or hide_model_only:
		_apply_invisible_mode()

	# Setup navigation agent
	if not nav_agent:
		nav_agent = get_node_or_null("NavigationAgent3D")

	if nav_agent:
		nav_agent.velocity_computed.connect(_on_velocity_computed)
		nav_agent.target_reached.connect(_on_target_reached)
		nav_agent.navigation_finished.connect(_on_navigation_finished)

	# Setup interaction area
	_setup_interaction_area()

	# Add to groups
	add_to_group("npcs")
	if is_interactable:
		add_to_group("interactable")

## Stored spawn position for invisible NPCs (they don't use physics)
var _invisible_spawn_position: Vector3 = Vector3.ZERO

func _apply_invisible_mode():
	## Hide model and optionally disable collision for invisible NPCs

	# Store spawn position - invisible NPCs stay fixed in place
	_invisible_spawn_position = global_position

	# Hide the mesh/model
	var mesh_root = get_node_or_null("MeshRoot")
	if mesh_root:
		mesh_root.visible = false

	# Also check for direct model children
	for child in get_children():
		if child is MeshInstance3D or child.name.contains("Model") or child.name.contains("Mesh"):
			child.visible = false

	# Disable body collision in full invisible mode
	if invisible_mode:
		collision_layer = 0
		collision_mask = 0

		# Disable collision shapes (but not interaction area)
		for child in get_children():
			if child is CollisionShape3D and child.get_parent() == self:
				child.disabled = true

func _setup_interaction_area():
	if not is_interactable:
		return

	# Find existing or create interaction area (with buffer for less jittery detection)
	interaction_area = get_node_or_null("InteractionArea")
	if not interaction_area:
		interaction_area = Area3D.new()
		interaction_area.name = "InteractionArea"
		var shape = CollisionShape3D.new()
		var sphere = SphereShape3D.new()
		sphere.radius = interaction_range + INTERACTION_BUFFER
		shape.shape = sphere
		interaction_area.add_child(shape)
		add_child(interaction_area)

	# IMPORTANT: Ensure the Area3D can detect players (layer 2)
	# This is needed even if the InteractionArea exists in the scene
	interaction_area.collision_layer = 0  # NPCs don't need to be detected by other areas
	interaction_area.collision_mask = 2   # Detect players (collision layer 2)
	interaction_area.monitoring = true
	interaction_area.monitorable = false

	if not interaction_area.body_entered.is_connected(_on_interaction_body_entered):
		interaction_area.body_entered.connect(_on_interaction_body_entered)
	if not interaction_area.body_exited.is_connected(_on_interaction_body_exited):
		interaction_area.body_exited.connect(_on_interaction_body_exited)

func _physics_process(delta: float):
	# Invisible NPCs don't use physics - stay at spawn position
	if invisible_mode:
		global_position = _invisible_spawn_position
		# Still update interaction prompts
		_update_nearby_player_prompts()
		return  # Skip all physics (gravity, movement, etc.)

	# AI thinking
	ai_think_timer += delta
	if ai_think_timer >= AI_THINK_INTERVAL:
		ai_think_timer = 0.0
		_ai_think()

	# Navigation movement
	if is_navigating and nav_agent:
		_update_navigation()
	
	# Check if dialogue ended (player closed dialogue but didn't leave area)
	if is_in_dialogue and interacting_player:
		if not _is_player_in_dialogue(interacting_player):
			end_interaction()

	# Update interaction prompt visibility based on actual distance (more reliable than Area3D alone)
	_update_nearby_player_prompts()

	super._physics_process(delta)

func _is_player_in_dialogue(player: Node) -> bool:
	## Check if player is still in dialogue mode
	# Check state manager for talking state
	var state_manager = player.get_node_or_null("StateManager")
	if state_manager and state_manager.has_method("get_current_state_name"):
		return state_manager.get_current_state_name() == "talking"
	# Fallback: check NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if network and "_current_dialogue_node_id" in network:
		return not network._current_dialogue_node_id.is_empty()
	return false

func _update_nearby_player_prompts():
	## Continuously check if nearby players should see/hide interaction prompt
	for player in nearby_players:
		if not is_instance_valid(player):
			continue
		
		var dist = global_position.distance_to(player.global_position)
		var should_show = dist <= interaction_range and can_interact()
		
		if should_show:
			if player.has_method("show_interaction_prompt"):
				# Only update if this NPC is the closest interactable
				var nearest = _get_player_nearest_interactable(player)
				if nearest == self:
					player.show_interaction_prompt(interaction_prompt, self)
		else:
			# Player is out of interaction range (but still in detection area)
			if player.has_method("hide_interaction_prompt"):
				# Only hide if we were the one showing the prompt
				if player.has_method("get_prompt_target") and player.get_prompt_target() == self:
					player.hide_interaction_prompt()

func _get_player_nearest_interactable(player: Node) -> Node:
	## Helper to check if this NPC is the nearest interactable to the player
	var nearest: Node = null
	var nearest_dist: float = INF
	
	for interactable in player.get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(interactable):
			continue
		if interactable.has_method("can_interact") and not interactable.can_interact():
			continue
		
		var dist = player.global_position.distance_to(interactable.global_position)
		if dist < nearest_dist and dist <= interaction_range:
			nearest_dist = dist
			nearest = interactable
	
	return nearest

#region AI Decision Making
func _ai_think():
	# Server-only AI processing in multiplayer
	if network_identity and not network_identity.is_local_authority:
		return
	
	# Check for targets
	_scan_for_targets()
	
	# Update behavior based on current state
	match behavior_type:
		"aggressive":
			_think_aggressive()
		"guard":
			_think_guard()
		"patrol":
			_think_patrol()
		"idle":
			_think_idle()

func _scan_for_targets():
	if current_target:
		# Check if we should lose current target
		if not is_instance_valid(current_target) or current_target.is_dead():
			_lose_target()
			return
		
		var distance = global_position.distance_to(current_target.global_position)
		if distance > lose_target_range:
			_lose_target()
			return
	
	# Look for new targets
	if not current_target:
		# Get entities from group to avoid class_name load order issues
		var potential_targets = _get_entities_in_range(detection_range)
		for entity in potential_targets:
			if _is_valid_target(entity):
				if _can_see_target(entity):
					_acquire_target(entity)
					break

func _get_entities_in_range(radius: float) -> Array:
	## Get all ActionEntities within radius using groups (avoids class_name load order issues)
	var entities: Array = []
	for entity in get_tree().get_nodes_in_group("action_entities"):
		if is_instance_valid(entity) and entity is Node3D:
			if entity.global_position.distance_to(global_position) <= radius:
				entities.append(entity)
	return entities

func _is_valid_target(entity) -> bool:
	if entity == self:
		return false
	if entity.team_id == team_id:
		return false
	if entity.is_dead():
		return false
	return true

func _can_see_target(target) -> bool:
	# Check field of view
	var to_target = (target.global_position - global_position).normalized()
	var forward = -global_transform.basis.z
	var angle = rad_to_deg(acos(forward.dot(to_target)))
	
	if angle > field_of_view / 2.0:
		return false
	
	# Raycast check for obstacles
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP,
		target.global_position + Vector3.UP
	)
	query.exclude = [self]
	
	var result = space_state.intersect_ray(query)
	if result and result.collider != target:
		return false
	
	return true

func _acquire_target(target):
	current_target = target
	target_acquired.emit(target)

func _lose_target():
	current_target = null
	target_lost.emit()

func _think_aggressive():
	if current_target:
		var distance = global_position.distance_to(current_target.global_position)
		
		if distance <= attack_range:
			# In attack range - attack
			stop_navigation()
			set_facing(current_target.global_position - global_position)
			_try_attack()
		else:
			# Chase target
			navigate_to(current_target.global_position)
	else:
		# Wander or idle
		if not is_navigating:
			_start_wander()

func _think_guard():
	if current_target:
		var distance = global_position.distance_to(current_target.global_position)
		
		if distance <= attack_range:
			stop_navigation()
			set_facing(current_target.global_position - global_position)
			_try_attack()
		elif distance <= detection_range:
			navigate_to(current_target.global_position)
	else:
		# Return to guard position
		if global_position.distance_to(wander_origin) > 1.0:
			navigate_to(wander_origin)

func _think_patrol():
	if current_target:
		_think_aggressive()
		return
	
	if not is_navigating and patrol_points.size() > 0:
		var next_point = patrol_points[patrol_index]
		patrol_index = (patrol_index + 1) % patrol_points.size()
		navigate_to(next_point.global_position)

func _think_idle():
	if current_target and aggression > 0:
		_think_aggressive()

func _try_attack():
	if state_manager and not state_manager.is_in_state("attack_light"):
		state_manager.change_state("attack_light")

func _start_wander():
	var random_offset = Vector3(
		randf_range(-wander_radius, wander_radius),
		0,
		randf_range(-wander_radius, wander_radius)
	)
	var target = wander_origin + random_offset
	navigate_to(target)
#endregion

#region Navigation
func navigate_to(target_pos: Vector3) -> bool:
	if not nav_agent:
		return false
	
	nav_destination = target_pos
	nav_agent.target_position = target_pos
	is_navigating = true
	return true

func stop_navigation():
	is_navigating = false
	if nav_agent:
		nav_agent.target_position = global_position
	move_direction = Vector3.ZERO

func _update_navigation():
	if not nav_agent or nav_agent.is_navigation_finished():
		return
	
	var next_pos = nav_agent.get_next_path_position()
	var direction = (next_pos - global_position).normalized()
	direction.y = 0
	
	# Use safe velocity for avoidance
	if nav_agent.avoidance_enabled:
		nav_agent.velocity = direction * base_move_speed
	else:
		move_direction = direction
		face_direction = direction

func _on_velocity_computed(safe_velocity: Vector3):
	if is_navigating:
		var direction = safe_velocity.normalized()
		direction.y = 0
		move_direction = direction
		if direction.length() > 0.1:
			face_direction = direction

func _on_target_reached():
	is_navigating = false
	destination_reached.emit()

func _on_navigation_finished():
	is_navigating = false
#endregion

#region Override Entity Methods
func get_movement_input() -> Vector3:
	return move_direction
#endregion

#region AI Control
func set_behavior(new_behavior: String):
	behavior_type = new_behavior

func force_target(target):
	_acquire_target(target)

func clear_target():
	_lose_target()
#endregion

#region Interaction System
func _on_interaction_body_entered(body: Node):
	if body.is_in_group("players"):
		if body not in nearby_players:
			nearby_players.append(body)
		# Don't show prompt immediately - let _update_nearby_player_prompts handle it
		# This prevents flicker when quickly entering/exiting the buffer zone

func _on_interaction_body_exited(body: Node):
	if body in nearby_players:
		nearby_players.erase(body)
		# Player left the buffered area - definitely hide prompt
		if body.has_method("hide_interaction_prompt"):
			if body.has_method("get_prompt_target") and body.get_prompt_target() == self:
				body.hide_interaction_prompt()
		
		if interacting_player == body:
			end_interaction()

func can_interact() -> bool:
	return is_interactable and not is_in_dialogue

func start_interaction(player: Node):
	if not can_interact():
		return
	
	interacting_player = player
	
	# Face the player
	if face_player_on_interact:
		var dir_to_player = (player.global_position - global_position).normalized()
		dir_to_player.y = 0
		if dir_to_player.length() > 0.1:
			set_facing(dir_to_player)
	
	interaction_started.emit(player)
	
	# Start dialogue
	_start_dialogue(player)

func end_interaction():
	if interacting_player:
		var player = interacting_player
		interacting_player = null
		is_in_dialogue = false
		interaction_ended.emit(player)

func _start_dialogue(_player: Node):
	is_in_dialogue = true
	dialogue_requested.emit(_player)
	
	if dialogue_tree_id.is_empty():
		_show_fallback_dialogue()
		return
	
	# Use server-authoritative dialogue via NetworkManager
	var network = get_node_or_null("/root/NetworkManager")
	if network and network.has_method("request_dialogue"):
		network.request_dialogue(dialogue_tree_id)
		return
	
	# No NetworkManager - show fallback
	_show_fallback_dialogue()

func _show_fallback_dialogue():
	if fallback_dialogue.size() > 0:
		print("[", npc_name, "] ", fallback_dialogue[0])
	end_interaction()

func get_npc_id() -> String:
	return entity_id if entity_id else name

func get_dialogue_tree_id() -> String:
	return dialogue_tree_id if dialogue_tree_id else get_npc_id()

func handle_dialogue_event(event: Dictionary, player: Node) -> bool:
	## Called by dialogue system when an event is triggered
	## Routes to PioneerEventManager for handling
	var event_manager = get_node_or_null("/root/PioneerEventManager")
	if event_manager and event_manager.has_method("handle_dialogue_event"):
		return event_manager.handle_dialogue_event(event, player, self)

	push_warning("[ActionNPC] PioneerEventManager not found, cannot handle event: %s" % event)
	return false
#endregion

