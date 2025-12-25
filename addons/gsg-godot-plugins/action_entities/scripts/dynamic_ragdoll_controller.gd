extends Node
class_name DynamicRagdollController

## Dynamic Ragdoll Controller - Active ragdoll with procedural hit reactions
## Physical bones are always simulating but constrained to follow animation.
## On hit, nearby bones temporarily loosen for visceral impact feedback.

signal hit_impact_applied(bone_name: String, force: Vector3)
signal full_ragdoll_enabled()
signal full_ragdoll_disabled()

#region Configuration
@export_group("Skeleton Reference")
@export var skeleton_path: NodePath
@export var animation_player_path: NodePath

@export_group("Follow Strength")
## Base force multiplier for bones following animation (higher = stiffer)
@export var base_follow_strength: float = 50.0
## Angular force for rotation matching
@export var angular_follow_strength: float = 30.0
## Damping to prevent oscillation
@export var follow_damping: float = 5.0

@export_group("Hit Reaction")
## How much follow strength drops on direct hit (0 = full ragdoll, 1 = no effect)
@export var hit_looseness: float = 0.1
## How far the looseness spreads to neighboring bones (in bone chain distance)
@export var hit_spread_radius: int = 2
## How much looseness falls off per bone distance (multiplier per step)
@export var spread_falloff: float = 0.5
## Time to recover back to full follow strength
@export var recovery_time: float = 0.4
## Impulse multiplier applied to hit bone
@export var hit_impulse_multiplier: float = 1.0

@export_group("Full Ragdoll (Death)")
## Follow strength when fully ragdolled (death)
@export var ragdoll_follow_strength: float = 0.0
## Time to blend into full ragdoll
@export var ragdoll_blend_time: float = 0.15
#endregion

#region Internal State
var skeleton: Skeleton3D
var animation_player: AnimationPlayer
var physical_bones: Dictionary = {}  # bone_name -> PhysicalBone3D
var bone_parents: Dictionary = {}  # bone_name -> parent_bone_name
var bone_children: Dictionary = {}  # bone_name -> [child_bone_names]

# Per-bone follow strength (1.0 = full follow, 0.0 = full ragdoll)
var bone_follow_multipliers: Dictionary = {}  # bone_name -> current_multiplier
var bone_target_multipliers: Dictionary = {}  # bone_name -> target_multiplier

# Cached animated poses for comparison
var animated_bone_poses: Dictionary = {}  # bone_idx -> Transform3D

var is_full_ragdoll: bool = false
var ragdoll_blend_progress: float = 0.0
#endregion

func _ready():
	# Get skeleton reference
	if skeleton_path:
		skeleton = get_node_or_null(skeleton_path)
	
	if not skeleton:
		# Try to find skeleton in parent
		skeleton = _find_skeleton(get_parent())
	
	if not skeleton:
		push_error("[DynamicRagdollController] No Skeleton3D found!")
		return
	
	# Get animation player
	if animation_player_path:
		animation_player = get_node_or_null(animation_player_path)
	
	# Discover physical bones and build hierarchy
	_discover_physical_bones()
	_build_bone_hierarchy()
	
	# Initialize all bones to full follow
	for bone_name in physical_bones.keys():
		bone_follow_multipliers[bone_name] = 1.0
		bone_target_multipliers[bone_name] = 1.0
	
	# Start simulation
	call_deferred("_start_simulation")

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found = _find_skeleton(child)
		if found:
			return found
	return null

func _discover_physical_bones():
	physical_bones.clear()
	for i in skeleton.get_bone_count():
		var bone_name = skeleton.get_bone_name(i)
		# Physical bones are children of the skeleton with matching names
		for child in skeleton.get_children():
			if child is PhysicalBone3D and child.bone_name == bone_name:
				physical_bones[bone_name] = child
				break

func _build_bone_hierarchy():
	bone_parents.clear()
	bone_children.clear()
	
	for i in skeleton.get_bone_count():
		var bone_name = skeleton.get_bone_name(i)
		var parent_idx = skeleton.get_bone_parent(i)
		
		if parent_idx >= 0:
			var parent_name = skeleton.get_bone_name(parent_idx)
			bone_parents[bone_name] = parent_name
			
			if not bone_children.has(parent_name):
				bone_children[parent_name] = []
			bone_children[parent_name].append(bone_name)

func _start_simulation():
	if skeleton and physical_bones.size() > 0:
		skeleton.physical_bones_start_simulation()
		print("[DynamicRagdollController] Started simulation with %d physical bones" % physical_bones.size())

func _physics_process(delta: float):
	if not skeleton or physical_bones.size() == 0:
		return
	
	# Update follow multipliers (smooth recovery)
	_update_follow_multipliers(delta)
	
	# Cache current animated poses
	_cache_animated_poses()
	
	# Apply follow forces to each physical bone
	for bone_name in physical_bones.keys():
		_apply_follow_force(bone_name, delta)

