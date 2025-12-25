class_name MenuBuilder

# Helper class for building menu UI from JSON config
# All static methods, no state

static var black_window_prefab = preload("res://prefabs/windows/black_window.tscn")

# Helper function to apply menu theme to dynamically created controls
# Call this when creating Label, RichTextLabel, or Button nodes in code
static func apply_menu_theme(control: Control, custom_theme: Theme = null):
	"""Apply the menu theme to a control. Use custom_theme to override default."""
	var theme_to_apply = custom_theme if custom_theme else MenuManager.menu_theme
	if theme_to_apply and (control is Label or control is RichTextLabel or control is Button):
		control.theme = theme_to_apply

static func create_dynamic_menu(menu_name: String, is_dropdown: bool, custom_size: Vector2, container_type: String, layout_config: Dictionary, show_background: bool, menu_theme: Theme) -> Control:
	# Create the main control container
	var menu_container = Control.new()
	menu_container.name = menu_name + "_container"
	menu_container.visible = false
	menu_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_container.layout_mode = 2
	
	# Create the nine patch window or transparent container
	var window: Control
	if show_background:
		window = black_window_prefab.instantiate()
	else:
		window = Control.new()
		window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Reset anchors so manual positioning works predictably
	if window is Control:
		window.anchor_left = 0
		window.anchor_top = 0
		window.anchor_right = 0
		window.anchor_bottom = 0
		window.offset_left = 0
		window.offset_top = 0
		window.offset_right = 0
		window.offset_bottom = 0
	menu_container.add_child(window)
	
	# Apply sizing
	if custom_size != Vector2.ZERO:
		window.custom_minimum_size = custom_size
		window.size = custom_size
	else:
		apply_default_menu_sizing(window, menu_name, is_dropdown)
	
	# Get margins config from DataManager if available
	var margins_config = {}
	if DataManager.menus.has(menu_name):
		margins_config = DataManager.menus[menu_name].get("margins", {})
	
	# Create a MarginContainer for padding
	var margin_container = MarginContainer.new()
	margin_container.add_theme_constant_override("margin_left", 20)
	margin_container.add_theme_constant_override("margin_top", 20)
	margin_container.add_theme_constant_override("margin_right", 20)
	margin_container.add_theme_constant_override("margin_bottom", 20)
	margin_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin_container.layout_mode = 2
	# Check if clip_contents is explicitly set in margins config
	if margins_config.has("clip_contents"):
		margin_container.clip_contents = margins_config["clip_contents"]
	else:
		margin_container.clip_contents = true
	window.add_child(margin_container)
	
	# Create the primary content container
	var primary_container = create_container_by_type(container_type, layout_config)
	primary_container.name = menu_name + "_primary_content"
	primary_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	if primary_container is Container:
		# Check if clip_contents is explicitly set in layout_config
		if layout_config.has("clip_contents"):
			primary_container.clip_contents = layout_config["clip_contents"]
		else:
			primary_container.clip_contents = true
	
	apply_container_layout(primary_container, layout_config)
	margin_container.add_child(primary_container)
	
	# Create nested containers if specified
	if layout_config.has("nested_containers"):
		create_nested_containers(primary_container, layout_config.nested_containers)
	
	return menu_container

static func apply_default_menu_sizing(window: Control, menu_name: String, is_dropdown: bool):
	# Try to get size from DataManager.menus first
	if DataManager.menus.has(menu_name):
		var config = DataManager.menus[menu_name]
		if config.has("custom_size"):
			var size_data = config["custom_size"]
			var x = size_data.get("x", 0)
			var y = size_data.get("y", 0)
			if x > 0 or y > 0:
				window.custom_minimum_size = Vector2(x, y)
				return
	
	# Fallback to default sizing
	if is_dropdown:
		window.custom_minimum_size = Vector2(180, 200)
	else:
		window.custom_minimum_size = Vector2(480, 320)

