extends Node

## SteamManager - Full GodotSteam integration
## Uses dynamic access to Steam singleton so it parses correctly when Steam isn't available

#region Signals
signal steam_initialized(success: bool)
signal steam_shutdown()
signal auth_ticket_received(ticket: PackedByteArray)
signal auth_ticket_validated(steam_id: int, response: int)
signal auth_ticket_cancelled()
signal lobby_created(lobby_id: int, result: int)
signal lobby_joined(lobby_id: int, response: int)
signal lobby_join_requested(lobby_id: int, friend_id: int)
signal lobby_left()
signal lobby_updated(lobby_id: int)
signal lobby_member_joined(steam_id: int)
signal lobby_member_left(steam_id: int)
signal lobby_member_updated(steam_id: int)
signal lobby_chat_received(sender_id: int, message: String)
signal lobby_data_changed(lobby_id: int)
signal lobby_list_received(lobbies: Array)
signal matchmaking_started()
signal matchmaking_found(lobby_id: int)
signal matchmaking_failed(reason: String)
signal matchmaking_cancelled()
signal rich_presence_updated()
#endregion

#region Configuration
@export var app_id: int = 480 # Spacewar test app ID
@export var auto_initialize: bool = true
#endregion

#region State
var is_initialized: bool = false
var is_mock_mode: bool = false
var steam_id: int = 0
var persona_name: String = ""
var avatar_texture: ImageTexture = null

var current_lobby_id: int = 0
var is_lobby_owner: bool = false
var lobby_members: Array[int] = []
var lobby_data: Dictionary = {}

var _auth_ticket_handle: int = 0
var _steam: Object = null  # Dynamic reference to Steam singleton
#endregion

#region Constants
enum LobbyType {PRIVATE = 0, FRIENDS_ONLY = 1, PUBLIC = 2, INVISIBLE = 3}
const MAX_SQUAD_SIZE: int = 4
const MAX_LOBBY_MEMBERS: int = 32
#endregion

func _ready():
	if auto_initialize:
		initialize_steam()

func _process(_delta):
	if is_initialized and not is_mock_mode and _steam:
		_steam.run_callbacks()

func initialize_steam() -> bool:
	if is_initialized:
		return true
	
	# Check if GodotSteam is available (dynamic check)
	if not Engine.has_singleton("Steam"):
		push_warning("[SteamManager] GodotSteam not available - running in MOCK mode")
		is_mock_mode = true
		return _initialize_mock()
	
	# Get Steam singleton dynamically
	_steam = Engine.get_singleton("Steam")
	if not _steam:
		push_warning("[SteamManager] Could not get Steam singleton - running in MOCK mode")
		is_mock_mode = true
		return _initialize_mock()
	
	# Initialize Steam
	var init_result = _steam.steamInitEx()
	
	# Check result - STEAM_API_INIT_RESULT_OK = 0
	if init_result.status != 0:
		push_warning("[SteamManager] Steam init failed: " + str(init_result.verbal) + " - running in MOCK mode")
		is_mock_mode = true
		_steam = null
		return _initialize_mock()
	
	# Get user info
	steam_id = _steam.getSteamID()
	persona_name = _steam.getPersonaName()
	is_initialized = true
	is_mock_mode = false
	
	# Connect Steam signals
	_connect_steam_signals()
	
	print("[SteamManager] Initialized - Steam ID: ", steam_id, " Name: ", persona_name)
	steam_initialized.emit(true)
	return true

func _initialize_mock() -> bool:
	# Generate mock Steam ID and name for testing
	steam_id = randi() % 900000000 + 76561198000000000
	persona_name = "Player_" + str(randi() % 9999)
	is_initialized = true
	
	print("[SteamManager] Mock initialized - ID: ", steam_id, " Name: ", persona_name)
	steam_initialized.emit(true)
	return true