func _update_follow_multipliers(delta: float):
	var recovery_speed = 1.0 / recovery_time if recovery_time > 0 else 100.0
	
	for bone_name in bone_follow_multipliers.keys():
		var current = bone_follow_multipliers[bone_name]
		var target = bone_target_multipliers[bone_name]
		
		# Smoothly recover toward target
		if current < target:
			bone_follow_multipliers[bone_name] = minf(current + recovery_speed * delta, target)
		elif current > target:
			# Instant loosening on hit
			bone_follow_multipliers[bone_name] = target

func _cache_animated_poses():
	# Store the current animated bone transforms before physics override
	for i in skeleton.get_bone_count():
		animated_bone_poses[i] = skeleton.get_bone_global_pose(i)

func _apply_follow_force(bone_name: String, delta: float):
	var phys_bone: PhysicalBone3D = physical_bones[bone_name]
	if not phys_bone or not phys_bone.is_simulating_physics():
		return
	
	var bone_idx = skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return
	
	# Get animated target pose
	var target_pose: Transform3D = animated_bone_poses.get(bone_idx, Transform3D.IDENTITY)
	var target_global = skeleton.global_transform * target_pose
	
	# Current physics bone state
	var current_global = phys_bone.global_transform
	
	# Follow strength based on multiplier
	var follow_mult = bone_follow_multipliers.get(bone_name, 1.0)
	var effective_strength = base_follow_strength * follow_mult
	var effective_angular = angular_follow_strength * follow_mult
	
	if effective_strength < 0.01:
		return  # Full ragdoll, no forces
	
	# --- Position Force ---
	var pos_diff = target_global.origin - current_global.origin
	var velocity_damping = -phys_bone.linear_velocity * follow_damping * follow_mult
	var pos_force = pos_diff * effective_strength + velocity_damping
	
	phys_bone.apply_central_force(pos_force * phys_bone.mass)
	
	# --- Rotation Torque ---
	var current_basis = current_global.basis
	var target_basis = target_global.basis
	
	# Calculate rotation difference as axis-angle
	var rot_diff = (target_basis * current_basis.inverse())
	var axis_angle = _basis_to_axis_angle(rot_diff)
	
	var angular_damping = -phys_bone.angular_velocity * follow_damping * follow_mult
	var torque = axis_angle * effective_angular + angular_damping
	
	phys_bone.apply_torque(torque * phys_bone.mass)

func _basis_to_axis_angle(basis: Basis) -> Vector3:
	# Convert rotation basis to axis-angle representation
	var angle = acos(clampf((basis.x.x + basis.y.y + basis.z.z - 1.0) / 2.0, -1.0, 1.0))
	if abs(angle) < 0.001:
		return Vector3.ZERO
	
	var axis = Vector3(
		basis.z.y - basis.y.z,
		basis.x.z - basis.z.x,
		basis.y.x - basis.x.y
	).normalized()
	
	return axis * angle

#region Hit Reactions
## Apply hit impact to a specific bone - loosens it and neighbors temporarily
func apply_hit_impact(bone_name: String, hit_direction: Vector3 = Vector3.ZERO, impact_force: float = 10.0):
	if not physical_bones.has(bone_name):
		# Try to find closest physical bone
		bone_name = _find_closest_physical_bone(bone_name)
		if bone_name.is_empty():
			return
	
	# Loosen the hit bone
	bone_target_multipliers[bone_name] = hit_looseness
	bone_follow_multipliers[bone_name] = hit_looseness
	
	# Spread to neighbors with falloff
	_spread_looseness(bone_name, hit_spread_radius, hit_looseness)
	
	# Apply impulse force
	if hit_direction.length() > 0.01:
		var phys_bone: PhysicalBone3D = physical_bones[bone_name]
		if phys_bone:
			var impulse = hit_direction.normalized() * impact_force * hit_impulse_multiplier
			phys_bone.apply_central_impulse(impulse)
	
	# Schedule recovery
	_schedule_recovery(bone_name)
	
	hit_impact_applied.emit(bone_name, hit_direction)

## Apply hit from world position - finds the closest bone automatically
func apply_hit_at_position(world_position: Vector3, hit_direction: Vector3, impact_force: float = 10.0):
	var closest_bone = _find_bone_at_position(world_position)
	if not closest_bone.is_empty():
		apply_hit_impact(closest_bone, hit_direction, impact_force)

