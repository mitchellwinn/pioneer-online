extends Node
# Note: No class_name since this is an autoload singleton

## ItemDatabase - Two-part system:
## 1. Item DEFINITIONS loaded from JSON (stats, prefabs) - static, same for everyone
## 2. Player DATA stored in SQLite (inventory, equipment, ammo state) - per-player persistence

#region Signals
signal items_loaded(count: int)
signal item_equipped(character_id: int, slot: String, item_id: String)
signal item_unequipped(character_id: int, slot: String)
signal inventory_changed(character_id: int)
signal bank_changed(character_id: int)
signal item_database_ready()
#endregion

#region Constants
const SIZE_LARGE = "large"
const SIZE_MEDIUM = "medium"
const SIZE_SMALL = "small"

# Equipment slots - match EquipmentManager's 3-slot system
const SLOT_PRIMARY = "weapon_1"    # Main weapon (rifle)
const SLOT_SECONDARY = "weapon_2"  # Secondary weapon (SMG)
const SLOT_SIDEARM = "weapon_3"    # Sidearm/melee
const SLOT_MELEE = "weapon_3"      # Melee shares slot 3
#endregion

## Path to item JSON files
const ITEM_DATA_PATH = "res://data/items/"

var db_manager: Node = null

## Item definitions from JSON (cached in memory)
var _items: Dictionary = {}  # item_id -> full item data including weapon_data
var _holster_slots: Dictionary = {}  # size -> [slot_ids]
var _equipment_slots: Dictionary = {}  # slot_name -> {max_size, description}

var is_ready: bool = false
var is_server_instance: bool = false
var _initialized: bool = false

func _ready():
	print("[ItemDatabase] Initializing...")
	
	# ALWAYS load item definitions from JSON first (they're static)
	_load_item_definitions()
	
	# Connect to NetworkManager signals to detect when we become a server
	var network = get_node_or_null("/root/NetworkManager")
	if network:
		if network.has_signal("server_started"):
			network.server_started.connect(_on_server_started)
		if network.has_signal("connected_to_server"):
			network.connected_to_server.connect(_on_connected_as_client)
	
	# Try to get DatabaseManager for player data
	if has_node("/root/DatabaseManager"):
		db_manager = get_node("/root/DatabaseManager")
		if not db_manager.is_open:
			db_manager.database_opened.connect(_on_database_opened)

func _on_server_started():
	## Called when this instance starts as a server
	print("[ItemDatabase] Server started - setting up player data tables...")
	is_server_instance = true
	_setup_player_tables()

func _on_connected_as_client():
	## Called when this instance connects to a server as a client
	print("[ItemDatabase] Connected as client - item definitions loaded from JSON")
	is_server_instance = false
	is_ready = true
	_initialized = true
	item_database_ready.emit()

func _on_database_opened(_path: String):
	print("[ItemDatabase] Database opened")
	if is_server_instance:
		_setup_player_tables()

func _setup_player_tables():
	## Create SQLite tables for player inventory/equipment (NOT item definitions)
	if _initialized:
		return
	
	if not db_manager:
		db_manager = get_node_or_null("/root/DatabaseManager")
	
	if not db_manager or not db_manager.is_open:
		print("[ItemDatabase] Waiting for database to open...")
		return
	
	_initialized = true
	_create_player_tables()
	
	is_ready = true
	print("[ItemDatabase] Item database ready! ", _items.size(), " items loaded from JSON")
	item_database_ready.emit()

func _create_player_tables():
	## Create ONLY the player-specific tables (inventory, equipment)
	## Item definitions stay in JSON, not duplicated to SQLite
	if not db_manager or not db_manager.is_open:
		return
	
	print("[ItemDatabase] Creating player data tables...")
	
	# Player inventory - what items each player owns
	db_manager.execute_query("""
		CREATE TABLE IF NOT EXISTS player_inventory (
			inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			item_id TEXT NOT NULL,
			quantity INTEGER DEFAULT 1,
			acquired_at INTEGER NOT NULL,
			instance_data_json TEXT DEFAULT '{}'
		);
	""")
	
	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_inventory_character ON player_inventory(character_id);")
	
	# Player equipment - what's equipped in each slot
	db_manager.execute_query("""
		CREATE TABLE IF NOT EXISTS player_equipment (
			equipment_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			slot_name TEXT NOT NULL,
			inventory_id INTEGER NOT NULL,
			equipped_at INTEGER NOT NULL,
			FOREIGN KEY (inventory_id) REFERENCES player_inventory(inventory_id),
			UNIQUE(character_id, slot_name)
		);
	""")
	
	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_equipment_character ON player_equipment(character_id);")

	# Player bank - stored items (separate from active inventory)
	db_manager.execute_query("""
		CREATE TABLE IF NOT EXISTS player_bank (
			bank_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			item_id TEXT NOT NULL,
			quantity INTEGER DEFAULT 1,
			stored_at INTEGER NOT NULL,
			instance_data_json TEXT DEFAULT '{}'
		);
	""")

	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_bank_character ON player_bank(character_id);")

	print("[ItemDatabase] Player data tables ready")

