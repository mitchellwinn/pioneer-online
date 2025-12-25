extends Node

## DataParser - Static utility functions for loading and saving JSON/XML data
## Provides functions for converting between files and dictionaries

#region Directory Helpers

## Get all files in a directory. Works with res:// paths in exported builds.
## Returns empty array if directory doesn't exist.
static func get_files_in_dir(dir_path: String) -> Array[String]:
	var files: Array[String] = []
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return files
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return files

## Get all subdirectories in a directory. Works with res:// paths in exported builds.
## Returns empty array if directory doesn't exist.
static func get_dirs_in_dir(dir_path: String) -> Array[String]:
	var dirs: Array[String] = []
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return dirs
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			dirs.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return dirs

## Check if a directory exists. Works with res:// paths in exported builds.
static func dir_exists(dir_path: String) -> bool:
	return DirAccess.open(dir_path) != null

#endregion

#region JSON Functions

## Load a JSON file and return it as a Dictionary
## Returns an empty Dictionary if the file doesn't exist or fails to parse
static func json_to_dict(file_path: String) -> Dictionary:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_warning("[DataParser] JSON file not found: ", file_path)
		return {}
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result == OK:
		if json.data is Dictionary:
			return json.data
		else:
			push_warning("[DataParser] JSON root is not a Dictionary in: ", file_path)
			return {"_data": json.data}  # Wrap non-dict data
	else:
		push_error("[DataParser] Failed to parse JSON: ", json.get_error_message(), " at line ", json.get_error_line())
		return {}

## Load JSON files from a directory (optionally recursive) and combine them into a single Dictionary
## Each file's data is stored under a key based on its filename (without extension)
## If recursive is true, subdirectory names become nested dictionary keys
## file_pattern allows filtering (e.g., "*.json" or "*config*.json")
static func json_dir_to_dict(dir_path: String, recursive: bool = false, file_pattern: String = "*.json") -> Dictionary:
	if not dir_exists(dir_path):
		push_warning("[DataParser] Directory not found or inaccessible: ", dir_path)
		return {}

	var all_files: Array[Dictionary] = []
	collect_json_files(dir_path, "", recursive, file_pattern, all_files)
	
	if all_files.is_empty():
		return {}
	
	var results: Dictionary = {}
	var mutex := Mutex.new()
	
	var task_func = func(i: int):
		var item = all_files[i]
		var file_data = json_to_dict(item.path)
		if not file_data.is_empty():
			mutex.lock()
			results[item.key] = file_data
			mutex.unlock()
			
	var group_id = WorkerThreadPool.add_group_task(task_func, all_files.size())
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	
	return results

static func collect_json_files(current_dir: String, key_prefix: String, recursive: bool, pattern: String, result_list: Array) -> void:
	for file_name in get_files_in_dir(current_dir):
		if file_name.ends_with(".json") and _matches_pattern(file_name, pattern):
			var file_key = key_prefix + file_name.get_basename()
			result_list.append({
				"path": current_dir.path_join(file_name),
				"key": file_key
			})
	
	if recursive:
		for subdir_name in get_dirs_in_dir(current_dir):
			var new_prefix = key_prefix + subdir_name + "/"
			var new_path = current_dir.path_join(subdir_name)
			collect_json_files(new_path, new_prefix, true, pattern, result_list)

## Simple pattern matching helper (supports * wildcard)
static func _matches_pattern(filename: String, pattern: String) -> bool:
	if pattern == "*" or pattern == "*.*" or pattern == "*.json":
		return true
	
	# Simple wildcard matching
	if pattern.contains("*"):
		var parts = pattern.split("*")
		var pos = 0
		for i in range(parts.size()):
			var part = parts[i]
			if part.is_empty():
				continue
			var found_pos = filename.find(part, pos)
			if found_pos == -1:
				return false
			if i == 0 and found_pos != 0:  # First part must be at start
				return false
			pos = found_pos + part.length()
		return true
	else:
		return filename == pattern

