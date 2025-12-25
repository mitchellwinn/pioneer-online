extends Node3D
class_name WeaponComponent

## WeaponComponent - Handles weapon behavior, firing, and IK attachment points
## Attach to weapon prefabs as a child node

#region Signals
signal fired(muzzle_position: Vector3, direction: Vector3)
signal reload_started()
signal reload_finished()
signal overheat_started()
signal overheat_finished()
signal ammo_changed(current: int, max: int)
signal heat_changed(current: float, max: float)
#endregion

#region Configuration - Set from ItemDatabase or inspector
@export_group("Weapon Identity")
@export var item_id: String = ""
@export var weapon_name: String = "Weapon"
@export var holster_slot: String = "back_primary"  # Where to holster when not in use
@export var rarity: String = "common"  # Item rarity for UI display

@export_group("IK Attachment Points")
## Primary grip (right hand on trigger)
@export var grip_point: Marker3D
## Secondary grip (left hand on foregrip)
@export var foregrip_point: Marker3D
## Where to aim from (usually near sights)
@export var aim_point: Marker3D
## Where projectiles spawn
@export var muzzle_point: Marker3D
## Muzzle flash effect to spawn when firing
@export var muzzle_flash: PackedScene

@export_group("Combat Stats")
@export var damage: float = 25.0
@export var damage_type: String = "energy"
@export var fire_rate: float = 8.0  # Rounds per second
@export var fire_mode: String = "auto"  # "auto", "semi", "burst"
@export var burst_count: int = 3
@export var effective_range: float = 100.0

@export_group("Ammo & Reload")
@export var clip_size: int = 30
@export var max_ammo: int = 180
@export var ammo_type: String = ""  # Shared ammo type (e.g., "energy_light", "energy_medium")
@export var reload_type: String = "magazine"  # "magazine", "overheat"
@export var reload_time: float = 2.0

@export_group("Overheat (if reload_type == overheat)")
@export var heat_per_shot: float = 2.5
@export var overheat_threshold: float = 100.0
@export var cooldown_rate: float = 30.0  # Heat lost per second
@export var overheat_lockout: float = 2.0  # Forced cooldown time

@export_group("Projectile")
@export var projectile_prefab: PackedScene
@export var projectile_path: String = ""  # Alternative: load by path
@export var muzzle_velocity: float = 150.0

@export_group("Accuracy")
@export var spread_hip: float = 3.0  # Degrees
@export var spread_aim: float = 0.5  # Degrees when aiming
@export var recoil_vertical: float = 4.0  # Degrees of vertical kick
@export var recoil_horizontal: float = 1.5  # Degrees of horizontal kick

@export_group("Aiming")
@export var aim_zoom: float = 1.4
@export var aim_time: float = 0.2  # Time to ADS

@export_group("Impact Effects")
@export var knockback_force: float = 0.0  # Force applied to target on hit
@export var hitstun_duration: float = 0.0  # Seconds target is stunned
@export var impact_force: float = 5.0  # Physics impulse on hit

@export_group("Sound")
@export var fire_sound: String = ""  # Path to fire sound (e.g. "res://sounds/rifle_fire.wav")
#endregion

#region Runtime State
var current_ammo: int = 0
var reserve_ammo: int = 0
var current_heat: float = 0.0
var is_reloading: bool = false
var is_overheated: bool = false
var is_aiming: bool = false

var _fire_cooldown: float = 0.0
var _reload_timer: float = 0.0
var _overheat_timer: float = 0.0
var _aim_blend: float = 0.0  # 0 = hip, 1 = aimed

var _owner_entity: Node3D = null

# Recoil state - exposed for WeaponAttachmentSetup to use
var recoil_offset: Vector3 = Vector3.ZERO  # Current positional recoil offset
var recoil_rotation: Vector3 = Vector3.ZERO  # Current rotational recoil (degrees)
var _target_recoil_offset: Vector3 = Vector3.ZERO  # Target recoil to smooth toward
var _target_recoil_rotation: Vector3 = Vector3.ZERO
#endregion