func _spread_looseness(center_bone: String, radius: int, base_looseness: float):
	if radius <= 0:
		return
	
	var affected_bones: Dictionary = {center_bone: 0}  # bone_name -> distance
	var to_process: Array = [center_bone]
	
	while to_process.size() > 0:
		var current = to_process.pop_front()
		var current_dist = affected_bones[current]
		
		if current_dist >= radius:
			continue
		
		# Get neighbors (parent and children)
		var neighbors: Array = []
		if bone_parents.has(current):
			neighbors.append(bone_parents[current])
		if bone_children.has(current):
			neighbors.append_array(bone_children[current])
		
		for neighbor in neighbors:
			if not affected_bones.has(neighbor) and physical_bones.has(neighbor):
				var new_dist = current_dist + 1
				affected_bones[neighbor] = new_dist
				to_process.append(neighbor)
				
				# Calculate falloff looseness
				var falloff = pow(spread_falloff, new_dist)
				var neighbor_looseness = lerpf(1.0, base_looseness, falloff)
				
				# Only loosen if it would make it looser
				if neighbor_looseness < bone_target_multipliers.get(neighbor, 1.0):
					bone_target_multipliers[neighbor] = neighbor_looseness
					bone_follow_multipliers[neighbor] = neighbor_looseness

func _schedule_recovery(bone_name: String):
	# After recovery_time, set target back to 1.0
	# The _update_follow_multipliers will smoothly recover
	await get_tree().create_timer(recovery_time * 0.5).timeout
	
	if not is_full_ragdoll:
		bone_target_multipliers[bone_name] = 1.0
		
		# Also recover spread bones
		for other_bone in bone_target_multipliers.keys():
			if not is_full_ragdoll:
				bone_target_multipliers[other_bone] = 1.0

func _find_closest_physical_bone(bone_name: String) -> String:
	# Walk up the hierarchy to find a physical bone
	var current = bone_name
	while current and not current.is_empty():
		if physical_bones.has(current):
			return current
		current = bone_parents.get(current, "")
	
	# Fallback to any physical bone
	if physical_bones.size() > 0:
		return physical_bones.keys()[0]
	return ""

func _find_bone_at_position(world_pos: Vector3) -> String:
	var closest_bone: String = ""
	var closest_dist: float = INF
	
	for bone_name in physical_bones.keys():
		var phys_bone: PhysicalBone3D = physical_bones[bone_name]
		var dist = phys_bone.global_position.distance_to(world_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_bone = bone_name
	
	return closest_bone
#endregion

#region Full Ragdoll (Death)
func enable_full_ragdoll(impulse: Vector3 = Vector3.ZERO, impulse_bone: String = ""):
	is_full_ragdoll = true
	
	# Set all bones to ragdoll
	for bone_name in bone_target_multipliers.keys():
		bone_target_multipliers[bone_name] = ragdoll_follow_strength
	
	# Tween the actual multipliers for smooth blend
	var tween = create_tween()
	tween.set_parallel(true)
	
	for bone_name in bone_follow_multipliers.keys():
		# Use a callable to update the dictionary
		var start_val = bone_follow_multipliers[bone_name]
		tween.tween_method(
			func(val): bone_follow_multipliers[bone_name] = val,
			start_val,
			ragdoll_follow_strength,
			ragdoll_blend_time
		)
	
	# Apply death impulse
	if impulse.length() > 0.01:
		var target_bone = impulse_bone if physical_bones.has(impulse_bone) else _find_closest_physical_bone(impulse_bone)
		if not target_bone.is_empty():
			var phys_bone: PhysicalBone3D = physical_bones[target_bone]
			if phys_bone:
				# Delay slightly for physics to activate
				await get_tree().create_timer(0.05).timeout
				phys_bone.apply_central_impulse(impulse)
	
	full_ragdoll_enabled.emit()

func disable_full_ragdoll():
	is_full_ragdoll = false
	
	# Restore all bones to full follow
	for bone_name in bone_target_multipliers.keys():
		bone_target_multipliers[bone_name] = 1.0
	
	# Tween back
	var tween = create_tween()
	tween.set_parallel(true)
	
	for bone_name in bone_follow_multipliers.keys():
		var start_val = bone_follow_multipliers[bone_name]
		tween.tween_method(
			func(val): bone_follow_multipliers[bone_name] = val,
			start_val,
			1.0,
			ragdoll_blend_time * 2  # Slower recovery from death
		)
	
	full_ragdoll_enabled.emit()
#endregion

#region Utility
func set_bone_follow_strength(bone_name: String, strength: float):
	if bone_follow_multipliers.has(bone_name):
		bone_follow_multipliers[bone_name] = clampf(strength, 0.0, 1.0)
		bone_target_multipliers[bone_name] = clampf(strength, 0.0, 1.0)

func get_bone_follow_strength(bone_name: String) -> float:
	return bone_follow_multipliers.get(bone_name, 1.0)

func is_simulating() -> bool:
	return skeleton != null and physical_bones.size() > 0
#endregion



