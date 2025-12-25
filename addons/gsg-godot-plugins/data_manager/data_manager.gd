extends Node

## DataManager - Configurable data management system
## Loads data configurations from scripts in data_configs folder
## Can be accessed as DataManager or aliased as DataManager for backwards compatibility

#region Configuration
## Folder to auto-load data configuration scripts from
@export_dir var data_configs_folder: String = "res://data_configs"

## Whether to auto-load data configuration scripts on ready
@export var auto_load_configs: bool = true

## Save system configuration
@export_dir var save_data_base_folder: String = "user://save_data"
@export var max_save_slots: int = 3

#endregion

#region Data Storage
# All data is stored in this dictionary
# Keys are defined by configuration scripts
var data: Dictionary = {}

# Snapshot of data at the time of last load/save for change detection
var base_data: Dictionary = {}

# Current save slot (1..max_save_slots)
var current_save_slot: int = 1

var initialized: bool = false
#endregion

#region Initialization
func _ready():
	# Always register conditional_flags category
	register_category("conditional_flags")
	
	# Auto-load data configuration scripts if enabled
	if auto_load_configs:
		_load_data_config_scripts()
	
	initialized = true
	print("[DataManager] Initialized with ", data.keys().size(), " data categories")

func _load_data_config_scripts():
	"""Auto-load data configuration scripts from data_configs_folder"""
	var files = DataParser.get_files_in_dir(data_configs_folder)
	if files.is_empty():
		push_warning("[DataManager] Data configs folder not found or empty: ", data_configs_folder)
		return
	
	for fname in files:
		# Support both source (.gd) and compiled (.gdc / .gde) scripts in exports
		if fname.ends_with(".gd") or fname.ends_with(".gdc") or fname.ends_with(".gde"):
			var script_path = data_configs_folder.path_join(fname)
			var script = load(script_path)
			if script:
				var instance = script.new()
				if instance.has_method("configure_data"):
					# Add as child node to keep it alive
					add_child(instance)
					instance.configure_data(self)
					print("[DataManager] Loaded data config from: ", fname)
				else:
					push_warning("[DataManager] Script missing configure_data() method: ", fname)
#endregion

#region Data Access
func get_data(category: String) -> Dictionary:
	"""Get a data category dictionary"""
	return data.get(category, {})

func set_data(category: String, value: Dictionary):
	"""Set a data category dictionary"""
	data[category] = value

func has_data(category: String) -> bool:
	"""Check if a data category exists"""
	return data.has(category)

func clear_data(category: String):
	"""Clear a data category"""
	if data.has(category):
		data[category].clear()

func get_value(category: String, key: String, default = null):
	"""Get a specific value from a data category"""
	if data.has(category) and data[category].has(key):
		return data[category][key]
	return default

func set_value(category: String, key: String, value):
	"""Set a specific value in a data category"""
	if not data.has(category):
		data[category] = {}
	data[category][key] = value
#endregion

#region Helper Methods for Config Scripts

# Batch loading queue
var _batch_loading_active: bool = false
var _load_queue: Array = [] # Array of Dictionary: {type: "file"|"folder", path: String, category: String, recursive: bool}

func begin_load_batch():
	"""Start a batch loading session. Calls to queue_load_json_* will be queued."""
	_batch_loading_active = true
	_load_queue.clear()
	print("[DataManager] Batch loading started")

func queue_load_json_file(file_path: String, category: String):
	"""Queue a file to be loaded in the batch"""
	if not _batch_loading_active:
		load_json_file(file_path, category)
		return
	
	_load_queue.append({
		"type": "file",
		"path": file_path,
		"category": category
	})

func queue_load_json_folder(folder_path: String, category: String, recursive: bool = true, use_filename_as_key: bool = false):
	"""Queue a folder to be loaded in the batch"""
	if not _batch_loading_active:
		# Fallback for non-batch mode (legacy) - assumes not using filename as key for now or we'd need to update load_json_folder too
		load_json_folder(folder_path, category, recursive)
		return
		
	_load_queue.append({
		"type": "folder",
		"path": folder_path,
		"category": category,
		"recursive": recursive,
		"use_filename_as_key": use_filename_as_key
	})