func _ready():
	# Auto-find attachment points if not set
	if not grip_point:
		grip_point = get_node_or_null("GripPoint")
	if not foregrip_point:
		foregrip_point = get_node_or_null("ForegripPoint")
	if not aim_point:
		aim_point = get_node_or_null("AimPoint")
	if not muzzle_point:
		muzzle_point = get_node_or_null("MuzzlePoint")
	
	# Load projectile from path if prefab not set
	if not projectile_prefab and not projectile_path.is_empty():
		projectile_prefab = load(projectile_path)
	
	# Initialize ammo
	current_ammo = clip_size
	reserve_ammo = max_ammo - clip_size if max_ammo > 0 else 0

func _process(delta: float):
	# Update fire cooldown
	if _fire_cooldown > 0:
		_fire_cooldown -= delta
	
	# Update reload
	if is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0:
			_finish_reload()
	
	# Update heat/overheat
	if reload_type == "overheat":
		if is_overheated:
			_overheat_timer -= delta
			if _overheat_timer <= 0:
				is_overheated = false
				current_heat = 0.0
				overheat_finished.emit()
				heat_changed.emit(current_heat, overheat_threshold)
		elif current_heat > 0:
			current_heat = maxf(0, current_heat - cooldown_rate * delta)
			heat_changed.emit(current_heat, overheat_threshold)
	
	# Update aim blend
	var target_aim = 1.0 if is_aiming else 0.0
	_aim_blend = move_toward(_aim_blend, target_aim, delta / aim_time)
	
	# Smooth recoil - spring toward target then decay target
	var recoil_spring_speed = 25.0  # How fast we reach target
	var recoil_decay_speed = 12.0   # How fast target decays to zero
	
	# Spring current values toward target
	recoil_offset = recoil_offset.lerp(_target_recoil_offset, recoil_spring_speed * delta)
	recoil_rotation = recoil_rotation.lerp(_target_recoil_rotation, recoil_spring_speed * delta)
	
	# Decay target back to zero (this creates the "bounce back" feel)
	_target_recoil_offset = _target_recoil_offset.lerp(Vector3.ZERO, recoil_decay_speed * delta)
	_target_recoil_rotation = _target_recoil_rotation.lerp(Vector3.ZERO, recoil_decay_speed * delta)
	
	# NOTE: WeaponAttachmentSetup reads recoil_offset/recoil_rotation and applies them

#region Weapon Actions
func try_fire() -> bool:
	## Attempt to fire the weapon. Returns true if successful.
	if not can_fire():
		return false
	
	_fire()
	return true

func can_fire() -> bool:
	if is_reloading:
		return false
	if is_overheated:
		return false
	if _fire_cooldown > 0:
		return false
	if reload_type == "magazine" and current_ammo <= 0:
		return false
	return true

func _fire():
	# Consume ammo or add heat
	if reload_type == "magazine":
		current_ammo -= 1
		ammo_changed.emit(current_ammo, clip_size)
	else:
		current_heat += heat_per_shot
		if current_heat >= overheat_threshold:
			_start_overheat()
		heat_changed.emit(current_heat, overheat_threshold)
	
	# Set fire cooldown
	_fire_cooldown = 1.0 / fire_rate
	
	# Calculate spread
	var spread = spread_aim if is_aiming else spread_hip
	spread = deg_to_rad(spread)
	
	# Get fire direction with spread
	var muzzle_pos = get_muzzle_position()
	var base_direction = get_fire_direction()
	var spread_direction = _apply_spread(base_direction, spread)
	
	# Apply weapon recoil (kick back and rotate up)
	_apply_recoil()
	
	# Spawn projectile
	_spawn_projectile(muzzle_pos, spread_direction)
	
	# Spawn muzzle flash effect
	_spawn_muzzle_flash(muzzle_pos, spread_direction)
	
	# Play fire sound
	_play_fire_sound(muzzle_pos)

	# Emit signal for effects (muzzle flash, sound, etc.)
	fired.emit(muzzle_pos, spread_direction)

