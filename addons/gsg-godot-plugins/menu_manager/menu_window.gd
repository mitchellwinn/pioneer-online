extends Control
class_name MenuWindow


# Self-contained menu window instance created from menu JSON
# Each window manages its own state, focus, and child windows

signal window_opened
signal window_closed
signal menu_ready  # Emitted when MenuManager finishes building the menu structure

func _log(msg):
	var tag = menu_name
	if tag == "":
		tag = str(name)
	print("[MenuWindow:" + str(tag) + "] " + str(msg))

# Window state
var is_open: bool = false
var menu_name: String = ""

# Window hierarchy
var parent_window: Control = null
var child_windows: Array = []

# Window behavior (set from JSON config)
var close_parent_on_open: bool = false
var hide_parent_on_open: bool = true
var auto_focus_on_open: bool = true
var restore_focus_on_close: bool = true
var closable_via_back: bool = true
var pop_on_back: bool = false

# Focus tracking
var last_focused_control: Control = null
var _is_active_window: bool = false

# Tethered windows (windows that should close together)
var tethered_windows: Array = []

# Dialogue support
var dialogue_label: RichTextLabel = null

func _ready():
	# Make window fill parent for proper positioning
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout_mode = 2
	# Windows start hidden
	visible = false
	
	# Create dialogue label for this window if needed (may be overridden by JSON element)
	create_dialogue_label()
	_log("_ready complete (window hidden, anchors set)")

func open_window():
	"""Open this window"""
	print("[MenuWindow:" + menu_name + "] open_window() CALLED")
	if is_open:
		print("[MenuWindow:" + menu_name + "] already open, returning")
		return
	
	print("[MenuWindow:" + menu_name + "] is_inside_tree: ", is_inside_tree())
	# Ensure we're in the scene tree before using get_tree()/viewport
	if not is_inside_tree():
		print("[MenuWindow:" + menu_name + "] NOT in tree, awaiting tree_entered")
		await tree_entered
		print("[MenuWindow:" + menu_name + "] NOW in tree")
	
	print("[MenuWindow:" + menu_name + "] About to play sound")
	# Play open sound
	if SoundManager:
		SoundManager.play_sound("res://sounds/menu/open_menu.wav")
	
	print("[MenuWindow:" + menu_name + "] Setting is_open=true, visible=true")
	is_open = true
	visible = true
	print("[MenuWindow:" + menu_name + "] visible is now: ", visible)
	
	# Handle parent window behavior
	if parent_window and close_parent_on_open:
		print("[MenuWindow:" + menu_name + "] Closing parent window: ", parent_window.menu_name if "menu_name" in parent_window else parent_window.name)
		# Before closing parent, remember its last focus if we should restore later
		if parent_window and parent_window.has_method("get_viewport") and parent_window.restore_focus_on_close:
			parent_window.last_focused_control = parent_window.get_viewport().gui_get_focus_owner()
		parent_window.close_window()
	elif parent_window and hide_parent_on_open:
		print("[MenuWindow:" + menu_name + "] Hiding parent window: ", parent_window.menu_name if "menu_name" in parent_window else parent_window.name)
		# Hide parent but keep it in the stack; remember last focus for restoration
		if parent_window and parent_window.has_method("get_viewport") and parent_window.restore_focus_on_close:
			parent_window.last_focused_control = parent_window.get_viewport().gui_get_focus_owner()
		parent_window.visible = false
	else:
		if parent_window:
			print("[MenuWindow:" + menu_name + "] NOT hiding parent (hide_parent_on_open=false)")
	
	# Position and show the menu
	var parent_control = get_parent() as Control
	var parent_size: Vector2
	if parent_control:
		parent_size = parent_control.size
	else:
		# Fallback to viewport size when parent isn't a Control
		var vp_sizei = get_viewport().get_visible_rect().size
		parent_size = Vector2(vp_sizei.x, vp_sizei.y)
	_log("Applying position strategy with parent size=" + str(parent_size))
	var strategy = MenuManager.get_menu_strategy(menu_name)
	var context = get_meta("position_context", {})
	await apply_position_strategy(strategy, parent_size, context)
	show_menu_visual()
	
	# Auto-focus first button if enabled
	if auto_focus_on_open:
		await get_tree().process_frame
		focus_first_button()
	
	# Add to active window stack
	MenuManager.push_window(self)
	
	window_opened.emit()
	_log("opened")