func process_load_batch():
	"""Execute all queued loading tasks in parallel"""
	if not _batch_loading_active:
		return
		
	if _load_queue.is_empty():
		_batch_loading_active = false
		return
		
	var start_time = Time.get_ticks_msec()
	print("[DataManager] Processing batch load of ", _load_queue.size(), " tasks...")
	
	# 1. Collect ALL files from ALL tasks
	var all_files_to_parse: Array[Dictionary] = [] # {path: String, task_index: int, key: String}
	
	for i in range(_load_queue.size()):
		var task = _load_queue[i]
		# Ensure category exists
		if not data.has(task.category):
			data[task.category] = {}
			
		if task.type == "file":
			all_files_to_parse.append({
				"path": task.path,
				"task_index": i,
				"key": "" # Root merge for files
			})
		elif task.type == "folder":
			var folder_files: Array[Dictionary] = [] # {path, key}
			DataParser.collect_json_files(task.path, "", task.recursive, "*.json", folder_files)
			for f in folder_files:
				all_files_to_parse.append({
					"path": f.path,
					"task_index": i,
					"key": f.key
				})
	
	if all_files_to_parse.is_empty():
		print("[DataManager] No files found in batch")
		_batch_loading_active = false
		return
		
	# 2. Parse EVERYTHING in parallel
	var parsed_data_list: Array = []
	parsed_data_list.resize(all_files_to_parse.size())
	
	var thread_func = func(idx: int):
		var item = all_files_to_parse[idx]
		var file_data = DataParser.json_to_dict(item.path)
		parsed_data_list[idx] = file_data
		
	var group_id = WorkerThreadPool.add_group_task(thread_func, all_files_to_parse.size())
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	
	# 3. Merge results back in order
	# We iterate through parsed files and merge them into their respective task's target
	# But we must respect the queue order (task 0, then task 1...)
	# So we bucket the results by task_index first
	var results_by_task: Array = [] # Array of Arrays of {data, key}
	results_by_task.resize(_load_queue.size())
	for i in range(results_by_task.size()):
		results_by_task[i] = []
		
	for i in range(all_files_to_parse.size()):
		var file_info = all_files_to_parse[i]
		var file_data = parsed_data_list[i]
		if not file_data.is_empty():
			results_by_task[file_info.task_index].append({
				"data": file_data,
				"key": file_info.key
			})
			
	# Now merge strictly in task order
	for i in range(_load_queue.size()):
		var task = _load_queue[i]
		var target_category = data[task.category]
		var files = results_by_task[i]
		
		for f in files:
			if task.type == "file":
				_merge_dictionaries(target_category, f.data)
			elif task.type == "folder":
				if task.use_filename_as_key:
					# For One-File-Per-Entry (e.g. Enemies), use filename as key
					if not target_category.has(f.key):
						target_category[f.key] = f.data
					else:
						_merge_dictionaries(target_category[f.key], f.data)
				else:
					# For Aggregated Files (e.g. Items), merge content directly
					_merge_dictionaries(target_category, f.data)
					
	var elapsed = Time.get_ticks_msec() - start_time
	print("[DataManager] Batch load complete in ", elapsed, "ms")
	_batch_loading_active = false
	_load_queue.clear()

func register_category(category_name: String):
	"""Register a new data category (creates empty dictionary)"""
	if not data.has(category_name):
		data[category_name] = {}
		print("[DataManager] Registered category: ", category_name)

func load_json_file(file_path: String, category: String, merge: bool = true):
	"""Load a JSON file into a category"""
	if not data.has(category):
		data[category] = {}
	
	var json_data = DataParser.json_to_dict(file_path)
	
	if json_data.is_empty():
		return
	
	if merge:
		# Merge with existing data
		_merge_dictionaries(data[category], json_data)
	else:
		# Replace existing data
		data[category] = json_data
	
	print("[DataManager] Loaded JSON: ", file_path, " → ", category)