func _apply_recoil():
	## Apply enhanced visual recoil kick to the weapon with weapon-specific behavior
	var aim_reduction = 0.5 if is_aiming else 1.0  # Less recoil when aiming

	# Weapon-specific recoil patterns
	var weapon_type = get_weapon_type()
	var kick_intensity = 1.0
	var kick_pattern = "standard"

	match weapon_type:
		"pistol":
			kick_intensity = 0.7
			kick_pattern = "snappy"
		"rifle":
			kick_intensity = 1.0
			kick_pattern = "controlled"
		"shotgun":
			kick_intensity = 1.8
			kick_pattern = "heavy"
		"sniper":
			kick_intensity = 0.6
			kick_pattern = "precision"
		"smg":
			kick_intensity = 0.9
			kick_pattern = "rapid"

	# Base kick values
	var base_kick_back = 0.08 * kick_intensity
	var base_kick_up = 0.025 * kick_intensity
	var base_rot_kick = recoil_vertical * kick_intensity
	var base_rot_side = recoil_horizontal * kick_intensity

	# Apply kick pattern modifiers
	match kick_pattern:
		"snappy":
			# Pistols have quick, snappy recoil
			base_kick_back *= 0.8
			base_rot_kick *= 1.2
		"heavy":
			# Shotguns have strong upward kick
			base_kick_up *= 2.0
			base_rot_kick *= 1.5
		"precision":
			# Snipers are more controlled
			base_kick_back *= 0.6
			base_rot_kick *= 0.7
		"rapid":
			# SMGs have lighter individual kicks
			base_kick_back *= 0.7
			base_rot_kick *= 0.8

	# Apply aiming reduction
	base_kick_back *= aim_reduction
	base_kick_up *= aim_reduction
	base_rot_kick *= aim_reduction
	base_rot_side *= aim_reduction

	# Add random variation for feel (more variation for less controlled weapons)
	var variation_factor = 1.0
	match kick_pattern:
		"precision": variation_factor = 0.5
		"heavy": variation_factor = 1.3

	var kick_back = base_kick_back * randf_range(0.8, 1.2) * variation_factor
	var kick_up = base_kick_up * randf_range(0.9, 1.3) * variation_factor

	# Positional kick - immediate and smooth
	_target_recoil_offset.z += kick_back
	_target_recoil_offset.y += kick_up

	# Rotational kick with weapon-specific patterns
	var rot_kick = base_rot_kick * randf_range(0.7, 1.3) * variation_factor
	var rot_side = randf_range(-base_rot_side, base_rot_side) * variation_factor

	# Different rotational patterns per weapon type
	match kick_pattern:
		"heavy":
			# Shotguns have more vertical kick
			rot_kick *= 1.3
			rot_side *= 0.7
		"precision":
			# Snipers have more predictable kick
			rot_side *= 0.5

	_target_recoil_rotation.x -= rot_kick  # Barrel kicks up
	_target_recoil_rotation.y += rot_side  # Side-to-side
	_target_recoil_rotation.z += randf_range(-0.8, 0.8) * kick_intensity * aim_reduction  # Roll

	# Dynamic clamping based on weapon type
	var max_back = 0.12
	var max_up = 0.06
	var max_rot_x = -20.0

	match kick_pattern:
		"heavy":
			max_back = 0.18
			max_up = 0.10
			max_rot_x = -30.0
		"precision":
			max_back = 0.08
			max_up = 0.04
			max_rot_x = -15.0

	_target_recoil_offset.z = minf(_target_recoil_offset.z, max_back)
	_target_recoil_offset.y = minf(_target_recoil_offset.y, max_up)
	_target_recoil_rotation.x = clampf(_target_recoil_rotation.x, max_rot_x, 5.0)
	
	# Apply camera recoil if we have an owner with camera
	if _owner_entity:
		var camera = _owner_entity.get_node_or_null("PlayerCamera")
		if camera and camera.has_method("apply_recoil"):
			var cam_weapon_type = get_weapon_type()
			camera.apply_recoil(recoil_vertical * aim_reduction, recoil_horizontal * aim_reduction, cam_weapon_type)

