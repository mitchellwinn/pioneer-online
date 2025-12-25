extends Node

# Menu management system for creating robust, flexible menus
# This singleton handles all menu creation, positioning, and management

# ===== Centralized menu strategy helpers =====
func register_default_menu_strategies():
	"""Register menu positioning strategies from DataManager.menus"""
	if not DataManager or not DataManager.menus:
		print("WARNING: DataManager.menus not loaded yet")
		return
		
	for menu_name in DataManager.menus.keys():
		var config = DataManager.menus[menu_name]
		if config is Dictionary and config.has("position_strategy"):
			menu_position_strategies[menu_name] = parse_position_strategy(config["position_strategy"])

func parse_position_strategy(strategy_data: Dictionary) -> Dictionary:
	"""Parse position strategy from JSON data"""
	var strategy = {"type": strategy_data.get("type", "center")}
	
	if strategy_data.has("offset"):
		var offset_data = strategy_data["offset"]
		strategy["offset"] = Vector2(offset_data.get("x", 0), offset_data.get("y", 0))
	
	if strategy_data.has("y_offset"):
		strategy["y_offset"] = strategy_data["y_offset"]
	
	if strategy_data.has("margin_right"):
		strategy["margin_right"] = strategy_data["margin_right"]
	
	if strategy_data.has("margin_bottom"):
		strategy["margin_bottom"] = strategy_data["margin_bottom"]
	
	if strategy_data.has("width_percent"):
		strategy["width_percent"] = strategy_data["width_percent"]
	
	return strategy

func set_menu_strategy(menu_name: String, strategy: Dictionary):
	menu_position_strategies[menu_name] = strategy

func get_menu_strategy(menu_name: String) -> Dictionary:
	return menu_position_strategies.get(menu_name, {"type": "center", "offset": Vector2.ZERO})


# Dynamic menu system
var dynamic_menus: Dictionary = {}
var black_window_prefab = preload("res://prefabs/windows/black_window.tscn")
var menu_theme: Theme # Loaded in _ready()

# UI root (CanvasLayer + Control) where all menu windows live
var ui_canvas_layer: CanvasLayer = null
var ui_root: Control = null

func _log(msg):
	print("[MenuManager] ", msg)

func load_all_menus():
	"""Load menu JSONs from plugin's menus folder and game's res://menus/ folder"""
	var menus_data = {}
	
	# Load general menus from plugin
	var plugin_menus_path = "res://addons/gsg-godot-plugins/menu_manager/menus"
	var plugin_menus = DataParser.json_dir_to_dict(plugin_menus_path, false)
	for key in plugin_menus.keys():
		menus_data[key] = plugin_menus[key]
	# _log("Loaded " + str(plugin_menus.keys().size()) + " general menus from plugin")
	
	# Load game-specific menus from res://menus/
	var game_menus_path = "res://menus"
	var game_menus = DataParser.json_dir_to_dict(game_menus_path, false)
	for key in game_menus.keys():
		menus_data[key] = game_menus[key]  # Game menus override plugin menus if same name
	# _log("Loaded " + str(game_menus.keys().size()) + " game-specific menus")
	
	# Store in DataManager for access
	DataManager.set_data("menus", menus_data)
	# _log("Total menus loaded: " + str(menus_data.keys().size()))


# Window stack management
var window_stack: Array = []
var window_instances: Dictionary = {} # menu_name -> window instance
var windows_being_created: Dictionary = {} # menu_name -> bool, prevents duplicate creation during await

# Centralized positioning strategies per menu
# type: "center" | "top_center" | "dropdown_party"
# For center: optional {offset: Vector2}
# For top_center: {y_offset: float}
# For dropdown_party: requires context {party_sprites: Array, party_index: int}
var menu_position_strategies: Dictionary = {}

# Party portrait interaction state
var portrait_action_type: String = "" # What action to perform when clicking a portrait (e.g. "stats", "use_item", "item_user")
var current_party_index: int = -1 # Currently selected party member index
var preselected_party_member: int = -1 # Pre-selected party member for item usage (set by item_user flow)


###### WINDOW STACK MANAGEMENT ######

func push_window(window):
	"""Add a window to the active stack"""
	if not window_stack.has(window):
		# Deactivate current top before pushing new one
		var old_top = get_active_window()
		window_stack.append(window)
		if old_top and old_top.has_method("set_window_active"):
			old_top.set_window_active(false)
		if window and window.has_method("set_window_active"):
			window.set_window_active(true)
		# Update z-index based on stack position
		_update_window_z_indices()
		# if window and "menu_name" in window:
			# print("[MenuManager] Pushed window to stack: ", window.menu_name, " (stack size: ", window_stack.size(), ")")