func load_json_folder(folder_path: String, category: String, recursive: bool = true):
	"""Load all JSON files from a folder into a category using parallel processing"""
	if not data.has(category):
		data[category] = {}
	
	var all_files: Array[Dictionary] = []
	DataParser.collect_json_files(folder_path, "", recursive, "*.json", all_files)
	
	if all_files.is_empty():
		return
		
	var parsed_results: Array = []
	parsed_results.resize(all_files.size())
	
	var task_func = func(i: int):
		var item = all_files[i]
		var file_data = DataParser.json_to_dict(item.path)
		parsed_results[i] = file_data # Store directly, empty dict if failed
		
	var group_id = WorkerThreadPool.add_group_task(task_func, all_files.size())
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	
	# Merge sequentially
	for res in parsed_results:
		if not res.is_empty():
			_merge_dictionaries(data[category], res)
	
	print("[DataManager] Loaded JSON folder: ", folder_path, " -> ", category)

func _load_json_folder_recursive(folder_path: String, category: String, recursive: bool):
	"""Deprecated internal helper, kept for API compatibility if called directly"""
	load_json_folder(folder_path, category, recursive)

func _merge_dictionaries(target: Dictionary, source: Dictionary):
	"""Recursively merge source into target"""
	for key in source.keys():
		if target.has(key) and target[key] is Dictionary and source[key] is Dictionary:
			_merge_dictionaries(target[key], source[key])
		else:
			target[key] = source[key]

func _is_folder_structure(data: Dictionary) -> bool:
	"""Return true if all values are dictionaries (folder-style structure)."""
	if data.is_empty():
		return false
	for value in data.values():
		if typeof(value) != TYPE_DICTIONARY:
			return false
	return true
#endregion

#region Flag Management
## Conditional flags for game state, dialogue conditions, etc.
## Flags are stored in data["conditional_flags"]

## Signal emitted when a flag is changed
signal conditional_flag_changed(flag_key: String)

func get_flag(key: String) -> String:
	"""Get a flag value as a string. Returns 'MISSING-FLAG!' if not found."""
	if not data.has("conditional_flags"):
		return "MISSING-FLAG!"
	if data["conditional_flags"].has(key):
		return str(data["conditional_flags"][key])
	else:
		return "MISSING-FLAG!"

func set_flag(key: String, value: String, datatype: String = "string"):
	"""Set a flag with automatic type conversion."""
	if not data.has("conditional_flags"):
		data["conditional_flags"] = {}
	
	match datatype:
		"string":
			data["conditional_flags"][key] = value
		"int":
			data["conditional_flags"][key] = int(value)
		"float":
			data["conditional_flags"][key] = float(value)
		"bool":
			data["conditional_flags"][key] = value == "true"
	print("[DataManager] Set flag " + key + " of type " + datatype + " to " + value)
	conditional_flag_changed.emit(key)

func increment_flag(key: String, change: float):
	"""Increment a numeric flag by the given amount. Creates the flag if it doesn't exist."""
	if not data.has("conditional_flags"):
		data["conditional_flags"] = {}
	
	if not data["conditional_flags"].has(key):
		data["conditional_flags"][key] = change
		print("[DataManager] Set flag " + key + " to " + str(change))
		return
	
	if typeof(data["conditional_flags"][key]) == TYPE_INT:
		data["conditional_flags"][key] += int(change)
	elif typeof(data["conditional_flags"][key]) == TYPE_FLOAT:
		data["conditional_flags"][key] += change
	print("[DataManager] Increment flag " + key + " by " + str(change))
	conditional_flag_changed.emit(key)

func has_flag(key: String) -> bool:
	"""Check if a flag exists."""
	if not data.has("conditional_flags"):
		return false
	return data["conditional_flags"].has(key)