#region JSON Loading (Item Definitions - cached in memory)
func _load_item_definitions():
	## Load all item definitions from JSON into memory
	## This is called on startup for BOTH server and client
	_items.clear()
	_holster_slots.clear()
	_equipment_slots.clear()
	
	var dir = DirAccess.open(ITEM_DATA_PATH)
	if not dir:
		print("[ItemDatabase] No item directory at: ", ITEM_DATA_PATH)
		return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name.ends_with(".json"):
			var full_path = ITEM_DATA_PATH + file_name
			_load_json_file(full_path)
		file_name = dir.get_next()
	
	print("[ItemDatabase] Loaded ", _items.size(), " item definitions from JSON")
	items_loaded.emit(_items.size())

func _load_json_file(path: String):
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[ItemDatabase] Cannot open: ", path)
		return
	
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		push_error("[ItemDatabase] Invalid JSON in: ", path)
		return
	
	# Load items into memory cache
	var items_array = data.get("items", [])
	for item_data in items_array:
		var item_id = item_data.get("id", "")
		if not item_id.is_empty():
			# Flatten weapon_data into the main dict for easier access
			var flat_item = item_data.duplicate(true)
			if flat_item.has("weapon_data"):
				var wd = flat_item.weapon_data
				for key in wd:
					flat_item[key] = wd[key]
			_items[item_id] = flat_item
	
	# Load holster slot configuration
	var holster_data = data.get("holster_slots", {})
	for size_category in holster_data:
		if not _holster_slots.has(size_category):
			_holster_slots[size_category] = []
		for slot_id in holster_data[size_category]:
			_holster_slots[size_category].append(slot_id)
	
	# Load equipment slot configuration
	var equip_data = data.get("equipment_slots", {})
	for slot_name in equip_data:
		_equipment_slots[slot_name] = equip_data[slot_name]

func reload_item_definitions():
	## Reload item definitions from JSON (for development hot-reload)
	_load_item_definitions()
	print("[ItemDatabase] Reloaded item definitions")
#endregion

#region Item Definition Queries (from JSON cache)
func get_item(item_id: String) -> Dictionary:
	## Get item definition from JSON cache
	return _items.get(item_id, {})

func get_items_by_type(item_type: String) -> Array:
	## Get all items of a type from JSON cache
	var result = []
	for item_id in _items:
		if _items[item_id].get("type") == item_type:
			result.append(_items[item_id])
	return result

func get_items_by_subtype(subtype: String) -> Array:
	## Get all items of a subtype from JSON cache
	var result = []
	for item_id in _items:
		if _items[item_id].get("subtype") == subtype:
			result.append(_items[item_id])
	return result

func get_weapon_stats(item_id: String) -> Dictionary:
	## Get weapon stats - they're already flattened into the item dict
	var item = get_item(item_id)
	if item.get("type") == "weapon":
		return item
	return {}

func get_full_weapon_data(item_id: String) -> Dictionary:
	## Get complete weapon data (same as get_item for weapons now)
	return get_item(item_id)

func get_all_weapons() -> Array:
	## Get all weapon definitions
	return get_items_by_type("weapon")

func get_holster_slots_for_size(size: String) -> Array:
	## Get valid holster slots for an item size
	return _holster_slots.get(size, [])

func get_equipment_slot(slot_name: String) -> Dictionary:
	## Get equipment slot configuration
	return _equipment_slots.get(slot_name, {})
#endregion

#region Inventory Management (SQLite for player data)
func add_to_inventory(steam_id: int, character_id: int, item_id: String, quantity: int = 1, instance_data: Dictionary = {}) -> int:
	## Add an item to player's inventory (SQLite)
	if not db_manager or not db_manager.is_open:
		push_error("[ItemDatabase] Database not ready!")
		return -1
	
	# Verify item exists in JSON definitions
	if not _items.has(item_id):
		push_error("[ItemDatabase] Unknown item_id: ", item_id)
		return -1
	
	var now = Time.get_unix_time_from_system()
	var instance_json = JSON.stringify(instance_data)
	
	db_manager.execute_query("""
		INSERT INTO player_inventory (steam_id, character_id, item_id, quantity, acquired_at, instance_data_json)
		VALUES (?, ?, ?, ?, ?, ?);
	""", [steam_id, character_id, item_id, quantity, now, instance_json])
	
	var result = db_manager.execute_query("SELECT last_insert_rowid() as id;")
	var inventory_id = result[0].id if result.size() > 0 else -1
	
	if inventory_id > 0:
		inventory_changed.emit(character_id)
	
	return inventory_id

func remove_from_inventory(inventory_id: int) -> bool:
	if not db_manager or not db_manager.is_open:
		return false
	
	# Get character_id before deletion for signal
	var item = db_manager.execute_query(
		"SELECT character_id FROM player_inventory WHERE inventory_id = ?;", [inventory_id]
	)
	
	if item.size() == 0:
		return false
	
	var character_id = item[0].character_id
	
	# Unequip if equipped
	db_manager.execute_query(
		"DELETE FROM player_equipment WHERE inventory_id = ?;", [inventory_id]
	)
	
	# Remove from inventory
	db_manager.execute_query(
		"DELETE FROM player_inventory WHERE inventory_id = ?;", [inventory_id]
	)
	
	inventory_changed.emit(character_id)
	return true

