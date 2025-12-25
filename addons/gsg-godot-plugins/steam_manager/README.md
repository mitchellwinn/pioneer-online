# Steam Manager Plugin

GodotSteam wrapper for authentication, lobbies, matchmaking, and rich presence. Integrates Steam services for live-service multiplayer games.

## Features

- **Steam Authentication** - Auth tickets for server validation
- **Lobbies** - Create/join lobbies for squad formation
- **Matchmaking** - Search for available lobbies
- **Rich Presence** - Show player status to friends
- **Friends List** - Access friends and their status
- **Avatars** - Load player avatars

## Requirements

- [GodotSteam](https://godotsteam.com/) addon installed
- Steam client running
- Valid Steam App ID

## Installation

1. Install GodotSteam addon first
2. Copy `steam_manager` to your project's `addons/` folder
3. Enable **Steam Manager** in **Project → Project Settings → Plugins**
4. Set your App ID in the SteamManager node (default: 480 for testing)

## Quick Start

### Initialization

```gdscript
# SteamManager auto-initializes on ready
# Check initialization status:
SteamManager.steam_initialized.connect(func(success):
    if success:
        print("Steam ID: ", SteamManager.get_steam_id())
        print("Name: ", SteamManager.get_persona_name())
)
```

### Authentication

```gdscript
# Client: Get auth ticket to send to server
var ticket = SteamManager.get_auth_ticket()
# Send ticket bytes to server...

# Server: Validate client's auth ticket
SteamManager.auth_ticket_validated.connect(func(steam_id, response):
    if response == Steam.AUTH_SESSION_RESPONSE_OK:
        print("Player ", steam_id, " authenticated!")
        # Allow player to connect
)

SteamManager.validate_auth_ticket(ticket_bytes, client_steam_id)
```

### Lobby Management

```gdscript
# Create lobby for squad (up to 4 players)
SteamManager.lobby_created.connect(func(lobby_id, result):
    if result == Steam.RESULT_OK:
        # Set lobby metadata
        SteamManager.set_lobby_data("game_mode", "mission")
        SteamManager.set_lobby_data("mission_id", "mission_01")
)
SteamManager.create_lobby(SteamManager.LobbyType.FRIENDS_ONLY, 4)

# Join existing lobby
SteamManager.lobby_joined.connect(func(lobby_id, response):
    if response == Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
        print("Joined lobby!")
)
SteamManager.join_lobby(lobby_id)

# Handle member changes
SteamManager.lobby_member_joined.connect(func(steam_id):
    print(SteamManager.get_player_name(steam_id), " joined")
)

SteamManager.lobby_member_left.connect(func(steam_id):
    print(SteamManager.get_player_name(steam_id), " left")
)

# Invite friends
SteamManager.invite_to_lobby(friend_steam_id)

# Leave lobby
SteamManager.leave_lobby()
```

### Matchmaking

```gdscript
# Search for lobbies
SteamManager.lobby_list_received.connect(func(lobbies):
    for lobby in lobbies:
        print("Found lobby: ", lobby.lobby_id)
        print("  Members: ", lobby.member_count, "/", lobby.max_members)
)

SteamManager.search_lobbies({
    "max_results": 20,
    "slots_available": 1,  # At least 1 slot open
    "string_filters": {
        "game_mode": "mission"
    }
})

# Or auto-join first match
SteamManager.matchmaking_found.connect(func(lobby_id):
    SteamManager.join_lobby(lobby_id)
)
```

### Rich Presence

```gdscript
# Show status to friends
SteamManager.set_in_lobby("Squad Alpha", 3, 4)
SteamManager.set_in_hub("Channel 1")
SteamManager.set_in_mission("Extraction Point", "zone_01")

# Custom status
SteamManager.set_status("Looking for squad")
```

### Friends

```gdscript
# Get online friends
var friends = SteamManager.get_online_friends()
for friend in friends:
    print(friend.name, " - ", friend.steam_id)

# Get friend's avatar
SteamManager.get_friend_avatar(friend_steam_id)
```

## Lobby Data Keys

Standard keys used by the system:

| Key | Description |
|-----|-------------|
| `game_mode` | Current game mode |
| `mission_id` | Selected mission |
| `status` | Squad status (forming, ready, in_mission) |
| `region` | Preferred region |
| `min_level` | Minimum player level |

## Integration with NetworkManager

```gdscript
# After lobby is ready, start the game server
func _on_start_mission():
    if SteamManager.is_lobby_host():
        # Host starts server
        NetworkManager.start_server()
        
        # Tell lobby members to connect
        var ip = get_public_ip()  # Your server IP
        SteamManager.set_lobby_data("server_ip", ip)
        SteamManager.set_lobby_data("server_port", str(NetworkManager.server_port))
    
    # Lock lobby
    SteamManager.set_lobby_joinable(false)

# Non-host clients connect when lobby data changes
func _on_lobby_data_changed(lobby_id):
    if not SteamManager.is_lobby_host():
        var ip = SteamManager.get_lobby_data("server_ip")
        var port = int(SteamManager.get_lobby_data("server_port"))
        
        if ip and port:
            NetworkManager.connect_to_server(ip, port)
```

## Integration with DatabaseManager

```gdscript
# Use Steam ID for database operations
var steam_id = SteamManager.get_steam_id()
var persona_name = SteamManager.get_persona_name()

# Create/load player
DatabaseManager.create_player(steam_id, persona_name)
var player = DatabaseManager.get_player(steam_id)

# All operations keyed by Steam ID
var characters = DatabaseManager.get_characters(steam_id)
```

## Rich Presence Localization

Create `steam_richpresence.vdf` in your Steam app config:

```
"lang"
{
    "english"
    {
        "tokens"
        {
            "#Status"           "%status%"
            "#InLobby"          "In Lobby (%members%/%max_members%)"
            "#InMission"        "Playing %mission%"
            "#InHub"            "In Hub - %channel%"
        }
    }
}
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `app_id` | 480 | Steam App ID (480 = Spacewar test) |
| `auto_initialize` | true | Init Steam on ready |
| `require_steam_running` | true | Fail if Steam not running |

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_SQUAD_SIZE` | 4 | Default squad size |
| `MAX_LOBBY_MEMBERS` | 32 | Max lobby members |

## License

Provided as-is for use in any project.

