# Data Manager Plugin

A configurable data management system for loading and managing game data from JSON/XML files. Uses the DataParser plugin under the hood and supports custom data loading configurations.

## Features

- **Auto-loading**: Automatically loads data from configuration scripts
- **Flexible**: Define your own data categories and loading logic
- **Property Access**: Access data categories like `DataManager.talents` or `DataManager.skills`
- **Merge Support**: Merge data from multiple sources (e.g., numerical + language-specific)
- **Backwards Compatible**: Can replace existing JsonData singleton

## Installation

1. Make sure the `data_parser` plugin is installed and enabled
2. Copy the `data_manager` folder to your project's `addons/gsg-godot-plugins/` directory
3. Enable the "Data Manager" plugin in Project Settings → Plugins
4. The `DataManager` autoload will be automatically registered
5. Create a `res://data_configs/` folder for your data configuration scripts

## Usage

### Creating Data Configuration Scripts

Data configurations are GDScript files placed in `res://data_configs/` that define what data to load and how to organize it.

#### Example 1: Basic Configuration

**res://data_configs/basic_game_data.gd:**
```gdscript
extends Node

func configure_data(manager):
	# Register categories
	manager.register_category("items")
	manager.register_category("enemies")
	manager.register_category("skills")
	
	# Load JSON files into categories
	manager.load_json_file("res://data/items.json", "items")
	manager.load_json_folder("res://data/enemies", "enemies")
	manager.load_json_folder("res://data/skills", "skills")
```

#### Example 2: Multi-Language Configuration

**res://data_configs/multilanguage_data.gd:**
```gdscript
extends Node

func configure_data(manager):
	var language = "english"  # Get from GameManager or settings
	
	# Register all categories
	var categories = ["items", "enemies", "skills", "talents", "dialogue"]
	for cat in categories:
		manager.register_category(cat)
	
	# Base path for language data
	var lang_path = "res://data/languages/%s" % language
	var numerical_path = "res://data/numerical"
	
	# Load numerical data first (stats, values)
	manager.load_json_folder(numerical_path + "/items", "items")
	manager.load_json_folder(numerical_path + "/enemies", "enemies")
	
	# Then load language-specific data (names, descriptions) - merges with numerical
	manager.load_json_folder(lang_path + "/items", "items")
	manager.load_json_folder(lang_path + "/enemies", "enemies")
```

#### Example 3: YGBF-Style Configuration (JsonData Replacement)

**res://data_configs/ygbf_data.gd:**
```gdscript
extends Node

func configure_data(manager):
	var language = GameManager.game_language if GameManager else "english"
	
	# Register all categories (matching JsonData properties)
	var categories = [
		"talents", "skills", "enemies", "party_members", "shops",
		"enemy_troops", "battle", "misc", "items", "menu",
		"battle_backgrounds", "personalities", "damage_number_materials",
		"battle_portrait_shader_profiles", "buffs", "general_data",
		"options", "songs", "npc_sprites", "npc_active_dialogue",
		"map_markers", "menus", "battle_menus", "overworld_motions", "inventory"
	]
	
	for cat in categories:
		manager.register_category(cat)
	
	# Paths
	var lang_base = "res://scripts/json_data/%s" % language
	var num_base = "res://scripts/json_data/numerical_data"
	
	# Load talents
	manager.load_json_folder(lang_base + "/talents", "talents")
	
	# Load personalities
	manager.load_json_file(lang_base + "/personalities.json", "personalities")
	
	# Load skills (numerical + language)
	manager.load_json_folder(lang_base + "/skills", "skills")
	manager.load_json_folder(num_base + "/skills", "skills")
	
	# Load enemies (numerical + language)
	manager.load_json_folder(lang_base + "/enemies", "enemies")
	manager.load_json_folder(num_base + "/enemies", "enemies")
	
	# Load party_members (numerical first, then language overlay)
	manager.load_json_folder(num_base + "/party_members", "party_members")
	manager.load_json_folder(lang_base + "/party_members", "party_members")
	
	# Load shops
	manager.load_json_folder(lang_base + "/shops", "shops")
	manager.load_json_folder(num_base + "/shops", "shops")
	
	# Load items
	manager.load_json_folder(lang_base + "/items", "items")
	manager.load_json_folder(num_base + "/items", "items")
	
	# Load enemy troops
	manager.load_json_file(lang_base + "/enemy_troops.json", "enemy_troops")
	manager.load_json_file(num_base + "/enemy_troops.json", "enemy_troops")
	
	# Load battle backgrounds
	manager.load_json_file(num_base + "/battle_backgrounds.json", "battle_backgrounds")
	
	# Load damage number materials
	manager.load_json_file(num_base + "/damage_number_materials.json", "damage_number_materials")
	
	# Load battle portrait shader profiles
	manager.load_json_file(num_base + "/battle_portrait_shader_profiles.json", "battle_portrait_shader_profiles")
	
	# Load buffs (numerical + language)
	manager.load_json_file(num_base + "/buffs.json", "buffs")
	manager.load_json_file(lang_base + "/buffs.json", "buffs")
	
	# Load battle/menu/misc text
	manager.load_json_file(lang_base + "/battle.json", "battle")
	manager.load_json_file(lang_base + "/menu.json", "menu")
	manager.load_json_file(lang_base + "/miscelaneous.json", "misc")
	manager.load_json_file(lang_base + "/options.json", "options")
	
	# Load NPC data
	manager.load_json_file(num_base + "/npc_sprites.json", "npc_sprites")
	manager.load_json_file(num_base + "/npc_active_dialogue.json", "npc_active_dialogue")
	
	# Load map markers
	manager.load_json_folder(num_base + "/map_markers", "map_markers")
	
	# Load menus
	manager.load_json_folder(num_base + "/menus", "menus")
	manager.load_json_folder(num_base + "/battle_menus", "battle_menus")
	
	# Load overworld motions
	manager.load_json_file(num_base + "/overworld_motions.json", "overworld_motions")
	
	# Apply any save-slot overrides and snapshot clean baseline for diff-based saving
	if manager.has_method("apply_save_slot_overrides"):
		manager.apply_save_slot_overrides()
	if manager.has_method("snapshot_base_data"):
		manager.snapshot_base_data()
```