func pop_window(window):
	"""Remove a window from the active stack"""
	if window_stack.has(window):
		window_stack.erase(window)
		# Deactivate the popped window
		if window and window.has_method("set_window_active"):
			window.set_window_active(false)
		# Activate new top if exists
		var new_top = get_active_window()
		if new_top and new_top.has_method("set_window_active"):
			new_top.set_window_active(true)
		# Update z-index based on new stack position
		_update_window_z_indices()
		# if window and "menu_name" in window:
			# print("[MenuManager] Popped window from stack: ", window.menu_name, " (stack size: ", window_stack.size(), ")")

func get_active_window():
	"""Get the top window from the stack"""
	if window_stack.is_empty():
		return null
	return window_stack[window_stack.size() - 1]

func _update_window_z_indices():
	"""Update z_index for all windows based on their stack position"""
	# Base z-index for windows
	var base_z = 0
	for i in range(window_stack.size()):
		var window = window_stack[i]
		if window and is_instance_valid(window):
			window.z_index = base_z + i
			# print("[MenuManager] Set z_index=", window.z_index, " for window: ", window.menu_name if "menu_name" in window else window.name)

func get_menu_window(menu_name: String):
	"""Get a window instance by menu name"""
	return window_instances.get(menu_name, null)

func open_window(menu_name: String, parent_window: Control = null, position_context: Dictionary = {}):
	"""Open a window by name (auto-creates and attaches to UI root if needed)"""
	var window = get_menu_window(menu_name)
	if not window:
		# Check if window is already being created (race condition guard)
		if windows_being_created.get(menu_name, false):
			_log("Window '" + menu_name + "' is already being created, skipping duplicate creation")
			return
		# Auto-create instance
		windows_being_created[menu_name] = true
		window = await create_menu_from_config(menu_name)
		windows_being_created.erase(menu_name)
		if not window:
			_log("ERROR: Could not create window for '" + menu_name + "'")
			return
	
	if parent_window and parent_window.has_method("add_child_window"):
		parent_window.add_child_window(window)
		_log("Added child window '" + menu_name + "' to parent '" + parent_window.name + "'")
	
	# Store position context if provided (for dropdowns, etc.)
	if not position_context.is_empty():
		window.set_meta("position_context", position_context)
	
	_log("Opening window '" + menu_name + "'")
	window.open_window()

func close_active_window():
	"""Close the currently active window if allowed"""
	var active = get_active_window()
	if active:
		# Special case: some windows should pop off the stack on back instead of closing
		if "pop_on_back" in active and active.pop_on_back:
			# Let window react to being popped off (e.g., disable mouse on overlays)
			if active.has_method("on_popped_from_stack"):
				active.on_popped_from_stack()
			pop_window(active)
			# Activate new top which restores focus
			var new_top = get_active_window()
			if new_top and new_top.has_method("set_window_active"):
				new_top.set_window_active(true)
			return
		if "closable_via_back" in active and not active.closable_via_back:
			_log("Active window '" + (active.menu_name if "menu_name" in active else active.name) + "' is not closable via back")
			return
		if SoundManager != null:
			SoundManager.play_sound("res://sounds/menu/close_menu.wav")
		active.close_window()

func force_close_window(menu_name: String):
	"""Force-close a window by name, ignoring closable_via_back."""
	var win = get_menu_window(menu_name)
	if win:
		win.close_window()

func force_close_all_windows():
	"""Force-close all open windows, ignoring closable_via_back flags."""
	for name in window_instances.keys():
		var win = window_instances[name]
		if win and win.is_open:
			win.close_window()