func get_inventory(character_id: int) -> Array:
	## Get player's inventory, merging SQLite data with JSON definitions
	if not db_manager or not db_manager.is_open:
		return []
	
	var rows = db_manager.execute_query("""
		SELECT * FROM player_inventory WHERE character_id = ?;
	""", [character_id])
	
	var result = []
	for row in rows:
		var item_def = get_item(row.item_id)
		if not item_def.is_empty():
			var merged = row.duplicate()
			for key in item_def:
				merged[key] = item_def[key]
			result.append(merged)
	
	return result

func get_inventory_weapons(character_id: int) -> Array:
	## Get player's weapons from inventory with full stats
	var inventory = get_inventory(character_id)
	var weapons = []
	for item in inventory:
		if item.get("type") == "weapon":
			weapons.append(item)
	return weapons
#endregion

#region Bank Management (SQLite for stored items)
func add_to_bank(steam_id: int, character_id: int, item_id: String, quantity: int = 1, instance_data: Dictionary = {}) -> int:
	## Add an item directly to player's bank
	if not db_manager or not db_manager.is_open:
		push_error("[ItemDatabase] Database not ready!")
		return -1

	if not _items.has(item_id):
		push_error("[ItemDatabase] Unknown item_id: ", item_id)
		return -1

	var now = Time.get_unix_time_from_system()
	var instance_json = JSON.stringify(instance_data)

	db_manager.execute_query("""
		INSERT INTO player_bank (steam_id, character_id, item_id, quantity, stored_at, instance_data_json)
		VALUES (?, ?, ?, ?, ?, ?);
	""", [steam_id, character_id, item_id, quantity, now, instance_json])

	var result = db_manager.execute_query("SELECT last_insert_rowid() as id;")
	var bank_id = result[0].id if result.size() > 0 else -1

	if bank_id > 0:
		bank_changed.emit(character_id)

	return bank_id

func remove_from_bank(bank_id: int) -> bool:
	## Remove an item from bank by bank_id
	if not db_manager or not db_manager.is_open:
		return false

	var item = db_manager.execute_query(
		"SELECT character_id FROM player_bank WHERE bank_id = ?;", [bank_id]
	)

	if item.size() == 0:
		return false

	var character_id = item[0].character_id

	db_manager.execute_query(
		"DELETE FROM player_bank WHERE bank_id = ?;", [bank_id]
	)

	bank_changed.emit(character_id)
	return true

func get_bank(character_id: int) -> Array:
	## Get player's banked items, merging with JSON definitions
	if not db_manager or not db_manager.is_open:
		return []

	var rows = db_manager.execute_query("""
		SELECT * FROM player_bank WHERE character_id = ?;
	""", [character_id])

	var result = []
	for row in rows:
		var item_def = get_item(row.item_id)
		if not item_def.is_empty():
			var merged = row.duplicate()
			for key in item_def:
				merged[key] = item_def[key]
			result.append(merged)

	return result

func bank_item(inventory_id: int) -> int:
	## Move an item from inventory to bank. Returns bank_id or -1 on failure.
	if not db_manager or not db_manager.is_open:
		return -1

	# Get inventory item data
	var inv_rows = db_manager.execute_query("""
		SELECT * FROM player_inventory WHERE inventory_id = ?;
	""", [inventory_id])

	if inv_rows.size() == 0:
		push_error("[ItemDatabase] Inventory item not found: ", inventory_id)
		return -1

	var inv_item = inv_rows[0]

	# Unequip if equipped
	db_manager.execute_query(
		"DELETE FROM player_equipment WHERE inventory_id = ?;", [inventory_id]
	)

	# Add to bank
	var now = Time.get_unix_time_from_system()
	db_manager.execute_query("""
		INSERT INTO player_bank (steam_id, character_id, item_id, quantity, stored_at, instance_data_json)
		VALUES (?, ?, ?, ?, ?, ?);
	""", [inv_item.steam_id, inv_item.character_id, inv_item.item_id, inv_item.quantity, now, inv_item.instance_data_json])

	var result = db_manager.execute_query("SELECT last_insert_rowid() as id;")
	var bank_id = result[0].id if result.size() > 0 else -1

	# Remove from inventory
	db_manager.execute_query(
		"DELETE FROM player_inventory WHERE inventory_id = ?;", [inventory_id]
	)

	inventory_changed.emit(inv_item.character_id)
	bank_changed.emit(inv_item.character_id)

	return bank_id

