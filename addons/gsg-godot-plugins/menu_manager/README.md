# Menu Manager Plugin

Dynamic, JSON-driven menu and window system for Godot 4.x.

## Installation

1. Copy the `menu_manager` folder to `addons/gsg-godot-plugins/`
2. Enable **MenuManager** in **Project → Project Settings → Plugins**

## Basics

- Loads plugin menus from `res://addons/gsg-godot-plugins/menu_manager/menus`
- Loads game menus from `res://menus` (game overrides plugin by key)
- Stores configs in `DataManager.menus`
- Builds windows at runtime and manages a window stack (back/close, z-index)

### Open / Close

```gdscript
MenuManager.open_window("pause_menu")
MenuManager.close_active_window()
MenuManager.force_close_all_windows()
```

## Menu JSON (Example)

```json
{
  "window_name": "dialogue",
  "window_script": "res://scripts/windows/dialogue_window.gd",
  "custom_size": { "x": 880, "y": 100 },
  "container_type": "HBox",
  "position_strategy": {
    "type": "bottom_overlay",
    "width_percent": 0.92,
    "y_offset": -40
  }
}
```

Key ideas:
- `window_name`: name used with `open_window()`
- `window_script`: optional custom script (otherwise base window)
- Layout & behavior (size, container, position, buttons) are driven entirely by JSON.

## Integration

- Uses **DataManager** for `menus` data
- Used by **DialogueManager** for dialogue and choice windows
- Uses **SoundManager** for menu SFX (focus/close)

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
