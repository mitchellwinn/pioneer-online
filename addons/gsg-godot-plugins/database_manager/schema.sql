-- Game Database Schema
-- Primary key: Steam ID (SteamID64)
-- Designed for server-authoritative live service games

-- Enable optimizations
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ============================================================================
-- PLAYERS TABLE
-- Core player account data, keyed by Steam ID
-- ============================================================================
CREATE TABLE IF NOT EXISTS players (
    steam_id INTEGER PRIMARY KEY,           -- SteamID64 (64-bit integer)
    display_name TEXT NOT NULL,             -- Steam display name
    created_at INTEGER NOT NULL,            -- Unix timestamp
    last_login INTEGER NOT NULL,            -- Unix timestamp
    total_playtime INTEGER DEFAULT 0,       -- Total playtime in seconds
    is_banned INTEGER DEFAULT 0,            -- Ban flag
    ban_reason TEXT,                        -- Reason for ban
    ban_expires INTEGER                     -- Unix timestamp (-1 for permanent)
);

-- ============================================================================
-- CHARACTERS TABLE
-- Player characters (multiple per account)
-- ============================================================================
CREATE TABLE IF NOT EXISTS characters (
    character_id INTEGER PRIMARY KEY AUTOINCREMENT,
    steam_id INTEGER NOT NULL,
    character_name TEXT NOT NULL,
    class_id TEXT NOT NULL,                 -- Class/archetype identifier
    level INTEGER DEFAULT 1,
    experience INTEGER DEFAULT 0,
    currency INTEGER DEFAULT 0,             -- Standard in-game currency
    premium_currency INTEGER DEFAULT 0,     -- Paid/premium currency
    inventory_json TEXT DEFAULT '{}',       -- JSON: {slot: {item_id, count, data}}
    equipment_json TEXT DEFAULT '{}',       -- JSON: {slot: item_id}
    stats_json TEXT DEFAULT '{}',           -- JSON: {stat_name: value}
    cosmetics_json TEXT DEFAULT '{}',       -- JSON: {slot: cosmetic_id}
    created_at INTEGER NOT NULL,
    last_played INTEGER NOT NULL,
    total_playtime INTEGER DEFAULT 0,
    is_deleted INTEGER DEFAULT 0,           -- Soft delete flag
    FOREIGN KEY (steam_id) REFERENCES players(steam_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_characters_steam_id ON characters(steam_id);
CREATE INDEX IF NOT EXISTS idx_characters_last_played ON characters(last_played DESC);

-- ============================================================================
-- TRANSACTIONS TABLE
-- Audit trail for all currency changes (gambling, purchases, rewards)
-- Server-signed for integrity verification
-- ============================================================================
CREATE TABLE IF NOT EXISTS transactions (
    transaction_id INTEGER PRIMARY KEY AUTOINCREMENT,
    steam_id INTEGER NOT NULL,
    character_id INTEGER,                   -- Nullable for account-level transactions
    transaction_type TEXT NOT NULL,         -- 'reward', 'purchase', 'gamble_bet', 'gamble_win', etc.
    currency_type TEXT DEFAULT 'standard',  -- 'standard' or 'premium'
    amount INTEGER NOT NULL,                -- Positive for gains, negative for losses
    balance_before INTEGER NOT NULL,
    balance_after INTEGER NOT NULL,
    description TEXT,
    metadata_json TEXT DEFAULT '{}',        -- Additional context data
    timestamp INTEGER NOT NULL,
    server_id TEXT,                         -- Which server processed this
    server_signature TEXT,                  -- HMAC signature for verification
    FOREIGN KEY (steam_id) REFERENCES players(steam_id) ON DELETE CASCADE,
    FOREIGN KEY (character_id) REFERENCES characters(character_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_transactions_steam_id ON transactions(steam_id);
CREATE INDEX IF NOT EXISTS idx_transactions_timestamp ON transactions(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_transactions_type ON transactions(transaction_type);

-- ============================================================================
-- MATCH HISTORY TABLE
-- Records of completed missions/matches
-- ============================================================================
CREATE TABLE IF NOT EXISTS match_history (
    match_id INTEGER PRIMARY KEY AUTOINCREMENT,
    steam_id INTEGER NOT NULL,
    character_id INTEGER NOT NULL,
    mission_id TEXT NOT NULL,               -- Mission/level identifier
    zone_id TEXT,                           -- Zone instance ID
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    result TEXT,                            -- 'completed', 'failed', 'abandoned'
    score INTEGER DEFAULT 0,
    rewards_json TEXT DEFAULT '{}',         -- JSON: {currency, items, exp}
    stats_json TEXT DEFAULT '{}',           -- JSON: {kills, deaths, damage, etc.}
    squad_members_json TEXT DEFAULT '[]',   -- JSON: [steam_id, steam_id, ...]
    FOREIGN KEY (steam_id) REFERENCES players(steam_id) ON DELETE CASCADE,
    FOREIGN KEY (character_id) REFERENCES characters(character_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_match_history_steam_id ON match_history(steam_id);
CREATE INDEX IF NOT EXISTS idx_match_history_mission ON match_history(mission_id);
CREATE INDEX IF NOT EXISTS idx_match_history_started ON match_history(started_at DESC);

-- ============================================================================
-- LEADERBOARDS TABLE
-- Persistent leaderboard scores
-- ============================================================================
CREATE TABLE IF NOT EXISTS leaderboards (
    leaderboard_id INTEGER PRIMARY KEY AUTOINCREMENT,
    leaderboard_name TEXT NOT NULL,         -- 'weekly_kills', 'mission_speedrun', etc.
    steam_id INTEGER NOT NULL,
    character_id INTEGER,
    score INTEGER NOT NULL,
    rank INTEGER,                           -- Cached rank (updated periodically)
    metadata_json TEXT DEFAULT '{}',        -- Additional score context
    submitted_at INTEGER NOT NULL,
    FOREIGN KEY (steam_id) REFERENCES players(steam_id) ON DELETE CASCADE,
    UNIQUE(leaderboard_name, steam_id)
);

CREATE INDEX IF NOT EXISTS idx_leaderboards_name_score ON leaderboards(leaderboard_name, score DESC);

-- ============================================================================
-- INVENTORY ITEMS TABLE (Optional - for relational inventory)
-- Use this instead of inventory_json for complex item systems
-- ============================================================================
-- CREATE TABLE IF NOT EXISTS inventory_items (
--     item_instance_id INTEGER PRIMARY KEY AUTOINCREMENT,
--     character_id INTEGER NOT NULL,
--     item_def_id TEXT NOT NULL,           -- Reference to item definition
--     quantity INTEGER DEFAULT 1,
--     durability INTEGER,
--     enchantments_json TEXT DEFAULT '{}',
--     acquired_at INTEGER NOT NULL,
--     acquired_from TEXT,                  -- 'drop', 'purchase', 'trade', 'craft'
--     is_equipped INTEGER DEFAULT 0,
--     equipped_slot TEXT,
--     FOREIGN KEY (character_id) REFERENCES characters(character_id) ON DELETE CASCADE
-- );
-- 
-- CREATE INDEX IF NOT EXISTS idx_inventory_character ON inventory_items(character_id);

-- ============================================================================
-- SOCIAL TABLE (Optional - for friends/guilds)
-- ============================================================================
-- CREATE TABLE IF NOT EXISTS friends (
--     steam_id_1 INTEGER NOT NULL,
--     steam_id_2 INTEGER NOT NULL,
--     status TEXT DEFAULT 'pending',       -- 'pending', 'accepted', 'blocked'
--     created_at INTEGER NOT NULL,
--     PRIMARY KEY (steam_id_1, steam_id_2),
--     FOREIGN KEY (steam_id_1) REFERENCES players(steam_id),
--     FOREIGN KEY (steam_id_2) REFERENCES players(steam_id)
-- );

-- ============================================================================
-- USEFUL VIEWS
-- ============================================================================

-- Active players view
CREATE VIEW IF NOT EXISTS active_players AS
SELECT p.*, COUNT(c.character_id) as character_count
FROM players p
LEFT JOIN characters c ON p.steam_id = c.steam_id AND c.is_deleted = 0
WHERE p.is_banned = 0
GROUP BY p.steam_id;

-- Player currency totals view
CREATE VIEW IF NOT EXISTS player_currency AS
SELECT 
    p.steam_id,
    p.display_name,
    COALESCE(SUM(c.currency), 0) as total_currency,
    COALESCE(SUM(c.premium_currency), 0) as total_premium_currency
FROM players p
LEFT JOIN characters c ON p.steam_id = c.steam_id AND c.is_deleted = 0
GROUP BY p.steam_id;

-- Transaction summary view
CREATE VIEW IF NOT EXISTS transaction_summary AS
SELECT 
    steam_id,
    transaction_type,
    currency_type,
    COUNT(*) as transaction_count,
    SUM(amount) as total_amount,
    MIN(timestamp) as first_transaction,
    MAX(timestamp) as last_transaction
FROM transactions
GROUP BY steam_id, transaction_type, currency_type;

