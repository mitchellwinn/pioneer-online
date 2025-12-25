extends CanvasLayer
class_name WeaponHUD

## WeaponHUD - Displays ammo, heat, and weapon info

#region Configuration
@export_group("UI Elements")
@export var ammo_label: Label
@export var weapon_name_label: Label
@export var heat_bar: ProgressBar
@export var reload_bar: ProgressBar
@export var crosshair: TextureRect

@export_group("Colors")
@export var ammo_normal_color: Color = Color.WHITE
@export var ammo_low_color: Color = Color.YELLOW
@export var ammo_empty_color: Color = Color.RED
@export var heat_normal_color: Color = Color.CYAN
@export var heat_high_color: Color = Color.ORANGE
@export var heat_max_color: Color = Color.RED
#endregion

#region Runtime
var equipment_manager: Node = null # EquipmentManager - untyped to avoid circular dependency
var current_weapon: Node3D = null # WeaponComponent - untyped to avoid circular dependency
var _low_ammo_threshold: float = 0.25
var crosshair_hud: Control = null # CrosshairHUD instance
var _using_cinematic_hud: bool = false # Whether CinematicHUD is active (shows health bars that should always be visible)
#endregion

func _ready():
	# Defer the local player check to ensure parent's _ready has run first
	# This is critical because parent sets can_receive_input in its _ready
	call_deferred("_deferred_init")

func _deferred_init():
	# Only create HUD for local player
	var parent = get_parent()
	if parent and "can_receive_input" in parent:
		if not parent.can_receive_input:
			# Remote player - don't create HUD at all
			print("[WeaponHUD] Remote player detected, removing HUD")
			queue_free()
			return
	
	# Also check network identity directly
	if parent:
		var network_id = parent.get_node_or_null("NetworkIdentity")
		if network_id and "owner_peer_id" in network_id:
			var local_peer = 1
			if multiplayer and multiplayer.has_multiplayer_peer():
				local_peer = multiplayer.get_unique_id()
			if network_id.owner_peer_id != local_peer and network_id.owner_peer_id > 1:
				print("[WeaponHUD] Not our player (owner=%d, local=%d), removing HUD" % [network_id.owner_peer_id, local_peer])
				queue_free()
				return
	
	# Create default UI if not set
	if not ammo_label:
		_create_default_ui()

	# Hide initially (but NOT if using CinematicHUD - it shows health bars that should always be visible)
	if not _using_cinematic_hud:
		set_visible(false)

	# Auto-find EquipmentManager in parent
	call_deferred("_find_equipment_manager")

func _find_equipment_manager():
	var parent = get_parent()
	if parent:
		var equip = parent.get_node_or_null("EquipmentManager")
		if equip:
			connect_to_equipment_manager(equip)

