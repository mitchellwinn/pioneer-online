# Network Manager Plugin

Client-server networking layer for Godot 4 with server-authoritative gameplay, state synchronization, client-side prediction, and input buffering.

## Features

- **NetworkManager** autoload for connection management
- **StateSync** component for entity interpolation/prediction
- **InputBuffer** for reliable input transmission
- Server tick-based processing
- Latency measurement and compensation
- Peer management with heartbeats

## Installation

1. Copy `network_manager` to your project's `addons/` folder
2. Enable **Network Manager** in **Project → Project Settings → Plugins**
3. NetworkManager autoload is added automatically

## Quick Start

### Starting a Server

```gdscript
# Start server on default port
NetworkManager.start_server()

# Or specify port
NetworkManager.start_server(7777)

# Listen for connections
NetworkManager.peer_connected.connect(_on_player_joined)
NetworkManager.peer_disconnected.connect(_on_player_left)
```

### Connecting as Client

```gdscript
# Connect to server
NetworkManager.connect_to_server("192.168.1.100", 7777)

# Handle connection events
NetworkManager.connected_to_server.connect(_on_connected)
NetworkManager.connection_failed.connect(_on_failed)
NetworkManager.disconnected_from_server.connect(_on_disconnected)
```

### Registering Players

```gdscript
# After connecting, register with Steam ID
NetworkManager.register_player(steam_id, display_name, character_id)

# Spawn player entity
var player = preload("res://player.tscn").instantiate()
add_child(player)
NetworkManager.set_player_entity(peer_id, player)
```

## State Synchronization

Add `StateSync` to networked entities:

```gdscript
# In your entity scene:
# Entity (CharacterBody3D)
#   └── StateSync

# StateSync automatically syncs:
# - Position
# - Rotation
# - Velocity
# - Custom properties (configure in inspector)
```

### Interpolation

Remote entities are interpolated for smooth movement:

```gdscript
@export var interpolation_enabled: bool = true
@export var interpolation_delay: float = 0.1  # 100ms behind server
```

### Client-Side Prediction

Local player uses prediction with server reconciliation:

```gdscript
var state_sync = $StateSync
state_sync.set_is_local_player(true)
state_sync.prediction_enabled = true

# Prediction corrects when server state differs
state_sync.prediction_corrected.connect(func(delta):
    print("Corrected by ", delta)
)
```

## Input Buffering

Use `InputBuffer` for reliable input transmission:

```gdscript
var input_buffer = InputBuffer.new()
add_child(input_buffer)

# Inputs are automatically sampled and sent
input_buffer.input_recorded.connect(func(tick, input):
    # Apply to local prediction
    player.apply_network_input(input)
)
```

### Input Format

```gdscript
# Input dictionary structure:
{
    "move_x": float,      # -1 to 1
    "move_z": float,      # -1 to 1
    "aim_x": float,       # Camera X
    "aim_y": float,       # Camera Y
    "actions": int,       # Bitmask of actions
    "tick": int           # Input tick number
}

# Unpack actions bitmask:
var actions = InputBuffer.unpack_actions(input.actions)
if actions.jump:
    do_jump()
```

## Server Authority

The server validates all gameplay:

```gdscript
# On server - process player inputs
func _on_tick_processed(tick: int):
    for peer_id in NetworkManager.get_peer_ids():
        var player_data = NetworkManager.get_player_data(peer_id)
        # Validate and apply inputs
        # Broadcast authoritative state
```

### Damage Validation

```gdscript
# Client requests damage
func try_attack(target: Node):
    rpc_id(1, "_request_damage", target.get_path(), damage)

# Server validates
@rpc("any_peer", "call_remote", "reliable")
func _request_damage(target_path: String, damage: float):
    if not multiplayer.is_server():
        return
    
    var attacker_id = multiplayer.get_remote_sender_id()
    var target = get_node(target_path)
    
    # Validate attack is possible
    if _validate_attack(attacker_id, target, damage):
        target.take_damage(damage)
        # Broadcast to all clients
        _sync_damage.rpc(target_path, damage)
```

## Latency Compensation

```gdscript
# Get peer latency
var latency = NetworkManager.get_peer_latency(peer_id)

# Latency updates via signal
NetworkManager.latency_updated.connect(func(peer_id, ms):
    print("Peer ", peer_id, " latency: ", ms, "ms")
)
```

## Configuration

### NetworkManager Exports

| Setting | Default | Description |
|---------|---------|-------------|
| `default_port` | 7777 | Default server port |
| `max_clients` | 32 | Maximum connected clients |
| `tick_rate` | 20 | Server ticks per second |
| `interpolation_delay` | 0.1 | Seconds behind for interpolation |
| `connection_timeout` | 10.0 | Connection timeout seconds |
| `heartbeat_interval` | 1.0 | Heartbeat frequency |

### StateSync Exports

| Setting | Default | Description |
|---------|---------|-------------|
| `sync_position` | true | Sync entity position |
| `sync_rotation` | true | Sync entity rotation |
| `sync_velocity` | true | Sync velocity |
| `interpolation_delay` | 0.1 | Interpolation buffer time |
| `max_prediction_error` | 0.5 | Max error before correction |

## Network States

```gdscript
enum NetworkState {
    OFFLINE,      # Not connected
    CONNECTING,   # Connection in progress
    CONNECTED,    # Connected as client
    HOSTING       # Running as server
}

# Check state
if NetworkManager.state == NetworkManager.NetworkState.HOSTING:
    print("We are the server")
```

## Integration with Action Entities

```gdscript
# ActionEntity already includes NetworkIdentity
# Just ensure server processes inputs:

func apply_network_input(input: Dictionary):
    var move_dir = Vector3(input.move_x, 0, input.move_z)
    var actions = InputBuffer.unpack_actions(input.actions)
    
    if actions.sprint:
        is_sprinting = true
    
    apply_movement(move_dir)
```

## License

Provided as-is for use in any project.

