@tool
extends CSGBox3D

## Automatically sizes this CSG box to match the parent Area3D's CollisionShape3D
## This provides a visual representation of the zone boundaries in the editor
## Toggle visibility manually in the inspector to show/hide

@export_range(0.0, 1.0, 0.01) var color: float = 0.5:
	set(value):
		color = value
		if Engine.is_editor_hint():
			_update_color()

func _ready():
	if Engine.is_editor_hint():
		_update_size()
		_update_color()

func _process(_delta):
	if Engine.is_editor_hint():
		_update_size()

func _update_color():
	var material = material_override as ShaderMaterial
	if not material:
		return
	
	# Generate a color from the hue slider using HSV
	# Hue varies with slider, saturation and value are fixed for vibrant colors
	var hue = color
	var saturation = 0.8
	var value = 1.0
	var alpha = 0.3
	
	var stripe_color = Color.from_hsv(hue, saturation, value, alpha)
	material.set_shader_parameter("stripe_color", stripe_color)

func _update_size():
	var parent = get_parent()
	if not parent or not parent is Area3D:
		return
	
	# Find the CollisionShape3D in the parent Area3D
	var collision_shape: CollisionShape3D = null
	for child in parent.get_children():
		if child is CollisionShape3D:
			collision_shape = child
			break
	
	if not collision_shape or not collision_shape.shape:
		return
	
	var shape = collision_shape.shape
	
	# Handle different shape types
	if shape is BoxShape3D:
		size = shape.size
		position = collision_shape.position
	elif shape is CylinderShape3D:
		# Approximate cylinder with a box
		size = Vector3(shape.radius * 2, shape.height, shape.radius * 2)
		position = collision_shape.position
	elif shape is CapsuleShape3D:
		# Approximate capsule with a box
		size = Vector3(shape.radius * 2, shape.height, shape.radius * 2)
		position = collision_shape.position
	elif shape is SphereShape3D:
		# Approximate sphere with a cube
		var diameter = shape.radius * 2
		size = Vector3(diameter, diameter, diameter)
		position = collision_shape.position