func close_window():
	"""Close this window"""
	if not is_open:
		return
	
	# Play close sound
	if SoundManager:
		SoundManager.play_sound("res://sounds/menu/close_menu.wav")
	
	# Save currently focused control
	if restore_focus_on_close:
		last_focused_control = get_viewport().gui_get_focus_owner()
	
	is_open = false
	hide_menu_visual()
	
	_log("closing")
	# Close all child windows
	for child in child_windows.duplicate():
		if child and is_instance_valid(child):
			child.close_window()
	
	# Close all tethered windows
	for tethered in tethered_windows.duplicate():
		if tethered and is_instance_valid(tethered) and tethered.has_method("close_window"):
			tethered.close_window()
	
	# Remove from active window stack
	MenuManager.pop_window(self)
	
	# Restore parent window
	if parent_window and is_instance_valid(parent_window):
		parent_window.visible = true
		if restore_focus_on_close and parent_window.last_focused_control:
			await get_tree().process_frame
			if is_instance_valid(parent_window.last_focused_control):
				parent_window.last_focused_control.grab_focus()
	
	window_closed.emit()
	_log("closed")

func set_window_active(active: bool):
	"""Enable/disable focusability for this window's controls based on active stack status.
	When deactivating, remember the last focused control. When reactivating, restore it or focus first inside subphase if present."""
	_is_active_window = active
	# Remember last focused control if deactivating
	if not active and restore_focus_on_close:
		var current_focus = get_viewport().gui_get_focus_owner()
		if current_focus and is_instance_valid(current_focus) and self.is_ancestor_of(current_focus):
			last_focused_control = current_focus
	
	# Disable all custom buttons when deactivating
	if not active:
		var content_container: Control = MenuManager.get_menu_content_container(menu_name)
		if content_container:
			_disable_all_custom_buttons(content_container)
	
	# Re-enable buttons and restore focus when activating
	if active:
		var content_container: Control = MenuManager.get_menu_content_container(menu_name)
		if content_container:
			if has_subphases():
				# For subphased windows, apply gating (which enables appropriate buttons)
				apply_subphase_focus_gating()
			else:
				# For non-subphased windows, enable all buttons
				_enable_all_custom_buttons(content_container)
		
		# Restore focus
		if has_subphases():
			if last_focused_control and is_instance_valid(last_focused_control) and last_focused_control.visible and _is_control_allowed_by_subphase(last_focused_control):
				last_focused_control.grab_focus()
			else:
				_focus_first_in_subphase(get_subphase())
		else:
			if last_focused_control and is_instance_valid(last_focused_control) and last_focused_control.visible:
				last_focused_control.grab_focus()
			else:
				focus_first_button()

func focus_first_button():
	"""Focus the first available button in this window"""
	# If window has subphases, use subphase-aware focusing
	if has_subphases():
		_focus_first_in_subphase(get_subphase())
		return
	
	# Find first focusable button under this menu's container
	var menu_container = MenuManager.get_menu(menu_name)
	if menu_container:
		for node in menu_container.get_children():
			if node is Control:
				if _focus_first_descendant(node):
					return
	_log("No focusable buttons found")

func _focus_first_descendant(root: Control) -> bool:
	# Prefer CustomButton/CustomTextureButton; skip generic containers
	for child in root.get_children():
		if (child is CustomButton or child is CustomTextureButton) and (child as Control).visible and (child as Control).focus_mode == Control.FOCUS_ALL:
			(child as Control).grab_focus()
			return true
		if child is Control:
			if _focus_first_descendant(child):
				return true
	return false

func add_child_window(child):
	"""Register a child window"""
	child.parent_window = self
	if not child_windows.has(child):
		child_windows.append(child)

func tether_window(other_window):
	"""Tether another window to this one - when this closes, other closes too"""
	if other_window and not tethered_windows.has(other_window):
		tethered_windows.append(other_window)
		_log("Tethered window: " + other_window.menu_name if "menu_name" in other_window else str(other_window))

func create_dialogue_label():
	"""Create a dialogue label for this window"""
	if not dialogue_label:
		dialogue_label = RichTextLabel.new()
		dialogue_label.name = menu_name + "_dialogue_label"
		dialogue_label.bbcode_enabled = true
		dialogue_label.fit_content = true
		if MenuManager.menu_theme:
			dialogue_label.theme = MenuManager.menu_theme
		add_child(dialogue_label)
		dialogue_label.visible = false
		_log("dialogue_label created")