func _create_default_ui():
	# Create a basic HUD container
	var container = Control.new()
	container.name = "WeaponHUDContainer"
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE # Don't block mouse input!
	add_child(container)

	# Try to load CinematicHUD first (new full HUD with integrated ammo display)
	var hud_scene = load("res://scenes/ui/cinematic_hud.tscn")
	var use_cinematic_hud = hud_scene != null

	if use_cinematic_hud:
		# CinematicHUD handles all display - no need for legacy elements
		crosshair_hud = hud_scene.instantiate()
		crosshair_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(crosshair_hud)

		# Mark that we're using CinematicHUD
		_using_cinematic_hud = true
		print("[WeaponHUD] Created CinematicHUD - HUD will stay visible for health/stamina bars")

		# CinematicHUD shows health/stamina which should ALWAYS be visible
		# Override the initial hide - CinematicHUD manages its own weapon section visibility
		set_visible(true)

		# Connect CinematicHUD to player if it has set_player method
		if crosshair_hud.has_method("set_player"):
			var parent_node = get_parent()
			if parent_node:
				crosshair_hud.set_player(parent_node)
		
		# Create dummy labels to prevent null errors (hidden)
		weapon_name_label = Label.new()
		weapon_name_label.visible = false
		container.add_child(weapon_name_label)
		
		ammo_label = Label.new()
		ammo_label.visible = false
		container.add_child(ammo_label)
		
		heat_bar = ProgressBar.new()
		heat_bar.visible = false
		container.add_child(heat_bar)
		
		reload_bar = ProgressBar.new()
		reload_bar.visible = false
		container.add_child(reload_bar)
	else:
		# Fallback: Create legacy ammo display (bottom right)
		var ammo_container = VBoxContainer.new()
		ammo_container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		ammo_container.position = Vector2(-200, -120)
		container.add_child(ammo_container)
		
		weapon_name_label = Label.new()
		weapon_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		weapon_name_label.add_theme_font_size_override("font_size", 14)
		weapon_name_label.modulate = Color(0.7, 0.7, 0.7)
		ammo_container.add_child(weapon_name_label)
		
		ammo_label = Label.new()
		ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ammo_label.add_theme_font_size_override("font_size", 32)
		ammo_container.add_child(ammo_label)
		
		# Heat bar
		heat_bar = ProgressBar.new()
		heat_bar.custom_minimum_size = Vector2(180, 8)
		heat_bar.show_percentage = false
		heat_bar.visible = false
		ammo_container.add_child(heat_bar)
		
		# Reload bar
		reload_bar = ProgressBar.new()
		reload_bar.custom_minimum_size = Vector2(180, 4)
		reload_bar.show_percentage = false
		reload_bar.visible = false
		ammo_container.add_child(reload_bar)
		
		# Try CrosshairHUD for just the crosshair
		var crosshair_scene = load("res://scenes/ui/crosshair_hud.tscn")
		if crosshair_scene:
			crosshair_hud = crosshair_scene.instantiate()
			crosshair_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
			container.add_child(crosshair_hud)
		else:
			# Ultimate fallback to simple texture crosshair
			crosshair = TextureRect.new()
			crosshair.set_anchors_preset(Control.PRESET_CENTER)
			crosshair.position = Vector2(-16, -16)
			crosshair.custom_minimum_size = Vector2(32, 32)
			crosshair.visible = false
			container.add_child(crosshair)

func _process(_delta: float):
	if not current_weapon:
		return
	
	# Skip legacy updates when using CinematicHUD (it handles its own updates)
	if ammo_label and ammo_label.visible:
		_update_ammo_display()
		_update_heat_display()
		_update_reload_display()

func connect_to_equipment_manager(manager: Node): # manager is EquipmentManager
	equipment_manager = manager
	
	manager.weapon_drawn.connect(_on_weapon_drawn)
	manager.weapon_holstered.connect(_on_weapon_holstered)

func _on_weapon_drawn(weapon: Node3D):
	# Try to get WeaponComponent
	current_weapon = weapon.get_node_or_null("WeaponComponent")
	if not current_weapon and weapon.get_script():
		var script_name = weapon.get_script().get_global_name()
		if script_name == "WeaponComponent":
			current_weapon = weapon
	
	if current_weapon:
		set_visible(true)
		
		# Only update legacy labels if they're visible (not using CinematicHUD)
		if weapon_name_label and weapon_name_label.visible:
			weapon_name_label.text = current_weapon.weapon_name
		
		# Connect signals (check if not already connected)
		if not current_weapon.ammo_changed.is_connected(_on_ammo_changed):
			current_weapon.ammo_changed.connect(_on_ammo_changed)
		if not current_weapon.heat_changed.is_connected(_on_heat_changed):
			current_weapon.heat_changed.connect(_on_heat_changed)
		if not current_weapon.reload_started.is_connected(_on_reload_started):
			current_weapon.reload_started.connect(_on_reload_started)
		if not current_weapon.reload_finished.is_connected(_on_reload_finished):
			current_weapon.reload_finished.connect(_on_reload_finished)
		if not current_weapon.overheat_started.is_connected(_on_overheat_started):
			current_weapon.overheat_started.connect(_on_overheat_started)
		if not current_weapon.overheat_finished.is_connected(_on_overheat_finished):
			current_weapon.overheat_finished.connect(_on_overheat_finished)
		if not current_weapon.fired.is_connected(_on_weapon_fired):
			current_weapon.fired.connect(_on_weapon_fired)
		
		# Initial display (only for legacy mode)
		if ammo_label and ammo_label.visible:
			_update_ammo_display()
		
		# Show heat bar for overheat weapons (only legacy mode)
		if heat_bar and heat_bar.visible:
			heat_bar.visible = current_weapon.reload_type == "overheat"
		
		# Update crosshair spread
		if crosshair_hud and crosshair_hud.has_method("set_spread"):
			crosshair_hud.set_spread(current_weapon.spread_hip)

