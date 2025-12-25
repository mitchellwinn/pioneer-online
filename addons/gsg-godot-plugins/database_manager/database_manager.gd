extends Node

## DatabaseManager - SQLite database abstraction for player data and transactions
## Uses Steam ID as primary key for all player-related data

#region Signals
signal database_opened(path: String)
signal database_closed()
signal player_created(steam_id: int)
signal player_loaded(steam_id: int, data: Dictionary)
signal character_created(steam_id: int, character_id: int)
signal transaction_recorded(transaction_id: int)
signal query_error(error: String)
#endregion

#region Configuration
@export var database_path: String = "user://game_data.db"
@export var auto_open: bool = true
@export var enable_foreign_keys: bool = true
@export var enable_wal_mode: bool = true # Better concurrent performance
#endregion

#region Database State
var db = null # SQLite instance (typed dynamically to avoid parse errors)
var is_open: bool = false
var _sqlite_available: bool = false
var _mock_mode: bool = false
var _mock_data: Dictionary = {} # Fallback storage when SQLite unavailable
#endregion

func _ready():
	_check_sqlite_available()
	if auto_open:
		open_database()

func _exit_tree():
	close_database()

func _check_sqlite_available():
	_sqlite_available = ClassDB.class_exists("SQLite")
	if not _sqlite_available:
		push_warning("[DatabaseManager] godot-sqlite addon not found or not enabled.")
		push_warning("[DatabaseManager] Install from: https://github.com/2shady4u/godot-sqlite")
		push_warning("[DatabaseManager] Running in MOCK mode - data will not persist!")
		_mock_mode = true

#region Database Connection
func open_database(path: String = "") -> bool:
	if is_open:
		close_database()
	
	if path == "":
		path = database_path
	
	# Mock mode fallback
	if _mock_mode:
		is_open = true
		print("[DatabaseManager] Mock mode active - no persistence")
		database_opened.emit(path)
		return true
	
	# Real SQLite
	db = ClassDB.instantiate("SQLite")
	db.path = path
	db.verbosity_level = 0 # QUIET
	
	if not db.open_db():
		push_error("[DatabaseManager] Failed to open database: ", path)
		query_error.emit("Failed to open database")
		return false
	
	is_open = true
	
	# Enable optimizations
	if enable_foreign_keys:
		db.query("PRAGMA foreign_keys = ON;")
	
	if enable_wal_mode:
		db.query("PRAGMA journal_mode = WAL;")
	
	# Initialize schema
	_create_tables()
	
	print("[DatabaseManager] Database opened: ", path)
	database_opened.emit(path)
	return true

func close_database():
	if db and is_open:
		db.close_db()
		is_open = false
		database_closed.emit()
		print("[DatabaseManager] Database closed")
#endregion