func _apply_spread(direction: Vector3, spread_angle: float) -> Vector3:
	if spread_angle <= 0:
		return direction
	
	# Random spread within cone
	var spread_x = randf_range(-spread_angle, spread_angle)
	var spread_y = randf_range(-spread_angle, spread_angle)
	
	# Create rotation basis from direction
	var basis = Basis.looking_at(direction, Vector3.UP)
	var spread_rot = basis * Basis(Vector3.RIGHT, spread_x) * Basis(Vector3.UP, spread_y)
	
	return -spread_rot.z

func _spawn_projectile(position: Vector3, direction: Vector3):
	if not projectile_prefab:
		# No projectile - this might be a hitscan weapon
		print("[WeaponComponent] No projectile prefab, doing hitscan")
		_do_hitscan(position, direction)
		return
	
	# Spawn local projectile
	_spawn_projectile_local(position, direction)
	
	# Broadcast to other clients for visual sync (only if local player)
	if _is_local_player():
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_method("broadcast_projectile"):
			var prefab_path = projectile_prefab.resource_path
			network.broadcast_projectile(prefab_path, position, direction, muzzle_velocity, damage, damage_type)

func _spawn_projectile_local(position: Vector3, direction: Vector3):
	## Actually instantiate the projectile (called locally and from network)
	if not projectile_prefab:
		push_warning("[WeaponComponent] No projectile_prefab to spawn!")
		return
		
	var projectile = projectile_prefab.instantiate()
	get_tree().current_scene.add_child(projectile)
	
	# Spawn slightly in front of muzzle to avoid self-collision
	var spawn_pos = position + direction * 0.1
	projectile.global_position = spawn_pos
	
	# Initialize projectile FIRST (sets velocity)
	if projectile.has_method("initialize"):
		projectile.initialize(direction * muzzle_velocity, damage, damage_type, _owner_entity, knockback_force, hitstun_duration)
	
	print("[WeaponComponent] Spawned projectile at %s dir=%s vel=%.1f dmg=%.1f kb=%.1f" % [
		spawn_pos, direction, muzzle_velocity, damage, knockback_force
	])

func _spawn_muzzle_flash(position: Vector3, direction: Vector3):
	## Spawn muzzle flash effect at the muzzle position
	if not muzzle_flash:
		return

	var effect = muzzle_flash.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = position

	# Muzzle flashes are billboarded, so no need for manual orientation
	# The effect will automatically face the camera

	print("[WeaponComponent] Spawned muzzle flash at %s" % position)

func _play_fire_sound(position: Vector3):
	## Play the weapon's fire sound at the muzzle position
	if fire_sound.is_empty():
		return
	
	var sound_manager = get_node_or_null("/root/SoundManager")
	if sound_manager and sound_manager.has_method("play_sound_3d_with_variation"):
		# Use variation for slight pitch randomness on gunfire
		sound_manager.play_sound_3d_with_variation(fire_sound, position, null, 0.0, 0.05)

func _is_local_player() -> bool:
	## Check if owner entity is the local player
	if not _owner_entity:
		return false
	if _owner_entity.has_method("can_receive_input"):
		return _owner_entity.can_receive_input
	if "can_receive_input" in _owner_entity:
		return _owner_entity.can_receive_input
	return true  # Fallback for singleplayer

func _do_hitscan(position: Vector3, direction: Vector3):
	## Instant hit detection for hitscan weapons
	var space_state = get_world_3d().direct_space_state
	var end_pos = position + direction * effective_range
	
	var query = PhysicsRayQueryParameters3D.create(position, end_pos)
	if _owner_entity:
		query.exclude = [_owner_entity.get_rid()]
	
	var result = space_state.intersect_ray(query)
	if result:
		var target = result.collider
		if target.has_method("take_damage"):
			target.take_damage(damage, _owner_entity, damage_type)
#endregion

#region Reload
func try_reload() -> bool:
	if not can_reload():
		return false
	
	_start_reload()
	return true