func _connect_steam_signals():
	if is_mock_mode or not _steam:
		return
	
	# Lobby signals
	_steam.lobby_created.connect(_on_lobby_created)
	_steam.lobby_joined.connect(_on_lobby_joined)
	_steam.lobby_chat_update.connect(_on_lobby_chat_update)
	_steam.lobby_data_update.connect(_on_lobby_data_update)
	_steam.lobby_message.connect(_on_lobby_message)
	_steam.lobby_match_list.connect(_on_lobby_match_list)
	_steam.join_requested.connect(_on_join_requested)
	
	# Auth signals
	_steam.get_auth_session_ticket_response.connect(_on_auth_session_ticket_response)
	_steam.validate_auth_ticket_response.connect(_on_validate_auth_ticket_response)

func shutdown_steam():
	if current_lobby_id > 0:
		leave_lobby()
	
	if not is_mock_mode and _steam:
		_steam.steamShutdown()
	
	is_initialized = false
	_steam = null
	steam_shutdown.emit()

#region Getters
func get_steam_id() -> int:
	return steam_id

func get_persona_name() -> String:
	return persona_name

func is_steam_running() -> bool:
	return is_initialized

func is_using_steam() -> bool:
	return is_initialized and not is_mock_mode
#endregion

#region Authentication
func get_auth_ticket() -> PackedByteArray:
	if is_mock_mode or not _steam:
		var mock_ticket = PackedByteArray()
		for i in range(32):
			mock_ticket.append(randi() % 256)
		call_deferred("_emit_auth_ticket", mock_ticket)
		return mock_ticket
	
	var ticket_data = _steam.getAuthSessionTicket()
	_auth_ticket_handle = ticket_data.id
	return ticket_data.ticket

func _emit_auth_ticket(ticket: PackedByteArray):
	auth_ticket_received.emit(ticket)

func _on_auth_session_ticket_response(auth_ticket: int, result: int):
	if not _steam:
		return
	if auth_ticket == _auth_ticket_handle:
		if result == 1:  # RESULT_OK
			auth_ticket_received.emit(_steam.getAuthSessionTicket().ticket)
		else:
			push_warning("[SteamManager] Auth ticket failed: " + str(result))

func cancel_auth_ticket():
	if not is_mock_mode and _steam and _auth_ticket_handle > 0:
		_steam.cancelAuthTicket(_auth_ticket_handle)
		_auth_ticket_handle = 0
	auth_ticket_cancelled.emit()

func validate_auth_ticket(ticket: PackedByteArray, sender_steam_id: int) -> bool:
	if is_mock_mode or not _steam:
		get_tree().create_timer(0.1).timeout.connect(
			func(): auth_ticket_validated.emit(sender_steam_id, 0)
		)
		return true
	
	var result = _steam.beginAuthSession(ticket, ticket.size(), sender_steam_id)
	return result == 0  # BEGIN_AUTH_SESSION_RESULT_OK

func _on_validate_auth_ticket_response(auth_id: int, response: int, _owner_steam_id: int):
	auth_ticket_validated.emit(auth_id, response)

func end_auth_session(sender_steam_id: int):
	if not is_mock_mode and _steam:
		_steam.endAuthSession(sender_steam_id)
#endregion

#region Lobby Management
func create_lobby(lobby_type: LobbyType = LobbyType.FRIENDS_ONLY, max_members: int = MAX_SQUAD_SIZE) -> void:
	if is_mock_mode or not _steam:
		current_lobby_id = randi() % 900000000 + 100000000
		is_lobby_owner = true
		lobby_members = [steam_id]
		lobby_data = {"type": lobby_type, "max": max_members}
		call_deferred("_emit_lobby_created_mock")
		return
	
	_steam.createLobby(lobby_type, max_members)

func _emit_lobby_created_mock():
	lobby_created.emit(current_lobby_id, 0)

func _on_lobby_created(result: int, lobby_id: int):
	if result == 1:  # RESULT_OK
		current_lobby_id = lobby_id
		is_lobby_owner = true
		lobby_members = [steam_id]
		print("[SteamManager] Lobby created: ", lobby_id)
	lobby_created.emit(lobby_id, result)

func join_lobby(lobby_id: int) -> void:
	if is_mock_mode or not _steam:
		current_lobby_id = lobby_id
		is_lobby_owner = false
		lobby_members = [steam_id]
		call_deferred("_emit_lobby_joined_mock")
		return
	
	_steam.joinLobby(lobby_id)