func unbank_item(bank_id: int) -> int:
	## Move an item from bank to inventory. Returns inventory_id or -1 on failure.
	if not db_manager or not db_manager.is_open:
		return -1

	# Get bank item data
	var bank_rows = db_manager.execute_query("""
		SELECT * FROM player_bank WHERE bank_id = ?;
	""", [bank_id])

	if bank_rows.size() == 0:
		push_error("[ItemDatabase] Bank item not found: ", bank_id)
		return -1

	var bank_item = bank_rows[0]

	# Add to inventory
	var now = Time.get_unix_time_from_system()
	db_manager.execute_query("""
		INSERT INTO player_inventory (steam_id, character_id, item_id, quantity, acquired_at, instance_data_json)
		VALUES (?, ?, ?, ?, ?, ?);
	""", [bank_item.steam_id, bank_item.character_id, bank_item.item_id, bank_item.quantity, now, bank_item.instance_data_json])

	var result = db_manager.execute_query("SELECT last_insert_rowid() as id;")
	var inventory_id = result[0].id if result.size() > 0 else -1

	# Remove from bank
	db_manager.execute_query(
		"DELETE FROM player_bank WHERE bank_id = ?;", [bank_id]
	)

	inventory_changed.emit(bank_item.character_id)
	bank_changed.emit(bank_item.character_id)

	return inventory_id

func bank_all_inventory(character_id: int) -> int:
	## Move ALL inventory items to bank. Returns count of items banked.
	## Used by rental loadout system.
	if not db_manager or not db_manager.is_open:
		return 0

	# Get steam_id for this character
	var char_rows = db_manager.execute_query("""
		SELECT steam_id FROM player_inventory WHERE character_id = ? LIMIT 1;
	""", [character_id])

	if char_rows.size() == 0:
		# No inventory items
		return 0

	var steam_id = char_rows[0].steam_id

	# Unequip everything first
	db_manager.execute_query(
		"DELETE FROM player_equipment WHERE character_id = ?;", [character_id]
	)

	# Get all inventory items
	var inv_rows = db_manager.execute_query("""
		SELECT * FROM player_inventory WHERE character_id = ?;
	""", [character_id])

	var now = Time.get_unix_time_from_system()
	var count = 0

	for inv_item in inv_rows:
		# Add to bank
		db_manager.execute_query("""
			INSERT INTO player_bank (steam_id, character_id, item_id, quantity, stored_at, instance_data_json)
			VALUES (?, ?, ?, ?, ?, ?);
		""", [inv_item.steam_id, inv_item.character_id, inv_item.item_id, inv_item.quantity, now, inv_item.instance_data_json])
		count += 1

	# Clear inventory
	db_manager.execute_query(
		"DELETE FROM player_inventory WHERE character_id = ?;", [character_id]
	)

	if count > 0:
		inventory_changed.emit(character_id)
		bank_changed.emit(character_id)

	print("[ItemDatabase] Banked %d items for character %d" % [count, character_id])
	return count

func unbank_all(character_id: int) -> int:
	## Move ALL banked items back to inventory. Returns count of items restored.
	if not db_manager or not db_manager.is_open:
		return 0

	# Get all banked items
	var bank_rows = db_manager.execute_query("""
		SELECT * FROM player_bank WHERE character_id = ?;
	""", [character_id])

	var now = Time.get_unix_time_from_system()
	var count = 0

	for bank_item in bank_rows:
		# Add to inventory
		db_manager.execute_query("""
			INSERT INTO player_inventory (steam_id, character_id, item_id, quantity, acquired_at, instance_data_json)
			VALUES (?, ?, ?, ?, ?, ?);
		""", [bank_item.steam_id, bank_item.character_id, bank_item.item_id, bank_item.quantity, now, bank_item.instance_data_json])
		count += 1

	# Clear bank
	db_manager.execute_query(
		"DELETE FROM player_bank WHERE character_id = ?;", [character_id]
	)

	if count > 0:
		inventory_changed.emit(character_id)
		bank_changed.emit(character_id)

	print("[ItemDatabase] Unbanked %d items for character %d" % [count, character_id])
	return count
#endregion

#region Equipment Management (SQLite for equipped state)
func equip_item(character_id: int, slot_name: String, inventory_id: int) -> bool:
	if not db_manager or not db_manager.is_open:
		return false
	
	# Validate the slot exists in JSON config
	var slot_config = _equipment_slots.get(slot_name, {})
	if slot_config.is_empty():
		push_error("[ItemDatabase] Invalid equipment slot: ", slot_name)
		return false
	
	# Get the inventory item
	var inv_rows = db_manager.execute_query("""
		SELECT * FROM player_inventory 
		WHERE inventory_id = ? AND character_id = ?;
	""", [inventory_id, character_id])
	
	if inv_rows.size() == 0:
		push_error("[ItemDatabase] Inventory item not found: ", inventory_id)
		return false
	
	var inv_item = inv_rows[0]
	var item_def = get_item(inv_item.item_id)
	
	# Validate size compatibility
	var item_size = item_def.get("size", "medium")
	var max_size = slot_config.get("max_size", "large")
	if not _is_size_compatible(item_size, max_size):
		push_error("[ItemDatabase] Item too large for slot. Item: ", item_size, " Slot max: ", max_size)
		return false
	
	# Unequip current item in slot
	unequip_slot(character_id, slot_name)
	
	# Equip new item
	var now = Time.get_unix_time_from_system()
	db_manager.execute_query("""
		INSERT INTO player_equipment (steam_id, character_id, slot_name, inventory_id, equipped_at)
		SELECT steam_id, character_id, ?, ?, ?
		FROM player_inventory WHERE inventory_id = ?;
	""", [slot_name, inventory_id, now, inventory_id])
	
	item_equipped.emit(character_id, slot_name, inv_item.item_id)
	return true