#region Schema Creation
func _create_tables():
	# Players table - Steam ID is primary key
	db.query("""
		CREATE TABLE IF NOT EXISTS players (
			steam_id INTEGER PRIMARY KEY,
			display_name TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			last_login INTEGER NOT NULL,
			total_playtime INTEGER DEFAULT 0,
			is_banned INTEGER DEFAULT 0,
			ban_reason TEXT,
			ban_expires INTEGER
		);
	""")
	
	# Characters table
	db.query("""
		CREATE TABLE IF NOT EXISTS characters (
			character_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_name TEXT NOT NULL,
			class_id TEXT NOT NULL,
			level INTEGER DEFAULT 1,
			experience INTEGER DEFAULT 0,
			currency INTEGER DEFAULT 0,
			premium_currency INTEGER DEFAULT 0,
			inventory_json TEXT DEFAULT '{}',
			equipment_json TEXT DEFAULT '{}',
			stats_json TEXT DEFAULT '{}',
			cosmetics_json TEXT DEFAULT '{}',
			created_at INTEGER NOT NULL,
			last_played INTEGER NOT NULL,
			total_playtime INTEGER DEFAULT 0,
			is_deleted INTEGER DEFAULT 0,
			FOREIGN KEY (steam_id) REFERENCES players(steam_id)
		);
	""")
	
	# Create index for character lookups
	db.query("CREATE INDEX IF NOT EXISTS idx_characters_steam_id ON characters(steam_id);")
	
	# Transactions table - for gambling/economy audit trail
	db.query("""
		CREATE TABLE IF NOT EXISTS transactions (
			transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER,
			transaction_type TEXT NOT NULL,
			currency_type TEXT DEFAULT 'standard',
			amount INTEGER NOT NULL,
			balance_before INTEGER NOT NULL,
			balance_after INTEGER NOT NULL,
			description TEXT,
			metadata_json TEXT DEFAULT '{}',
			timestamp INTEGER NOT NULL,
			server_id TEXT,
			server_signature TEXT,
			FOREIGN KEY (steam_id) REFERENCES players(steam_id),
			FOREIGN KEY (character_id) REFERENCES characters(character_id)
		);
	""")
	
	# Create indexes for transaction lookups
	db.query("CREATE INDEX IF NOT EXISTS idx_transactions_steam_id ON transactions(steam_id);")
	db.query("CREATE INDEX IF NOT EXISTS idx_transactions_timestamp ON transactions(timestamp);")
	db.query("CREATE INDEX IF NOT EXISTS idx_transactions_type ON transactions(transaction_type);")
	
	# Match history table
	db.query("""
		CREATE TABLE IF NOT EXISTS match_history (
			match_id INTEGER PRIMARY KEY AUTOINCREMENT,
			steam_id INTEGER NOT NULL,
			character_id INTEGER NOT NULL,
			mission_id TEXT NOT NULL,
			zone_id TEXT,
			started_at INTEGER NOT NULL,
			ended_at INTEGER,
			result TEXT,
			score INTEGER DEFAULT 0,
			rewards_json TEXT DEFAULT '{}',
			stats_json TEXT DEFAULT '{}',
			squad_members_json TEXT DEFAULT '[]',
			FOREIGN KEY (steam_id) REFERENCES players(steam_id),
			FOREIGN KEY (character_id) REFERENCES characters(character_id)
		);
	""")
	
	db.query("CREATE INDEX IF NOT EXISTS idx_match_history_steam_id ON match_history(steam_id);")
	
	# Leaderboards table
	db.query("""
		CREATE TABLE IF NOT EXISTS leaderboards (
			leaderboard_id INTEGER PRIMARY KEY AUTOINCREMENT,
			leaderboard_name TEXT NOT NULL,
			steam_id INTEGER NOT NULL,
			character_id INTEGER,
			score INTEGER NOT NULL,
			rank INTEGER,
			metadata_json TEXT DEFAULT '{}',
			submitted_at INTEGER NOT NULL,
			FOREIGN KEY (steam_id) REFERENCES players(steam_id),
			UNIQUE(leaderboard_name, steam_id)
		);
	""")
	
	db.query("CREATE INDEX IF NOT EXISTS idx_leaderboards_name_score ON leaderboards(leaderboard_name, score DESC);")
	
	print("[DatabaseManager] Tables created/verified")
#endregion

#region Player Management
func create_player(steam_id: int, display_name: String) -> bool:
	if not is_open:
		return false
	
	var now = Time.get_unix_time_from_system()
	
	var success = db.query_with_bindings("""
		INSERT OR IGNORE INTO players (steam_id, display_name, created_at, last_login)
		VALUES (?, ?, ?, ?);
	""", [steam_id, display_name, now, now])
	
	if success:
		player_created.emit(steam_id)
	
	return success

func get_player(steam_id: int) -> Dictionary:
	if not is_open:
		return {}
	
	db.query_with_bindings("SELECT * FROM players WHERE steam_id = ?;", [steam_id])
	
	if db.query_result.size() > 0:
		var data = db.query_result[0]
		player_loaded.emit(steam_id, data)
		return data
	
	return {}

func update_player_login(steam_id: int) -> bool:
	if not is_open:
		return false
	
	var now = Time.get_unix_time_from_system()
	return db.query_with_bindings("""
		UPDATE players SET last_login = ? WHERE steam_id = ?;
	""", [now, steam_id])

func ban_player(steam_id: int, reason: String, duration_hours: int = -1) -> bool:
	if not is_open:
		return false
	
	var expires = -1
	if duration_hours > 0:
		expires = Time.get_unix_time_from_system() + (duration_hours * 3600)
	
	return db.query_with_bindings("""
		UPDATE players SET is_banned = 1, ban_reason = ?, ban_expires = ?
		WHERE steam_id = ?;
	""", [reason, expires, steam_id])

func unban_player(steam_id: int) -> bool:
	if not is_open:
		return false
	
	return db.query_with_bindings("""
		UPDATE players SET is_banned = 0, ban_reason = NULL, ban_expires = NULL
		WHERE steam_id = ?;
	""", [steam_id])

func is_player_banned(steam_id: int) -> Dictionary:
	if not is_open:
		return {"banned": false}
	
	db.query_with_bindings("""
		SELECT is_banned, ban_reason, ban_expires FROM players WHERE steam_id = ?;
	""", [steam_id])
	
	if db.query_result.size() == 0:
		return {"banned": false}
	
	var row = db.query_result[0]
	var is_banned = row.is_banned == 1
	
	# Check if temp ban expired
	if is_banned and row.ban_expires > 0:
		var now = Time.get_unix_time_from_system()
		if now >= row.ban_expires:
			unban_player(steam_id)
			return {"banned": false}
	
	return {
		"banned": is_banned,
		"reason": row.get("ban_reason", ""),
		"expires": row.get("ban_expires", -1)
	}