### Accessing Data

Once configured, access data categories as properties:

```gdscript
# Get item data
var sword_data = DataManager.items["iron_sword"]
print(sword_data["name"])  # "Iron Sword"

# Get enemy data
var goblin = DataManager.enemies["goblin"]
print(goblin["hp"])  # 50

# Check if category exists
if DataManager.has_data("skills"):
	var fireball = DataManager.skills["fireball"]

# Get specific value with default
var item_name = DataManager.get_value("items", "potion", {"name": "Unknown"})
```

## API Reference

### Configuration Script Methods

Your configuration scripts receive a `manager` parameter with these methods:

#### `register_category(category_name: String)`
Register a new data category. Creates an empty dictionary for the category.

```gdscript
manager.register_category("items")
```

#### `load_json_file(file_path: String, category: String, merge: bool = true)`
Load a single JSON file into a category.
- `merge`: If true, merges with existing data. If false, replaces existing data.

```gdscript
manager.load_json_file("res://data/items.json", "items")
```

#### `load_json_folder(folder_path: String, category: String, recursive: bool = true)`
Load all JSON files from a folder into a category.
- `recursive`: If true, includes subdirectories

```gdscript
manager.load_json_folder("res://data/enemies", "enemies", true)
```

### DataManager Methods

#### `get_data(category: String) -> Dictionary`
Get an entire data category dictionary.

```gdscript
var all_items = DataManager.get_data("items")
```

#### `set_data(category: String, value: Dictionary)`
Set an entire data category dictionary.

```gdscript
DataManager.set_data("items", my_items_dict)
```

#### `has_data(category: String) -> bool`
Check if a data category exists.

```gdscript
if DataManager.has_data("items"):
	# Access items
```

#### `clear_data(category: String)`
Clear all data in a category.

```gdscript
DataManager.clear_data("temp_data")
```

#### `get_value(category: String, key: String, default = null)`
Get a specific value from a category with a default fallback.

```gdscript
var item = DataManager.get_value("items", "sword", {})
```

#### `set_value(category: String, key: String, value)`
Set a specific value in a category.

```gdscript
DataManager.set_value("items", "new_item", item_data)
```

## Configuration

Select `DataManager` in the autoload list to configure:

- **data_configs_folder**: Folder to auto-load config scripts from (default: `res://data_configs`)
- **auto_load_configs**: Whether to auto-load scripts on ready (default: `true`)

## Migration from JsonData

To migrate from an existing `JsonData` singleton:

1. Create a YGBF-style config script (see Example 3 above)
2. Enable the DataManager plugin
3. In `project.godot`, change the autoload:
   ```
   # Old:
   JsonData="*res://scripts/singletons/json_data.gd"
   
   # New:
   DataManager="*res://addons/gsg-godot-plugins/data_manager/data_manager.gd"
   ```
4. Create an alias for backwards compatibility:
   ```gdscript
   # In a global script or autoload
   var JsonData = DataManager
   ```
5. Or find-and-replace `JsonData` with `DataManager` in your codebase

The property access pattern (`DataManager.items`, `DataManager.skills`, etc.) works identically to the old `JsonData`.

## Best Practices

- **Separate configs by domain**: Create different config scripts for different game systems
- **Order matters**: Load numerical/base data before language-specific overlays
- **Use merge**: When loading multilingual data, always merge to combine stats with translations
- **Category naming**: Use snake_case for consistency with JSON keys
- **Error handling**: Config scripts run during initialization - any errors will prevent game startup

## Example Project Structure

```
res://
├── data_configs/
│   ├── core_game_data.gd      # Items, enemies, skills
│   ├── character_data.gd      # Party members, NPCs
│   └── ui_data.gd             # Menus, UI text
├── data/
│   ├── numerical/
│   │   ├── items/
│   │   ├── enemies/
│   │   └── ...
│   └── languages/
│       ├── english/
│       │   ├── items/
│       │   └── ...
│       └── spanish/
│           └── ...
```

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