func _emit_lobby_joined_mock():
	lobby_joined.emit(current_lobby_id, 1)

func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int):
	if not _steam:
		return
	if response == 1:  # CHAT_ROOM_ENTER_RESPONSE_SUCCESS
		current_lobby_id = lobby_id
		is_lobby_owner = (_steam.getLobbyOwner(lobby_id) == steam_id)
		_refresh_lobby_members()
		print("[SteamManager] Joined lobby: ", lobby_id)
	lobby_joined.emit(lobby_id, response)

func leave_lobby() -> void:
	if current_lobby_id == 0:
		return
	
	if not is_mock_mode and _steam:
		_steam.leaveLobby(current_lobby_id)
	
	current_lobby_id = 0
	is_lobby_owner = false
	lobby_members.clear()
	lobby_data.clear()
	lobby_left.emit()

func invite_to_lobby(friend_steam_id: int) -> bool:
	if current_lobby_id == 0:
		return false
	
	if is_mock_mode or not _steam:
		return true
	
	return _steam.inviteUserToLobby(current_lobby_id, friend_steam_id)

func set_lobby_data(key: String, value: String) -> bool:
	if current_lobby_id == 0:
		return false
	
	if is_mock_mode or not _steam:
		lobby_data[key] = value
		lobby_data_changed.emit(current_lobby_id)
		return true
	
	return _steam.setLobbyData(current_lobby_id, key, value)

func get_lobby_data(key: String) -> String:
	if is_mock_mode or not _steam:
		return lobby_data.get(key, "")
	
	if current_lobby_id == 0:
		return ""
	
	return _steam.getLobbyData(current_lobby_id, key)

func get_lobby_members() -> Array[int]:
	return lobby_members

func get_lobby_member_count() -> int:
	return lobby_members.size()

func is_in_lobby() -> bool:
	return current_lobby_id > 0

func get_current_lobby_id() -> int:
	return current_lobby_id

func send_lobby_chat(message: String) -> bool:
	if current_lobby_id == 0:
		return false
	
	if is_mock_mode or not _steam:
		lobby_chat_received.emit(steam_id, message)
		return true
	
	return _steam.sendLobbyChatMsg(current_lobby_id, message)

func _refresh_lobby_members():
	if is_mock_mode or not _steam:
		return
	
	lobby_members.clear()
	var member_count = _steam.getNumLobbyMembers(current_lobby_id)
	for i in range(member_count):
		lobby_members.append(_steam.getLobbyMemberByIndex(current_lobby_id, i))

func _on_lobby_chat_update(lobby_id: int, changed_id: int, _making_change_id: int, chat_state: int):
	if lobby_id != current_lobby_id:
		return
	
	# Chat state constants
	const ENTERED = 1
	const LEFT = 2
	const DISCONNECTED = 4
	const KICKED = 8
	const BANNED = 16
	
	if chat_state == ENTERED:
		if changed_id not in lobby_members:
			lobby_members.append(changed_id)
		lobby_member_joined.emit(changed_id)
	elif chat_state in [LEFT, DISCONNECTED, KICKED, BANNED]:
		lobby_members.erase(changed_id)
		lobby_member_left.emit(changed_id)
	
	lobby_updated.emit(lobby_id)

func _on_lobby_data_update(_success: int, lobby_id: int, _member_id: int):
	if lobby_id == current_lobby_id:
		lobby_data_changed.emit(lobby_id)

func _on_lobby_message(lobby_id: int, user_id: int, message: String, _chat_type: int):
	if lobby_id == current_lobby_id:
		lobby_chat_received.emit(user_id, message)

func _on_join_requested(lobby_id: int, friend_id: int):
	lobby_join_requested.emit(lobby_id, friend_id)
#endregion