func show_dialogue(text: String):
	"""Show dialogue in this window"""
	if dialogue_label:
		dialogue_label.visible = true
		dialogue_label.text = text

func hide_dialogue():
	"""Hide dialogue in this window"""
	if dialogue_label:
		dialogue_label.visible = false

func _unhandled_input(event):
	# Handle back button for menu windows
	if event.is_action_pressed("back"):
		# If this window is open and active, handle back
		if is_open and MenuManager.get_active_window() == self:
			if closable_via_back:
				# Check if we have subphases and can go back to a previous subphase
				var has_subs = has_subphases()
				var can_go_back = can_go_back_subphase()
				_log("Back pressed: has_subphases=" + str(has_subs) + ", can_go_back=" + str(can_go_back) + ", current_subphase=" + get_subphase())
				if has_subs and can_go_back:
					go_back_subphase()
					get_viewport().set_input_as_handled()
				else:
					# No subphase to go back to, close the window
					close_window()
					get_viewport().set_input_as_handled()
		# If no window is active and not in battle/dialogue, open main menu
		elif not MenuManager.get_active_window():
			if not DialogueManager.is_open and not GameManager.is_transitioning and not BattleManager.in_battle and not BattleManager.is_transitioning_to_battle:
				MenuManager.open_window("main")
				get_viewport().set_input_as_handled()

func _on_custom_button_pressed(button, button_type: String, index: int, parameter: String):
	"""Handle button presses - override in child classes or handle via signals"""
	# Play button sound for all button presses
	if SoundManager:
		SoundManager.play_sound("res://sounds/menu/confirm_select.wav")
	_log("button press type=" + button_type + ", index=" + str(index) + ", param=" + parameter)

# Subphase focus gating system
var _subphase_registry: Dictionary = {}
var _subphase_focus_memory: Dictionary = {} # Store last focused control per subphase
var _subphase_focus_index: Dictionary = {} # Store last focused button index per subphase

func _is_control_allowed_by_subphase(control: Control) -> bool:
	if _subphase_registry.is_empty():
		return true
	var content_container: Control = MenuManager.get_menu_content_container(menu_name)
	if content_container == null:
		return true
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var current: String = _subphase_registry.get("current", "")
	var def: Dictionary = defs.get(current, {})
	var paths: Array = def.get("enabled_focus_paths", [])
	for p in paths:
		if content_container.has_node(p):
			var node: Node = content_container.get_node(p)
			if node is Control:
				if node == control or (node as Control).is_ancestor_of(control):
					return true
	return false




func rebuild_for_subphase(subphase: String):
	"""Called during subphase transitions. Override in child classes to rebuild UI for a subphase. Call super() first if overriding."""
	if not has_subphases():
		return

func register_subphases(defs: Dictionary, initial: String):
	"""Register subphases for this window"""
	_subphase_registry = {"current": initial, "defs": defs}
	apply_subphase_focus_gating()

func set_subphase(new_subphase: String):
	"""Switch to a new subphase: rebuild (if window provides), then gate, then focus."""
	if _subphase_registry.is_empty():
		return
	var current: String = _subphase_registry.get("current", "")
	# Save current focus before leaving subphase
	var current_focus = get_viewport().gui_get_focus_owner()
	if current_focus and is_instance_valid(current_focus):
		_subphase_focus_memory[current] = current_focus
		# Also save the button index if possible
		var button_index = _get_button_index_in_subphase(current_focus, current)
		if button_index >= 0:
			_subphase_focus_index[current] = button_index
	# Call hooks
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var old_def: Dictionary = defs.get(current, {})
	if old_def.has("on_exit") and old_def["on_exit"] is Callable:
		old_def["on_exit"].call()
	_subphase_registry["current"] = new_subphase
	var new_def: Dictionary = defs.get(new_subphase, {})
	if new_def.has("on_enter") and new_def["on_enter"] is Callable:
		new_def["on_enter"].call()
	# Let window rebuild for this subphase, then wait a frame so nodes exist
	rebuild_for_subphase(new_subphase)
	await get_tree().process_frame
	# Apply gating after rebuild
	apply_subphase_focus_gating()
	# Restore focus for new subphase: try saved control first, then try saved index, else focus-first
	if _subphase_focus_memory.has(new_subphase):
		var saved_focus = _subphase_focus_memory[new_subphase]
		if is_instance_valid(saved_focus) and saved_focus.visible and saved_focus.focus_mode == Control.FOCUS_ALL and _is_control_allowed_by_subphase(saved_focus):
			saved_focus.grab_focus()
			return
	# If saved control is invalid, try to restore by index
	if _subphase_focus_index.has(new_subphase):
		if _focus_button_by_index_in_subphase(new_subphase, _subphase_focus_index[new_subphase]):
			return
	_focus_first_in_subphase(new_subphase)

