# Dialogue Manager

Dialogue and text display system with XML parsing, dialogue choices, and event integration for Godot 4.x.

## Features

- **XML Dialogue System**: Load and parse dialogue trees from XML files
- **Conditional Branching**: Support for conditional dialogue paths based on flags
- **Dialogue Choices**: Present multiple-choice options to players
- **Event Integration**: Process inline events within dialogue text (e.g., `*Speaker|character*`, `*wait|0.5*`)
- **Text Typewriter Effect**: Character-by-character text reveal with customizable speed
- **Voice Synthesis**: Per-character voice settings with pitch variation
- **Quick Read Mode**: Display text without full dialogue tree processing

## Installation

This plugin is enabled by default when you install the gsg-godot-plugins collection.

To enable manually:
1. **Project → Project Settings → Plugins**
2. Enable "DialogueManager"

The plugin automatically registers the `DialogueManager` singleton.

## Basic Usage

### Starting Dialogue

```gdscript
# Start a dialogue tree by name
DialogueManager.start_dialogue("npc_greeting", npc_node)

# The dialogue system will:
# 1. Evaluate starter conditions
# 2. Display dialogue text with typewriter effect
# 3. Process inline events
# 4. Present choices if available
# 5. Emit dialogue_finished signal when complete
```

### Listening for Dialogue Events

```gdscript
func _ready():
	DialogueManager.dialogue_started.connect(_on_dialogue_started)
	DialogueManager.dialogue_finished.connect(_on_dialogue_finished)

func _on_dialogue_started():
	print("Dialogue has started")

func _on_dialogue_finished():
	print("Dialogue has ended")
```

## XML Dialogue Format

### Basic Structure

```xml
<dialogue>
	<!-- Starters define entry points with optional conditions -->
	<starter id="default" all_true="">
		<!-- Empty conditions means this is the default starter -->
	</starter>
	
	<starter id="if_flag_set" all_true="true">
		<condition key="some_flag" value="true" operator=""/>
	</starter>
	
	<!-- Lines define individual dialogue entries -->
	<line id="greeting" next="ask_question">
		*Speaker|npc_name*
		Hello there! Welcome to my shop.
	</line>
	
	<line id="ask_question" next="">
		*Speaker|npc_name*
		Would you like to see my wares?
		<choice text="Yes, please!" next="show_shop"/>
		<choice text="No, thanks." next="decline"/>
	</line>
	
	<line id="show_shop" next="">
		*openShop|shop_key*
		Thanks for shopping!
	</line>
	
	<line id="decline" next="">
		Alright, come back anytime!
	</line>
</dialogue>
```

### Inline Events

Events are processed by the EventManager and can be embedded directly in dialogue text:

- `*Speaker|character_key*` - Set the current speaker
- `*wait|seconds*` - Pause dialogue for specified duration  
- `*faceEntity|entity1|entity2*` - Make entity1 face entity2
- `*moveEntity|entity|x|y*` - Move entity to position
- `*giveItem|item_key*` - Give item to player
- `*setFlag|flag_name|value|type*` - Set a game flag
- Custom events registered via EventManager

### Conditional Dialogue

```xml
<line id="check_level" next="low_level">
	<conditional_next id="high_level" all_true="true">
		<condition key="player_level" value="10" operator=">="/>
	</conditional_next>
	*Speaker|trainer*
	Let's see what you're made of!
</line>
```

## API Reference

### Properties

- `is_open: bool` - Whether dialogue is currently active
- `current_tree_name: String` - Name of the active dialogue tree
- `current_npc: Node` - Reference to the NPC in dialogue
- `text_speed: float` - Typewriter effect speed (default: 0.05)

### Methods

#### `start_dialogue(dialogue_name: String, npc: Node = null)`
Start a dialogue tree by name.

#### `read_line(line_id: String, label: RichTextLabel = null)`
Read a specific dialogue line (usually called internally).

#### `quick_read(text: String, label: RichTextLabel, json_parent: String = "", json_subkey: String = "", json_key: String = "")`
Display text quickly without full dialogue tree processing.

#### `convert_xml(filepath: String) -> Dictionary`
Parse an XML dialogue file into a dictionary structure.

### Signals

- `dialogue_started` - Emitted when dialogue begins
- `dialogue_finished` - Emitted when dialogue ends

## Integration with Other Systems

### Event Manager
DialogueManager relies on EventManager for processing inline events. Make sure EventManager is loaded before DialogueManager.

### Menu Manager
DialogueManager uses MenuManager to display dialogue windows and choice menus.

### Data Manager
Dialogue files can reference data from DataManager (e.g., character names, item data).

## Configuration

The dialogue system automatically detects dialogue windows through MenuManager. No manual configuration is needed for basic usage.

For custom dialogue windows, implement the `get_message_label()` method to return your RichTextLabel.

## Credits

Originally developed for the YGBF project as ThirdDialogueManager, refactored into a reusable plugin.

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