func can_reload() -> bool:
	if reload_type != "magazine":
		return false
	if is_reloading:
		return false
	if current_ammo >= clip_size:
		return false
	if reserve_ammo <= 0:
		return false
	return true

func _start_reload():
	is_reloading = true
	_reload_timer = reload_time
	reload_started.emit()

func _finish_reload():
	is_reloading = false
	
	var needed = clip_size - current_ammo
	var available = mini(needed, reserve_ammo)
	
	current_ammo += available
	reserve_ammo -= available
	
	ammo_changed.emit(current_ammo, clip_size)
	reload_finished.emit()

func cancel_reload():
	if is_reloading:
		is_reloading = false
		_reload_timer = 0.0
#endregion

#region Overheat
func _start_overheat():
	is_overheated = true
	_overheat_timer = overheat_lockout
	overheat_started.emit()
#endregion

#region Aiming
func set_aiming(aiming: bool):
	is_aiming = aiming

func get_aim_blend() -> float:
	return _aim_blend

func get_current_spread() -> float:
	return lerpf(spread_hip, spread_aim, _aim_blend)

func get_weapon_type() -> String:
	## Determine weapon type for recoil calculations
	# WeaponComponent doesn't store the full database dict; use what we have.
	# Prefer a valid holster_slot hint, otherwise fall back to "weapon".
	var slot := holster_slot.to_lower()
	if slot.contains("hip"):
		return "pistol"
	if slot.contains("back"):
		return "rifle"
	if slot.contains("thigh"):
		return "pistol"
	return "weapon"
#endregion

#region IK Helpers
func get_grip_transform() -> Transform3D:
	## Get the transform for the primary (right) hand grip
	if grip_point:
		return grip_point.global_transform
	return global_transform

func get_foregrip_transform() -> Transform3D:
	## Get the transform for the secondary (left) hand grip
	if foregrip_point:
		return foregrip_point.global_transform
	# Fallback: offset from weapon center
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.3))

func get_aim_transform() -> Transform3D:
	## Get the transform for aiming (where eyes should align)
	if aim_point:
		return aim_point.global_transform
	return global_transform

func get_muzzle_position() -> Vector3:
	if muzzle_point:
		return muzzle_point.global_position
	return global_position + global_transform.basis.z * -0.5

func get_fire_direction() -> Vector3:
	## Get the direction to fire - aims at where crosshair points
	## Uses raycast from camera to find target, then calculates direction from muzzle
	
	var muzzle_pos = get_muzzle_position()
	
	# Try to get aim target from owner (raycast from camera)
	if _owner_entity and _owner_entity.has_method("get_aim_target"):
		var target_point = _owner_entity.get_aim_target(effective_range)
		# Direction from muzzle to where camera is aiming
		var dir = (target_point - muzzle_pos).normalized()
		if dir.length() > 0.001:
			# For very close targets, blend towards camera direction to avoid extreme angles
			var distance_to_target = muzzle_pos.distance_to(target_point)
			if distance_to_target < 3.0:  # Within 3 units (increased range)
				var camera_dir = _owner_entity.get_aim_ray_direction()
				# Only blend if camera direction is reasonably horizontal (not straight up/down)
				if abs(camera_dir.dot(Vector3.UP)) < 0.8:  # Camera not looking mostly up/down
					var blend_factor = clamp((3.0 - distance_to_target) / 3.0, 0.0, 0.5)  # Max 50% blend
					dir = dir.lerp(camera_dir, blend_factor).normalized()
			return dir
	
	# Fallback: use camera direction directly
	if _owner_entity and _owner_entity.has_method("get_aim_ray_direction"):
		return _owner_entity.get_aim_ray_direction()
	
	# Last resort: muzzle forward
	if muzzle_point:
		return -muzzle_point.global_transform.basis.z
	return -global_transform.basis.z
#endregion

#region Setup
func set_weapon_owner(entity: Node3D):
	_owner_entity = entity