func unequip_slot(character_id: int, slot_name: String) -> bool:
	if not db_manager or not db_manager.is_open:
		return false
	
	db_manager.execute_query(
		"DELETE FROM player_equipment WHERE character_id = ? AND slot_name = ?;",
		[character_id, slot_name]
	)
	
	item_unequipped.emit(character_id, slot_name)
	return true

#region Network RPCs for Equip/Unequip
## Client requests to unequip an item - server processes and confirms
func request_unequip(slot_name: String):
	## Called by CLIENT to request unequipping an item
	if is_server_instance:
		# We ARE the server, just do it locally
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_method("get_local_character_id"):
			var char_id = network.get_local_character_id()
			unequip_slot(char_id, slot_name)
	else:
		# Send request to server
		_rpc_request_unequip.rpc_id(1, slot_name)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_unequip(slot_name: String):
	## Server receives unequip request from client
	if not is_server_instance:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return
	
	# Get character_id for this peer
	var char_id = 0
	if network.has_method("get_character_id_for_peer"):
		char_id = network.get_character_id_for_peer(sender_id)
	elif network.connected_peers.has(sender_id):
		char_id = network.connected_peers[sender_id].character_id
	
	if char_id <= 0:
		print("[ItemDatabase] Cannot unequip - no character_id for peer %d" % sender_id)
		return
	
	# Do the unequip on server
	if unequip_slot(char_id, slot_name):
		print("[ItemDatabase] Server unequipped %s for character %d" % [slot_name, char_id])
		# Confirm back to client
		_rpc_confirm_unequip.rpc_id(sender_id, slot_name, true)
	else:
		_rpc_confirm_unequip.rpc_id(sender_id, slot_name, false)

@rpc("authority", "call_remote", "reliable")
func _rpc_confirm_unequip(slot_name: String, success: bool):
	## Client receives confirmation of unequip
	if is_server_instance:
		return
	print("[ItemDatabase] Unequip %s confirmed: %s" % [slot_name, success])
	if success:
		item_unequipped.emit(0, slot_name)  # character_id not needed client-side