## Save a Dictionary to a JSON file
## pretty_print: if true, formats JSON with indentation for readability
## Returns true on success, false on failure
static func dict_to_json(data: Dictionary, file_path: String, pretty_print: bool = true) -> bool:
	var json_string: String
	
	if pretty_print:
		json_string = JSON.stringify(data, "\t")
	else:
		json_string = JSON.stringify(data)
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		push_error("[DataParser] Failed to create JSON file: ", file_path)
		return false
	
	file.store_string(json_string)
	file.close()
	
	return true

#endregion

#region XML Functions (Dialogue Manager Format)

## Convert XML dialogue data to Dictionary format
## Uses DialogueManager-specific XML format with starters, lines, choices, and conditional_next
## Returns {"starters": {...}, "lines": {...}}
static func dialogue_xml_to_dict(file_path: String) -> Dictionary:
	var parser = XMLParser.new()
	var err = parser.open(file_path)
	
	if err != OK:
		push_error("[DataParser] Failed to open XML file: ", file_path)
		return {}
	
	var starters: Dictionary = {}
	var lines: Dictionary = {}
	
	var current_starter: String
	var current_line: String
	var current_condition: String
	var is_reading_starter: bool = false
	var is_reading: bool = false
	
	while parser.read() != ERR_FILE_EOF:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			# Read each line of dialogue and associated data
			if parser.get_node_name() == "starter":
				is_reading_starter = true
				current_starter = parser.get_named_attribute_value_safe("id")
				starters[current_starter] = {"all_true": parser.get_named_attribute_value_safe("all_true")}
				starters[current_starter]["conditions"] = {}
			elif parser.get_node_name() == "line":
				current_line = parser.get_named_attribute_value_safe("id")
				lines[current_line] = {"next": parser.get_named_attribute_value_safe("next")}
				is_reading = true
				lines[current_line]["choices"] = []  # Array for indexed choices
				lines[current_line]["cond_next"] = {}
			else:
				is_reading = false
			
			if parser.get_node_name() == "choice":
				var choice_data = {
					"text": parser.get_named_attribute_value_safe("text"),
					"next": parser.get_named_attribute_value_safe("next")
				}
				lines[current_line]["choices"].append(choice_data)
			elif parser.get_node_name() == "conditional_next":
				current_condition = parser.get_named_attribute_value_safe("id")
				lines[current_line]["cond_next"][current_condition] = {"all_true": parser.get_named_attribute_value_safe("all_true")}
				lines[current_line]["cond_next"][current_condition]["conditions"] = {}
			elif parser.get_node_name() == "condition":
				if is_reading_starter:
					starters[current_starter]["conditions"][parser.get_named_attribute_value_safe("key")] = {
						"value": parser.get_named_attribute_value_safe("value"),
						"operator": parser.get_named_attribute_value_safe("operator")
					}
				elif current_condition != "":
					lines[current_line]["cond_next"][current_condition]["conditions"][parser.get_named_attribute_value_safe("key")] = {
						"value": parser.get_named_attribute_value_safe("value"),
						"operator": parser.get_named_attribute_value_safe("operator")
					}
		
		if parser.get_node_type() == XMLParser.NODE_TEXT and is_reading:
			lines[current_line]["text"] = parser.get_node_data().strip_edges()
			is_reading = false
		
		if parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "starter":
				is_reading_starter = false
	
	return {"starters": starters, "lines": lines}