func load_from_database(weapon_data: Dictionary):
	## Initialize weapon stats from ItemDatabase data
	item_id = weapon_data.get("item_id", item_id)
	weapon_name = weapon_data.get("name", weapon_name)
	holster_slot = weapon_data.get("holster_slot", holster_slot)
	rarity = weapon_data.get("rarity", rarity)

	# Combat stats
	damage = weapon_data.get("damage", damage)
	damage_type = weapon_data.get("damage_type", damage_type)
	fire_rate = weapon_data.get("fire_rate", fire_rate)
	fire_mode = weapon_data.get("fire_mode", fire_mode)
	effective_range = weapon_data.get("range", effective_range)
	
	# Ammo
	clip_size = weapon_data.get("clip_size", clip_size)
	max_ammo = weapon_data.get("max_ammo", max_ammo)
	ammo_type = weapon_data.get("ammo_type", ammo_type)
	reload_type = weapon_data.get("reload_type", reload_type)
	reload_time = weapon_data.get("reload_time", reload_time)
	
	# Overheat
	heat_per_shot = weapon_data.get("heat_per_shot", heat_per_shot)
	overheat_threshold = weapon_data.get("overheat_threshold", overheat_threshold)
	cooldown_rate = weapon_data.get("cooldown_rate", cooldown_rate)
	overheat_lockout = weapon_data.get("overheat_lockout", overheat_lockout)
	
	# Projectile
	var proj_path = weapon_data.get("projectile_prefab", "")
	if not proj_path.is_empty():
		projectile_path = proj_path
		projectile_prefab = load(proj_path) if ResourceLoader.exists(proj_path) else null
	muzzle_velocity = weapon_data.get("muzzle_velocity", muzzle_velocity)
	
	# Accuracy
	spread_hip = weapon_data.get("spread_hip", spread_hip)
	spread_aim = weapon_data.get("spread_aim", spread_aim)
	recoil_vertical = weapon_data.get("recoil_vertical", recoil_vertical)
	recoil_horizontal = weapon_data.get("recoil_horizontal", recoil_horizontal)
	
	# Aiming
	aim_zoom = weapon_data.get("aim_zoom", aim_zoom)
	aim_time = weapon_data.get("aim_time", aim_time)
	
	# Impact effects
	knockback_force = weapon_data.get("knockback_force", knockback_force)
	hitstun_duration = weapon_data.get("hitstun_duration", hitstun_duration)
	impact_force = weapon_data.get("impact_force", impact_force)

	# Muzzle flash
	var muzzle_flash_path = weapon_data.get("muzzle_flash", "")
	if not muzzle_flash_path.is_empty():
		muzzle_flash = load(muzzle_flash_path) if ResourceLoader.exists(muzzle_flash_path) else null
	
	# Fire sound
	fire_sound = weapon_data.get("fire_sound", fire_sound)
	
	# Reset state
	current_ammo = clip_size
	reserve_ammo = max_ammo - clip_size if max_ammo > 0 else 0
	current_heat = 0.0
	is_reloading = false
	is_overheated = false

func add_ammo(amount: int) -> int:
	## Add ammo to reserves. Returns amount actually added.
	if max_ammo < 0:
		return 0  # Infinite ammo weapon
	
	var space = max_ammo - reserve_ammo - current_ammo
	var added = mini(amount, space)
	reserve_ammo += added
	return added

func get_instance_state() -> Dictionary:
	## Get current weapon state for saving to database
	return {
		"current_ammo": current_ammo,
		"reserve_ammo": reserve_ammo,
		"current_heat": current_heat,
		"is_overheated": is_overheated
	}

func load_instance_state(state: Dictionary):
	## Load saved weapon state from database
	if state.has("current_ammo"):
		current_ammo = state.current_ammo
	if state.has("reserve_ammo"):
		reserve_ammo = state.reserve_ammo
	if state.has("current_heat"):
		current_heat = state.current_heat
	if state.has("is_overheated"):
		is_overheated = state.is_overheated
	
	# Emit signals to update UI
	ammo_changed.emit(current_ammo, clip_size)
	heat_changed.emit(current_heat, overheat_threshold)
	print("[WeaponComponent] Loaded instance state: ammo=", current_ammo, "/", clip_size, " reserve=", reserve_ammo)
#endregion