## Client requests to equip an item
func request_equip(slot_name: String, inventory_id: int):
	## Called by CLIENT to request equipping an item
	if is_server_instance:
		var network = get_node_or_null("/root/NetworkManager")
		if network and network.has_method("get_local_character_id"):
			var char_id = network.get_local_character_id()
			equip_item(char_id, slot_name, inventory_id)
	else:
		_rpc_request_equip.rpc_id(1, slot_name, inventory_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_equip(slot_name: String, inventory_id: int):
	## Server receives equip request
	if not is_server_instance:
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	var network = get_node_or_null("/root/NetworkManager")
	if not network:
		return
	
	var char_id = 0
	if network.has_method("get_character_id_for_peer"):
		char_id = network.get_character_id_for_peer(sender_id)
	elif network.connected_peers.has(sender_id):
		char_id = network.connected_peers[sender_id].character_id
	
	if char_id <= 0:
		print("[ItemDatabase] Cannot equip - no character_id for peer %d" % sender_id)
		return
	
	if equip_item(char_id, slot_name, inventory_id):
		print("[ItemDatabase] Server equipped item %d to %s for character %d" % [inventory_id, slot_name, char_id])
		# Get the equipped item data to send back
		var equipped = get_equipped_items(char_id)
		var item_data = equipped.get(slot_name, {})
		_rpc_confirm_equip.rpc_id(sender_id, slot_name, item_data)

@rpc("authority", "call_remote", "reliable") 
func _rpc_confirm_equip(slot_name: String, item_data: Dictionary):
	## Client receives confirmation of equip with item data
	if is_server_instance:
		return
	print("[ItemDatabase] Equip %s confirmed with item: %s" % [slot_name, item_data.get("name", "?")])
	if not item_data.is_empty():
		item_equipped.emit(0, slot_name, item_data.get("item_id", ""))
#endregion

func get_equipped_items(character_id: int) -> Dictionary:
	## Get all equipped items, merging SQLite state with JSON definitions
	if not db_manager or not db_manager.is_open:
		return {}
	
	var rows = db_manager.execute_query("""
		SELECT pe.slot_name, pe.inventory_id, pi.item_id, pi.instance_data_json
		FROM player_equipment pe
		JOIN player_inventory pi ON pe.inventory_id = pi.inventory_id
		WHERE pe.character_id = ?;
	""", [character_id])
	
	var equipped = {}
	for row in rows:
		var item_def = get_item(row.item_id)
		if not item_def.is_empty():
			var merged = row.duplicate()
			for key in item_def:
				merged[key] = item_def[key]
			# Parse instance state
			if row.instance_data_json:
				var state = JSON.parse_string(row.instance_data_json)
				if state is Dictionary:
					merged["instance_state"] = state
			equipped[row.slot_name] = merged
	
	return equipped

func get_equipped_weapon(character_id: int, slot_name: String) -> Dictionary:
	## Get single equipped weapon with full data
	var equipped = get_equipped_items(character_id)
	return equipped.get(slot_name, {})

func _is_size_compatible(item_size: String, max_size: String) -> bool:
	var size_order = {"small": 0, "medium": 1, "large": 2}
	var item_level = size_order.get(item_size, 1)
	var max_level = size_order.get(max_size, 1)
	return item_level <= max_level
#endregion

#region Starting Loadout
func delete_character_data(steam_id: int):
	## Delete all character data for a Steam user (for testing/reset)
	if not db_manager or not db_manager.is_open:
		push_error("[ItemDatabase] Cannot delete character data - database not ready")
		return
	
	print("[ItemDatabase] Deleting all character data for Steam ID: ", steam_id)
	
	# Delete equipment first (foreign key to inventory)
	db_manager.execute_query("DELETE FROM player_equipment WHERE steam_id = ?;", [steam_id])
	
	# Delete inventory
	db_manager.execute_query("DELETE FROM player_inventory WHERE steam_id = ?;", [steam_id])
	
	# Delete characters
	db_manager.execute_query("DELETE FROM characters WHERE steam_id = ?;", [steam_id])
	
	print("[ItemDatabase] Character data deleted for Steam ID: ", steam_id)

func recreate_inventory_tables():
	## Drop and recreate inventory/equipment tables (fixes schema issues)
	if not db_manager or not db_manager.is_open:
		push_error("[ItemDatabase] Cannot recreate tables - database not ready")
		return
	
	print("[ItemDatabase] Recreating inventory tables (fixes foreign key issues)...")
	
	# Drop tables in correct order (equipment depends on inventory)
	db_manager.execute_query("DROP TABLE IF EXISTS player_equipment;")
	db_manager.execute_query("DROP TABLE IF EXISTS player_inventory;")
	
	# Recreate without foreign key on item_id (items come from JSON, not SQL)
	db_manager.execute_query("""
		CREATE TABLE IF NOT EXISTS player_inventory (
			inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			item_id TEXT NOT NULL,
			quantity INTEGER DEFAULT 1,
			acquired_at INTEGER NOT NULL,
			instance_data_json TEXT DEFAULT '{}'
		);
	""")
	
	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_inventory_steam ON player_inventory(steam_id);")
	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_inventory_character ON player_inventory(character_id);")
	
	db_manager.execute_query("""
		CREATE TABLE IF NOT EXISTS player_equipment (
			equipment_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			slot_name TEXT NOT NULL,
			inventory_id INTEGER NOT NULL,
			equipped_at INTEGER NOT NULL,
			FOREIGN KEY (inventory_id) REFERENCES player_inventory(inventory_id),
			UNIQUE(character_id, slot_name)
		);
	""")
	
	db_manager.execute_query("CREATE INDEX IF NOT EXISTS idx_equipment_character ON player_equipment(character_id);")
	
	print("[ItemDatabase] Inventory tables recreated!")

func give_starting_weapons(steam_id: int, character_id: int):
	## Give a new character their default starting weapons
	## DEBUG: Gives extra weapons for testing - remove in production
	if not db_manager or not db_manager.is_open:
		push_error("[ItemDatabase] Cannot give starting weapons - database not ready")
		return
	
	# Give starting credits
	set_player_credits(character_id, DEFAULT_STARTING_CREDITS)
	print("[ItemDatabase] Gave %d starting credits to character %d" % [DEFAULT_STARTING_CREDITS, character_id])
	
	# Add MA5 assault rifle to inventory and equip to primary slot
	var rifle_inv_id = add_to_inventory(steam_id, character_id, "assault_rifle_ma5")
	if rifle_inv_id > 0:
		equip_item(character_id, SLOT_PRIMARY, rifle_inv_id)
		print("[ItemDatabase] Equipped MA5 assault rifle for character ", character_id)
	
	# Add M7S suppressed SMG to inventory and equip to secondary slot
	var smg_inv_id = add_to_inventory(steam_id, character_id, "suppressed_smg_m7s")
	if smg_inv_id > 0:
		equip_item(character_id, SLOT_SECONDARY, smg_inv_id)
		print("[ItemDatabase] Equipped M7S suppressed SMG for character ", character_id)
	
	# Add energy pistol to inventory and equip to sidearm slot
	var pistol_inv_id = add_to_inventory(steam_id, character_id, "energy_pistol_01")
	if pistol_inv_id > 0:
		equip_item(character_id, SLOT_SIDEARM, pistol_inv_id)
		print("[ItemDatabase] Equipped starting pistol for character ", character_id)
	
	# Add energy saber to inventory and equip to melee slot
	var saber_inv_id = add_to_inventory(steam_id, character_id, "energy_saber_01")
	if saber_inv_id > 0:
		equip_item(character_id, SLOT_MELEE, saber_inv_id)
		print("[ItemDatabase] Equipped starting saber for character ", character_id)
	
	# DEBUG: Also add pulse cannon, plasma repeater, and grenade launcher to inventory (not equipped)
	var pulse_inv_id = add_to_inventory(steam_id, character_id, "energy_rifle_01")
	if pulse_inv_id > 0:
		print("[ItemDatabase] Added Pulse Cannon to inventory for character ", character_id)
	var plasma_inv_id = add_to_inventory(steam_id, character_id, "plasma_smg_01")
	if plasma_inv_id > 0:
		print("[ItemDatabase] Added Plasma Repeater to inventory for character ", character_id)
	var grenade_inv_id = add_to_inventory(steam_id, character_id, "grenade_launcher_01")
	if grenade_inv_id > 0:
		print("[ItemDatabase] Added Grenade Launcher to inventory for character ", character_id)
	
	# Give starting ammo for all weapons
	var light_ammo = add_to_inventory(steam_id, character_id, "ammo_energy_light", 200)
	if light_ammo > 0:
		print("[ItemDatabase] Added 200 Light Energy Cells for character ", character_id)
	var medium_ammo = add_to_inventory(steam_id, character_id, "ammo_energy_medium", 180)
	if medium_ammo > 0:
		print("[ItemDatabase] Added 180 Medium Energy Cells for character ", character_id)
	var heavy_ammo = add_to_inventory(steam_id, character_id, "ammo_energy_heavy", 20)
	if heavy_ammo > 0:
		print("[ItemDatabase] Added 20 Heavy Energy Cells for character ", character_id)
	var grenades = add_to_inventory(steam_id, character_id, "ammo_grenades", 6)
	if grenades > 0:
		print("[ItemDatabase] Added 6 Frag Grenades for character ", character_id)

func has_starting_weapons(character_id: int) -> bool:
	## Check if character already has starting weapons
	var equipped = get_equipped_items(character_id)
	return equipped.has(SLOT_PRIMARY) or equipped.has(SLOT_SIDEARM) or equipped.has(SLOT_MELEE)

#region Ammo System
func get_ammo_count(character_id: int, ammo_type: String) -> int:
	## Get total ammo of a specific type in player's inventory
	if not db_manager or not db_manager.is_open:
		return 0
	
	# Find item_id for this ammo type
	var ammo_item_id = "ammo_" + ammo_type
	if not _items.has(ammo_item_id):
		return 0
	
	var result = db_manager.execute_query("""
		SELECT SUM(quantity) as total FROM player_inventory
		WHERE character_id = ? AND item_id = ?;
	""", [character_id, ammo_item_id])
	
	if result.size() > 0 and result[0].total != null:
		return int(result[0].total)
	return 0

func consume_ammo(character_id: int, ammo_type: String, amount: int) -> bool:
	## Consume ammo from inventory. Returns true if successful.
	if amount <= 0:
		return true
	
	var current = get_ammo_count(character_id, ammo_type)
	if current < amount:
		return false
	
	var ammo_item_id = "ammo_" + ammo_type
	
	# Get all inventory entries for this ammo type
	var result = db_manager.execute_query("""
		SELECT inventory_id, quantity FROM player_inventory
		WHERE character_id = ? AND item_id = ?
		ORDER BY inventory_id ASC;
	""", [character_id, ammo_item_id])
	
	var remaining = amount
	for row in result:
		if remaining <= 0:
			break
		
		var inv_id = row.inventory_id
		var qty = int(row.quantity)
		
		if qty <= remaining:
			# Delete this stack entirely
			db_manager.execute_query("DELETE FROM player_inventory WHERE inventory_id = ?;", [inv_id])
			remaining -= qty
		else:
			# Reduce this stack
			db_manager.execute_query("UPDATE player_inventory SET quantity = ? WHERE inventory_id = ?;", [qty - remaining, inv_id])
			remaining = 0
	
	inventory_changed.emit(character_id)
	return true

func add_ammo(character_id: int, steam_id: int, ammo_type: String, amount: int) -> bool:
	## Add ammo to inventory. Stacks with existing ammo.
	if amount <= 0:
		return false
	
	var ammo_item_id = "ammo_" + ammo_type
	if not _items.has(ammo_item_id):
		push_error("[ItemDatabase] Unknown ammo type: ", ammo_type)
		return false
	
	var item_def = _items[ammo_item_id]
	var stack_size = item_def.get("stack_size", 999)
	
	# Try to add to existing stacks first
	var result = db_manager.execute_query("""
		SELECT inventory_id, quantity FROM player_inventory
		WHERE character_id = ? AND item_id = ? AND quantity < ?
		ORDER BY quantity DESC;
	""", [character_id, ammo_item_id, stack_size])
	
	var remaining = amount
	for row in result:
		if remaining <= 0:
			break
		
		var inv_id = row.inventory_id
		var qty = int(row.quantity)
		var space = stack_size - qty
		var to_add = mini(space, remaining)
		
		db_manager.execute_query("UPDATE player_inventory SET quantity = ? WHERE inventory_id = ?;", [qty + to_add, inv_id])
		remaining -= to_add
	
	# Create new stacks for remainder
	while remaining > 0:
		var to_add = mini(stack_size, remaining)
		add_to_inventory(steam_id, character_id, ammo_item_id, to_add)
		remaining -= to_add
	
	return true

func get_all_ammo(character_id: int) -> Dictionary:
	## Get all ammo counts by type
	var ammo = {}
	for item_id in _items:
		var item = _items[item_id]
		if item.get("type") == "ammo":
			var ammo_type = item.get("ammo_type", "")
			if not ammo_type.is_empty():
				ammo[ammo_type] = get_ammo_count(character_id, ammo_type)
	return ammo
#endregion

#region Credits System
const DEFAULT_STARTING_CREDITS = 5000

func get_player_credits(character_id: int) -> int:
	## Get player's current credits (uses 'currency' column in characters table)
	if not db_manager or not db_manager.is_open:
		return DEFAULT_STARTING_CREDITS
	
	var result = db_manager.execute_query("""
		SELECT currency FROM characters WHERE character_id = ?;
	""", [character_id])
	
	if result.size() > 0 and result[0].has("currency"):
		var value = result[0].currency
		if value == null:
			return DEFAULT_STARTING_CREDITS
		return int(value)
	return DEFAULT_STARTING_CREDITS

func set_player_credits(character_id: int, credits: int):
	## Set player's credits (uses 'currency' column in characters table)
	if not db_manager or not db_manager.is_open:
		return
	
	db_manager.execute_query("""
		UPDATE characters SET currency = ? WHERE character_id = ?;
	""", [credits, character_id])

func add_credits(character_id: int, amount: int) -> int:
	## Add credits to player. Returns new total.
	var current = get_player_credits(character_id)
	var new_total = current + amount
	set_player_credits(character_id, new_total)
	return new_total

func spend_credits(character_id: int, amount: int) -> bool:
	## Spend credits. Returns true if successful.
	var current = get_player_credits(character_id)
	if current < amount:
		return false
	set_player_credits(character_id, current - amount)
	return true

func get_all_items() -> Dictionary:
	## Get all item definitions
	return _items
#endregion

func clear_all_player_data():
	## WARNING: Deletes all player inventory and equipment data
	if not db_manager or not db_manager.is_open:
		return
	print("[ItemDatabase] Clearing all player data...")
	db_manager.execute_query("DELETE FROM player_equipment;")
	db_manager.execute_query("DELETE FROM player_inventory;")
	print("[ItemDatabase] Player data cleared!")

func reset_character_equipment(character_id: int, steam_id: int):
	## Reset a character's inventory and equipment, give starting weapons
	if not db_manager or not db_manager.is_open:
		return
	print("[ItemDatabase] Resetting equipment for character ", character_id)
	db_manager.execute_query("DELETE FROM player_equipment WHERE character_id = ?;", [character_id])
	db_manager.execute_query("DELETE FROM player_inventory WHERE character_id = ?;", [character_id])
	give_starting_weapons(steam_id, character_id)
#endregion

#region Weapon Instance State (ammo, heat, etc.)
func save_weapon_state(inventory_id: int, state: Dictionary) -> bool:
	## Save weapon runtime state (ammo, heat, etc.) to database
	## Called when player disconnects or weapon is holstered
	if not db_manager or not db_manager.is_open:
		return false
	
	var state_json = JSON.stringify(state)
	
	db_manager.execute_query("""
		UPDATE player_inventory 
		SET instance_data_json = ?
		WHERE inventory_id = ?;
	""", [state_json, inventory_id])
	
	print("[ItemDatabase] Saved weapon state for inventory_id ", inventory_id)
	return true

func get_weapon_instance_state(inventory_id: int) -> Dictionary:
	## Get saved weapon state (ammo, heat, etc.)
	if not db_manager or not db_manager.is_open:
		return {}
	
	var results = db_manager.execute_query("""
		SELECT instance_data_json FROM player_inventory
		WHERE inventory_id = ?;
	""", [inventory_id])
	
	if results.size() > 0 and results[0].instance_data_json:
		var state = JSON.parse_string(results[0].instance_data_json)
		if state is Dictionary:
			return state
	
	return {}

func save_all_equipment_state(character_id: int, equipment_states: Dictionary) -> bool:
	## Save state for all equipped weapons
	## equipment_states: { slot_name: { inventory_id: int, state: Dictionary } }
	if not db_manager or not db_manager.is_open:
		return false
	
	for slot_name in equipment_states:
		var data = equipment_states[slot_name]
		if data.has("inventory_id") and data.has("state"):
			save_weapon_state(data.inventory_id, data.state)
	
	print("[ItemDatabase] Saved all equipment state for character ", character_id)
	return true
#endregion