func get_subphase() -> String:
	"""Get current subphase"""
	return _subphase_registry.get("current", "")

func has_subphases() -> bool:
	"""Check if this window has subphases"""
	return not _subphase_registry.is_empty()

func can_go_back_subphase() -> bool:
	"""Check if we can navigate back to a previous subphase"""
	if _subphase_registry.is_empty():
		return false
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var current: String = _subphase_registry.get("current", "")
	var current_def: Dictionary = defs.get(current, {})
	# Check if current subphase has a parent to go back to
	return current_def.has("parent_subphase")

func go_back_subphase():
	"""Navigate back to the parent subphase"""
	if _subphase_registry.is_empty():
		return
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var current: String = _subphase_registry.get("current", "")
	var current_def: Dictionary = defs.get(current, {})
	if current_def.has("parent_subphase"):
		var parent = current_def["parent_subphase"]
		_log("Going back from subphase '" + current + "' to '" + parent + "'")
		set_subphase(parent)

func apply_subphase_focus_gating():
	"""Toggle only CustomButton/CustomTextureButton selectability based on current subphase paths."""
	if _subphase_registry.is_empty():
		return
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var current: String = _subphase_registry.get("current", "")
	var def: Dictionary = defs.get(current, {})
	var content_container: Control = MenuManager.get_menu_content_container(menu_name)
	if content_container == null:
		return
	# Build allowed containers list
	var allowed_containers: Array = []
	var paths: Array = def.get("enabled_focus_paths", [])
	_log("Applying subphase gating for '" + current + "', enabled paths: " + str(paths))
	for p in paths:
		if content_container.has_node(p):
			var node: Node = content_container.get_node(p)
			if node is Control:
				allowed_containers.append(node)
				_log("  Found allowed container: " + p)
	var disabled_count = 0
	var enabled_count = 0
	# First, disable all custom buttons under the content container
	_for_each_custom_button(content_container, func(btn):
		btn.make_unselectable()
		disabled_count += 1
	)
	# Then, enable only those that are inside allowed containers
	for allowed in allowed_containers:
		_for_each_custom_button(allowed, func(btn):
			btn.make_selectable()
			enabled_count += 1
		)
	_log("Gating complete: disabled " + str(disabled_count) + ", enabled " + str(enabled_count))

func _focus_first_in_subphase(subphase: String):
	"""Focus the first available control in a subphase"""
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var def: Dictionary = defs.get(subphase, {})
	var content_container: Control = MenuManager.get_menu_content_container(menu_name)
	if content_container == null:
		return
	var paths: Array = def.get("enabled_focus_paths", [])
	for p in paths:
		if content_container.has_node(p):
			var node: Node = content_container.get_node(p)
			if node is Control:
				if _focus_first_descendant(node):
					return

func _get_button_index_in_subphase(control: Control, subphase: String) -> int:
	"""Get the index of a button within its subphase container. Returns -1 if not found."""
	if not (control is CustomButton or control is CustomTextureButton):
		return -1
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var def: Dictionary = defs.get(subphase, {})
	var content_container: Control = MenuManager.get_menu_content_container(menu_name)
	if content_container == null:
		return -1
	var paths: Array = def.get("enabled_focus_paths", [])
	# Find which enabled path contains this control
	for p in paths:
		if content_container.has_node(p):
			var container: Node = content_container.get_node(p)
			if container is Control and (container == control.get_parent() or (container as Control).is_ancestor_of(control)):
				# Found the right container, now find the button index within it
				var buttons: Array = []
				_collect_custom_buttons(container, buttons)
				for i in range(buttons.size()):
					if buttons[i] == control:
						return i
	return -1