func evaluate_flag_condition(condition: String) -> bool:
	"""Evaluate a flag condition string.
	Examples:
		'flag_name' - true if flag exists and is truthy
		'count>5' - true if count flag > 5
		'level>=10' - true if level flag >= 10
		'name==john' - true if name flag equals 'john'
	Supported operators: ==, !=, <, <=, >, >=
	"""
	if condition.is_empty():
		return false
	
	# Trim whitespace
	condition = condition.strip_edges()
	
	# Check for operators (in order of longest first to avoid conflicts)
	var operators = ["==", "!=", ">=", "<=", ">", "<"]
	for op in operators:
		var parts = condition.split(op, false, 1)
		if parts.size() == 2:
			var flag_key = parts[0].strip_edges()
			var compare_value = parts[1].strip_edges()
			
			# Get flag value
			if not has_flag(flag_key):
				return false
			
			var flag_value = data["conditional_flags"][flag_key]
			
			# Try to parse as number if possible
			var flag_num = null
			var compare_num = null
			if typeof(flag_value) == TYPE_INT or typeof(flag_value) == TYPE_FLOAT:
				flag_num = float(flag_value)
			if compare_value.is_valid_float() or compare_value.is_valid_int():
				compare_num = float(compare_value)
			
			# Perform comparison
			match op:
				"==":
					if flag_num != null and compare_num != null:
						return is_equal_approx(flag_num, compare_num)
					else:
						return str(flag_value) == compare_value
				"!=":
					if flag_num != null and compare_num != null:
						return not is_equal_approx(flag_num, compare_num)
					else:
						return str(flag_value) != compare_value
				">":
					if flag_num != null and compare_num != null:
						return flag_num > compare_num
					return false
				">=":
					if flag_num != null and compare_num != null:
						return flag_num >= compare_num
					return false
				"<":
					if flag_num != null and compare_num != null:
						return flag_num < compare_num
					return false
				"<=":
					if flag_num != null and compare_num != null:
						return flag_num <= compare_num
					return false
			
			return false
	
	# No operator found - check if flag exists and is truthy
	if not has_flag(condition):
		return false
	
	var flag_value = data["conditional_flags"][condition]
	
	# Check truthiness
	if typeof(flag_value) == TYPE_BOOL:
		return flag_value
	elif typeof(flag_value) == TYPE_INT or typeof(flag_value) == TYPE_FLOAT:
		return flag_value != 0
	elif typeof(flag_value) == TYPE_STRING:
		return flag_value != "" and flag_value != "false" and flag_value != "0"
	else:
		return flag_value != null
#endregion

#region Save System - Automatic JSON-based persistence

## Deep copy the current data dictionary to use as a clean baseline for change detection.
func snapshot_base_data():
	base_data = _deep_copy(data)
	print("[DataManager] Snapshot base_data for change detection")

func set_save_slot(slot: int) -> bool:
	if slot < 1 or slot > max_save_slots:
		push_warning("[DataManager] Invalid save slot: %d (1-%d)" % [slot, max_save_slots])
		return false
	current_save_slot = slot
	print("[DataManager] Switched to save slot: ", slot)
	return true

func get_current_save_path() -> String:
	return save_data_base_folder.path_join("save_%d" % current_save_slot)

func ensure_save_directories_exist():
	# Ensure base save directory exists
	if not DirAccess.dir_exists_absolute(save_data_base_folder):
		DirAccess.make_dir_recursive_absolute(save_data_base_folder)
		print("[DataManager] Created save data base folder: ", save_data_base_folder)
	# Ensure each slot directory exists
	for slot in range(1, max_save_slots + 1):
		var slot_path = save_data_base_folder.path_join("save_%d" % slot)
		if not DirAccess.dir_exists_absolute(slot_path):
			DirAccess.make_dir_absolute(slot_path)
			print("[DataManager] Created slot directory: ", slot_path)

