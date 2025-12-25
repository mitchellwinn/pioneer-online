extends Node3D
class_name ProceduralBodyTurn

## Simple upper body rotation when strafing
## Just rotates the mesh slightly - no IK or complex logic

@export var mesh_root: Node3D  # The visual mesh to rotate
@export var max_turn_angle: float = 3.0  # Max degrees of rotation (barely noticeable)
@export var turn_speed: float = 6.0  # How fast it rotates
@export var velocity_threshold: float = 0.3  # Min velocity to register as moving

var parent_entity: Node3D
var current_turn: float = 0.0

func _ready():
	parent_entity = get_parent()
	
	# Try to find mesh root if not assigned
	if not mesh_root:
		mesh_root = parent_entity.get_node_or_null("MeshRoot")
	
	if not mesh_root:
		push_warning("[ProceduralBodyTurn] No MeshRoot found")

func _process(delta: float):
	if not mesh_root or not parent_entity:
		return
	
	# Get horizontal velocity
	var target_turn: float = 0.0
	
	if "velocity" in parent_entity:
		var vel = parent_entity.velocity
		var horizontal_vel = Vector3(vel.x, 0, vel.z)
		
		if horizontal_vel.length() > velocity_threshold:
			# Get local movement direction (relative to entity facing)
			var local_dir = parent_entity.global_transform.basis.inverse() * horizontal_vel.normalized()
			
			# Slight rotation based on sideways movement
			# Moving right (positive X) = slight left rotation (positive Y)
			target_turn = local_dir.x * max_turn_angle
	
	# Smooth interpolation
	current_turn = lerp(current_turn, target_turn, turn_speed * delta)
	
	# Apply only Y rotation to mesh root
	mesh_root.rotation.y = deg_to_rad(current_turn)