static func build_buttons_from_config(menu_name: String, button_configs: Array, content_container: Control, button_style: Dictionary, on_pressed_callback: Callable, on_focus_callback: Callable):
	"""Create buttons from JSON config array"""
	if not content_container:
		print("ERROR: No content container found for menu: ", menu_name)
		return
	
	for i in range(button_configs.size()):
		var btn_config = button_configs[i]
		var button_scene: PackedScene = load("res://prefabs/default_button.tscn")
		var btn = button_scene.instantiate()
		
		# Get text from JSON
		var text_key = btn_config.get("text_key", "")
		if not text_key.is_empty():
			btn.text = get_text_from_json_path(text_key)
		else:
			btn.text = btn_config.get("text", "Button")
		
		# Set button properties
		var group_name = btn_config.get("group", "buttons")
		var button_type = btn_config.get("button_type", "menu")
		btn.add_to_group(group_name)
		btn.add_to_group(menu_name + "_buttons")
		btn.add_to_group("all_menu_buttons")
		btn.index = i
		btn.button_type = button_type
		btn.parameter = group_name
		btn.focus_mode = Control.FOCUS_ALL
		btn.layout_mode = 2
		
		# Connect signals
		btn.custom_button_pressed.connect(on_pressed_callback)
		btn.focus_entered.connect(on_focus_callback)
		
		content_container.add_child(btn)
	
	# Apply button style if defined
	if not button_style.is_empty():
		for child in content_container.get_children():
			if child is Control and child.is_in_group(menu_name + "_buttons"):
				if button_style.has("custom_minimum_size"):
					var size_data = button_style["custom_minimum_size"]
					(child as Control).custom_minimum_size = Vector2(size_data.get("x", 0), size_data.get("y", 0))

static func build_custom_elements(menu_name: String, custom_elements_config: Array, content_container: Control, menu_theme: Theme):
	if not content_container:
		print("ERROR: No content container found for menu: ", menu_name)
		return
	
	for config_item in custom_elements_config:
		if config_item.has("target_path"):
			var target_path = config_item.get("target_path", "")
			var elements = config_item.get("elements", [])
			
			var target_container: Control = null
			if target_path.is_empty():
				target_container = content_container
			else:
				target_container = content_container.get_node(target_path) if content_container.has_node(target_path) else null
			
			if not target_container:
				print("ERROR: Target container not found: ", target_path)
				continue
			
			for element_config in elements:
				var element = create_ui_element(menu_name, element_config, menu_theme)
				if element:
					target_container.add_child(element)
		else:
			var element = create_ui_element(menu_name, config_item, menu_theme)
			if element:
				content_container.add_child(element)
	
	# After creating all elements, connect button signals to window handler
	_connect_custom_element_buttons(menu_name, content_container)