#endregion

#region Character Management
func create_character(steam_id: int, character_name: String, class_id: String) -> int:
	if not is_open:
		return -1
	
	var now = Time.get_unix_time_from_system()
	
	var success = db.query_with_bindings("""
		INSERT INTO characters (steam_id, character_name, class_id, created_at, last_played)
		VALUES (?, ?, ?, ?, ?);
	""", [steam_id, character_name, class_id, now, now])
	
	if success:
		# Get the created character ID
		db.query("SELECT last_insert_rowid() as id;")
		if db.query_result.size() > 0:
			var character_id = db.query_result[0].id
			character_created.emit(steam_id, character_id)
			return character_id
	
	return -1

func get_characters(steam_id: int) -> Array:
	if not is_open:
		return []
	
	db.query_with_bindings("""
		SELECT * FROM characters WHERE steam_id = ? AND is_deleted = 0
		ORDER BY last_played DESC;
	""", [steam_id])
	
	return db.query_result.duplicate()

func get_character(character_id: int) -> Dictionary:
	if not is_open:
		return {}
	
	db.query_with_bindings("SELECT * FROM characters WHERE character_id = ?;", [character_id])
	
	if db.query_result.size() > 0:
		return db.query_result[0]
	
	return {}

func update_character(character_id: int, data: Dictionary) -> bool:
	if not is_open:
		return false
	
	var updates = []
	var values = []
	
	for key in data:
		if key in ["level", "experience", "currency", "premium_currency",
				   "inventory_json", "equipment_json", "stats_json", "cosmetics_json"]:
			updates.append(key + " = ?")
			values.append(data[key])
	
	if updates.size() == 0:
		return true
	
	values.append(character_id)
	
	var query = "UPDATE characters SET " + ", ".join(updates) + " WHERE character_id = ?;"
	return db.query_with_bindings(query, values)

func delete_character(character_id: int, soft_delete: bool = true) -> bool:
	if not is_open:
		return false
	
	if soft_delete:
		return db.query_with_bindings("""
			UPDATE characters SET is_deleted = 1 WHERE character_id = ?;
		""", [character_id])
	else:
		return db.query_with_bindings("DELETE FROM characters WHERE character_id = ?;", [character_id])

func add_currency(character_id: int, amount: int, currency_type: String = "standard",
				  transaction_type: String = "reward", description: String = "") -> bool:
	if not is_open:
		return false
	
	# Get current balance
	var character = get_character(character_id)
	if character.is_empty():
		return false
	
	var balance_field = "currency" if currency_type == "standard" else "premium_currency"
	var balance_before = character.get(balance_field, 0)
	var balance_after = balance_before + amount
	
	if balance_after < 0:
		return false # Insufficient funds
	
	# Update balance
	var update_success = db.query_with_bindings(
		"UPDATE characters SET " + balance_field + " = ? WHERE character_id = ?;",
		[balance_after, character_id]
	)
	
	if update_success:
		# Record transaction
		record_transaction(character.steam_id, character_id, transaction_type,
						   currency_type, amount, balance_before, balance_after, description)
	
	return update_success
#endregion

#region Transaction Logging
func record_transaction(steam_id: int, character_id: int, transaction_type: String,
						currency_type: String, amount: int, balance_before: int,
						balance_after: int, description: String = "",
						metadata: Dictionary = {}, server_id: String = "") -> int:
	if not is_open:
		return -1
	
	var now = Time.get_unix_time_from_system()
	var metadata_json = JSON.stringify(metadata)
	var signature = _generate_server_signature(steam_id, amount, now)
	
	var success = db.query_with_bindings("""
		INSERT INTO transactions 
		(steam_id, character_id, transaction_type, currency_type, amount,
		 balance_before, balance_after, description, metadata_json, 
		 timestamp, server_id, server_signature)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
	""", [steam_id, character_id, transaction_type, currency_type, amount,
		  balance_before, balance_after, description, metadata_json,
		  now, server_id, signature])
	
	if success:
		db.query("SELECT last_insert_rowid() as id;")
		if db.query_result.size() > 0:
			var transaction_id = db.query_result[0].id
			transaction_recorded.emit(transaction_id)
			return transaction_id
	
	return -1

func get_transactions(steam_id: int, limit: int = 100, offset: int = 0) -> Array:
	if not is_open:
		return []
	
	db.query_with_bindings("""
		SELECT * FROM transactions WHERE steam_id = ?
		ORDER BY timestamp DESC LIMIT ? OFFSET ?;
	""", [steam_id, limit, offset])
	
	return db.query_result.duplicate()