func show_menu_dialogue(text: String):
	"""Show dialogue text in the menu dialogue window (creates it if needed)"""
	var active_window = get_active_window()
	if not active_window:
		_log("ERROR: No active window to show dialogue on")
		return
	
	# Check if menu_dialogue window already exists and is open
	var dialogue_window = get_menu_window("menu_dialogue")
	if dialogue_window and dialogue_window.is_open:
		# Find the label and update the text
		var content_container = get_menu_content_container("menu_dialogue")
		if content_container:
			var dialogue_label = content_container.get_node_or_null("dialogue_text")
			if dialogue_label:
				await DialogueManager.quick_read(text, dialogue_label)
				dialogue_window.close_window()
		return
	
	# Open the dialogue window as a child of the active window
	open_window("menu_dialogue", active_window)
	await get_tree().process_frame
	
	# Now display the text using DialogueManager
	dialogue_window = get_menu_window("menu_dialogue")
	if dialogue_window:
		var content_container = get_menu_content_container("menu_dialogue")
		if content_container:
			var dialogue_label = content_container.get_node_or_null("dialogue_text")
			if dialogue_label:
				await DialogueManager.quick_read(text, dialogue_label)
				dialogue_window.close_window()
			else:
				_log("ERROR: Could not find dialogue_text in menu_dialogue")
		else:
			_log("ERROR: Could not find content container for menu_dialogue")

# Called when the node enters the scene tree for the first time.
func _ready():
	# Load menus from plugin and game folders
	load_all_menus()
	
	# Load menu theme
	menu_theme = load("res://text_themes/menu_theme.tres")
	# _log("_ready: theme loaded")
	# Ensure a UI CanvasLayer + root Control exists for menus
	ensure_ui_root()
	# Connect to viewport resize events to keep menus centered
	get_viewport().size_changed.connect(_on_viewport_resized)
	# Register default menu positioning strategies from DataManager
	register_default_menu_strategies()
	# _log("_ready: default strategies registered; menus available=" + str(DataManager.menus.keys()))
	# Auto-apply menu theme to all Label, RichTextLabel, and Button nodes
	get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node):
	"""Automatically apply menu theme to text controls when they enter the scene tree"""
	if node is Label or node is RichTextLabel or node is Button:
		var control = node as Control
		# print("[MenuManager] Node added: ", control.name, " type=", control.get_class(), " has_theme=", control.theme != null)
		# Only apply if no theme is already set
		if control.theme == null and menu_theme:
			# print("[MenuManager] Applying menu theme to: ", control.name)
			control.theme = menu_theme
		else:
			pass
			# if control.theme != null:
				# print("[MenuManager] Node already has theme: ", control.name)
			# else:
				# print("[MenuManager] menu_theme is null!")

func ensure_ui_root():
	# If we already have a ui_root, make sure it's actually attached to the scene tree
	if ui_root and is_instance_valid(ui_root):
		# Ensure we have a valid CanvasLayer
		if not ui_canvas_layer or not is_instance_valid(ui_canvas_layer):
			ui_canvas_layer = CanvasLayer.new()
			ui_canvas_layer.layer = 101
			get_tree().root.add_child(ui_canvas_layer)
		elif not ui_canvas_layer.is_inside_tree():
			get_tree().root.add_child(ui_canvas_layer)
		# Reattach ui_root if it's not in the tree or has wrong parent
		if not ui_root.is_inside_tree():
			if ui_root.get_parent() != ui_canvas_layer:
				# Godot 4: reparent moves the node under the new parent (works even if not in tree)
				ui_root.reparent(ui_canvas_layer)
			else:
				ui_canvas_layer.add_child(ui_root)
		return
	# Otherwise, create a fresh CanvasLayer + Control
	ui_canvas_layer = CanvasLayer.new()
	ui_canvas_layer.layer = 101
	get_tree().root.add_child(ui_canvas_layer)
	ui_root = Control.new()
	ui_root.name = "menu_ui_root"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.layout_mode = 2
	ui_canvas_layer.add_child(ui_root)
	# _log("UI root created (CanvasLayer + Control)")

func get_ui_root() -> Control:
	ensure_ui_root()
	return ui_root

func _on_viewport_resized():
	"""Notify all visible window instances to re-apply their positioning"""
	for menu_name in window_instances.keys():
		var window = window_instances[menu_name]
		if window and window.is_open:
			var parent_size = window.get_parent().size if window.get_parent() is Control else get_viewport().get_visible_rect().size
			var strategy = get_menu_strategy(menu_name)
			await window.apply_position_strategy(strategy, parent_size, {})

###### CREATE MENUS ######