## Compare current data against base_data and save changed categories to JSON in the current slot.
func save_game() -> bool:
	ensure_save_directories_exist()
	
	var any_saved := false
	# Critical categories that should always be saved
	var critical_categories = ["party_members", "conditional_flags", "inventory", "general_data"]
	
	# First, ALWAYS save critical categories
	for category in critical_categories:
		if not data.has(category):
			data[category] = {}
		var current_value = data[category]
		if typeof(current_value) != TYPE_DICTIONARY:
			continue
		if not _save_category_to_slot(category, current_value):
			push_warning("[DataManager] Failed to save critical category: " + str(category))
		else:
			any_saved = true
	
	# Then, save other categories only if changed
	for category in data.keys():
		if critical_categories.has(category):
			continue  # Already saved above
		
		var current_value = data[category]
		if typeof(current_value) != TYPE_DICTIONARY:
			continue
		
		var baseline = base_data.get(category, {})
		if _deep_equal(current_value, baseline):
			continue
		if not _save_category_to_slot(category, current_value):
			push_warning("[DataManager] Failed to save category: " + str(category))
		else:
			any_saved = true
	
	if any_saved:
		snapshot_base_data()
		print("[DataManager] Game saved to slot ", current_save_slot)
	else:
		print("[DataManager] save_game(): No changes detected; nothing to save")
	return any_saved

## Reload all data from config scripts plus save-slot overrides for the current slot.
func load_game() -> bool:
	print("[DataManager] Loading game from slot ", current_save_slot)
	data.clear()
	_load_data_config_scripts()
	apply_save_slot_overrides()
	snapshot_base_data()
	# Reload menus since _load_data_config_scripts() cleared them
	if MenuManager:
		MenuManager.load_all_menus()
		MenuManager.register_default_menu_strategies()
	return true

## Reload only text/language data without resetting game state
func reload_text_data():
	for fname in DataParser.get_files_in_dir(data_configs_folder):
		if fname.ends_with(".gd") or fname.ends_with(".gdc") or fname.ends_with(".gde"):
			var script_path = data_configs_folder.path_join(fname)
			var script = load(script_path)
			if script:
				var instance = script.new()
				# We don't need to add child here as we just run a method
				if instance.has_method("reload_text_data"):
					instance.reload_text_data(self)
					print("[DataManager] Reloaded text data from: ", fname)
				instance.free()

func _save_category_to_slot(category: String, category_data: Dictionary) -> bool:
	var slot_path = get_current_save_path()
	var is_folder = _is_folder_structure(category_data)
	var ok := true
	if is_folder:
		var folder_path = slot_path.path_join(category)
		var dir = DirAccess.open(slot_path)
		if dir and not dir.dir_exists(category):
			dir.make_dir(category)
		# Clear old JSON files in folder so removed keys don't linger
		var existing_dir = DirAccess.open(folder_path)
		if existing_dir:
			existing_dir.list_dir_begin()
			var file_name = existing_dir.get_next()
			while file_name != "":
				if not existing_dir.current_is_dir() and file_name.ends_with(".json"):
					existing_dir.remove(file_name)
				file_name = existing_dir.get_next()
			existing_dir.list_dir_end()
		for sub_key in category_data.keys():
			var sub_data = category_data[sub_key]
			if typeof(sub_data) == TYPE_DICTIONARY:
				var file_path = folder_path.path_join(str(sub_key) + ".json")
				if not DataParser.dict_to_json(sub_data, file_path, true):
					ok = false
	else:
		var file_path = slot_path.path_join(category + ".json")
		ok = DataParser.dict_to_json(category_data, file_path, true)
	return ok

