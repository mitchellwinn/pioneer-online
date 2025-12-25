# Music Manager Plugin

A comprehensive music management system for Godot with multi-stem support, zone-based music control, crossfading, intro/loop support, and pause effects.

## Features

- **Multi-Stem Music**: Play songs with multiple audio stems (bass, drums, melody, etc.) that can be controlled independently
- **Intro/Loop System**: Seamless transition from intro to looping sections
- **Zone-Based Music**: Automatically switch music based on player location with priority system
- **Music Overrides**: Temporarily override zone music (e.g., for battles or events)
- **Equal-Power Crossfading**: Smooth transitions between songs maintaining perceived loudness
- **Pause Effect**: Automatic low-pass filter when game is paused
- **Dynamic Stem Control**: Fade in/out or isolate individual stems during gameplay
- **Auto Bus Configuration**: Automatically creates and configures the Music audio bus

## Installation

1. Copy the `music_manager` folder to your project's `addons` directory: `res://addons/music_manager/`
2. In Godot, go to **Project → Project Settings → Plugins**
3. Enable the **Music Manager** plugin
4. The `MusicManager` singleton will be automatically added to your project

## Configuration

### Initial Setup

Select the `MusicManager` autoload in **Project → Project Settings → Autoload** to configure:

- **songs_json_path**: Path to your songs JSON file (default: `res://data/songs.json`)
- **music_folder**: Root folder for music files (default: `res://music`)
- **auto_configure_audio_buses**: Auto-create the Music bus (default: `true`)

### Audio Bus Settings

- **music_bus_name**: Name of the music bus (default: `"Music"`)
- **music_bus_volume_db**: Default volume in dB (default: `0.0`)
- **music_bus_parent**: Parent bus name (default: `"Master"`)

### Pause Effect Settings

- **enable_pause_lowpass**: Enable low-pass filter on pause (default: `true`)
- **pause_cutoff_hz**: Cutoff frequency when paused (default: `800.0`)
- **pause_resonance**: Filter resonance (default: `1.0`)

## Songs JSON Format

Create a JSON file with your song definitions:

```json
{
  "forest_theme": {
    "stems": {
      "bass": {
        "intro": "res://music/forest/bass_intro.ogg",
        "loop": "res://music/forest/bass_loop.ogg"
      },
      "melody": {
        "intro": "res://music/forest/melody_intro.ogg",
        "loop": "res://music/forest/melody_loop.ogg"
      },
      "drums": {
        "intro": "res://music/forest/drums_intro.ogg",
        "loop": "res://music/forest/drums_loop.ogg"
      }
    }
  },
  "battle_theme": {
    "stems": {
      "full": {
        "intro": "res://music/battle/intro.ogg",
        "loop": "res://music/battle/loop.ogg"
      }
    }
  }
}
```

## Usage

### Zone-Based Music (Recommended)

The plugin works seamlessly with `MultimediaZone` nodes. Create an Area3D with the following exported variables:

```gdscript
extends Area3D

@export var prio: int = 0  # Higher priority zones override lower ones
@export var music_track: String = "forest_theme"
@export var fade_duration: float = 6.0
@export var stem_volumes: Dictionary = {}  # Optional: {"bass": -3.0, "drums": 0.0}

func _on_body_entered(body):
    if body == player:
        MusicManager.register_zone(self)

func _on_body_exited(body):
    if body == player:
        MusicManager.unregister_zone(self)
```

### Music Overrides

Temporarily override zone music for events:

```gdscript
# Start battle music
MusicManager.play_music_override("battle_theme", 2.0)

# Return to zone music
MusicManager.stop_music_override(2.0)

# Clear all overrides
MusicManager.clear_all_overrides()
```

### Stem Control

Control individual stems dynamically:

```gdscript
# Fade out all stems except bass
MusicManager.isolate_stem("bass", 1.0)

# Fade individual stem
MusicManager.lerp_stem_volume("drums", -10.0, 2.0)

# Set stem volume immediately
MusicManager.set_stem_volume("melody", -6.0)

# Reset all stems to normal
MusicManager.reset_all_stem_volumes(1.0)
```

### Stop All Music

```gdscript
MusicManager.stop_all()
```

## Example: Dynamic Music Layers

```gdscript
# Start with just bass and drums
MusicManager.play_music_override("forest_theme", 2.0)
MusicManager.set_stem_volume("melody", -80.0)  # Silent
MusicManager.set_stem_volume("harmony", -80.0)

# Later, bring in melody when player discovers something
MusicManager.lerp_stem_volume("melody", 0.0, 3.0)

# Add harmony during climax
MusicManager.lerp_stem_volume("harmony", 0.0, 2.0)
```

## Example: Battle System Integration

```gdscript
func start_battle():
    # Switch to battle music
    MusicManager.play_music_override("battle_theme", 1.5)

func end_battle():
    # Return to exploration music
    MusicManager.stop_music_override(2.0)
```

## Tips

- **Stem Naming**: Use consistent stem names across songs for easier control
- **Fade Durations**: Longer fades (4-8s) work well for atmospheric changes, shorter (1-2s) for action transitions
- **Zone Priorities**: Use priority 0 for general areas, higher values for specific zones
- **Volume Levels**: -80 dB is effectively silent, 0 dB is normal, positive values boost (use carefully)
- **File Format**: Use `.ogg` format for music files (smaller and well-supported in Godot)

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
