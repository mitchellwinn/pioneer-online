extends Node

## MusicManager - Handles music playback with intro/loop support, multi-stem mixing, and zone-based control
## Configurable plugin version that can be used across different projects

#region Configuration
## Path to the JSON file containing song definitions
## Format: {"song_key": {"stems": {"stem_name": {"intro": "path", "loop": "path"}}}}
@export_file("*.json") var songs_json_path: String = "res://data/songs.json"

## Root folder where music files are stored
@export_dir var music_folder: String = "res://music"

## Whether to automatically configure audio buses on ready
@export var auto_configure_audio_buses: bool = true

## Music bus configuration
@export_group("Audio Bus Settings")
@export var music_bus_name: String = "Music"
@export var music_bus_volume_db: float = 0.0
@export var music_bus_parent: String = "Master"

## Low-pass filter settings for pause effect
@export_group("Pause Effect Settings")
@export var enable_pause_lowpass: bool = true
@export var pause_cutoff_hz: float = 800.0
@export var pause_resonance: float = 1.0
#endregion

#region Internal State
# Current playing music
var current_song_key: String = ""
var all_loaded_songs: Dictionary = {} # song_key -> {stems: Dictionary}

# Song data loaded from JSON
var songs: Dictionary = {}

# Zone-based music system
var active_zones: Array = [] # Array of MultimediaZone-like objects
var music_override_stack: Array[String] = []
var current_zone = null
var zone_song_map: Dictionary = {}

# Volume lerping
var volume_lerps: Dictionary = {}

# Low-pass filter for pause
var music_bus_idx: int = -1
var lowpass_effect: AudioEffectLowPassFilter = null
var lowpass_effect_idx: int = -1
var is_game_paused: bool = false
#endregion

#region Initialization
func _ready():
	# Allow music to continue during pause
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Load song data from JSON
	_load_songs_from_json()
	
	# Configure audio buses if enabled
	if auto_configure_audio_buses:
		_configure_audio_buses()
	
	# Set up low-pass filter for pause effect
	if enable_pause_lowpass:
		_setup_pause_filter()
	
	# print("[MusicManager] Initialized with ", songs.size(), " songs")

