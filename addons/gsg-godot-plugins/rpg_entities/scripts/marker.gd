extends Entity
class_name Marker

# Registry of entity IDs currently navigating to this marker
var navigators: Dictionary = {}

func _ready():
	# Call parent _ready first
	super._ready()
	# Markers don't use directional animations
	directional_animation = false
	# Markers don't need shadows - remove it if created
	if shadow_sprite and is_instance_valid(shadow_sprite):
		shadow_sprite.queue_free()
		shadow_sprite = null
	# Start with "off" animation
	if animator:
		animator.play("off")

# Function to add an entity to the navigation registry
func add_navigator(entity_id: String):
	if entity_id == "":
		return
	
	navigators[entity_id] = true
	print("[MARKER] Entity ", entity_id, " started navigating to marker ", self.entity_id)
	_update_marker_state()

# Function to remove an entity from the navigation registry
func remove_navigator(entity_id: String):
	if entity_id == "" or not navigators.has(entity_id):
		return
	
	navigators.erase(entity_id)
	print("[MARKER] Entity ", entity_id, " stopped navigating to marker ", self.entity_id)
	_update_marker_state()

# Update marker visual state based on navigator count
func _update_marker_state():
	if not animator:
		return
	
	if navigators.size() > 0:
		# Someone is navigating to this marker - play "on"
		animator.play("on")
	else:
		# No one is navigating to this marker - play "off"
		animator.play("off")

# Get count of navigators (for debugging/info)
func get_navigator_count() -> int:
	return navigators.size()

# Clean up invalid navigators (entities that no longer exist)
func cleanup_navigators():
	var to_remove = []
	for entity_id in navigators.keys():
		var entity = Entity.get_entity_by_id(entity_id)
		if not is_instance_valid(entity):
			to_remove.append(entity_id)
	
	for entity_id in to_remove:
		remove_navigator(entity_id)

# Static function to register navigation to a marker
static func register_navigation_to_marker(marker_id: String, navigator_id: String):
	var marker = Entity.get_entity_by_id(marker_id)
	if marker and marker is Marker:
		(marker as Marker).add_navigator(navigator_id)

# Static function to unregister navigation to a marker
static func unregister_navigation_to_marker(marker_id: String, navigator_id: String):
	var marker = Entity.get_entity_by_id(marker_id)
	if marker and marker is Marker:
		(marker as Marker).remove_navigator(navigator_id)


