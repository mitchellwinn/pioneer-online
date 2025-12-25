# Database Manager Plugin

SQLite database abstraction layer for player data, character management, and server-validated transactions. Uses Steam ID as the primary key for all player-related data.

## Features

- **Steam ID as Primary Key** - No separate account system needed
- **Character Management** - Multiple characters per player
- **Transaction Logging** - Full audit trail for currency changes
- **Match History** - Track mission completions and stats
- **Leaderboards** - Persistent score tracking
- **Server Signatures** - Verify transaction integrity

## Installation

1. Copy `database_manager` to your project's `addons/` folder
2. Enable **Database Manager** in **Project → Project Settings → Plugins**
3. DatabaseManager autoload is added automatically

**Note:** Requires [godot-sqlite](https://github.com/2shady4u/godot-sqlite) addon.

## Quick Start

### Opening Database

```gdscript
# Auto-opens on ready, or manually:
DatabaseManager.open_database("user://my_game.db")

# Check status
if DatabaseManager.is_open:
    print("Database ready!")
```

### Player Management

```gdscript
# Create player from Steam ID
var steam_id = Steam.getSteamID()
DatabaseManager.create_player(steam_id, Steam.getPersonaName())

# Load player data
var player = DatabaseManager.get_player(steam_id)
print("Welcome back, ", player.display_name)

# Update login time
DatabaseManager.update_player_login(steam_id)
```

### Character Management

```gdscript
# Create character
var character_id = DatabaseManager.create_character(
    steam_id, 
    "MyCharacter", 
    "warrior"
)

# Get all characters
var characters = DatabaseManager.get_characters(steam_id)
for char in characters:
    print(char.character_name, " - Level ", char.level)

# Update character
DatabaseManager.update_character(character_id, {
    "level": 10,
    "experience": 5000,
    "equipment_json": JSON.stringify({"weapon": "sword_01"})
})
```

### Currency & Transactions

```gdscript
# Add currency (automatically logs transaction)
DatabaseManager.add_currency(
    character_id,
    1000,                    # amount
    "standard",              # currency_type
    "mission_reward",        # transaction_type
    "Completed Mission 1"    # description
)

# View transaction history
var transactions = DatabaseManager.get_transactions(steam_id, 50)
for t in transactions:
    print(t.transaction_type, ": ", t.amount)

# Get gambling transactions specifically
var gambles = DatabaseManager.get_transactions_by_type(steam_id, "gamble_bet")
```

### Match History

```gdscript
# Start a match
var match_id = DatabaseManager.start_match(
    steam_id,
    character_id,
    "mission_01",
    zone_id,
    [squad_member_1, squad_member_2]  # Steam IDs
)

# End match with results
DatabaseManager.end_match(
    match_id,
    "completed",  # result
    15000,        # score
    {"currency": 500, "exp": 1000},  # rewards
    {"kills": 25, "deaths": 2}       # stats
)

# Get history
var history = DatabaseManager.get_match_history(steam_id, 20)
```

### Leaderboards

```gdscript
# Submit score
DatabaseManager.submit_score(
    "weekly_kills",
    steam_id,
    150,  # score
    character_id
)

# Get leaderboard
var top_players = DatabaseManager.get_leaderboard("weekly_kills", 100)
for i in range(top_players.size()):
    var entry = top_players[i]
    print("#", i + 1, " ", entry.display_name, ": ", entry.score)

# Get player's rank
var rank_info = DatabaseManager.get_player_rank("weekly_kills", steam_id)
print("Your rank: #", rank_info.rank, " with score ", rank_info.score)
```

## Schema

### Players Table

| Column | Type | Description |
|--------|------|-------------|
| steam_id | INTEGER | Primary key (SteamID64) |
| display_name | TEXT | Steam persona name |
| created_at | INTEGER | Unix timestamp |
| last_login | INTEGER | Unix timestamp |
| is_banned | INTEGER | Ban flag |
| ban_reason | TEXT | Ban reason if banned |
| ban_expires | INTEGER | Ban expiry timestamp |

### Characters Table

| Column | Type | Description |
|--------|------|-------------|
| character_id | INTEGER | Primary key |
| steam_id | INTEGER | Foreign key to players |
| character_name | TEXT | Character name |
| class_id | TEXT | Class/archetype |
| level | INTEGER | Character level |
| currency | INTEGER | In-game currency |
| premium_currency | INTEGER | Premium currency |
| inventory_json | TEXT | Inventory data |
| stats_json | TEXT | Character stats |

### Transactions Table

| Column | Type | Description |
|--------|------|-------------|
| transaction_id | INTEGER | Primary key |
| steam_id | INTEGER | Player Steam ID |
| transaction_type | TEXT | Type of transaction |
| amount | INTEGER | Amount changed |
| balance_before | INTEGER | Balance before |
| balance_after | INTEGER | Balance after |
| server_signature | TEXT | Integrity signature |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `database_path` | `user://game_data.db` | Database file location |
| `auto_open` | `true` | Open on ready |
| `enable_foreign_keys` | `true` | Enforce referential integrity |
| `enable_wal_mode` | `true` | Better concurrency |

## Banning Players

```gdscript
# Permanent ban
DatabaseManager.ban_player(steam_id, "Cheating")

# Temporary ban (24 hours)
DatabaseManager.ban_player(steam_id, "Toxic behavior", 24)

# Check ban status
var ban_info = DatabaseManager.is_player_banned(steam_id)
if ban_info.banned:
    print("Banned: ", ban_info.reason)
```

## Server Integration

Transactions include server signatures for verification:

```gdscript
# Server validates transaction before recording
func process_gambling(steam_id: int, bet_amount: int):
    var character = DatabaseManager.get_character(current_character_id)
    
    if character.currency < bet_amount:
        return {"error": "Insufficient funds"}
    
    # Deduct bet (records transaction with server signature)
    DatabaseManager.add_currency(
        character_id, 
        -bet_amount,
        "standard",
        "gamble_bet",
        "Slot machine bet"
    )
    
    # Calculate result...
    var winnings = calculate_slot_result(bet_amount)
    
    if winnings > 0:
        DatabaseManager.add_currency(
            character_id,
            winnings,
            "standard", 
            "gamble_win",
            "Slot machine win"
        )
```

## Migration to PostgreSQL

The schema is designed for easy migration:
- SQLite INTEGER maps to PostgreSQL BIGINT
- JSON columns work in both
- Indexes are compatible
- See `schema.sql` for full schema

## License

Provided as-is for use in any project.

