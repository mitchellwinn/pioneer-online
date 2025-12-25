# Zone Manager Plugin

Zone instance management for MMO-lite multiplayer games. Handles dynamic spawning, capacity tracking, and player routing between hub zones and mission instances.

## Features

- **Hub Zones** - Persistent social spaces with automatic scaling
- **Mission Zones** - Instanced gameplay areas for squads
- **Player Routing** - Automatic zone assignment based on capacity
- **Squad Support** - Group players into squads for missions
- **Dynamic Scaling** - Spawn/close zones based on demand

## Installation

1. Copy `zone_manager` to your project's `addons/` folder
2. Enable **Zone Manager** in **Project → Project Settings → Plugins**
3. ZoneManager autoload is added automatically

## Concepts

### Hub Zones
Persistent social spaces where players hang out between missions. Multiple hub instances (channels) can exist, and players are automatically routed to non-full ones.

### Mission Zones
Instanced gameplay areas that hold up to 32 players (8 squads of 4). Created on demand when squads queue for missions. Auto-close when empty.

## Quick Start

### Joining the Hub

```gdscript
# Get available hub (creates new if all full)
var hub_id = ZoneManager.get_available_hub()

# Add player to hub
ZoneManager.add_player_to_zone(peer_id, hub_id)

# Or route automatically
ZoneManager.request_transfer_to_hub(peer_id)
```

### Starting a Mission

```gdscript
# Squad wants to play mission_01
var squad_peer_ids = [peer_1, peer_2, peer_3, peer_4]

# Find or create mission zone, add squad
var zone_id = ZoneManager.join_mission_as_squad("mission_01", squad_peer_ids)

# Players are now in the mission zone
```

### Hub Channels

```gdscript
# Get list of available hubs
var hubs = ZoneManager.get_hub_list()
for hub in hubs:
    print(hub.metadata.channel, ": ", hub.player_count, "/", hub.max_players)

# Join specific hub
ZoneManager.request_transfer(peer_id, "hub_3")
```

### Zone Events

```gdscript
ZoneManager.player_joined_zone.connect(func(peer_id, zone_id):
    print("Player ", peer_id, " joined ", zone_id)
)

ZoneManager.player_left_zone.connect(func(peer_id, zone_id):
    print("Player ", peer_id, " left ", zone_id)
)

ZoneManager.zone_created.connect(func(zone_id, zone_type):
    print("New ", zone_type, " zone: ", zone_id)
)

ZoneManager.zone_destroyed.connect(func(zone_id):
    print("Zone closed: ", zone_id)
)
```

### Zone Transfers

```gdscript
# Request transfer (async)
ZoneManager.transfer_requested.connect(func(peer_id, from_zone, to_zone):
    # Client should load new zone scene
    pass
)

ZoneManager.request_transfer(peer_id, target_zone_id)

# After client is ready, complete transfer
ZoneManager.transfer_completed.connect(func(peer_id, zone_id):
    # Spawn player in new zone
    pass
)

ZoneManager.complete_transfer(peer_id)
```

### Ending Missions

```gdscript
# Mission complete - send everyone back to hub
ZoneManager.end_mission(zone_id, "completed")

# Or with failure
ZoneManager.end_mission(zone_id, "failed")

# Players automatically transferred to hub
```

## Zone Data Structure

```gdscript
{
    "zone_id": "hub_1",
    "zone_type": "hub",  # or "mission"
    "status": "active",  # initializing, active, closing, closed
    "player_count": 24,
    "max_players": 32,
    "squad_count": 0,    # For missions
    "metadata": {
        "channel": "Channel 1",  # For hubs
        "mission_id": "...",     # For missions
        "started_at": 1234567890
    }
}
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `hub_scene_path` | `res://scenes/hub/hub.tscn` | Hub scene to load |
| `hub_max_players` | 32 | Max players per hub |
| `hub_min_instances` | 1 | Minimum hub count |
| `hub_spawn_threshold` | 0.8 | Spawn new hub when 80% full |
| `mission_max_players` | 32 | Max players per mission (8 squads) |
| `mission_squad_size` | 4 | Players per squad |
| `mission_timeout_empty` | 60.0 | Seconds before empty mission closes |

## Server Integration

```gdscript
# On server, load zone scenes into a container
var zones_container = Node.new()
zones_container.name = "Zones"
add_child(zones_container)

ZoneManager.zone_created.connect(func(zone_id, zone_type):
    var scene = ZoneManager.load_zone_scene(zone_id, zones_container)
    # Scene is now a child of zones_container
)
```

## Player Flow Example

```gdscript
# 1. Player connects
func _on_player_connected(peer_id: int):
    # Put them in a hub
    var hub = ZoneManager.get_available_hub()
    ZoneManager.add_player_to_zone(peer_id, hub)

# 2. Player wants to do a mission with squad
func _on_start_mission(peer_id: int, mission_id: String, squad: Array):
    var zone_id = ZoneManager.join_mission_as_squad(mission_id, squad)
    
    # Notify squad members to load mission scene
    for member_id in squad:
        rpc_id(member_id, "load_mission", mission_id, zone_id)

# 3. Mission ends (success or failure)
func _on_mission_complete(zone_id: String, success: bool):
    var result = "completed" if success else "failed"
    ZoneManager.end_mission(zone_id, result)
    # Players automatically return to hub

# 4. Player disconnects
func _on_player_disconnected(peer_id: int):
    ZoneManager.remove_player_from_zone(peer_id)
```

## Extraction/Loot System Integration

For risk-based loot systems (lose gear on death):

```gdscript
# Player dies in mission
func _on_player_death(peer_id: int, zone_id: String):
    var zone_info = ZoneManager.get_zone_info(zone_id)
    
    if zone_info.zone_type == "mission":
        # They lose their loadout
        DatabaseManager.record_transaction(
            steam_id, character_id,
            "loadout_lost",
            "standard", 0, 0, 0,
            "Died in " + zone_info.metadata.mission_id
        )
        # Clear their equipped items...
        
        # Send back to hub
        ZoneManager.request_transfer_to_hub(peer_id)

# Player extracts successfully
func _on_player_extract(peer_id: int, zone_id: String, loot: Array):
    # They keep their loot
    DatabaseManager.record_transaction(
        steam_id, character_id,
        "loadout_extracted",
        "standard", loot_value, balance, balance + loot_value,
        "Extracted from mission"
    )
    
    # Add loot to inventory...
    
    # Send back to hub
    ZoneManager.request_transfer_to_hub(peer_id)
```

## License

Provided as-is for use in any project.