func create_menu_from_config(menu_name: String) -> Control:
	"""Creates a MenuWindow instance from its JSON configuration"""
	if not DataManager or not DataManager.menus or not DataManager.menus.has(menu_name):
		_log("ERROR: No config found for menu: " + menu_name + " in DataManager.menus")
		return null
	
	var config = DataManager.menus[menu_name]
	_log("Creating menu window for '" + menu_name + "'")
	
	# Try to load custom window script from multiple paths
	# Priority: res://windows/ > res://scripts/windows/ > base MenuWindow
	var windows_path = "res://windows/" + menu_name + "_window.gd"
	var scripts_windows_path = "res://scripts/windows/" + menu_name + "_window.gd"
	var script_to_use = null
	
	if ResourceLoader.exists(windows_path):
		script_to_use = load(windows_path)
		_log("Loaded custom window script: " + windows_path)
	elif ResourceLoader.exists(scripts_windows_path):
		script_to_use = load(scripts_windows_path)
		_log("Loaded custom window script: " + scripts_windows_path)
	else:
		script_to_use = load("res://addons/gsg-godot-plugins/menu_manager/menu_window.gd")
		_log("Using base MenuWindow for: " + menu_name)
	
	# Instantiate the node from script
	var window = Control.new()
	window.set_script(script_to_use)
	
	window.name = menu_name + "_window"
	window.menu_name = menu_name
	
	# Add to tree immediately so _ready() fires
	var parent = get_ui_root()
	_log("Parent in tree: " + str(parent.is_inside_tree()) + ", children before: " + str(parent.get_child_count()))
	parent.add_child(window, true)  # Force readable name
	_log("Children after: " + str(parent.get_child_count()) + ", window parent: " + str(window.get_parent()))
	# Wait for _ready() to be called
	await get_tree().process_frame
	_log("Window is_inside_tree: " + str(window.is_inside_tree()))
	
	# Parse window behavior
	if config.has("window_behavior"):
		var behavior = config["window_behavior"]
		window.close_parent_on_open = behavior.get("close_parent_on_open", false)
		window.hide_parent_on_open = behavior.get("hide_parent_on_open", true)
		window.auto_focus_on_open = behavior.get("auto_focus_on_open", true)
		window.restore_focus_on_close = behavior.get("restore_focus_on_close", true)
		if behavior.has("closable_via_back"):
			window.closable_via_back = behavior.get("closable_via_back", true)
		if behavior.has("pop_on_back"):
			window.pop_on_back = behavior.get("pop_on_back", false)
		_log("Window '" + menu_name + "' behavior: hide_parent=" + str(window.hide_parent_on_open) + ", close_parent=" + str(window.close_parent_on_open))
	
	# Parse and register subphases if defined
	if config.has("subphases") and window.has_method("register_subphases"):
		var subphases = config["subphases"]
		var initial = subphases.get("initial", "")
		var definitions = subphases.get("definitions", {})
		if not initial.is_empty() and not definitions.is_empty():
			window.register_subphases(definitions, initial)
			_log("Registered subphases for '" + menu_name + "': initial=" + initial)
	
	# Parse custom size
	var custom_size = Vector2.ZERO
	if config.has("custom_size"):
		var size_data = config["custom_size"]
		custom_size = Vector2(size_data.get("x", 0), size_data.get("y", 0))
	
	# Get container type and layout config
	var container_type = config.get("container_type", "VBox")
	var layout_config = config.get("layout_config", {})
	var is_dropdown = config.get("is_dropdown", false)
	var show_background = config.get("show_background", true)
	
	# Create the menu content via MenuBuilder
	var menu = MenuBuilder.create_dynamic_menu(menu_name, is_dropdown, custom_size, container_type, layout_config, show_background, menu_theme)
	
	# Store in dynamic_menus dictionary so it can be found by get_menu()
	dynamic_menus[menu_name] = menu
	
	# Add menu as child of window
	window.add_child(menu)
	_log("Added dynamic menu node to window '" + menu_name + "'")
	
	# Store window instance BEFORE building custom elements so buttons can be connected
	window_instances[menu_name] = window
	_log("Window instance stored for '" + menu_name + "' (before custom elements)")
	
	# Build custom elements if defined
	if config.has("custom_elements"):
		var content_container = get_menu_content_container(menu_name)
		MenuBuilder.build_custom_elements(menu_name, config["custom_elements"], content_container, menu_theme)
	
	# Call post-create setup if defined
	if config.has("post_create_setup"):
		var setup_func = config["post_create_setup"]
		# Prefer window-defined setup to keep MenuManager generic
		if window and window.has_method(setup_func):
			window.call(setup_func, menu)
		elif has_method(setup_func):
			# Fallback to legacy MenuManager method during migration
			call(setup_func, menu)
		else:
			print("WARNING: post_create_setup function not found on window or MenuManager: ", setup_func)
	
	# Create buttons if defined in config
	if config.has("buttons"):
		var content_container = get_menu_content_container(menu_name)
		if content_container:
			var button_style = config.get("button_style", {})
			# Connect buttons directly to the window's handler
			var on_pressed = window._on_custom_button_pressed if window.has_method("_on_custom_button_pressed") else _on_custom_button_pressed
			MenuBuilder.build_buttons_from_config(menu_name, config["buttons"], content_container, button_style, on_pressed, _on_button_focus)
	
	# Store window instance
	window_instances[menu_name] = window
	_log("Window instance stored for '" + menu_name + "'")
	
	# Emit signal that menu is fully constructed
	if window.has_signal("menu_ready"):
		window.menu_ready.emit()
	
	# Neighbors: tethering via JSON
	var neighbors: Dictionary = {}
	if config.has("neighbors") and config["neighbors"] is Dictionary:
		neighbors = config["neighbors"]
	var tether_list: Array = []
	if neighbors.has("tether"):
		tether_list = neighbors["tether"]
	elif config.has("tether"):
		# Support legacy top-level tether key
		tether_list = config["tether"]
	for other_name in tether_list:
		if typeof(other_name) == TYPE_STRING:
			var other_win = get_menu_window(other_name)
			if not other_win:
				other_win = await create_menu_from_config(other_name)
				# Attach to same UI root if needed
				if other_win and not other_win.is_inside_tree():
					get_ui_root().add_child(other_win)
			if other_win:
				# Directional tether: when THIS window closes, also close the tethered one
				if window.has_method("tether_window"):
					window.tether_window(other_win)
				_log("Tethered '" + menu_name + "' -> '" + other_name + "'")
	
	return window