static func create_ui_element(menu_name: String, element_config: Dictionary, menu_theme: Theme) -> Control:
	var element_type = element_config.get("type", "")
	var element_name = element_config.get("name", "")
	var properties = element_config.get("properties", {})
	var children = element_config.get("children", [])
	
	var element: Control = null
	
	match element_type:
		"portrait_button":
			var party_index = element_config.get("party_index", 0)
			var button = TextureButton.new()
			button.name = "portrait_button_" + str(party_index)
			button.custom_minimum_size = Vector2(128, 128)
			button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
			button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			button.add_to_group("party_portrait_buttons")
			button.add_to_group(menu_name + "_buttons")
			button.set_meta("party_index", party_index)
			# Start as unselectable - portraits only become focusable when actively used
			button.focus_mode = Control.FOCUS_NONE
			button.disabled = true
			button.mouse_filter = Control.MOUSE_FILTER_IGNORE
			
			var character_scene = load("res://prefabs/character.tscn")
			if character_scene:
				var character_instance = character_scene.instantiate()
				character_instance.position = Vector2(64, 64)
				button.add_child(character_instance)
				button.set_meta("character_node", character_instance)
				var sprite = character_instance.get_node_or_null("Sprite")
				if sprite:
					sprite.add_to_group("menu_party_sprite")
					# Ensure unique material per portrait so focus flashing can be toggled independently
					if sprite.material:
						sprite.material = sprite.material.duplicate()
						if sprite.material is ShaderMaterial:
							(sprite.material as ShaderMaterial).set_shader_parameter("flash_enabled", false)
			
			# Make it a CustomTextureButton for make_selectable/make_unselectable support
			var custom_script = load("res://scripts/custom_texture_button.gd")
			if custom_script:
				button.set_script(custom_script)
			
			return button
		"hbox_container":
			element = HBoxContainer.new()
		"vbox_container":
			element = VBoxContainer.new()
		"Label":
			element = Label.new()
		"RichTextLabel":
			element = RichTextLabel.new()
		"ScrollContainer":
			element = ScrollContainer.new()
		"VBoxContainer":
			element = VBoxContainer.new()
		"HBoxContainer":
			element = HBoxContainer.new()
		"GridContainer":
			element = GridContainer.new()
		"MarginContainer":
			element = MarginContainer.new()
		"PanelContainer":
			element = PanelContainer.new()
		"NinePatchRect":
			element = NinePatchRect.new()
		"TextureRect":
			element = TextureRect.new()
		"ProgressBar":
			element = ProgressBar.new()
		"Button":
			var button_scene: PackedScene = load("res://prefabs/default_button.tscn")
			element = button_scene.instantiate()
		"HSeparator":
			element = HSeparator.new()
		"VSeparator":
			element = VSeparator.new()
		"BlackWindow":
			element = black_window_prefab.instantiate()
		"Scene":
			# Load and instantiate a scene from scene_path
			var scene_path = element_config.get("scene_path", "")
			if scene_path.is_empty():
				print("ERROR: Scene element missing scene_path")
				return null
			var scene = load(scene_path)
			if scene:
				var instance = scene.instantiate()
				# Wrap Node2D in a Control container for proper layout
				if instance is Node2D:
					var container = Control.new()
					container.custom_minimum_size = Vector2(128, 128)
					instance.position = Vector2(64, 32)
					container.add_child(instance)
					# Store reference to the actual scene instance
					container.set_meta("scene_instance", instance)
					element = container
				else:
					element = instance
				# Apply any initial properties from config
				for prop_key in properties.keys():
					if prop_key in instance:
						instance.set(prop_key, properties[prop_key])
			else:
				print("ERROR: Could not load scene: ", scene_path)
				return null
		_:
			print("ERROR: Unknown element type: ", element_type)
			return null
	
	if not element_name.is_empty():
		element.name = element_name
	
	# Apply properties (this may override the default theme if "theme" property is specified)
	apply_element_properties(element, properties, menu_theme)
	
	# Recursively create children
	for child_config in children:
		var child = create_ui_element(menu_name, child_config, menu_theme)
		if child:
			element.add_child(child)
	
	return element

