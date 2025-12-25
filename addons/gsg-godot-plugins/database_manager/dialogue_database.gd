extends Node
class_name DialogueDatabase

## DialogueDatabase - Pure JSON-based dialogue system
## No SQL, just loads JSON files into memory

#region Constants
const PRIORITY_FALLBACK = 0
const PRIORITY_NORMAL = 100
const PRIORITY_CONTEXTUAL = 200
const PRIORITY_URGENT = 300
const PRIORITY_OVERRIDE = 999

const ORDER_FIRST = 10
const ORDER_SECOND = 20
const ORDER_THIRD = 30
const ORDER_FOURTH = 40
const ORDER_LAST = 100
#endregion

#region Signals
signal dialogue_loaded(tree_id: String, nodes: Array)
signal dialogue_flag_changed(flag_key: String, value: Variant)
signal dialogue_ready()
#endregion

## Path to dialogue JSON files
const DIALOGUE_DATA_PATH = "res://data/dialogue/"

## In-memory storage
var _dialogue_trees: Dictionary = {} # tree_id -> tree data
var _dialogue_nodes: Dictionary = {} # node_id -> node data
var _dialogue_choices: Dictionary = {} # choice_id -> choice data
var _dialogue_flags: Dictionary = {} # steam_id -> {flag_key -> value}
var _dialogue_history: Dictionary = {} # steam_id -> [{tree_id, node_id, choice_id, timestamp}]

var _ready_state: bool = false

func _ready():
	_load_all_dialogue_files()
	_ready_state = true
	print("[DialogueDatabase] Loaded %d dialogue trees" % _dialogue_trees.size())
	dialogue_ready.emit()

func is_ready() -> bool:
	return _ready_state

#region JSON Loading
func _load_all_dialogue_files():
	var dir = DirAccess.open(DIALOGUE_DATA_PATH)
	if not dir:
		print("[DialogueDatabase] No dialogue directory at: ", DIALOGUE_DATA_PATH)
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name.ends_with(".json"):
			var full_path = DIALOGUE_DATA_PATH + file_name
			_import_dialogue_file(full_path)
		file_name = dir.get_next()

func _import_dialogue_file(path: String) -> bool:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[DialogueDatabase] Cannot open: ", path)
		return false
	
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		push_error("[DialogueDatabase] Invalid JSON in: ", path)
		return false
	
	return import_dialogue_tree(data)

func import_dialogue_tree(data: Dictionary) -> bool:
	var tree_id = data.get("tree_id", "")
	var npc_id = data.get("npc_id", "")
	
	if tree_id.is_empty() or npc_id.is_empty():
		return false
	
	# Store tree
	_dialogue_trees[tree_id] = {
		"tree_id": tree_id,
		"npc_id": npc_id,
		"tree_name": data.get("name", tree_id),
		"description": data.get("description", ""),
		"priority": data.get("priority", PRIORITY_NORMAL),
		"condition": data.get("condition", {})
	}
	
	# Import nodes
	var nodes = data.get("nodes", [])
	var node_order = 10
	
	for node_data in nodes:
		var node_id = tree_id + "_" + node_data.get("id", str(node_order))
		var next_id = node_data.get("next", "")
		
		# Prefix next_id with tree_id if not already prefixed
		if next_id and not next_id.begins_with(tree_id + "_"):
			next_id = tree_id + "_" + next_id
		
		# Process conditional_next
		var conditional_next = node_data.get("conditional_next", [])
		var processed_conditional: Array = []
		for cond_id in conditional_next:
			if cond_id and not cond_id.begins_with(tree_id + "_"):
				processed_conditional.append(tree_id + "_" + cond_id)
			else:
				processed_conditional.append(cond_id)
		
		_dialogue_nodes[node_id] = {
			"node_id": node_id,
			"tree_id": tree_id,
			"speaker": node_data.get("speaker", "npc"),
			"text": node_data.get("text", ""),
			"emotion": node_data.get("emotion", "neutral"),
			"next_node_id": next_id,
			"conditional_next": processed_conditional,
			"condition": node_data.get("condition", {}),
			"on_enter_events": node_data.get("on_enter", []),
			"on_exit_events": node_data.get("on_exit", []),
			"sort_order": node_order
		}
		
		# Import choices
		var choices = node_data.get("choices", [])
		var choice_order = 10
		
		for choice_data in choices:
			var choice_id = node_id + "_c" + str(choice_order / 10)
			var target_id = choice_data.get("goto", "")
			
			# Prefix with tree_id if not already prefixed
			if target_id and not target_id.begins_with(tree_id + "_"):
				target_id = tree_id + "_" + target_id
			
			_dialogue_choices[choice_id] = {
				"choice_id": choice_id,
				"node_id": node_id,
				"choice_text": choice_data.get("text", ""),
				"target_node_id": target_id,
				"condition": choice_data.get("condition", {}),
				"events": choice_data.get("events", []),
				"sort_order": choice_order,
				"style": choice_data.get("style", "normal")
			}
			choice_order += 10
		
		node_order += 10
	
	return true

