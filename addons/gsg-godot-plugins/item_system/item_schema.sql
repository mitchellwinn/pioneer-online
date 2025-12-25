-- Item System Schema
-- Items are loaded from JSON and stored in SQLite for runtime queries

-- Base item definitions
CREATE TABLE IF NOT EXISTS items (
    item_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    type TEXT NOT NULL,
    subtype TEXT,
    size TEXT DEFAULT 'medium',
    rarity TEXT DEFAULT 'common',
    base_value INTEGER DEFAULT 0,
    prefab_path TEXT,
    holster_slot TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
CREATE INDEX IF NOT EXISTS idx_items_subtype ON items(subtype);

-- Weapon-specific stats (linked to items table)
CREATE TABLE IF NOT EXISTS weapon_stats (
    item_id TEXT PRIMARY KEY,
    damage REAL DEFAULT 10.0,
    damage_type TEXT DEFAULT 'kinetic',
    fire_rate REAL DEFAULT 5.0,
    fire_mode TEXT DEFAULT 'semi',
    range REAL DEFAULT 50.0,
    clip_size INTEGER DEFAULT 10,
    max_ammo INTEGER DEFAULT 100,
    reload_type TEXT DEFAULT 'magazine',
    reload_time REAL DEFAULT 2.0,
    heat_per_shot REAL DEFAULT 0,
    overheat_threshold REAL DEFAULT 100.0,
    cooldown_rate REAL DEFAULT 30.0,
    overheat_lockout REAL DEFAULT 2.0,
    projectile_prefab TEXT,
    muzzle_velocity REAL DEFAULT 100.0,
    spread_hip REAL DEFAULT 3.0,
    spread_aim REAL DEFAULT 1.0,
    recoil_vertical REAL DEFAULT 2.0,
    recoil_horizontal REAL DEFAULT 1.0,
    aim_zoom REAL DEFAULT 1.2,
    aim_time REAL DEFAULT 0.2,
    FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE CASCADE
);

-- Player inventory (items owned by players)
-- NOTE: No foreign key on item_id because items are loaded from JSON, not stored in SQL
CREATE TABLE IF NOT EXISTS player_inventory (
    inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,
    steam_id INTEGER NOT NULL,
    character_id INTEGER NOT NULL,
    item_id TEXT NOT NULL,
    quantity INTEGER DEFAULT 1,
    acquired_at INTEGER NOT NULL,
    instance_data_json TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_inventory_steam ON player_inventory(steam_id);
CREATE INDEX IF NOT EXISTS idx_inventory_character ON player_inventory(character_id);
CREATE INDEX IF NOT EXISTS idx_inventory_item ON player_inventory(item_id);

-- Player equipment (currently equipped items)
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

CREATE INDEX IF NOT EXISTS idx_equipment_character ON player_equipment(character_id);

-- Holster slot configuration
CREATE TABLE IF NOT EXISTS holster_slots (
    slot_id TEXT PRIMARY KEY,
    size_category TEXT NOT NULL,
    bone_attachment TEXT,
    position_offset_json TEXT DEFAULT '{"x": 0, "y": 0, "z": 0}',
    rotation_offset_json TEXT DEFAULT '{"x": 0, "y": 0, "z": 0}'
);

-- Equipment slot configuration
CREATE TABLE IF NOT EXISTS equipment_slots (
    slot_name TEXT PRIMARY KEY,
    max_size TEXT NOT NULL,
    description TEXT
);


