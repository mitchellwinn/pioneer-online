# Sound Manager Plugin

A flexible sound management system for Godot with voice synthesis, 2D/3D sound playback, and audio pooling for optimal performance.

## Features

- **Simple Sound Playback**: One-line function to play any sound effect
- **Voice Synthesis**: Character voice system with pitch variation for dialogue
- **3D Spatial Audio**: Play sounds at world positions or attached to nodes
- **Audio Pooling**: Efficient voice player pooling prevents audio stuttering
- **Auto Bus Configuration**: Automatically creates SFX and Voice audio buses
- **Multiple Playback Modes**: Support for file paths or pre-loaded AudioStream resources
- **Legacy Compatibility**: Backward-compatible functions for existing projects

## Installation

1. Copy the `sound_manager` folder to your project's `addons` directory: `res://addons/sound_manager/`
2. In Godot, go to **Project → Project Settings → Plugins**
3. Enable the **Sound Manager** plugin
4. The `SoundManager` singleton will be automatically added to your project

## Configuration

### Initial Setup

Select the `SoundManager` autoload in **Project → Project Settings → Autoload** to configure:

- **sounds_folder**: Root folder for sound files (default: `res://sounds`)
- **voices_folder**: Root folder for voice files (default: `res://sounds/voices`)
- **character_data_path**: Path to character voice JSON (optional)
- **auto_configure_audio_buses**: Auto-create audio buses (default: `true`)

### Audio Bus Settings

**SFX Bus:**
- **sfx_bus_name**: Name of the SFX bus (default: `"SFX"`)
- **sfx_bus_volume_db**: Default volume in dB (default: `0.0`)
- **sfx_bus_parent**: Parent bus name (default: `"Master"`)

**Voice Bus:**
- **voice_bus_name**: Name of the Voice bus (default: `"Voice"`)
- **voice_bus_volume_db**: Default volume in dB (default: `0.0`)
- **voice_bus_parent**: Parent bus name (default: `"Master"`)

### Voice Pool Settings

- **max_voice_players**: Number of pooled voice players (default: `10`)

## Character Voice JSON Format

Optional JSON file for character voice parameters:

```json
{
  "hero": {
    "voice": "hero_voice.wav",
    "voice_base_pitch": 1.0,
    "voice_pitch_range": 0.2
  },
  "villain": {
    "voice": "deep_voice.wav",
    "voice_base_pitch": 0.8,
    "voice_pitch_range": 0.15
  },
  "npc_shopkeeper": {
    "voice": "friendly_voice.wav",
    "voice_base_pitch": 1.2,
    "voice_pitch_range": 0.25
  }
}
```

Alternatively, set character data programmatically:

```gdscript
SoundManager.set_character_data({
    "hero": {
        "voice": "hero_voice.wav",
        "voice_base_pitch": 1.0,
        "voice_pitch_range": 0.2
    }
})
```

## Usage

### Basic Sound Effects

```gdscript
# Play a sound effect
SoundManager.play_sound("res://sounds/sfx/coin_pickup.wav")

# Play with volume adjustment
SoundManager.play_sound("res://sounds/sfx/explosion.wav", -3.0)

# Play pre-loaded stream
var stream = preload("res://sounds/sfx/jump.wav")
SoundManager.play_sound_stream(stream)
```

### 3D Spatial Audio

```gdscript
# Play at a world position
SoundManager.play_sound_3d(
    "res://sounds/sfx/footstep.wav",
    Vector3(10, 0, 5)
)

# Attach to a moving node (follows the node)
SoundManager.play_sound_3d(
    "res://sounds/sfx/engine.wav",
    Vector3.ZERO,
    car_node
)

# With volume adjustment
SoundManager.play_sound_3d(
    "res://sounds/sfx/waterfall.wav",
    waterfall_position,
    null,
    -6.0
)

# Using pre-loaded stream
var impact_sound = preload("res://sounds/sfx/impact.wav")
SoundManager.play_sound_3d_stream(impact_sound, hit_position)
```