func reload_dialogue():
	_dialogue_trees.clear()
	_dialogue_nodes.clear()
	_dialogue_choices.clear()
	_load_all_dialogue_files()
	print("[DialogueDatabase] Reloaded %d dialogue trees" % _dialogue_trees.size())
#endregion

#region Dialogue Tree Operations
func get_dialogue_tree(tree_id: String) -> Dictionary:
	return _dialogue_trees.get(tree_id, {})

func get_npc_dialogue_trees(npc_id: String, steam_id: int = 0) -> Array:
	var trees: Array = []
	for tree in _dialogue_trees.values():
		if tree.npc_id == npc_id:
			trees.append(tree)
	
	# Sort by priority descending
	trees.sort_custom(func(a, b): return a.priority > b.priority)
	
	# Filter by conditions if steam_id provided
	if steam_id > 0:
		var filtered: Array = []
		for tree in trees:
			if _evaluate_conditions(tree.get("condition", {}), steam_id):
				filtered.append(tree)
		return filtered
	
	return trees

func get_available_tree_for_npc(npc_id: String, steam_id: int) -> Dictionary:
	var trees = get_npc_dialogue_trees(npc_id, steam_id)
	return trees[0] if trees.size() > 0 else {}
#endregion

#region Dialogue Node Operations
func get_dialogue_nodes(tree_id: String) -> Array:
	var nodes: Array = []
	for node in _dialogue_nodes.values():
		if node.tree_id == tree_id:
			nodes.append(node)
	
	nodes.sort_custom(func(a, b): return a.sort_order < b.sort_order)
	return nodes

func get_dialogue_node(node_id: String) -> Dictionary:
	return _dialogue_nodes.get(node_id, {})

func get_first_node(tree_id: String) -> Dictionary:
	var nodes = get_dialogue_nodes(tree_id)
	return nodes[0] if nodes.size() > 0 else {}

func get_next_valid_node(current_node_id: String, steam_id: int) -> Dictionary:
	var current = get_dialogue_node(current_node_id)
	if current.is_empty():
		return {}
	
	var tree_id = current.get("tree_id", "")
	
	# Check conditional_next first
	var conditional_next = current.get("conditional_next", [])
	if conditional_next.size() > 0:
		for next_id in conditional_next:
			var candidate = get_dialogue_node(next_id)
			if not candidate.is_empty():
				var condition = candidate.get("condition", {})
				if _evaluate_conditions(condition, steam_id):
					return candidate
	
	# Fall back to simple next_node_id
	var next_id = current.get("next_node_id", "")
	if next_id.is_empty():
		return {}
	
	var next_node = get_dialogue_node(next_id)
	if not next_node.is_empty():
		var condition = next_node.get("condition", {})
		if _evaluate_conditions(condition, steam_id):
			return next_node
	
	return {}
#endregion

#region Choice Operations
func get_node_choices(node_id: String, steam_id: int = 0) -> Array:
	var choices: Array = []
	for choice in _dialogue_choices.values():
		if choice.node_id == node_id:
			choices.append(choice.duplicate())
	
	choices.sort_custom(func(a, b): return a.sort_order < b.sort_order)
	
	# Mark availability based on conditions
	if steam_id > 0:
		for choice in choices:
			choice["available"] = _evaluate_conditions(choice.get("condition", {}), steam_id)
	
	return choices

func get_choice(choice_id: String) -> Dictionary:
	return _dialogue_choices.get(choice_id, {})
#endregion

#region Flag Operations (in-memory)
func get_dialogue_flag(steam_id: int, flag_key: String) -> Variant:
	if not _dialogue_flags.has(steam_id):
		return null
	return _dialogue_flags[steam_id].get(flag_key, null)

func set_dialogue_flag(steam_id: int, flag_key: String, value: Variant) -> bool:
	if not _dialogue_flags.has(steam_id):
		_dialogue_flags[steam_id] = {}
	_dialogue_flags[steam_id][flag_key] = value
	dialogue_flag_changed.emit(flag_key, value)
	return true

func get_all_dialogue_flags(steam_id: int) -> Dictionary:
	return _dialogue_flags.get(steam_id, {})
#endregion