func _on_weapon_holstered():
	# Only hide the whole HUD if NOT using CinematicHUD
	# CinematicHUD shows health/stamina bars that should always be visible
	if not _using_cinematic_hud:
		set_visible(false)

	if current_weapon:
		# Disconnect signals safely
		if current_weapon.ammo_changed.is_connected(_on_ammo_changed):
			current_weapon.ammo_changed.disconnect(_on_ammo_changed)
		if current_weapon.heat_changed.is_connected(_on_heat_changed):
			current_weapon.heat_changed.disconnect(_on_heat_changed)
		if current_weapon.reload_started.is_connected(_on_reload_started):
			current_weapon.reload_started.disconnect(_on_reload_started)
		if current_weapon.reload_finished.is_connected(_on_reload_finished):
			current_weapon.reload_finished.disconnect(_on_reload_finished)
		if current_weapon.overheat_started.is_connected(_on_overheat_started):
			current_weapon.overheat_started.disconnect(_on_overheat_started)
		if current_weapon.overheat_finished.is_connected(_on_overheat_finished):
			current_weapon.overheat_finished.disconnect(_on_overheat_finished)
		if current_weapon.fired.is_connected(_on_weapon_fired):
			current_weapon.fired.disconnect(_on_weapon_fired)
	
	current_weapon = null

func _update_ammo_display():
	if not current_weapon or not ammo_label:
		return
	
	if current_weapon.reload_type == "magazine":
		ammo_label.text = "%d / %d" % [current_weapon.current_ammo, current_weapon.reserve_ammo]
		
		# Color based on ammo level
		var ammo_ratio = float(current_weapon.current_ammo) / float(current_weapon.clip_size)
		if ammo_ratio <= 0:
			ammo_label.modulate = ammo_empty_color
		elif ammo_ratio <= _low_ammo_threshold:
			ammo_label.modulate = ammo_low_color
		else:
			ammo_label.modulate = ammo_normal_color
	else:
		# Overheat weapon - no ammo display
		ammo_label.text = "∞"
		ammo_label.modulate = ammo_normal_color

func _update_heat_display():
	if not current_weapon or not heat_bar:
		return
	
	if current_weapon.reload_type != "overheat":
		heat_bar.visible = false
		return
	
	heat_bar.visible = true
	heat_bar.max_value = current_weapon.overheat_threshold
	heat_bar.value = current_weapon.current_heat
	
	# Color based on heat level
	var heat_ratio = current_weapon.current_heat / current_weapon.overheat_threshold
	if heat_ratio >= 1.0:
		heat_bar.modulate = heat_max_color
	elif heat_ratio >= 0.7:
		heat_bar.modulate = heat_high_color
	else:
		heat_bar.modulate = heat_normal_color

func _update_reload_display():
	if not current_weapon or not reload_bar:
		return
	
	reload_bar.visible = current_weapon.is_reloading
	
	if current_weapon.is_reloading:
		reload_bar.max_value = current_weapon.reload_time
		reload_bar.value = current_weapon.reload_time - current_weapon._reload_timer

#region Signal Handlers
func _on_ammo_changed(_current: int, _max: int):
	_update_ammo_display()

func _on_heat_changed(_current: float, _max: float):
	_update_heat_display()

func _on_reload_started():
	reload_bar.visible = true

func _on_reload_finished():
	reload_bar.visible = false
	_update_ammo_display()

func _on_overheat_started():
	ammo_label.text = "OVERHEAT"
	ammo_label.modulate = heat_max_color

func _on_overheat_finished():
	_update_ammo_display()

func _on_weapon_fired(_muzzle_pos: Vector3, _direction: Vector3):
	# Update crosshair spread based on current weapon spread
	if crosshair_hud and current_weapon and crosshair_hud.has_method("set_spread"):
		crosshair_hud.set_spread(current_weapon.get_current_spread())
#endregion

#region Crosshair
func show_hit_marker():
	## Show hit marker on crosshair (call when player lands a hit)
	if crosshair_hud and crosshair_hud.has_method("show_hit_marker"):
		crosshair_hud.show_hit_marker()

func set_crosshair_aiming(is_aiming: bool):
	## Tighten crosshair when aiming
	if crosshair_hud and crosshair_hud.has_method("set_aiming"):
		crosshair_hud.set_aiming(is_aiming)
	
	# Also update spread
	if crosshair_hud and current_weapon and crosshair_hud.has_method("set_spread"):
		var spread = current_weapon.spread_aim if is_aiming else current_weapon.spread_hip
		crosshair_hud.set_spread(spread)
#endregion
