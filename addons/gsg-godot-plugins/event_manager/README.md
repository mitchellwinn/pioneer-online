# Event Manager Plugin

A flexible event system for dialogue and text processing with support for custom game-specific events.

## Features

- **Universal Events**: Built-in events that work in any project (`textSpeed`, `Speaker`)
- **Custom Event Registration**: Add game-specific events via API or auto-loaded scripts
- **Extensible**: No modification of plugin code needed for custom functionality
- **Auto-loading**: Automatically loads custom event scripts from a folder

## Installation

1. Copy the `event_manager` folder to your project's `addons` directory
2. In Godot, go to **Project → Project Settings → Plugins**
3. Enable the **Event Manager** plugin
4. The `EventManager` singleton will be automatically added

## Usage

### Processing Events

Events are processed from dialogue text using the format: `*command_name|arg1|arg2*`

Example dialogue:
```
*Speaker|John* Hello, my *textSpeed|0.5* name is John.
```

In your dialogue system:
```gdscript
var processed_text = EventManager.process_events("Speaker|John")
```

### Built-in Events

#### textSpeed
Change text display speed.
```
*textSpeed|1.5*
```

#### Speaker
Set or clear the current speaker.
```
*Speaker|character_name*  # Set speaker
*Speaker|*                # Clear speaker
```

## Custom Events

### Method 1: Direct Registration

Register custom events in your game's initialization code:

```gdscript
func _ready():
	# Simple text substitution
	EventManager.register_event("leadName", func(args):
		return GameManager.party[0].get_character_name()
	)
	
	# Conditional text
	EventManager.register_event("partyPlurality", func(args):
		if GameManager.party.size() == 1:
			return args[1]  # Singular
		else:
			return args[2]  # Plural
	)
	
	# Game actions
	EventManager.register_event("giveItem", func(args):
		InventoryManager.add_item(args[1])
		return ""
	)
```

### Method 2: Auto-loaded Scripts

Create event handler scripts in `res://events/` folder:

**res://events/ygbf_events.gd:**
```gdscript
extends Node

func register_events(event_manager):
	# Text substitution events
	event_manager.register_event("leadName", _lead_name)
	event_manager.register_event("leadGender", _lead_gender)
	event_manager.register_event("item", _item)
	event_manager.register_event("skill", _skill)
	
	# Game action events
	event_manager.register_event("giveItem", _give_item)
	event_manager.register_event("giveMoney", _give_money)
	event_manager.register_event("heal", _heal)

func _lead_name(args: Array):
	return GameManager.party[0].get_character_name()

func _lead_gender(args: Array):
	match GameManager.party[0].character_gender:
		0: return args[1]  # Male
		1: return args[2]  # Female
		2: return args[3]  # Non-binary
	return ""

func _item(args: Array):
	return JsonData.items[args[1]]["name"]

func _skill(args: Array):
	return JsonData.skills[args[1]]["name"]

func _give_item(args: Array):
	InventoryManager.add_item(args[1])
	return ""

func _give_money(args: Array):
	GameManager.give_money(int(args[1]))
	return ""

func _heal(args: Array):
	GameManager.heal_all()
	return ""
```

The plugin will automatically load and register all events from scripts in the `res://events/` folder.

## Configuration

Select `EventManager` in the autoload list to configure:

- **custom_events_folder**: Folder to auto-load event scripts from (default: `res://events`)
- **auto_load_custom_events**: Whether to auto-load scripts on ready (default: `true`)

## Example Usage in Dialogue

```xml
<line id="greeting">
	*Speaker|merchant* Welcome, *leadName*! I have *item|health_potion* for sale.
</line>

<line id="offer">
	Would you like to buy *partyPlurality|it|them* for 50 gold?
</line>

<line id="purchase">
	*giveItem|health_potion* *takeMoney|50* Thank you for your purchase!
</line>
```

## Tips

- **Event Names**: Use camelCase for consistency
- **Return Values**: Return empty string `""` for events that perform actions without text substitution
- **Array Results**: Return `[value, true]` if the event should exit processing early (e.g., for animations)
- **Error Handling**: The plugin warns about unknown events but doesn't crash

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