func get_transactions_by_type(steam_id: int, transaction_type: String,
							   limit: int = 100) -> Array:
	if not is_open:
		return []
	
	db.query_with_bindings("""
		SELECT * FROM transactions 
		WHERE steam_id = ? AND transaction_type = ?
		ORDER BY timestamp DESC LIMIT ?;
	""", [steam_id, transaction_type, limit])
	
	return db.query_result.duplicate()

func _generate_server_signature(steam_id: int, amount: int, timestamp: int) -> String:
	# Simple signature for verification - in production use proper HMAC
	var data = str(steam_id) + str(amount) + str(timestamp) + "server_secret"
	return data.sha256_text()
#endregion

#region Match History
func start_match(steam_id: int, character_id: int, mission_id: String,
				 zone_id: String = "", squad_members: Array = []) -> int:
	if not is_open:
		return -1
	
	var now = Time.get_unix_time_from_system()
	var squad_json = JSON.stringify(squad_members)
	
	var success = db.query_with_bindings("""
		INSERT INTO match_history 
		(steam_id, character_id, mission_id, zone_id, started_at, squad_members_json)
		VALUES (?, ?, ?, ?, ?, ?);
	""", [steam_id, character_id, mission_id, zone_id, now, squad_json])
	
	if success:
		db.query("SELECT last_insert_rowid() as id;")
		if db.query_result.size() > 0:
			return db.query_result[0].id
	
	return -1

func end_match(match_id: int, result: String, score: int = 0,
			   rewards: Dictionary = {}, stats: Dictionary = {}) -> bool:
	if not is_open:
		return false
	
	var now = Time.get_unix_time_from_system()
	var rewards_json = JSON.stringify(rewards)
	var stats_json = JSON.stringify(stats)
	
	return db.query_with_bindings("""
		UPDATE match_history SET 
		ended_at = ?, result = ?, score = ?, rewards_json = ?, stats_json = ?
		WHERE match_id = ?;
	""", [now, result, score, rewards_json, stats_json, match_id])

func get_match_history(steam_id: int, limit: int = 50) -> Array:
	if not is_open:
		return []
	
	db.query_with_bindings("""
		SELECT * FROM match_history WHERE steam_id = ?
		ORDER BY started_at DESC LIMIT ?;
	""", [steam_id, limit])
	
	return db.query_result.duplicate()
#endregion

#region Leaderboards
func submit_score(leaderboard_name: String, steam_id: int, score: int,
				  character_id: int = -1, metadata: Dictionary = {}) -> bool:
	if not is_open:
		return false
	
	var now = Time.get_unix_time_from_system()
	var metadata_json = JSON.stringify(metadata)
	
	# Upsert - update if higher score
	return db.query_with_bindings("""
		INSERT INTO leaderboards (leaderboard_name, steam_id, character_id, score, metadata_json, submitted_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(leaderboard_name, steam_id) DO UPDATE SET
		score = CASE WHEN excluded.score > score THEN excluded.score ELSE score END,
		metadata_json = CASE WHEN excluded.score > score THEN excluded.metadata_json ELSE metadata_json END,
		submitted_at = CASE WHEN excluded.score > score THEN excluded.submitted_at ELSE submitted_at END;
	""", [leaderboard_name, steam_id, character_id, score, metadata_json, now])

func get_leaderboard(leaderboard_name: String, limit: int = 100, offset: int = 0) -> Array:
	if not is_open:
		return []
	
	db.query_with_bindings("""
		SELECT l.*, p.display_name 
		FROM leaderboards l
		JOIN players p ON l.steam_id = p.steam_id
		WHERE l.leaderboard_name = ?
		ORDER BY l.score DESC
		LIMIT ? OFFSET ?;
	""", [leaderboard_name, limit, offset])
	
	return db.query_result.duplicate()

func get_player_rank(leaderboard_name: String, steam_id: int) -> Dictionary:
	if not is_open:
		return {}
	
	db.query_with_bindings("""
		SELECT score,
		(SELECT COUNT(*) + 1 FROM leaderboards 
		 WHERE leaderboard_name = ? AND score > l.score) as rank
		FROM leaderboards l
		WHERE leaderboard_name = ? AND steam_id = ?;
	""", [leaderboard_name, leaderboard_name, steam_id])
	
	if db.query_result.size() > 0:
		return db.query_result[0]
	
	return {}
#endregion

#region Utility
func execute_query(query: String, bindings: Array = []) -> Array:
	if not is_open:
		return []
	
	if bindings.size() > 0:
		db.query_with_bindings(query, bindings)
	else:
		db.query(query)
	
	return db.query_result.duplicate()

func backup_database(backup_path: String) -> bool:
	if not is_open:
		return false
	
	# Use SQLite backup API via query
	return db.query_with_bindings("VACUUM INTO ?;", [backup_path])
#endregion
