extends NPCState
class_name NPCStateWander

# Wander state - NPC picks random points and meanders around

# Wander parameters
@export var wander_radius: float = 5.0 # How far from origin to wander
@export var min_wait_time: float = 2.0 # Minimum time to wait at each point
@export var max_wait_time: float = 5.0 # Maximum time to wait at each point
@export var look_around_chance: float = 0.3 # Chance to look around while waiting

var origin_position: Vector3 # Where the NPC started wandering from
var is_waiting: bool = false
var wait_timer: float = 0.0
var target_wait_time: float = 0.0

func on_start():
	# Store origin position
	origin_position = npc.global_position
	# Start wandering immediately
	_pick_new_wander_point()

func on_end():
	# Stop navigation when leaving wander state
	npc.stop_navigation()
	npc.is_navigating = false
	npc.stop()
	is_waiting = false
	wait_timer = 0.0

func on_process(_delta: float):
	pass

func on_physics_process(delta: float):
	if is_waiting:
		# Count down wait timer
		wait_timer -= delta
		if wait_timer <= 0:
			is_waiting = false
			_pick_new_wander_point()
	elif npc.is_navigating:
		# Currently moving to a wander point - check if we've reached it
		if npc.is_at_target():
			# Arrived at wander point, start waiting
			npc.stop_navigation()
			_start_waiting()

func _pick_new_wander_point():
	if not npc.nav_agent:
		print("[WANDER] No navigation agent, waiting in place")
		_start_waiting()
		return
	
	var nav_map = npc.nav_agent.get_navigation_map()
	
	# Ensure minimum distance is greater than nav_agent's target_desired_distance
	var min_distance = npc.nav_agent.target_desired_distance + 0.5
	var effective_radius = max(wander_radius, min_distance + 0.5)
	
	# Pick a random point within wander radius, but ensure it's far enough away
	var random_offset = Vector3.ZERO
	var attempts = 0
	while random_offset.length() < min_distance and attempts < 10:
		random_offset = Vector3(
			randf_range(-effective_radius, effective_radius),
			0,
			randf_range(-effective_radius, effective_radius)
		)
		attempts += 1
	
	var target_pos = origin_position + random_offset
	
	# Snap to nearest valid navmesh point (fast, no raycasts needed)
	var closest_point = NavigationServer3D.map_get_closest_point(nav_map, target_pos)
	
	# Navigate to the point
	var success = npc.navigate_to_position(closest_point)
	if not success:
		_start_waiting()
	else:
		print("[WANDER] ", npc.name, " navigating to ", closest_point)

func _start_waiting():
	is_waiting = true
	target_wait_time = randf_range(min_wait_time, max_wait_time)
	wait_timer = target_wait_time
	
	# Maybe look around
	if randf() < look_around_chance:
		_look_around()

func _look_around():
	# Pick a random direction to look
	var random_direction = Vector3(
		randf_range(-1, 1),
		0,
		randf_range(-1, 1)
	).normalized()
	
	if random_direction.length() > 0.01:
		npc.direction = random_direction
		npc.last_direction = random_direction  # Store for camera-relative facing updates



