extends Marker3D

## HubSpawnPoint - Defines where players spawn in the hub

@export var spawn_rotation: Vector3 = Vector3.ZERO
@export var is_available: bool = true

func get_spawn_rotation() -> Vector3:
	return spawn_rotation

func set_available(available: bool):
	is_available = available

func is_spawn_available() -> bool:
	return is_available