func apply_save_slot_overrides():
	var slot_path = get_current_save_path()
	if not DirAccess.dir_exists_absolute(slot_path):
		return
	var dir = DirAccess.open(slot_path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		var full_path = slot_path.path_join(entry)
		if dir.current_is_dir():
			var category = entry
			if not data.has(category):
				data[category] = {}
			_apply_folder_override(category, full_path)
		elif entry.ends_with(".json"):
			var category = entry.trim_suffix(".json")
			var override_data = DataParser.json_to_dict(full_path)
			if not override_data.is_empty():
				if not data.has(category):
					data[category] = {}
				_merge_dictionaries(data[category], override_data)
		entry = dir.get_next()
	dir.list_dir_end()

func _apply_folder_override(category: String, folder_path: String):
	var dir = DirAccess.open(folder_path)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var sub_key = file_name.trim_suffix(".json")
			var sub_path = folder_path.path_join(file_name)
			var sub_data = DataParser.json_to_dict(sub_path)
			if not sub_data.is_empty():
				if not data[category].has(sub_key):
					data[category][sub_key] = {}
				_merge_dictionaries(data[category][sub_key], sub_data)
		file_name = dir.get_next()
	dir.list_dir_end()

## Refresh all NPC instances' dialogue from DataManager.npc_active_dialogue mapping.
func refresh_all_npc_dialogues():
	var npcs: Array = []
	# Collect registered entities first
	for entity in Entity.get_all_entities():
		if entity is NPC and not npcs.has(entity):
			npcs.append(entity)
	# Also scan the current scene tree for NPCs (in case some lack entity_id)
	var root = get_tree().current_scene if get_tree().current_scene else get_tree().get_root()
	if root:
		_collect_npcs(root, npcs)
	# Update all found NPCs
	for npc in npcs:
		if npc and is_instance_valid(npc) and npc.has_method("update_dialogue_from_active"):
			npc.update_dialogue_from_active()

func _collect_npcs(node: Node, result: Array):
	for child in node.get_children():
		if child is NPC and not result.has(child):
			result.append(child)
		_collect_npcs(child, result)

## Returns true if the given slot has any save data (files or directories).
func has_save_data(slot: int) -> bool:
	if slot < 1 or slot > max_save_slots:
		return false
	var slot_path = save_data_base_folder.path_join("save_%d" % slot)
	if not DirAccess.dir_exists_absolute(slot_path):
		return false
	var files = DirAccess.get_files_at(slot_path)
	if files.size() > 0:
		return true
	var subdirs = DirAccess.get_directories_at(slot_path)
	return subdirs.size() > 0

## Get per-slot summary info used by save/load menus.
func get_save_slots_info() -> Dictionary:
	var slots_info := {}
	for slot in range(1, max_save_slots + 1):
		var slot_path = save_data_base_folder.path_join("save_%d" % slot)
		var slot_info := {
			"exists": false,
			"party_members": {},
			"inventory_count": 0,
			"last_modified": 0
		}
		if DirAccess.dir_exists_absolute(slot_path):
			var files = DirAccess.get_files_at(slot_path)
			var dirs = DirAccess.get_directories_at(slot_path)
			if files.size() > 0 or dirs.size() > 0:
				slot_info["exists"] = true
			# Load party member snapshot if present
			var party_data = _load_category_from_slot("party_members", slot)
			if not party_data.is_empty():
				slot_info["party_members"] = party_data
			# Load conditional_flags to get chapter info
			var flags_data = _load_category_from_slot("conditional_flags", slot)
			if not flags_data.is_empty():
				slot_info["conditional_flags"] = flags_data
				# Use party_members JSON timestamp as last_modified if available
				var pm_folder = slot_path.path_join("party_members")
				if DirAccess.dir_exists_absolute(pm_folder):
					var pm_files = DirAccess.get_files_at(pm_folder)
					if pm_files.size() > 0:
						var pm_path = pm_folder.path_join(pm_files[0])
						var f = FileAccess.open(pm_path, FileAccess.READ)
						if f:
							slot_info["last_modified"] = f.get_modified_time(pm_path)
							f.close()
			# Inventory count
			var inventory_data = _load_category_from_slot("inventory", slot)
			if not inventory_data.is_empty():
				slot_info["inventory_count"] = inventory_data.size()
			# Load general_data for money
			var general_data = _load_category_from_slot("general_data", slot)
			if not general_data.is_empty():
				slot_info["general_data"] = general_data
		slots_info["slot_%d" % slot] = slot_info
	return slots_info

func _load_category_from_slot(category: String, slot: int) -> Dictionary:
	var slot_path = save_data_base_folder.path_join("save_%d" % slot)
	if not DirAccess.dir_exists_absolute(slot_path):
		return {}
	var result: Dictionary = {}
	var folder_path = slot_path.path_join(category)
	var file_path = slot_path.path_join(category + ".json")
	if DirAccess.dir_exists_absolute(folder_path):
		var dir = DirAccess.open(folder_path)
		if not dir:
			return {}
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".json"):
				var sub_key = file_name.trim_suffix(".json")
				var sub_data = DataParser.json_to_dict(folder_path.path_join(file_name))
				if not sub_data.is_empty():
					result[sub_key] = sub_data
			file_name = dir.get_next()
		dir.list_dir_end()
		return result
	elif FileAccess.file_exists(file_path):
		return DataParser.json_to_dict(file_path)
	return {}

