extends NPCState
class_name NPCStateIdle

# Idle state - NPC stands in place
# Managed by events and other systems

# Idle behavior parameters
@export var look_around: bool = false # Whether NPC looks around while idle
@export var look_interval_min: float = 2.0 # Min time between looking
@export var look_interval_max: float = 5.0 # Max time between looking

var look_timer: float = 0.0
var next_look_time: float = 0.0

func on_start():
	# Stop any navigation
	if npc.is_navigating:
		npc.stop_navigation()
	
	# Initialize look timer
	if look_around:
		next_look_time = randf_range(look_interval_min, look_interval_max)
		look_timer = 0.0

func on_end():
	pass

func on_process(_delta: float):
	# Idle state doesn't do anything automatically
	# It can still be controlled by events, look_at_player, etc.
	pass

func on_physics_process(delta: float):
	if look_around:
		look_timer += delta
		if look_timer >= next_look_time:
			_look_random_direction()
			next_look_time = randf_range(look_interval_min, look_interval_max)
			look_timer = 0.0

func _look_random_direction():
	var random_angle = randf() * TAU
	var random_dir = Vector3(cos(random_angle), 0, sin(random_angle))
	npc.direction = random_dir
	npc.dir_string = npc.get_string_dir()