## Override dialogue text in an existing dialogue dictionary with translations from XML
## Preserves events (text between *) from the original and merges them with translated text
## dict_name: the key in dialogues dictionary to override
## file_path: path to the translation XML file
## dialogues_dict: the dialogues dictionary to modify (pass by reference)
static func override_dialogue_xml(dict_name: String, file_path: String, dialogues_dict: Dictionary) -> void:
	if not dialogues_dict.has(dict_name):
		push_warning("[DataParser] Dialogue '" + dict_name + "' not found in dialogues dictionary")
		return
	
	var parser = XMLParser.new()
	var err = parser.open(file_path)
	
	if err != OK:
		push_error("[DataParser] Failed to open override XML file: ", file_path)
		return
	
	var current_line: String = ""
	
	
	while parser.read() != ERR_FILE_EOF:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			if parser.get_node_name() == "line":
				current_line = parser.get_named_attribute_value_safe("id")
			elif parser.get_node_name() == "choice":
				var choice_index = int(parser.get_named_attribute_value_safe("index"))
				var override_text = parser.get_named_attribute_value_safe("text")
				
				# Override the choice text at the specified index
				if choice_index >= 0 and choice_index < dialogues_dict[dict_name]["lines"][current_line]["choices"].size():
					dialogues_dict[dict_name]["lines"][current_line]["choices"][choice_index]["text"] = override_text
		
		if parser.get_node_type() == XMLParser.NODE_TEXT:
			if current_line != "" and dialogues_dict.has(dict_name) and dialogues_dict[dict_name].has("lines") and dialogues_dict[dict_name]["lines"].has(current_line):
				if dialogues_dict[dict_name]["lines"][current_line].has("text"):
					var old_text = dialogues_dict[dict_name]["lines"][current_line]["text"]
					var new_text_raw = parser.get_node_data().strip_edges()
					
					# Parse English: track event positions and extract text
					var english_parts = old_text.split("*")
					var english_events_with_pos: Array = []  # [{event: "...", pos: "before"|"mid"|"after"}]
					var english_text = ""
					var found_text = false
					
					for i in range(english_parts.size()):
						if i % 2 == 0:
							# Text segment - strip whitespace
							var text_part = english_parts[i].strip_edges()
							if text_part != "":
								english_text += text_part
								found_text = true
						else:
							# Event segment
							var pos = "after"  # Default
							if not found_text:
								pos = "before"
							elif i < english_parts.size() - 1:  # Not the last segment
								# Check if there's more text after this event
								var has_text_after = false
								for j in range(i + 1, english_parts.size(), 2):
									if english_parts[j].strip_edges() != "":
										has_text_after = true
										break
								if has_text_after:
									pos = "mid"
							english_events_with_pos.append({"event": english_parts[i], "pos": pos})
					
					# Parse translation: extract events and text
					var translation_parts = new_text_raw.split("*")
					var translation_events: Array = []
					var translation_text = ""
					
					for i in range(translation_parts.size()):
						if i % 2 == 0:
							# Text segment - strip whitespace
							var text_part = translation_parts[i].strip_edges()
							if text_part != "":
								translation_text += text_part
						else:
							# Event segment
							translation_events.append(translation_parts[i])
					
					# Find missing events from English
					var missing_before: Array = []
					var missing_mid: Array = []
					var missing_after: Array = []
					
					for item in english_events_with_pos:
						if not translation_events.has(item["event"]):
							# Event is missing from translation
							if item["pos"] == "before":
								missing_before.append(item["event"])
							elif item["pos"] == "mid":
								missing_mid.append(item["event"])
							else:  # "after"
								missing_after.append(item["event"])
					
					# Reconstruct: if translation already has the text with its events, use it as-is
					# Otherwise build from scratch
					var final_text = ""
					
					if translation_text.strip_edges() == "" and translation_events.size() == 0:
						# Translation is completely empty, use English structure
						final_text = old_text
					else:
						# Use translation text/events and append missing events
						# Add missing "before" events
						for event in missing_before:
							final_text += "*" + event + "*"
						
						# Rebuild translation content WITHOUT whitespace between events
						for i in range(translation_parts.size()):
							if i % 2 == 0:
								# Text segment
								var text_part = translation_parts[i].strip_edges()
								if text_part != "":
									final_text += text_part
							else:
								# Event segment
								final_text += "*" + translation_parts[i] + "*"
						
						# Add missing "mid" events before "after" events
						for event in missing_mid:
							final_text += "*" + event + "*"
						
						# Add missing "after" events
						for event in missing_after:
							final_text += "*" + event + "*"
					
					dialogues_dict[dict_name]["lines"][current_line]["text"] = final_text

