extends Node

## EventManager - Extensible event system for dialogue and text processing
## Core plugin provides universal events, users can register custom events

#region Configuration
## Folder to auto-load custom event scripts from
@export_dir var custom_events_folder: String = "res://events"

## Whether to auto-load custom event scripts on ready
@export var auto_load_custom_events: bool = true
#endregion

#region Custom Event Registration
# Dictionary of custom event handlers: event_name -> Callable
var custom_events: Dictionary = {}

func register_event(event_name: String, handler: Callable) -> void:
	"""Register a custom event handler
	
	Example:
		EventManager.register_event("leadName", func(args): 
			return GameManager.party[0].get_character_name()
		)
	"""
	custom_events[event_name] = handler
	# print("[EventManager] Registered custom event: ", event_name)

func unregister_event(event_name: String) -> void:
	"""Remove a custom event handler"""
	if custom_events.has(event_name):
		custom_events.erase(event_name)
		# print("[EventManager] Unregistered custom event: ", event_name)
#endregion

#region Initialization
func _ready():
	# Auto-load custom event scripts if enabled
	if auto_load_custom_events:
		_load_custom_event_scripts()
	
	# print("[EventManager] Initialized with ", custom_events.size(), " custom events")

func _load_custom_event_scripts():
	"""Auto-load event handler scripts from custom_events_folder"""
	for fname in DataParser.get_files_in_dir(custom_events_folder):
		# Support both source (.gd) and compiled (.gdc / .gde) scripts in exports
		if fname.ends_with(".gd") or fname.ends_with(".gdc") or fname.ends_with(".gde"):
			var script_path = custom_events_folder.path_join(fname)
			var script = load(script_path)
			if script:
				var instance = script.new()
				if instance.has_method("register_events"):
					# Add as child node to keep it alive
					add_child(instance)
					instance.register_events(self)
					# print("[EventManager] Loaded custom events from: ", fname)
#endregion

#region Event Processing
func process_events(split_text: String):
	"""Process an event command and return the result
	
	Format: command_name|arg1|arg2|...
	Example: item|health_potion returns "Health Potion"
	
	Note: This function handles both sync and async event handlers.
	Async handlers (using await) will be awaited automatically.
	"""
	var split_command = split_text.split("|")
	var command_name = split_command[0]
	
	# Try custom events first
	if custom_events.has(command_name):
		var handler = custom_events[command_name]
		var result = await handler.call(split_command)
		if result is Array and result.size() > 1:
			# Handler returned [value, should_exit]
			return result[0]
		return result
	
	# Try built-in methods
	if has_method(command_name):
		var result = await call(command_name, split_command)
		if result is Array and result.size() > 1:
			return result[0]
		return result
	
	push_warning("[EventManager] Unknown event: ", command_name)
	return ""
#endregion

#region Built-in Universal Events
# These are events that work in any project context

func textSpeed(split_command: Array) -> String:
	"""Change text display speed
	Usage: textSpeed|1.5
	"""
	# This assumes a DialogueManager exists with speed_mult
	# If it doesn't exist, the event is simply ignored
	if has_node("/root/DialogueManager"):
		var dm = get_node("/root/DialogueManager")
		if "speed_mult" in dm:
			dm.speed_mult = float(split_command[1]) if split_command.size() > 1 else 1.0
	return ""

func Speaker(split_command: Array) -> String:
	"""Set or clear the current speaker
	Usage: Speaker|character_name or Speaker| to clear
	
	Returns formatted speaker tag for insertion into dialogue text.
	"""
	if split_command.size() < 2 or split_command[1].is_empty():
		# Clear speaker
		if has_node("/root/DialogueManager"):
			var dm = get_node("/root/DialogueManager")
			if "current_speaker" in dm:
				dm.current_speaker = ""
		return ""
	
	var speaker_name = split_command[1]
	
	# Store in DialogueManager if it exists
	if has_node("/root/DialogueManager"):
		var dm = get_node("/root/DialogueManager")
		if "current_speaker" in dm:
			dm.current_speaker = speaker_name
	
	# Return formatted speaker tag
	return "[bgcolor=white][color=black] " + speaker_name + " [/color][/bgcolor] "
#endregion