## Delete all save data for the given slot.
func delete_save_slot(slot: int) -> bool:
	if slot < 1 or slot > max_save_slots:
		push_warning("[DataManager] Invalid save slot for delete: " + str(slot))
		return false
	var slot_path = save_data_base_folder.path_join("save_%d" % slot)
	if not DirAccess.dir_exists_absolute(slot_path):
		return false
	# Godot 4's DirAccess does not provide remove_recursive, so perform a manual
	# recursive delete of all files and subdirectories, then remove the root.
	_delete_directory_recursive(slot_path)
	print("[DataManager] Deleted save slot: ", slot)
	return true

## Recursively delete a directory and all of its contents.
func _delete_directory_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				# Recurse into subdirectory
				_delete_directory_recursive(full_path)
			else:
				# Delete file
				DirAccess.remove_absolute(full_path)
			file_name = dir.get_next()
		dir.list_dir_end()
	# Finally remove the now-empty directory itself
	DirAccess.remove_absolute(path)

## Get saved scene and position information from general_data.player_data.
func get_saved_scene_info() -> Dictionary:
	if data.has("general_data") and data["general_data"].has("player_data"):
		return data["general_data"]["player_data"]
	return {
		"scene_path": "res://scenes/maps/maine.tscn",
		"position": {"x": 0, "y": 0, "z": 0}
	}

## Utility: deep copy of Dictionaries/Arrays
func _deep_copy(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var d := {}
			for k in value.keys():
				d[k] = _deep_copy(value[k])
			return d
		TYPE_ARRAY:
			var a: Array = []
			for v in value:
				a.append(_deep_copy(v))
			return a
		_:
			return value

## Utility: deep equality comparison for Dictionaries/Arrays
func _deep_equal(a, b) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_DICTIONARY:
			if a.size() != b.size():
				return false
			for key in a.keys():
				if not b.has(key):
					return false
				if not _deep_equal(a[key], b[key]):
					return false
			return true
		TYPE_ARRAY:
			if a.size() != b.size():
				return false
			for i in range(a.size()):
				if not _deep_equal(a[i], b[i]):
					return false
			return true
		_:
			return a == b

#endregion

#region Backwards Compatibility - Property Access
# This allows accessing data categories as properties: DataManager.talents
# Same as DataManager.talents
func _get(property: StringName):
	if data.has(property):
		return data[property]
	return {}

func _set(property: StringName, value) -> bool:
	if data.has(property):
		data[property] = value
		return true
	return false

func _get_property_list():
	# This makes the data categories show up in the inspector
	var properties = []
	for key in data.keys():
		properties.append({
			"name": key,
			"type": TYPE_DICTIONARY,
			"usage": PROPERTY_USAGE_DEFAULT
		})
	return properties
#endregion