## Load all dialogue XML files from a directory and return as Dictionary
## Each XML file becomes a key in the returned dictionary (filename without extension)
## If a language other than "english" is specified, it will load English first then override with translations
static func dialogue_xml_dir_to_dict(dir_path: String, language: String = "english") -> Dictionary:
	var dialogues: Dictionary = {}
	var mutex := Mutex.new()
	
	# Load English XMLs first
	var english_dir = dir_path + "/english"
	var xml_files: Array[String] = []
	for fname in get_files_in_dir(english_dir):
		if fname.ends_with(".xml"):
			xml_files.append(fname)
	
	if xml_files.is_empty():
		push_warning("[DataParser] English dialogue directory not found or empty: ", english_dir)
		return {}
			
	var task_func = func(i: int):
		var xml_file = xml_files[i]
		var dialogue_name = xml_file.trim_suffix(".xml")
		var full_path = english_dir.path_join(xml_file)
		var data = dialogue_xml_to_dict(full_path)
		
		mutex.lock()
		dialogues[dialogue_name] = data
		mutex.unlock()
	
	var group_id = WorkerThreadPool.add_group_task(task_func, xml_files.size())
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	
	# If not English, load translation overrides
	if language != "english":
		var translation_dir = dir_path + "/" + language
		for trans_file in get_files_in_dir(translation_dir):
			if trans_file.ends_with(".xml"):
				var dialogue_name = trans_file.trim_suffix(".xml")
				var full_path = translation_dir.path_join(trans_file)
				override_dialogue_xml(dialogue_name, full_path, dialogues)
	
	return dialogues

## Convert a Dictionary to XML dialogue format and save to file
## Converts nested dictionaries into XML elements with attributes and text content
static func dialogue_dict_to_xml(data: Dictionary, file_path: String, root_name: String = "dialogue") -> bool:
	var xml_string = '<?xml version="1.0" encoding="UTF-8"?>\n'
	xml_string += _dict_to_xml_recursive(data, root_name, 0)
	
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		push_error("[DataParser] Failed to create XML file: ", file_path)
		return false
	
	file.store_string(xml_string)
	file.close()
	
	return true

## Internal recursive helper for converting dict to XML
static func _dict_to_xml_recursive(data, element_name: String, indent_level: int) -> String:
	var indent = "\t".repeat(indent_level)
	var result = ""
	
	if data is Array:
		# Handle array of elements with the same name
		for item in data:
			if item is Dictionary:
				result += _dict_to_xml_recursive(item, element_name, indent_level)
			else:
				result += indent + "<" + element_name + ">" + str(item) + "</" + element_name + ">\n"
		return result
	
	# Start element
	result += indent + "<" + element_name
	
	# Add attributes if present
	var text_content = ""
	var child_elements = ""
	
	for key in data.keys():
		if key == "_attributes":
			# Handle attributes
			var attrs = data[key]
			for attr_key in attrs.keys():
				result += " " + attr_key + '="' + str(attrs[attr_key]) + '"'
		elif key == "_text":
			# Store text content for later
			text_content = str(data[key])
		else:
			# Handle child elements
			var value = data[key]
			if value is Dictionary or value is Array:
				child_elements += _dict_to_xml_recursive(value, key, indent_level + 1)
			else:
				child_elements += indent + "\t<" + key + ">" + str(value) + "</" + key + ">\n"
	
	# Close opening tag
	if text_content.is_empty() and child_elements.is_empty():
		# Self-closing tag
		result += " />\n"
	else:
		result += ">"
		
		if not text_content.is_empty() and child_elements.is_empty():
			# Text content only, keep on same line
			result += text_content + "</" + element_name + ">\n"
		else:
			# Has children or both text and children
			result += "\n"
			if not text_content.is_empty():
				result += indent + "\t" + text_content + "\n"
			result += child_elements
			result += indent + "</" + element_name + ">\n"
	
	return result

#endregion

#region Utility Functions

## Generic file loader that automatically detects JSON or XML based on extension
## Returns Dictionary for both formats
static func load_file_to_dict(file_path: String) -> Dictionary:
	var extension = file_path.get_extension().to_lower()
	
	match extension:
		"json":
			return json_to_dict(file_path)
		"xml":
			return dialogue_xml_to_dict(file_path)
		_:
			push_warning("[DataParser] Unsupported file extension: ", extension)
			return {}

## Generic file saver that automatically detects format based on extension
static func save_dict_to_file(data: Dictionary, file_path: String, pretty_print: bool = true) -> bool:
	var extension = file_path.get_extension().to_lower()
	
	match extension:
		"json":
			return dict_to_json(data, file_path, pretty_print)
		"xml":
			return dialogue_dict_to_xml(data, file_path)
		_:
			push_warning("[DataParser] Unsupported file extension: ", extension)
			return false

#endregion