func _load_songs_from_json():
	"""Load song definitions from the configured JSON file"""
	# Try common paths first
	var common_paths = [
		songs_json_path,
		"res://scripts/json_data/numerical_data/songs.json",
		"res://data/songs.json",
		"res://json/songs.json",
		"res://songs.json"
	]
	
	var found_path = ""
	for path in common_paths:
		var test_file = FileAccess.open(path, FileAccess.READ)
		if test_file:
			test_file.close()
			found_path = path
			break
	
	# If not found, search recursively
	if found_path.is_empty():
		# print("[MusicManager] Searching for songs.json...")
		found_path = _find_file_recursive("res://", "songs.json")
	
	if found_path.is_empty():
		push_warning("[MusicManager] songs.json not found anywhere in project")
		return
	
	var file = FileAccess.open(found_path, FileAccess.READ)
	if not file:
		push_error("[MusicManager] Failed to open songs JSON: ", found_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result == OK:
		songs = json.data
		# print("[MusicManager] Loaded ", songs.size(), " songs from ", found_path)
	else:
		push_error("[MusicManager] Failed to parse songs JSON: ", json.get_error_message())

func _find_file_recursive(dir_path: String, filename: String) -> String:
	"""Recursively search for a file in a directory"""
	var dir = DirAccess.open(dir_path)
	if not dir:
		return ""
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if dir.current_is_dir():
			# Skip hidden and addon directories except our own
			if not file_name.begins_with(".") and file_name != "addons":
				var result = _find_file_recursive(dir_path.path_join(file_name), filename)
				if not result.is_empty():
					return result
		else:
			if file_name == filename:
				return dir_path.path_join(file_name)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()
	return ""

func _configure_audio_buses():
	"""Automatically configure the music audio bus if it doesn't exist"""
	music_bus_idx = AudioServer.get_bus_index(music_bus_name)
	
	if music_bus_idx == -1:
		# Music bus doesn't exist, create it
		var bus_count = AudioServer.bus_count
		AudioServer.add_bus(bus_count)
		music_bus_idx = bus_count
		AudioServer.set_bus_name(music_bus_idx, music_bus_name)
		AudioServer.set_bus_volume_db(music_bus_idx, music_bus_volume_db)
		
		# Set parent bus
		var parent_idx = AudioServer.get_bus_index(music_bus_parent)
		if parent_idx != -1:
			AudioServer.set_bus_send(music_bus_idx, music_bus_parent)
		
		# print("[MusicManager] Created audio bus: ", music_bus_name)
	else:
		# print("[MusicManager] Using existing audio bus: ", music_bus_name)
		pass

func _setup_pause_filter():
	"""Set up the low-pass filter for pause effect"""
	music_bus_idx = AudioServer.get_bus_index(music_bus_name)
	if music_bus_idx == -1:
		push_warning("[MusicManager] Cannot setup pause filter - bus not found: ", music_bus_name)
		return
	
	# Create and add low-pass filter
	lowpass_effect = AudioEffectLowPassFilter.new()
	lowpass_effect.cutoff_hz = 20000.0 # Full range (no filtering)
	lowpass_effect.resonance = pause_resonance
	AudioServer.add_bus_effect(music_bus_idx, lowpass_effect)
	lowpass_effect_idx = AudioServer.get_bus_effect_count(music_bus_idx) - 1
	AudioServer.set_bus_effect_enabled(music_bus_idx, lowpass_effect_idx, false)
	# print("[MusicManager] Low-pass filter added to ", music_bus_name, " bus")
#endregion

#region Processing
func _process(delta: float):
	# Check for pause state changes
	var currently_paused = get_tree().paused
	if currently_paused != is_game_paused:
		is_game_paused = currently_paused
		_update_lowpass_filter()
	
	# Process volume lerps
	for lerp_key in volume_lerps.keys():
		var lerp_data = volume_lerps[lerp_key]
		lerp_data.elapsed += delta
		
		var song_key = lerp_data.song_key
		var stem_name = lerp_data.stem_name
		
		if not all_loaded_songs.has(song_key):
			volume_lerps.erase(lerp_key)
			continue
		
		var song_stems = all_loaded_songs[song_key].stems
		if not song_stems.has(stem_name):
			volume_lerps.erase(lerp_key)
			continue
		
		if lerp_data.elapsed >= lerp_data.duration:
			# Lerp complete
			_set_stem_volume_immediate_for_song(song_key, stem_name, lerp_data.target_db)
			volume_lerps.erase(lerp_key)
		else:
			# Lerp in progress with equal-power crossfade curve
			var t = lerp_data.elapsed / lerp_data.duration
			var start_db = lerp_data.start_db
			var target_db = lerp_data.target_db
			
			# Convert dB to linear, apply equal-power curve, convert back to dB
			var start_linear = db_to_linear(start_db)
			var target_linear = db_to_linear(target_db)
			
			# Equal-power crossfade: smooth S-curve
			var fade_curve = (1.0 - cos(t * PI * 0.5))
			var new_linear = lerp(start_linear, target_linear, fade_curve)
			
			var new_db = linear_to_db(new_linear) if new_linear > 0.0001 else -80.0
			_set_stem_volume_immediate_for_song(song_key, stem_name, new_db)

func _update_lowpass_filter():
	"""Enable/disable and animate low-pass filter based on pause state"""
	if music_bus_idx == -1 or lowpass_effect_idx == -1:
		return
	
	if is_game_paused:
		# Enable low-pass filter with cutoff for muffled effect
		AudioServer.set_bus_effect_enabled(music_bus_idx, lowpass_effect_idx, true)
		lowpass_effect.cutoff_hz = pause_cutoff_hz
	else:
		# Disable low-pass filter
		AudioServer.set_bus_effect_enabled(music_bus_idx, lowpass_effect_idx, false)
		lowpass_effect.cutoff_hz = 20000.0
#endregion

#region Zone Management
func register_zone(zone):
	"""Called when player enters a multimedia zone with music"""
	if zone not in active_zones:
		active_zones.append(zone)
		zone_song_map[zone] = zone.music_track
		# print("[MusicManager] Registered zone: ", zone.name, " with track: ", zone.music_track)
		_evaluate_zone_music()

func unregister_zone(zone):
	"""Called when player exits a multimedia zone"""
	if zone in active_zones:
		var song_key = zone_song_map.get(zone, "")
		active_zones.erase(zone)
		zone_song_map.erase(zone)
		# print("[MusicManager] Unregistered zone: ", zone.name)
		
		# Check if any other zones use this song
		var song_still_in_use = false
		for other_zone in active_zones:
			if zone_song_map.get(other_zone, "") == song_key:
				song_still_in_use = true
				break
		
		# If no zones use this song anymore, fade it out then unload
		if not song_still_in_use and not song_key.is_empty():
			# print("[MusicManager] No zones using '", song_key, "', fading out and unloading")
			var highest_zone = _get_highest_priority_zone()
			var fade_duration = highest_zone.fade_duration if highest_zone else 1.0
			_fade_song_to_volume(song_key, -80.0, fade_duration)
			get_tree().create_timer(fade_duration).timeout.connect(func(): _unload_song(song_key))
		
		_evaluate_zone_music()

func _get_highest_priority_zone():
	"""Find and return the highest priority active zone"""
	if active_zones.is_empty():
		return null
	
	var highest_priority_zone = active_zones[0]
	for zone in active_zones:
		if zone.prio > highest_priority_zone.prio:
			highest_priority_zone = zone
	return highest_priority_zone

func _evaluate_zone_music():
	"""Determine which zone's music should play based on priority"""
	# If there's a music override, don't change music
	if not music_override_stack.is_empty():
		return
	
	if active_zones.is_empty():
		# No zones active, fade out all music
		# print("[MusicManager] No active zones - fading out all music")
		current_zone = null
		current_song_key = ""
		for song_key in all_loaded_songs.keys():
			_fade_song_to_volume(song_key, -80.0, 3.0)
		return
	
	var highest_priority_zone = _get_highest_priority_zone()
	current_zone = highest_priority_zone
	current_song_key = highest_priority_zone.music_track
	
	# Update all zone music volumes based on priority
	for zone in active_zones:
		if zone.music_track.is_empty():
			continue
		
		var is_priority = (zone == highest_priority_zone)
		var fade_duration = zone.fade_duration
		
		# Load song if not already loaded
		if not all_loaded_songs.has(zone.music_track):
			# print("[MusicManager] Loading zone music: ", zone.music_track)
			_load_song(zone.music_track, -80.0)
		
		if is_priority:
			# Fade IN to full volume (or zone-specific volumes)
			# print("[MusicManager] Fading IN priority zone music: ", zone.music_track)
			var song_stems = all_loaded_songs[zone.music_track].stems
			for stem_name in song_stems.keys():
				var target_db = zone.stem_volumes.get(stem_name, 0.0)
				_lerp_stem_volume_for_song(zone.music_track, stem_name, target_db, fade_duration)
		else:
			# Fade OUT to silence
			# print("[MusicManager] Fading OUT non-priority zone music: ", zone.music_track)
			_fade_song_to_volume(zone.music_track, -80.0, fade_duration)
#endregion

#region Music Playback - Internal Core Functions
func _fade_song_to_volume(song_key: String, target_volume_db: float, duration: float):
	"""Fade all stems of a song to a specific volume"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	for stem_name in song_stems.keys():
		_lerp_stem_volume_for_song(song_key, stem_name, target_volume_db, duration)

func _load_song(song_key: String, initial_volume_db: float = 0.0):
	"""Load and start playing a song at specified volume"""
	if not songs.has(song_key):
		print("[MusicManager] Song not found: ", song_key)
		return
	
	# Don't reload if already loaded
	if all_loaded_songs.has(song_key):
		print("[MusicManager] Song already loaded: ", song_key)
		return
	
	var song_data = songs[song_key]
	var song_stems = {}
	
	# print("[MusicManager] Loading song: ", song_key)
	
	# Load all stems
	if song_data.has("stems"):
		for stem_name in song_data.stems.keys():
			var stem_data = song_data.stems[stem_name]
			var stem_info = _create_stem(song_key, stem_name, stem_data.intro, stem_data.loop, initial_volume_db)
			if stem_info:
				song_stems[stem_name] = stem_info
	
	all_loaded_songs[song_key] = {"stems": song_stems}

func _create_stem(song_key: String, stem_name: String, intro_path: String, loop_path: String, initial_volume_db: float = 0.0):
	"""Create audio player for a stem and start playback"""
	var player = AudioStreamPlayer.new()
	player.bus = music_bus_name
	player.name = song_key + "_" + stem_name
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)
	
	# Load intro stream
	var intro_stream = load(intro_path)
	var loop_stream = load(loop_path)
	
	if not intro_stream:
		print("[MusicManager] Failed to load intro: ", intro_path)
		player.queue_free()
		return null
	
	if not loop_stream:
		print("[MusicManager] Failed to load loop: ", loop_path)
		player.queue_free()
		return null
	
	# Create stem data
	var stem_info = {
		"intro": intro_stream,
		"loop": loop_stream,
		"player": player,
		"target_volume": initial_volume_db,
		"current_volume": initial_volume_db,
		"is_looping": false,
		"song_key": song_key,
		"stem_name": stem_name
	}
	
	# Connect finished signal for intro->loop transition
	player.finished.connect(_on_stem_finished.bind(song_key, stem_name))
	
	# Start playing intro at specified volume
	player.stream = intro_stream
	player.volume_db = initial_volume_db
	player.play()
	
	# print("[MusicManager] Created stem: ", song_key, "/", stem_name, " at ", initial_volume_db, "dB")
	return stem_info

func _on_stem_finished(song_key: String, stem_name: String):
	"""Called when a stem's intro finishes - switch to loop"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	if not song_stems.has(stem_name):
		return
	
	var stem = song_stems[stem_name]
	
	if not stem.is_looping:
		# Switch to loop
		stem.is_looping = true
		stem.player.stream = stem.loop
		stem.player.play()
		# print("[MusicManager] Stem '", song_key, "/", stem_name, "' switched to loop")

func stop_all():
	"""Stop and unload all songs"""
	for song_key in all_loaded_songs.keys():
		var song_stems = all_loaded_songs[song_key].stems
		for stem_name in song_stems.keys():
			var stem = song_stems[stem_name]
			if stem.player:
				stem.player.stop()
				stem.player.queue_free()
	
	all_loaded_songs.clear()
	current_song_key = ""
	volume_lerps.clear()
	# print("[MusicManager] Stopped all music")
#endregion

#region Stem Volume Control
func isolate_stem(stem_name: String, duration: float = 1.0):
	"""Fade out all stems except the specified one"""
	if current_song_key.is_empty() or not all_loaded_songs.has(current_song_key):
		return
	
	var song_stems = all_loaded_songs[current_song_key].stems
	for stem in song_stems.keys():
		if stem == stem_name:
			lerp_stem_volume(stem, 0.0, duration) # 0 dB = normal volume
		else:
			lerp_stem_volume(stem, -80.0, duration) # -80 dB = effectively silent

func _lerp_stem_volume_for_song(song_key: String, stem_name: String, target_db: float, duration: float):
	"""Smoothly lerp a specific song's stem volume to target over duration"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	if not song_stems.has(stem_name):
		print("[MusicManager] Stem not found: ", song_key, "/", stem_name)
		return
	
	var lerp_key = song_key + "/" + stem_name
	
	if duration <= 0:
		_set_stem_volume_immediate_for_song(song_key, stem_name, target_db)
		return
	
	# Get the actual current volume
	var start_db: float
	if volume_lerps.has(lerp_key):
		var existing_lerp = volume_lerps[lerp_key]
		var t = existing_lerp.elapsed / existing_lerp.duration
		var eased_t = smoothstep(0.0, 1.0, t)
		start_db = lerp(existing_lerp.start_db, existing_lerp.target_db, eased_t)
	else:
		start_db = song_stems[stem_name].current_volume
	
	# Set up new lerp
	volume_lerps[lerp_key] = {
		"song_key": song_key,
		"stem_name": stem_name,
		"start_db": start_db,
		"target_db": target_db,
		"duration": duration,
		"elapsed": 0.0
	}

func lerp_stem_volume(stem_name: String, target_db: float, duration: float):
	"""Smoothly lerp the current song's stem volume to target over duration"""
	if current_song_key.is_empty():
		return
	_lerp_stem_volume_for_song(current_song_key, stem_name, target_db, duration)

func set_stem_volume(stem_name: String, volume_db: float):
	"""Immediately set the current song's stem volume"""
	if current_song_key.is_empty():
		return
	_set_stem_volume_immediate_for_song(current_song_key, stem_name, volume_db)

func _set_stem_volume_immediate_for_song(song_key: String, stem_name: String, volume_db: float):
	"""Internal: Set a specific song's stem volume immediately"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	if not song_stems.has(stem_name):
		return
	
	var stem = song_stems[stem_name]
	stem.player.volume_db = volume_db
	stem.current_volume = volume_db

func reset_all_stem_volumes(duration: float = 1.0):
	"""Reset all stems of current song to 0 dB (normal)"""
	if current_song_key.is_empty():
		return
	
	if not all_loaded_songs.has(current_song_key):
		return
	
	var song_stems = all_loaded_songs[current_song_key].stems
	for stem_name in song_stems.keys():
		lerp_stem_volume(stem_name, 0.0, duration)
	
	# print("[MusicManager] Resetting all stem volumes")

func _resume_song(song_key: String):
	"""Resume all stems of a song"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	for stem_name in song_stems.keys():
		var stem = song_stems[stem_name]
		if stem.player:
			stem.player.stream_paused = false
	
	# print("[MusicManager] Resumed song: ", song_key)

func _unload_song(song_key: String):
	"""Stop and remove a song from memory"""
	if not all_loaded_songs.has(song_key):
		return
	
	var song_stems = all_loaded_songs[song_key].stems
	for stem_name in song_stems.keys():
		var stem = song_stems[stem_name]
		if stem.player:
			stem.player.stop()
			stem.player.queue_free()
	
	all_loaded_songs.erase(song_key)
	# print("[MusicManager] Unloaded song: ", song_key)
#endregion

#region Music Override System
func _play_song_simple(song_key: String, fade_duration: float = 0.0, stem_volumes: Dictionary = {}):
	"""Helper: Play a song with optional fade and stem volumes"""
	if not songs.has(song_key):
		print("[MusicManager] Song not found: ", song_key)
		return
	
	# Load song if needed
	if not all_loaded_songs.has(song_key):
		var initial_volume = -80.0 if fade_duration > 0 else 0.0
		_load_song(song_key, initial_volume)
	else:
		_resume_song(song_key)
	
	# Fade in or set immediately
	var song_stems = all_loaded_songs[song_key].stems
	for stem_name in song_stems.keys():
		var target_db = stem_volumes.get(stem_name, 0.0)
		if fade_duration > 0:
			_lerp_stem_volume_for_song(song_key, stem_name, target_db, fade_duration)
		else:
			_set_stem_volume_immediate_for_song(song_key, stem_name, target_db)

func play_music_override(song_key: String, fade_duration: float = 2.0):
	"""Temporarily override zone music with a specific track"""
	var previous_song = current_song_key
	music_override_stack.append(song_key)
	current_song_key = song_key
	
	# Fade in new music
	_play_song_simple(song_key, fade_duration, {})
	
	# Fade out previous music
	if not previous_song.is_empty() and all_loaded_songs.has(previous_song):
		# print("[MusicManager] Fading out previous song: ", previous_song)
		_fade_song_to_volume(previous_song, -80.0, fade_duration)
	
	# print("[MusicManager] Music override: ", song_key, " with ", fade_duration, "s crossfade")

func stop_music_override(fade_duration: float = 2.0):
	"""Stop the current music override and restore previous music"""
	if music_override_stack.is_empty():
		# print("[MusicManager] No music override to stop")
		return
	
	var old_override = music_override_stack.pop_back()
	
	# Fade out the old override
	if all_loaded_songs.has(old_override):
		_fade_song_to_volume(old_override, -80.0, fade_duration)
	
	if not music_override_stack.is_empty():
		# Play previous override
		var previous_override = music_override_stack.back()
		_play_song_simple(previous_override, fade_duration)
		# print("[MusicManager] Restored previous override: ", previous_override)
	else:
		# No more overrides, return to zone music
		_evaluate_zone_music()
		# print("[MusicManager] Restored zone music")

func clear_all_overrides():
	"""Clear all music overrides and return to zone music"""
	music_override_stack.clear()
	_evaluate_zone_music()
	print("[MusicManager] Cleared all music overrides")
#endregion