static func apply_element_properties(element: Control, properties: Dictionary, menu_theme: Theme):
	for prop_name in properties.keys():
		var prop_value = properties[prop_name]
		
		match prop_name:
			"text_key":
				var text = get_text_from_json_path(prop_value)
				if element.has_method("set_text"):
					element.set("text", text)
			"text":
				if element.has_method("set_text"):
					element.set("text", prop_value)
			"horizontal_alignment":
				if element is Label:
					match prop_value:
						"center":
							element.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
						"left":
							element.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
						"right":
							element.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			"size_flags_horizontal":
				if typeof(prop_value) == TYPE_INT or typeof(prop_value) == TYPE_FLOAT:
					# Direct numeric value (e.g., 3 = SIZE_EXPAND_FILL)
					element.size_flags_horizontal = int(prop_value)
				else:
					match prop_value:
						"expand_fill":
							element.size_flags_horizontal = Control.SIZE_EXPAND_FILL
						"shrink_center":
							element.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
						"shrink_begin":
							element.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			"size_flags_vertical":
				if typeof(prop_value) == TYPE_INT or typeof(prop_value) == TYPE_FLOAT:
					# Direct numeric value (e.g., 3 = SIZE_EXPAND_FILL)
					element.size_flags_vertical = int(prop_value)
				else:
					match prop_value:
						"expand_fill":
							element.size_flags_vertical = Control.SIZE_EXPAND_FILL
						"shrink_center":
							element.size_flags_vertical = Control.SIZE_SHRINK_CENTER
						"shrink_begin":
							element.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			"horizontal_scroll_mode":
				if element is ScrollContainer:
					if typeof(prop_value) == TYPE_INT or typeof(prop_value) == TYPE_FLOAT:
						element.horizontal_scroll_mode = int(prop_value)
					else:
						match prop_value:
							"disabled":
								element.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
							"auto":
								element.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			"vertical_scroll_mode":
				if element is ScrollContainer:
					if typeof(prop_value) == TYPE_INT or typeof(prop_value) == TYPE_FLOAT:
						element.vertical_scroll_mode = int(prop_value)
					else:
						match prop_value:
							"disabled":
								element.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
							"auto":
								element.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			"follow_focus":
				if element is ScrollContainer:
					element.follow_focus = prop_value
			"scroll_deadzone":
				if element is ScrollContainer:
					element.scroll_deadzone = prop_value
			"clip_contents":
				element.clip_contents = prop_value
			"circular_focus":
				# Store as metadata - will be processed after buttons are added
				element.set_meta("circular_focus", prop_value)
			"spacing":
				if element is VBoxContainer or element is HBoxContainer:
					element.add_theme_constant_override("separation", prop_value)
			"separation":
				if element is VBoxContainer or element is HBoxContainer:
					element.add_theme_constant_override("separation", prop_value)
			"alignment":
				if element is BoxContainer:
					match prop_value:
						"left", "begin":
							element.alignment = BoxContainer.ALIGNMENT_BEGIN
						"center":
							element.alignment = BoxContainer.ALIGNMENT_CENTER
						"right", "end":
							element.alignment = BoxContainer.ALIGNMENT_END
			"columns":
				if element is GridContainer:
					element.columns = prop_value
			"h_separation":
				if element is GridContainer:
					element.add_theme_constant_override("h_separation", prop_value)
			"v_separation":
				if element is GridContainer:
					element.add_theme_constant_override("v_separation", prop_value)
			"theme_font_size":
				if element is Label or element is RichTextLabel:
					element.add_theme_font_size_override("normal_font_size", int(prop_value))
			"custom_minimum_size":
				if typeof(prop_value) == TYPE_ARRAY and prop_value.size() >= 2:
					element.custom_minimum_size = Vector2(float(prop_value[0]), float(prop_value[1]))
				elif typeof(prop_value) == TYPE_DICTIONARY and prop_value.has("x") and prop_value.has("y"):
					element.custom_minimum_size = Vector2(float(prop_value["x"]), float(prop_value["y"]))
				else:
					element.custom_minimum_size = prop_value
			"margin_left", "margin_top", "margin_right", "margin_bottom":
				var theme_key = prop_name
				if element is MarginContainer:
					element.add_theme_constant_override(theme_key, int(prop_value))
				else:
					if prop_name in element:
						element.set(prop_name, prop_value)
			"theme":
				# Allow JSON to explicitly override the default menu theme
				if typeof(prop_value) == TYPE_STRING:
					var theme_path = prop_value
					if ResourceLoader.exists(theme_path):
						element.theme = load(theme_path)
				else:
					element.theme = prop_value
			"texture":
				# Load texture for NinePatchRect or TextureRect
				if typeof(prop_value) == TYPE_STRING and ResourceLoader.exists(prop_value):
					if element is NinePatchRect or element is TextureRect:
						element.texture = load(prop_value)
			"button_type":
				# Set button_type for CustomButton
				if element is CustomButton:
					element.button_type = str(prop_value)
					print("[MenuBuilder] Set button_type to '", prop_value, "' for button: ", element.name)
			"parameter":
				# Set parameter for CustomButton
				if element is CustomButton:
					element.parameter = str(prop_value)
					print("[MenuBuilder] Set parameter to '", prop_value, "' for button: ", element.name)
			"group":
				# Add button to group
				if element is Control:
					element.add_to_group(str(prop_value))
					print("[MenuBuilder] Added button '", element.name, "' to group: ", prop_value)
			"focus_mode":
				# Set focus mode explicitly
				if element is Control:
					if typeof(prop_value) == TYPE_INT:
						element.focus_mode = prop_value
					else:
						match prop_value:
							"none":
								element.focus_mode = Control.FOCUS_NONE
							"click":
								element.focus_mode = Control.FOCUS_CLICK
							"all":
								element.focus_mode = Control.FOCUS_ALL
			"disabled":
				# Set disabled state for buttons
				if element is BaseButton:
					element.disabled = prop_value
			_:
				if prop_name in element:
					element.set(prop_name, prop_value)