#region History Operations (in-memory)
func record_dialogue_history(steam_id: int, tree_id: String, node_id: String, choice_id: String = ""):
	if not _dialogue_history.has(steam_id):
		_dialogue_history[steam_id] = []
	
	_dialogue_history[steam_id].append({
		"tree_id": tree_id,
		"node_id": node_id,
		"choice_id": choice_id,
		"timestamp": Time.get_unix_time_from_system()
	})

func has_seen_node(steam_id: int, node_id: String) -> bool:
	if not _dialogue_history.has(steam_id):
		return false
	
	for entry in _dialogue_history[steam_id]:
		if entry.node_id == node_id:
			return true
	return false

func has_completed_tree(steam_id: int, tree_id: String) -> bool:
	if not _dialogue_history.has(steam_id):
		return false
	
	for entry in _dialogue_history[steam_id]:
		if entry.tree_id == tree_id:
			var node = get_dialogue_node(entry.node_id)
			if node.get("next_node_id", "").is_empty():
				return true
	return false
#endregion

#region Condition Evaluation
func _evaluate_conditions(conditions: Dictionary, steam_id: int) -> bool:
	if conditions.is_empty():
		return true
	
	var flags = get_all_dialogue_flags(steam_id)
	
	for key in conditions:
		var expected = conditions[key]
		var actual = null
		
		match key:
			"active_mission":
				actual = _get_active_mission()
			_:
				actual = flags.get(key, null)
		
		if expected is Dictionary:
			if not _evaluate_comparison(actual, expected):
				return false
		else:
			if actual != expected:
				return false
	
	return true

func _get_active_mission() -> Variant:
	if has_node("/root/MissionManager"):
		var mission_id = get_node("/root/MissionManager").get_current_mission()
		return mission_id if not mission_id.is_empty() else null
	return null

func _evaluate_comparison(actual: Variant, comparison: Dictionary) -> bool:
	if comparison.has("eq"):
		return actual == comparison.eq
	if comparison.has("ne"):
		return actual != comparison.ne
	if comparison.has("gt"):
		return actual != null and actual > comparison.gt
	if comparison.has("gte"):
		return actual != null and actual >= comparison.gte
	if comparison.has("lt"):
		return actual != null and actual < comparison.lt
	if comparison.has("lte"):
		return actual != null and actual <= comparison.lte
	if comparison.has("exists"):
		return (actual != null) == comparison.exists
	if comparison.has("in"):
		return actual in comparison["in"]
	return true
#endregion

#region Helper Methods for Dialogue Events
static func event_start_mission(mission_id: String) -> Dictionary:
	return {"type": "start_mission", "params": {"mission_id": mission_id}}

static func event_open_shop(shop_id: String, mode: String = "buy") -> Dictionary:
	return {"type": "open_shop", "params": {"shop_id": shop_id, "mode": mode}}

static func event_give_currency(amount: int, currency_type: String = "credits") -> Dictionary:
	return {"type": "give_currency", "params": {"amount": amount, "currency_type": currency_type}}

static func event_set_flag(flag_key: String, value: Variant = true) -> Dictionary:
	return {"type": "set_flag", "params": {"flag_key": flag_key, "value": value}}

static func event_transfer_zone(zone_type: String, zone_id: String = "") -> Dictionary:
	return {"type": "transfer_zone", "params": {"zone_type": zone_type, "zone_id": zone_id}}
#endregion

#region Legacy API compatibility (for existing code that might call these)
func create_dialogue_tree(_tree_id: String, _npc_id: String, _tree_name: String,
						   _priority: int = PRIORITY_NORMAL, _condition: Dictionary = {}) -> bool:
	push_warning("[DialogueDatabase] create_dialogue_tree() deprecated - edit JSON files directly")
	return false

func create_dialogue_node(_node_id: String, _tree_id: String, _speaker: String, _text: String,
						   _next_node_id: String = "", _sort_order: int = -1,
						   _condition: Dictionary = {}, _conditional_next: Array = []) -> bool:
	push_warning("[DialogueDatabase] create_dialogue_node() deprecated - edit JSON files directly")
	return false

func create_dialogue_choice(_choice_id: String, _node_id: String, _choice_text: String,
							 _target_node_id: String = "", _sort_order: int = -1,
							 _events: Array = []) -> bool:
	push_warning("[DialogueDatabase] create_dialogue_choice() deprecated - edit JSON files directly")
	return false

func add_node_events(_node_id: String, _on_enter: Array = [], _on_exit: Array = []) -> bool:
	push_warning("[DialogueDatabase] add_node_events() deprecated - edit JSON files directly")
	return false
#endregion