func _focus_button_by_index_in_subphase(subphase: String, index: int) -> bool:
	"""Focus a button by its index within the subphase. Returns true if successful."""
	var defs: Dictionary = _subphase_registry.get("defs", {})
	var def: Dictionary = defs.get(subphase, {})
	var content_container: Control = MenuManager.get_menu_content_container(menu_name)
	if content_container == null:
		return false
	var paths: Array = def.get("enabled_focus_paths", [])
	# Collect all buttons from all enabled paths
	var all_buttons: Array = []
	for p in paths:
		if content_container.has_node(p):
			var node: Node = content_container.get_node(p)
			if node is Control:
				_collect_custom_buttons(node, all_buttons)
	# Try to focus the button at the requested index
	if index >= 0 and index < all_buttons.size():
		var button = all_buttons[index]
		if button.visible and button.focus_mode == Control.FOCUS_ALL:
			button.grab_focus()
			return true
	return false

func _collect_custom_buttons(root: Node, buttons: Array) -> void:
	"""Recursively collect all CustomButton/CustomTextureButton instances from a node tree."""
	for child in root.get_children():
		if child is CustomButton or child is CustomTextureButton:
			buttons.append(child)
		if child.get_child_count() > 0:
			_collect_custom_buttons(child, buttons)

func _set_children_focus_mode_recursive(node: Node, mode: int):
	"""Legacy helper: adjust focus_mode and BaseButton.disabled. Not used for subphase gating."""
	if node is Control:
		if (node as Control).focus_mode != mode:
			(node as Control).focus_mode = mode
		if node is BaseButton:
			var want_disabled := (mode == Control.FOCUS_NONE)
			if (node as BaseButton).disabled != want_disabled:
				(node as BaseButton).disabled = want_disabled
	for child in node.get_children():
		_set_children_focus_mode_recursive(child, mode)

func _for_each_custom_button(root: Node, callback: Callable) -> void:
	for child in root.get_children():
		if child is CustomButton or child is CustomTextureButton:
			_log("  Found CustomButton: " + child.name + " (text: " + child.text + ")")
			callback.call(child)
		if child.get_child_count() > 0:
			_for_each_custom_button(child, callback)

func _disable_all_custom_buttons(root: Node) -> void:
	_for_each_custom_button(root, func(btn):
		btn.make_unselectable()
	)

func _enable_all_custom_buttons(root: Node) -> void:
	_for_each_custom_button(root, func(btn):
		btn.make_selectable()
	)

# Window positioning strategies
func apply_position_strategy(strategy: Dictionary, parent_size: Vector2, context: Dictionary = {}):
	var menu = MenuManager.get_menu(menu_name)
	if not menu:
		return
	var strategy_type = strategy.get("type", "center")
	match strategy_type:
		"center":
			var offset = context.get("offset", strategy.get("offset", Vector2.ZERO))
			await position_center(menu, parent_size, offset)
		"top_center":
			var y_offset = strategy.get("y_offset", 56.0)
			await position_top_center(menu, parent_size, y_offset)
		"full_width_top":
			var y_offset = strategy.get("y_offset", 20.0)
			await position_full_width_top(menu, parent_size, y_offset)
		"dropdown_party":
			if context.has("party_sprites") and context.has("party_index"):
				await position_dropdown_party(menu, context.party_sprites, int(context.party_index))
			else:
				_log("ERROR: dropdown_party needs {party_sprites, party_index}")
		"bottom_overlay":
			var width_percent = strategy.get("width_percent", 0.9)
			var y_offset = strategy.get("y_offset", -20)
			await position_bottom_overlay(menu, parent_size, width_percent, y_offset)
		"bottom_right_corner":
			var margin_right = strategy.get("margin_right", 20)
			var margin_bottom = strategy.get("margin_bottom", 20)
			await position_bottom_right_corner(menu, parent_size, margin_right, margin_bottom)
		"bottom_center":
			var y_offset = strategy.get("y_offset", -20)
			await position_bottom_center(menu, parent_size, y_offset)
		"multi_dialogue":
			await position_multi_dialogue(menu, parent_size, context)
		_:
			await position_center(menu, parent_size, Vector2.ZERO)

