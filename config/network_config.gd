extends RefCounted
class_name NetworkConfig

## Network configuration for Pioneer Online
## Edit PUBLIC_SERVER_IP when your IP changes

# Your public IP - update this when it changes
const PUBLIC_SERVER_IP: String = "47.152.116.196"

# Default port for game server
const DEFAULT_PORT: int = 7777

# Connection settings
const LOCALHOST: String = "127.0.0.1"
const CONNECTION_TIMEOUT: float = 3.0  # Seconds to wait before trying next server

# Server list to try in order
static func get_server_list() -> Array[String]:
	return [
		LOCALHOST,
		PUBLIC_SERVER_IP
	]

