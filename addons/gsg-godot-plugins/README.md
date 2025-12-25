# GSG Godot Plugins

A collection of professional plugins for Godot Engine 4.x, designed for live-service multiplayer action games.

## Plugins Overview

### Core Gameplay

| Plugin | Description |
|--------|-------------|
| **[Action Entities](action_entities/)** | Server-authoritative 3D entity system for modern action games with skeletal mesh support, state machine-based gameplay, networked combat, and AI behaviors |
| **[Camera System](camera_system/)** | Advanced camera system with multiple camera types (Pokemon-style DS camera, etc.) and zone support |
| **[RPG Entities](rpg_entities/)** | Entity, NPC, and PlayerCharacter scripts and prefabs for RPG-style character management with navigation, animation, and stamina systems |

### Networking & Infrastructure

| Plugin | Description |
|--------|-------------|
| **[Network Manager](network_manager/)** | Client-server networking with state sync, prediction, and input buffering |
| **[Database Manager](database_manager/)** | SQLite database abstraction for player data, character management, server-validated transactions, and leaderboards with Steam ID primary keys |
| **[Steam Manager](steam_manager/)** | GodotSteam wrapper for authentication, lobbies, matchmaking, rich presence, friends list, and avatar loading |
| **[Zone Manager](zone_manager/)** | Zone instance management for MMO-lite games with hub zones, mission instances, squad support, and dynamic scaling |

### Audio & UI

| Plugin | Description |
|--------|-------------|
| **[Music Manager](music_manager/)** | Multi-stem music with zones, crossfading, and intro/loop support |
| **[Sound Manager](sound_manager/)** | Sound effects, voice synthesis, and 3D spatial audio |
| **[Menu Manager](menu_manager/)** | JSON-driven menu system |
| **[Dialogue Manager](dialogue_manager/)** | Branching dialogue system |

### Utilities

| Plugin | Description |
|--------|-------------|
| **[Data Manager](data_manager/)** | Save/load game data with flags and conditions |
| **[Data Parser](data_parser/)** | JSON/CSV data parsing utilities |
| **[Event Manager](event_manager/)** | Global event bus |
| **[Scene Transitions](scene_transitions/)** | Smooth scene transitions with fade effects |
| **[Multimedia Zones](multimedia_zones/)** | Area-based audio/visual triggers |

## Quick Start

### Installation

1. Copy desired plugin folder(s) to your `addons/` directory
2. Enable in **Project → Project Settings → Plugins**
3. Autoloads are added automatically where applicable

### Live Service Game Setup

For a multiplayer extraction/looter game:

```gdscript
# 1. Initialize Steam
await SteamManager.steam_initialized

# 2. Load/create player from Steam ID
var steam_id = SteamManager.get_steam_id()
DatabaseManager.create_player(steam_id, SteamManager.get_persona_name())
var characters = DatabaseManager.get_characters(steam_id)

# 3. Join hub
var hub = ZoneManager.get_available_hub()
ZoneManager.add_player_to_zone(NetworkManager.get_local_peer_id(), hub)

# 4. Form squad via Steam lobby
SteamManager.create_lobby(SteamManager.LobbyType.FRIENDS_ONLY, 4)

# 5. Start mission
ZoneManager.join_mission_as_squad("extraction_01", squad_peer_ids)
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       Game Client                           │
├─────────────────────────────────────────────────────────────┤
│  SteamManager ─── Auth/Lobbies ───► Steam Services          │
│        │                                                    │
│        ▼                                                    │
│  NetworkManager ◄──────────────────► Game Server            │
│        │                                   │                │
│        ▼                                   ▼                │
│  ActionPlayer                        ZoneManager            │
│  (local input)                       (instances)            │
│        │                                   │                │
│        └────────► StateSync ◄──────────────┘                │
│                   (position, combat)                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                     ┌────────────────┐
                     │ DatabaseManager │
                     │   (SQLite/PG)   │
                     └────────────────┘
```

## Requirements

- Godot 4.0+
- [GodotSteam](https://godotsteam.com/) (for Steam integration)
- [godot-sqlite](https://github.com/2shady4u/godot-sqlite) (for database)

## Plugin Dependencies

```
action_entities ─────► network_manager (optional)
                └────► camera_system (optional)

network_manager ─────► (standalone)

database_manager ────► godot-sqlite addon

steam_manager ───────► GodotSteam addon
             └───────► network_manager (optional)

zone_manager ────────► network_manager (optional)
            └────────► steam_manager (optional)
```

## Example Project Structure

```
project/
├── addons/
│   └── gsg-godot-plugins/
│       ├── action_entities/
│       ├── network_manager/
│       ├── database_manager/
│       ├── steam_manager/
│       ├── zone_manager/
│       └── ...
├── scenes/
│   ├── hub/
│   │   ├── hub.tscn
│   │   ├── hub.gd
│   │   └── npc_mission_giver.gd
│   ├── missions/
│   │   └── mission_01.tscn
│   └── player/
│       └── player.tscn
└── project.godot
```

## License

These plugins are provided as-is. Free to use and modify for any project, commercial or otherwise.

## Credits

Developed by Glass Soldier Games for internal projects.