static func get_text_from_json_path(path: String) -> String:
	var parts = path.split(".")
	if parts.size() == 0:
		return path
	# Currently support resolving from DataManager.menu
	if parts[0] == "menu":
		var current: Variant = DataManager.menu
		for i in range(1, parts.size()):
			if current is Dictionary and current.has(parts[i]):
				current = current[parts[i]]
			else:
				return path
		return str(current)
	return path

static func create_container_by_type(container_type: String, layout_config: Dictionary) -> Control:
	var container: Control = null
	match container_type:
		"VBox":
			container = VBoxContainer.new()
		"HBox":
			container = HBoxContainer.new()
		"Grid":
			container = GridContainer.new()
			if layout_config.has("columns"):
				(container as GridContainer).columns = layout_config.columns
		"VSeparator":
			container = VSeparator.new()
		"HSeparator":
			container = HSeparator.new()
		_:
			container = VBoxContainer.new()
	
	container.layout_mode = 2
	
	if container is BoxContainer:
		(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	
	return container

static func apply_container_layout(container: Control, layout_config: Dictionary):
	if layout_config.has("alignment") and container is BoxContainer:
		match layout_config.alignment:
			"center":
				(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
			"left":
				(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_BEGIN
			"right":
				(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_END
			"top":
				(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_BEGIN
			"bottom":
				(container as BoxContainer).alignment = BoxContainer.ALIGNMENT_END
	
	if layout_config.has("spacing"):
		if container is VBoxContainer:
			container.add_theme_constant_override("separation", layout_config.spacing)
		elif container is HBoxContainer:
			container.add_theme_constant_override("separation", layout_config.spacing)
		elif container is GridContainer:
			container.add_theme_constant_override("h_separation", layout_config.spacing)
			container.add_theme_constant_override("v_separation", layout_config.spacing)

static func create_nested_containers(parent_container: Control, nested_configs: Array):
	for config in nested_configs:
		var nested_container = create_container_by_type(config.type, config)
		nested_container.name = config.name if config.has("name") else "nested_container"
		
		apply_container_layout(nested_container, config)
		
		if nested_container is Container:
			nested_container.clip_contents = true
		
		parent_container.add_child(nested_container)
		
		if config.has("nested_containers"):
			create_nested_containers(nested_container, config.nested_containers)

static func _connect_custom_element_buttons(menu_name: String, container: Control):
	"""Recursively find and connect CustomButton signals to the window's handler"""
	print("[MenuBuilder] _connect_custom_element_buttons called for: ", menu_name)
	var window = MenuManager.get_menu_window(menu_name)
	print("[MenuBuilder] Window found: ", window != null, " has method: ", window.has_method("_on_custom_button_pressed") if window else false)
	if not window or not window.has_method("_on_custom_button_pressed"):
		print("[MenuBuilder] Cannot connect buttons - window not ready")
		return
	
	for child in container.get_children():
		if child is CustomButton:
			# Connect if not already connected
			if not child.custom_button_pressed.is_connected(window._on_custom_button_pressed):
				child.custom_button_pressed.connect(window._on_custom_button_pressed)
				print("[MenuBuilder] Connected button: ", child.name, " type:", child.button_type)
		if child is Control:
			# Recursively check children
			_connect_custom_element_buttons(menu_name, child)