###### WINDOW MANAGEMENT ######



func _on_custom_button_pressed(button: CustomButton, button_type: String, index: int, parameter: String):
	"""Fallback handler for buttons not connected to a specific window"""
	# print("=== MENU MANAGER BUTTON PRESSED (FALLBACK) ===")
	# print("Button: ", button.name if button else "null")
	# print("Button type: ", button_type)
	# print("Index: ", index)
	# print("Parameter: ", parameter)
	print("WARNING: Button not properly routed to window handler")
	




func get_menu_content_container(menu_name: String) -> Control:
	"""Gets the primary content container inside a menu (the VBox/HBox/Grid inside the MarginContainer inside the NinePatch)"""
	var menu = get_menu(menu_name)
	if not menu:
		return null
	var window = menu.get_child(0) # The NinePatchRect
	if not window:
		return null
	var margin = window.get_child(0) # The MarginContainer
	if not margin:
		return null
	return margin.get_child(0) # The primary content container (VBox, etc.)

func get_menu_name_from_control(menu_control: Control) -> String:
	"""Gets the menu name from a control by searching through dynamic_menus"""
	for menu_name in dynamic_menus.keys():
		if dynamic_menus[menu_name] == menu_control:
			return menu_name
	return ""

###### ANIMATE MENUS ######



func _on_button_focus():
	if SoundManager != null:
		SoundManager.play_sound("res://sounds/menu/focus_button.wav")

func is_menu_visible(menu_name: String) -> bool:
	"""Checks if a menu is currently visible"""
	var menu = get_menu(menu_name)
	return menu != null and menu.visible


###### ITEMS MENU FUNCTIONS ######








###### HELPER FUNCTIONS ######









###### HELPER FUNCTIONS ######










func add_menu_to_parent(menu_control: Control, parent: Control):
	"""Adds a menu to a parent control and stores the reference"""
	parent.add_child(menu_control)
	return menu_control

func remove_menu_from_parent(menu_control: Control, parent: Control):
	"""Removes a menu from its parent control"""
	if menu_control.get_parent() == parent:
		parent.remove_child(menu_control)
		menu_control.queue_free()

func get_menu(menu_name: String) -> Control:
	"""Gets a menu by name, returns null if it doesn't exist"""
	return dynamic_menus.get(menu_name, null)

func get_menu_scale(menu_name: String) -> Vector2:
	"""Gets the current scale of a menu's NinePatchRect"""
	var menu = get_menu(menu_name)
	if menu:
		for child in menu.get_children():
			if child is NinePatchRect:
				return child.scale
	return Vector2(1, 1)