func position_center(menu_control: Control, parent_size: Vector2, offset: Vector2 = Vector2.ZERO):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	var parent_center = parent_size / 2
	var target_position = parent_center - (window.size / 2) + offset
	window.position = target_position

func position_top_center(menu_control: Control, parent_size: Vector2, y_offset: float = 56.0):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	var x_pos = max(0.0, (parent_size.x - window.size.x) / 2.0)
	window.position = Vector2(x_pos, y_offset)

func position_full_width_top(menu_control: Control, parent_size: Vector2, y_offset: float = 20.0):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	window.custom_minimum_size.x = parent_size.x
	window.size.x = parent_size.x
	window.position = Vector2(0, y_offset)

func position_dropdown_party(menu_control: Control, party_sprites: Array, party_index: int):
	await get_tree().process_frame
	var nine_patch = null
	for child in menu_control.get_children():
		if child is NinePatchRect:
			nine_patch = child
			break
	if nine_patch and party_index < party_sprites.size():
		var sprite = party_sprites[party_index]
		# Position below the sprite - sprite global_position already accounts for all transforms
		var target_x = sprite.global_position.x
		var target_y = sprite.global_position.y + 64 + 10  # sprite height + small gap
		# Center the dropdown horizontally on the sprite
		nine_patch.position = Vector2(target_x - nine_patch.size.x / 2, target_y)

func position_bottom_overlay(menu_control: Control, parent_size: Vector2, width_percent: float = 0.9, y_offset: float = -20):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	# Set width to percentage of parent
	var target_width = parent_size.x * width_percent
	window.custom_minimum_size.x = target_width
	window.size.x = target_width
	# Position at bottom center with offset
	var x_pos = (parent_size.x - target_width) / 2.0
	var y_pos = parent_size.y - window.size.y + y_offset
	window.position = Vector2(x_pos, y_pos)

func position_bottom_center(menu_control: Control, parent_size: Vector2, y_offset: float = -20):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	# Position at bottom center with offset, respecting custom size
	var x_pos = (parent_size.x - window.size.x) / 2.0
	var y_pos = parent_size.y - window.size.y + y_offset
	window.position = Vector2(x_pos, y_pos)

func position_bottom_right_corner(menu_control: Control, parent_size: Vector2, margin_right: float = 20, margin_bottom: float = 20):
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		print("[POSITION] ", menu_name, " - NO WINDOW FOUND")
		return
	print("[POSITION] ", menu_name, " - window found: ", window.name, " type: ", window.get_class())
	# Position in bottom right corner with margins
	var x_pos = parent_size.x - window.size.x - margin_right
	var y_pos = parent_size.y - window.size.y - margin_bottom
	print("[POSITION] ", menu_name, " - parent_size=", parent_size, " window.size=", window.size, " margin_bottom=", margin_bottom, " calculated y_pos=", y_pos)
	print("[POSITION] ", menu_name, " - BEFORE position=", window.position)
	window.position = Vector2(x_pos, y_pos)
	print("[POSITION] ", menu_name, " - AFTER position=", window.position)

func _find_inner_window(menu_control: Control) -> Control:
	for child in menu_control.get_children():
		if child is NinePatchRect or child is Control:
			return child
	return null

func position_multi_dialogue(menu_control: Control, parent_size: Vector2, context: Dictionary = {}):
	"""Position multi-dialogue window near the speaker's NPC or in a slot"""
	await get_tree().process_frame
	await get_tree().process_frame
	var window = _find_inner_window(menu_control)
	if not window:
		return
	
	# Define slot positions (margins from edges)
	var margin = 20.0
	var slots = [
		Vector2(margin, margin),  # Top-left
		Vector2(parent_size.x - window.size.x - margin, margin),  # Top-right
		Vector2(margin, parent_size.y - window.size.y - margin - 120),  # Bottom-left (above normal dialogue)
		Vector2(parent_size.x - window.size.x - margin, parent_size.y - window.size.y - margin - 120)  # Bottom-right
	]
	
	# Get slot index from metadata if set
	var slot_index = get_meta("slot_index", -1)
	
	# Try to position near NPC if we have entity reference
	var speaker_entity = get_meta("speaker_entity", null)
	if speaker_entity and is_instance_valid(speaker_entity):
		var screen_pos = _get_entity_screen_position(speaker_entity)
		if screen_pos.x >= 0 and screen_pos.y >= 0:
			# Position window near the NPC, trying to not cover them
			var target_pos = _calculate_window_position_near_entity(screen_pos, window.size, parent_size)
			window.position = target_pos
			return
	
	# Fallback to slot-based positioning
	if slot_index >= 0 and slot_index < slots.size():
		window.position = slots[slot_index]
	else:
		# Default to top-left if no slot assigned
		window.position = slots[0]