### Character Voice System

Perfect for dialogue systems with text-per-character reveal:

```gdscript
# In your dialogue system
func _on_character_revealed(character: String, character_key: String):
    # Play voice sound with pitch variation
    SoundManager.play_voice(character_key)
```

**Example dialogue integration:**

```gdscript
extends RichTextLabel

var character_key: String = "hero"
var text_speed: float = 0.05
var char_index: int = 0
var full_text: String = ""

func display_text(text: String, speaker: String):
    full_text = text
    character_key = speaker
    char_index = 0
    visible_characters = 0
    
    while char_index < full_text.length():
        visible_characters += 1
        if full_text[char_index] != " ":
            SoundManager.play_voice(character_key)
        char_index += 1
        await get_tree().create_timer(text_speed).timeout
```

## Example Use Cases

### Footstep System

```gdscript
extends CharacterBody3D

var footstep_sounds = [
    preload("res://sounds/footsteps/step1.wav"),
    preload("res://sounds/footsteps/step2.wav"),
    preload("res://sounds/footsteps/step3.wav")
]

func play_footstep():
    var random_step = footstep_sounds.pick_random()
    SoundManager.play_sound_3d_stream(random_step, global_position)
```

### UI Sounds

```gdscript
extends Button

func _ready():
    pressed.connect(_on_pressed)
    mouse_entered.connect(_on_hover)

func _on_pressed():
    SoundManager.play_sound("res://sounds/ui/button_click.wav")

func _on_hover():
    SoundManager.play_sound("res://sounds/ui/button_hover.wav", -10.0)
```

### Ambient Sound Emitters

```gdscript
extends Node3D

@export var sound_file: String = "res://sounds/ambient/birds.wav"
@export var loop: bool = true

func _ready():
    if loop:
        # For looping ambient sounds, use AudioStreamPlayer3D directly
        var player = AudioStreamPlayer3D.new()
        player.bus = "SFX"
        player.stream = load(sound_file)
        add_child(player)
        player.play()
    else:
        SoundManager.play_sound_3d(sound_file, global_position)
```

### Collision/Impact Sounds

```gdscript
func _on_body_entered(body):
    var impact_sound = "res://sounds/sfx/impact.wav"
    var velocity_magnitude = body.linear_velocity.length()
    
    # Adjust volume based on impact strength
    var volume = clamp(linear_to_db(velocity_magnitude / 10.0), -20.0, 0.0)
    
    SoundManager.play_sound_3d(
        impact_sound,
        global_position,
        null,
        volume
    )
```

## Legacy Functions

For backward compatibility with existing projects:

```gdscript
# Legacy instantiated player
SoundManager.play_sound_legacy(sfx_player_scene, "res://sounds/test.wav")

# Legacy AudioStreamPlayer2D
SoundManager.play_sound_from_player(audio_player_2d, "res://sounds/test.wav")
```

## Tips

- **File Format**: Use `.wav` for short sounds, `.ogg` for longer sounds/voice
- **Voice Pool Size**: Increase if you have rapid dialogue (e.g., fast text reveal)
- **3D Sound Range**: Set attenuation in AudioStreamPlayer3D for distance falloff
- **Volume Levels**: -20 dB to 0 dB is the typical range for most sound effects
- **Performance**: Pre-load frequently used sounds to avoid loading hitches

## Integrating with Existing Projects

If you already have `JsonData.enemies` or `JsonData.party_members`:

```gdscript
# In your game initialization
func _ready():
    # Use your existing character data
    SoundManager.character_data = JsonData.party_members
```

Or override the `get_character_data` function for custom data sources.

## License

These plugins are provided as-is and can be used freely. There is a strong priority for modularity, but ultimately all gsg plugins are designed with one another in mind and meant first and foremost for in-house development endeavors.
