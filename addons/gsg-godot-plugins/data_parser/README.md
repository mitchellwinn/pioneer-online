# Data Parser Plugin

A utility plugin for parsing and saving JSON/XML data files in Godot. Provides static functions for converting between files and dictionaries.

## Features

- **JSON to Dictionary**: Load single JSON files or entire directories
- **Dictionary to JSON**: Save dictionaries as formatted JSON files
- **XML to Dictionary**: Parse XML files (dialogue manager format) into dictionaries
- **Dictionary to XML**: Convert dictionaries back to XML format
- **Auto-detection**: Generic load/save functions that detect format by file extension

## Installation

1. Copy the `data_parser` folder to your project's `addons/gsg-godot-plugins/` directory
2. Enable the "Data Parser" plugin in Project Settings → Plugins
3. The `DataParser` autoload will be automatically registered

## Usage

All functions are static and can be called directly via the `DataParser` singleton:

### JSON Functions

#### Load a single JSON file
```gdscript
var data = DataParser.json_to_dict("res://data/config.json")
print(data)
```

#### Load all JSON files from a directory
```gdscript
# Load all JSON files in a directory
var all_data = DataParser.json_dir_to_dict("res://data/items")
# Result: { "sword": {...}, "shield": {...}, "potion": {...} }

# Load recursively from subdirectories
var nested_data = DataParser.json_dir_to_dict("res://data", true)
# Result: { "items/sword": {...}, "items/shield": {...}, "config": {...} }

# Load with file pattern filtering
var configs = DataParser.json_dir_to_dict("res://data", false, "*config*.json")
```

#### Save a dictionary to JSON
```gdscript
var my_data = {
	"player_name": "Hero",
	"level": 5,
	"items": ["sword", "shield"]
}

# Pretty printed (default)
DataParser.dict_to_json(my_data, "res://saves/player.json")

# Compact format
DataParser.dict_to_json(my_data, "res://saves/player.json", false)
```

### XML Functions (Dialogue Manager Format)

#### Load XML dialogue to dictionary
```gdscript
var dialogue = DataParser.dialogue_xml_to_dict("res://dialogue/chapter1.xml")
```

**XML Example:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<dialogue>
	<line speaker="Hero" emotion="happy">Hello, world!</line>
	<choice id="1">
		<option next="2">Yes</option>
		<option next="3">No</option>
	</choice>
</dialogue>
```

**Resulting Dictionary:**
```gdscript
{
	"dialogue": {
		"line": {
			"_attributes": { "speaker": "Hero", "emotion": "happy" },
			"_text": "Hello, world!"
		},
		"choice": {
			"_attributes": { "id": "1" },
			"option": [
				{ "_attributes": { "next": "2" }, "_text": "Yes" },
				{ "_attributes": { "next": "3" }, "_text": "No" }
			]
		}
	}
}
```

#### Save dictionary to XML dialogue
```gdscript
var dialogue_data = {
	"line": {
		"_attributes": { "speaker": "Hero" },
		"_text": "Hello!"
	}
}

DataParser.dialogue_dict_to_xml(dialogue_data, "res://dialogue/new.xml", "dialogue")
```

### Generic Functions

#### Auto-detect and load
```gdscript
# Automatically detects JSON or XML based on file extension
var data = DataParser.load_file_to_dict("res://data/config.json")
var dialogue = DataParser.load_file_to_dict("res://dialogue/scene.xml")
```

#### Auto-detect and save
```gdscript
# Saves as JSON or XML based on file extension
DataParser.save_dict_to_file(my_data, "res://output/data.json")
DataParser.save_dict_to_file(dialogue_data, "res://output/dialogue.xml")
```

## API Reference

### JSON Functions

- `json_to_dict(file_path: String) -> Dictionary`
  - Load a single JSON file and return as Dictionary
  - Returns empty Dictionary on error

- `json_dir_to_dict(dir_path: String, recursive: bool = false, file_pattern: String = "*.json") -> Dictionary`
  - Load all JSON files from a directory
  - `recursive`: Include subdirectories
  - `file_pattern`: Filter files (supports * wildcard)
  - Each file stored under key based on filename (without .json)

- `dict_to_json(data: Dictionary, file_path: String, pretty_print: bool = true) -> bool`
  - Save Dictionary to JSON file
  - Returns true on success

### XML Functions

- `dialogue_xml_to_dict(file_path: String) -> Dictionary`
  - Parse XML dialogue file to Dictionary
  - Attributes stored in `_attributes` key
  - Text content stored in `_text` key
  - Multiple elements with same name become arrays

- `dialogue_dict_to_xml(data: Dictionary, file_path: String, root_name: String = "dialogue") -> bool`
  - Convert Dictionary to XML dialogue format
  - `root_name`: Name of the root XML element
  - Returns true on success

### Utility Functions

- `load_file_to_dict(file_path: String) -> Dictionary`
  - Auto-detect format by extension (.json or .xml)

- `save_dict_to_file(data: Dictionary, file_path: String, pretty_print: bool = true) -> bool`
  - Auto-detect format by extension (.json or .xml)

## Notes

- All functions are static - no need to instantiate
- Warnings/errors are logged with `[DataParser]` prefix
- JSON files with non-dictionary root will be wrapped in `{"_data": ...}`
- XML parsing uses Godot's built-in XMLParser
- Directory loading skips hidden files (starting with .)

## Future Enhancements

- CSV support
- YAML support
- More advanced XML schema support
- Validation functions
- Async loading for large files

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