func _get_entity_screen_position(entity: Node) -> Vector2:
	"""Get the screen position of an entity"""
	# Get the camera
	var camera = null
	if GameManager and GameManager.main_camera:
		camera = GameManager.main_camera
	else:
		camera = get_viewport().get_camera_3d()
	
	if not camera:
		return Vector2(-1, -1)
	
	# Get entity position (use sprite position if available for visual accuracy)
	var world_pos = entity.global_position
	if "sprite" in entity and entity.sprite:
		world_pos = entity.sprite.global_position
	
	# Convert to screen coordinates
	var screen_pos = camera.unproject_position(world_pos)
	
	# Check if position is in front of camera
	var camera_forward = -camera.global_transform.basis.z
	var to_entity = (world_pos - camera.global_position).normalized()
	if camera_forward.dot(to_entity) < 0:
		return Vector2(-1, -1)  # Behind camera
	
	return screen_pos

func _calculate_window_position_near_entity(entity_screen_pos: Vector2, window_size: Vector2, parent_size: Vector2) -> Vector2:
	"""Calculate best position for window near an entity without covering it"""
	var margin = 20.0
	var entity_clearance = 80.0  # Approximate sprite size to avoid
	
	# Try positioning to the right of the entity first
	var right_pos = Vector2(entity_screen_pos.x + entity_clearance, entity_screen_pos.y - window_size.y / 2)
	if right_pos.x + window_size.x < parent_size.x - margin:
		return _clamp_to_screen(right_pos, window_size, parent_size, margin)
	
	# Try positioning to the left
	var left_pos = Vector2(entity_screen_pos.x - entity_clearance - window_size.x, entity_screen_pos.y - window_size.y / 2)
	if left_pos.x > margin:
		return _clamp_to_screen(left_pos, window_size, parent_size, margin)
	
	# Try positioning above
	var above_pos = Vector2(entity_screen_pos.x - window_size.x / 2, entity_screen_pos.y - entity_clearance - window_size.y)
	if above_pos.y > margin:
		return _clamp_to_screen(above_pos, window_size, parent_size, margin)
	
	# Fallback: position below (but above normal dialogue area)
	var below_pos = Vector2(entity_screen_pos.x - window_size.x / 2, entity_screen_pos.y + entity_clearance)
	return _clamp_to_screen(below_pos, window_size, parent_size, margin)

func _clamp_to_screen(pos: Vector2, window_size: Vector2, parent_size: Vector2, margin: float) -> Vector2:
	"""Clamp window position to stay within screen bounds"""
	var clamped = pos
	clamped.x = clamp(clamped.x, margin, parent_size.x - window_size.x - margin)
	clamped.y = clamp(clamped.y, margin, parent_size.y - window_size.y - margin - 120)  # Leave room for normal dialogue
	return clamped

func show_menu_visual():
	"""Make menu container visible with a quick open animation"""
	var menu = MenuManager.get_menu(menu_name)
	if not menu:
		return
	if not menu.visible:
		menu.visible = true
	# Animate inner window (NinePatchRect) if present, else the menu container
	var target: Control = _find_inner_window(menu)
	if target == null:
		target = menu
	# Center pivot before scaling so it zooms from middle
	target.pivot_offset = target.size / 2.0
	# Start slightly scaled down, then ease to 1.0
	target.scale = Vector2(0.95, 0.95)
	var tween = create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(target, "scale", Vector2(1, 1), 0.12)

func hide_menu_visual():
	"""Hide menu container with a quick close animation"""
	var menu = MenuManager.get_menu(menu_name)
	if not menu:
		return
	var target: Control = _find_inner_window(menu)
	if target == null:
		target = menu
	# Center pivot before scaling so it shrinks toward middle
	target.pivot_offset = target.size / 2.0
	# Ease down then hide
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(target, "scale", Vector2(0.97, 0.97), 0.08)
	await tween.finished
	menu.visible = false
	# Reset for next open
	target.scale = Vector2(1, 1)