#region Lobby Search
func request_lobby_list(filters: Dictionary = {}) -> void:
	if is_mock_mode or not _steam:
		call_deferred("_emit_lobby_list_mock")
		return
	
	# Apply filters
	if filters.has("distance"):
		_steam.addRequestLobbyListDistanceFilter(filters.distance)
	if filters.has("slots_available"):
		_steam.addRequestLobbyListFilterSlotsAvailable(filters.slots_available)
	if filters.has("max_results"):
		_steam.addRequestLobbyListResultCountFilter(filters.max_results)
	
	# Apply string filters
	for key in filters.get("string_filters", {}):
		var value = filters.string_filters[key]
		_steam.addRequestLobbyListStringFilter(key, value, 0)  # LOBBY_COMPARISON_EQUAL
	
	_steam.requestLobbyList()

func _emit_lobby_list_mock():
	lobby_list_received.emit([])

func _on_lobby_match_list(lobbies: Array):
	lobby_list_received.emit(lobbies)
#endregion

#region Rich Presence
func set_rich_presence(key: String, value: String) -> bool:
	if is_mock_mode or not _steam:
		rich_presence_updated.emit()
		return true
	
	var result = _steam.setRichPresence(key, value)
	rich_presence_updated.emit()
	return result

func clear_rich_presence():
	if not is_mock_mode and _steam:
		_steam.clearRichPresence()
	rich_presence_updated.emit()

func set_in_hub(channel: String = ""):
	set_rich_presence("status", "In Hub" + (" - " + channel if channel else ""))

func set_in_mission(mission_name: String, _zone_id: String = ""):
	set_rich_presence("status", "On Mission: " + mission_name)

func set_in_menu():
	set_rich_presence("status", "In Menu")
#endregion

#region Friends
func get_friend_persona_name(friend_id: int) -> String:
	if is_mock_mode or not _steam:
		return "Friend_" + str(friend_id % 1000)
	return _steam.getFriendPersonaName(friend_id)

func get_friends_list() -> Array:
	if is_mock_mode or not _steam:
		return []
	
	var friends = []
	var count = _steam.getFriendCount(4)  # FRIEND_FLAG_IMMEDIATE
	for i in range(count):
		friends.append(_steam.getFriendByIndex(i, 4))
	return friends

func get_online_friends() -> Array:
	if is_mock_mode or not _steam:
		return []
	
	var online = []
	for friend_id in get_friends_list():
		var state = _steam.getFriendPersonaState(friend_id)
		if state != 0:  # PERSONA_STATE_OFFLINE
			online.append(friend_id)
	return online
#endregion

#region Avatar
func get_player_avatar(size: int = 2) -> ImageTexture:
	if is_mock_mode or not _steam or avatar_texture != null:
		return avatar_texture
	
	# size: 0 = small (32x32), 1 = medium (64x64), 2 = large (184x184)
	var avatar_id = 0
	match size:
		0: avatar_id = _steam.getSmallFriendAvatar(steam_id)
		1: avatar_id = _steam.getMediumFriendAvatar(steam_id)
		2: avatar_id = _steam.getLargeFriendAvatar(steam_id)
	
	if avatar_id <= 0:
		return null
	
	var avatar_data = _steam.getImageRGBA(avatar_id)
	if avatar_data.is_empty():
		return null
	
	var image = Image.create_from_data(
		_steam.getImageSize(avatar_id).width,
		_steam.getImageSize(avatar_id).height,
		false,
		Image.FORMAT_RGBA8,
		avatar_data
	)
	
	avatar_texture = ImageTexture.create_from_image(image)
	return avatar_texture

func get_friend_avatar(friend_id: int, size: int = 1) -> ImageTexture:
	if is_mock_mode or not _steam:
		return null
	
	var avatar_id = 0
	match size:
		0: avatar_id = _steam.getSmallFriendAvatar(friend_id)
		1: avatar_id = _steam.getMediumFriendAvatar(friend_id)
		2: avatar_id = _steam.getLargeFriendAvatar(friend_id)
	
	if avatar_id <= 0:
		return null
	
	var avatar_data = _steam.getImageRGBA(avatar_id)
	if avatar_data.is_empty():
		return null
	
	var image = Image.create_from_data(
		_steam.getImageSize(avatar_id).width,
		_steam.getImageSize(avatar_id).height,
		false,
		Image.FORMAT_RGBA8,
		avatar_data
	)
	
	return ImageTexture.create_from_image(image)
#endregion
