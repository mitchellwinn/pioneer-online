extends Node

## SoundManager - Handles sound effects, voice synthesis, and spatial audio
## Configurable plugin version that can be used across different projects

#region Configuration
## Root folder where sound files are stored
@export_dir var sounds_folder: String = "res://sounds"

## Root folder where voice files are stored
@export_dir var voices_folder: String = "res://sounds/voices"

## Path to character data JSON (for voice parameters)
## Format: {"character_key": {"voice": "file.wav", "voice_base_pitch": 1.0, "voice_pitch_range": 0.2}}
@export_file("*.json") var character_data_path: String = ""

## Whether to automatically configure audio buses on ready
@export var auto_configure_audio_buses: bool = true

## Audio bus configuration
@export_group("Audio Bus Settings")
@export var sfx_bus_name: String = "SFX"
@export var sfx_bus_volume_db: float = -14.0  # Very quiet, ambient volume
@export var sfx_bus_parent: String = "Master"

## SFX Bus Effects Configuration
@export_group("SFX Audio Effects")
@export var enable_sfx_eq: bool = true
@export var enable_sfx_lowpass: bool = true  # Add low-pass filter to soften highs
@export var enable_sfx_compressor: bool = true   # Enable gentle compression for ambient mix

# EQ Settings for softening harsh frequencies (6-band EQ bands) - ambient mix
@export var sfx_eq_low_gain_db: float = -3.0    # Band 1 (~32Hz): Reduce low-end rumble significantly
@export var sfx_eq_mid_gain_db: float = -2.5    # Band 3 (~320Hz): Soften mid-range for warmth
@export var sfx_eq_high_gain_db: float = -8.0   # Band 5 (~3200Hz): Heavily tame piercing highs

# Low-pass filter settings for additional high-frequency softening
@export var sfx_lowpass_cutoff_hz: float = 6000.0  # Lower cutoff for more ambient sound
@export var sfx_lowpass_resonance: float = 0.3     # Gentle resonance

# Compressor settings for gentle ambient mixing
@export var sfx_compressor_threshold_db: float = -6.0
@export var sfx_compressor_ratio: float = 1.5
@export var sfx_compressor_attack_ms: float = 20.0
@export var sfx_compressor_release_ms: float = 500.0

@export var voice_bus_name: String = "Voice"
@export var voice_bus_volume_db: float = 0.0
@export var voice_bus_parent: String = "Master"

## Voice player pool settings
@export_group("Voice Pool Settings")
@export var max_voice_players: int = 10

## Sound preloading (eliminates lag on first play)
@export_group("Preloading")
@export var preload_on_ready: bool = true
## Base paths to preload (e.g. "res://sounds/dash" will preload dash_1.wav, dash_2.wav, etc.)
@export var sounds_to_preload: Array[String] = [
	"res://sounds/dash",
	"res://sounds/step",
	"res://sounds/slash",
	"res://sounds/explosion"
]
#endregion

#region Internal State
# Audio player pool for overlapping voice sounds
var voice_player_pool: Array[AudioStreamPlayer] = []

# Character data loaded from JSON
var character_data: Dictionary = {}

# Cache for sound variations (base_path -> array of full paths)
var _variation_cache: Dictionary = {}

# Cache for preloaded audio streams (full_path -> AudioStream)
var _stream_cache: Dictionary = {}
#endregion

#region Initialization
func _ready():
	# Load character data if path is provided
	if not character_data_path.is_empty():
		_load_character_data()
	
	# Configure audio buses if enabled
	if auto_configure_audio_buses:
		_configure_audio_buses()
	
	# Initialize audio player pool
	_initialize_voice_pool()
	
	# Preload common sounds to avoid lag on first play
	if preload_on_ready and sounds_to_preload.size() > 0:
		preload_sound_variations(sounds_to_preload)
	
	# print("[SoundManager] Initialized with voice pool size: ", max_voice_players)

func _load_character_data():
	"""Load character data from the configured JSON file"""
	var file = FileAccess.open(character_data_path, FileAccess.READ)
	if not file:
		push_warning("[SoundManager] Character data JSON not found at: ", character_data_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result == OK:
		character_data = json.data
		# print("[SoundManager] Loaded ", character_data.size(), " character voice configs from ", character_data_path)
	else:
		push_error("[SoundManager] Failed to parse character data JSON: ", json.get_error_message())

func _configure_audio_buses():
	"""Automatically configure the sound audio buses if they don't exist"""
	# Configure SFX bus
	var sfx_bus_idx = AudioServer.get_bus_index(sfx_bus_name)
	if sfx_bus_idx == -1:
		var bus_count = AudioServer.bus_count
		AudioServer.add_bus(bus_count)
		sfx_bus_idx = bus_count
		AudioServer.set_bus_name(sfx_bus_idx, sfx_bus_name)
		AudioServer.set_bus_volume_db(sfx_bus_idx, sfx_bus_volume_db)

		var parent_idx = AudioServer.get_bus_index(sfx_bus_parent)
		if parent_idx != -1:
			AudioServer.set_bus_send(sfx_bus_idx, sfx_bus_parent)

		# Add audio effects to soften the SFX
		_add_sfx_audio_effects(sfx_bus_idx)

		# print("[SoundManager] Created audio bus: ", sfx_bus_name)
	else:
		# Ensure effects are applied to existing bus too
		_add_sfx_audio_effects(sfx_bus_idx)
		# print("[SoundManager] Using existing audio bus: ", sfx_bus_name)
		pass
	
	# Configure Voice bus
	var voice_bus_idx = AudioServer.get_bus_index(voice_bus_name)
	if voice_bus_idx == -1:
		var bus_count = AudioServer.bus_count
		AudioServer.add_bus(bus_count)
		voice_bus_idx = bus_count
		AudioServer.set_bus_name(voice_bus_idx, voice_bus_name)
		AudioServer.set_bus_volume_db(voice_bus_idx, voice_bus_volume_db)
		
		var parent_idx = AudioServer.get_bus_index(voice_bus_parent)
		if parent_idx != -1:
			AudioServer.set_bus_send(voice_bus_idx, voice_bus_parent)
		
		# print("[SoundManager] Created audio bus: ", voice_bus_name)
	else:
		# print("[SoundManager] Using existing audio bus: ", voice_bus_name)
		pass

func _add_sfx_audio_effects(bus_idx: int):
	"""Add audio effects to soften and enhance the SFX bus"""
	if enable_sfx_eq:
		_add_eq_effect(bus_idx)
	if enable_sfx_lowpass:
		_add_lowpass_effect(bus_idx)
	if enable_sfx_compressor:
		_add_compressor_effect(bus_idx)

func _add_eq_effect(bus_idx: int):
	"""Add 6-band EQ to soften harsh frequencies"""
	var eq_effect = AudioEffectEQ6.new()

	# Set gains for different frequency bands (6-band EQ has bands 1-6)
	# Band 1: ~32Hz (low), Band 2: ~100Hz, Band 3: ~320Hz (mid), Band 4: ~1000Hz, Band 5: ~3200Hz (high), Band 6: ~10000Hz
	eq_effect.set_band_gain_db(0, sfx_eq_low_gain_db)    # Band 1: Low frequencies
	eq_effect.set_band_gain_db(2, sfx_eq_mid_gain_db)    # Band 3: Mid frequencies
	eq_effect.set_band_gain_db(4, sfx_eq_high_gain_db)   # Band 5: High frequencies

	AudioServer.add_bus_effect(bus_idx, eq_effect)
	print("[SoundManager] Added 6-band EQ effect to SFX bus")

func _add_lowpass_effect(bus_idx: int):
	"""Add low-pass filter to soften high frequencies"""
	var lowpass_effect = AudioEffectLowPassFilter.new()
	lowpass_effect.cutoff_hz = sfx_lowpass_cutoff_hz
	lowpass_effect.resonance = sfx_lowpass_resonance

	AudioServer.add_bus_effect(bus_idx, lowpass_effect)
	print("[SoundManager] Added low-pass filter to SFX bus")

func _add_compressor_effect(bus_idx: int):
	"""Add compressor to even out dynamics and prevent harsh peaks"""
	var compressor_effect = AudioEffectCompressor.new()
	compressor_effect.threshold = sfx_compressor_threshold_db
	compressor_effect.ratio = sfx_compressor_ratio
	compressor_effect.attack_us = sfx_compressor_attack_ms * 1000  # Convert ms to microseconds
	compressor_effect.release_ms = sfx_compressor_release_ms
	compressor_effect.mix = 1.0  # Full wet
	compressor_effect.sidechain = ""  # No sidechain

	AudioServer.add_bus_effect(bus_idx, compressor_effect)
	print("[SoundManager] Added compressor effect to SFX bus")

func _initialize_voice_pool():
	"""Initialize the audio player pool for voice sounds"""
	for i in range(max_voice_players):
		var player = AudioStreamPlayer.new()
		player.bus = voice_bus_name
		add_child(player)
		voice_player_pool.append(player)
#endregion

#region Voice Playback
## Play a character voice sound for a single letter/character
## Requires character_data to be loaded or set manually
func play_voice(character_key: String):
	var char_data = get_character_data(character_key)
	if char_data.is_empty():
		return
	
	var voice_file = char_data.get("voice", "basic.wav")
	var base_pitch = char_data.get("voice_base_pitch", 1.0)
	var pitch_range = char_data.get("voice_pitch_range", 0.2)
	
	# Calculate randomized pitch
	var random_pitch = base_pitch + randf_range(-pitch_range / 2.0, pitch_range / 2.0)
	
	# Find available player
	var player = get_available_voice_player()
	if player:
		var voice_path = voices_folder + "/" + voice_file
		var voice_stream = load(voice_path)
		if voice_stream:
			player.stream = voice_stream
			player.pitch_scale = random_pitch
			player.play()
		else:
			push_warning("[SoundManager] Voice file not found: ", voice_path)

func get_available_voice_player() -> AudioStreamPlayer:
	"""Find a player that's not currently playing"""
	for player in voice_player_pool:
		if not player.playing:
			return player
	# If all are busy, return the first one (it will be interrupted)
	return voice_player_pool[0]

func get_character_data(character_key: String) -> Dictionary:
	"""Get character voice data - can be overridden to use external data source"""
	return character_data.get(character_key, {})

## Set character data manually (alternative to JSON loading)
func set_character_data(data: Dictionary):
	character_data = data
#endregion

#region Sound Playback
## Simple play sound function - plays on SFX bus
## The sound will auto-delete when finished
func play_sound(stream_path: String, volume_db: float = 0.0):
	# Get stream from cache or load it
	var stream = _get_cached_stream(stream_path)
	if not stream:
		return
	
	var player = AudioStreamPlayer.new()
	player.bus = sfx_bus_name
	player.volume_db = volume_db
	player.stream = stream
	get_tree().root.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

## Play sound with a pre-loaded AudioStream resource
func play_sound_stream(stream: AudioStream, volume_db: float = 0.0):
	var player = AudioStreamPlayer.new()
	player.bus = sfx_bus_name
	player.volume_db = volume_db
	player.stream = stream
	get_tree().root.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

## Play sound with automatic variation handling (looking for _1, _2, etc.)
## If path is "res://sounds/hit", it looks for "res://sounds/hit_1.wav", "res://sounds/hit_2.wav" etc.
## If no variations found, it tries "res://sounds/hit.wav"
func play_sound_with_variation(path: String, volume_db: float = 0.0):
	var final_path = _get_random_variation_path(path)
	if final_path.is_empty():
		return
	
	# Get stream from cache or load it
	var stream = _get_cached_stream(final_path)
	if stream:
		play_sound_stream(stream, volume_db)
#endregion

#region Caching Helpers
## Get a random variation path from cache (builds cache on first call)
func _get_random_variation_path(path: String) -> String:
	var extension = path.get_extension()
	var base_path = path
	
	# If no extension provided, default to wav
	if extension.is_empty():
		extension = "wav"
	else:
		base_path = path.trim_suffix("." + extension)
	
	# Check cache first
	if _variation_cache.has(base_path):
		var cached: Array = _variation_cache[base_path]
		if cached.size() > 0:
			return cached[randi() % cached.size()]
		return ""
	
	# Not in cache - scan for variations (only happens once per base_path)
	var variations: Array = []
	var i = 1
	while i <= 20:
		var variation_path = base_path + "_" + str(i) + "." + extension
		if ResourceLoader.exists(variation_path):
			variations.append(variation_path)
			i += 1
		else:
			break
	
	# If no numbered variations found, check for base file
	if variations.size() == 0:
		var direct_path = base_path + "." + extension
		if ResourceLoader.exists(direct_path):
			variations.append(direct_path)
	
	# Cache the result (even if empty - so we don't re-scan)
	_variation_cache[base_path] = variations
	
	if variations.size() > 0:
		print("[SoundManager] Cached %d variations for: %s" % [variations.size(), base_path])
		return variations[randi() % variations.size()]
	else:
		push_warning("[SoundManager] No sound files found for: ", path)
		return ""

## Get stream from cache or load and cache it
func _get_cached_stream(path: String) -> AudioStream:
	if path.is_empty():
		return null
	
	# Check cache first
	if _stream_cache.has(path):
		return _stream_cache[path]
	
	# Load and cache
	var stream = load(path)
	if stream:
		_stream_cache[path] = stream
	else:
		push_warning("[SoundManager] Failed to load sound: ", path)
	return stream

## Preload sounds to avoid hitches on first play
## Call this during loading screens or game init
func preload_sound_variations(base_paths: Array):
	for base_path in base_paths:
		# This populates the variation cache
		var first_path = _get_random_variation_path(base_path)
		if not first_path.is_empty():
			# Preload all variations into stream cache
			var extension = base_path.get_extension()
			if extension.is_empty():
				extension = "wav"
			var clean_base = base_path.trim_suffix("." + extension) if not extension.is_empty() else base_path
			
			if _variation_cache.has(clean_base):
				for sound_path in _variation_cache[clean_base]:
					_get_cached_stream(sound_path)
				print("[SoundManager] Preloaded %d sounds for: %s" % [_variation_cache[clean_base].size(), base_path])

## Clear all caches (useful if sounds change at runtime)
func clear_sound_cache():
	_variation_cache.clear()
	_stream_cache.clear()
	print("[SoundManager] Sound cache cleared")
#endregion

#region 3D Sound Playback
## Play 3D sound with automatic variation and random pitch
## If path is "res://sounds/slash", it looks for "res://sounds/slash_1.wav", "res://sounds/slash_2.wav" etc.
## pitch_variation: random pitch range (0.1 means ±10% pitch variation)
func play_sound_3d_with_variation(path: String, position: Vector3 = Vector3.ZERO, parent_node: Node3D = null, volume_db: float = 0.0, pitch_variation: float = 0.1):
	var final_path = _get_random_variation_path(path)
	if final_path.is_empty():
		return
	
	# Get stream from cache or load it
	var stream = _get_cached_stream(final_path)
	if not stream:
		return
	
	# Create 3D player with random pitch
	var player = AudioStreamPlayer3D.new()
	player.bus = sfx_bus_name
	player.volume_db = volume_db
	player.pitch_scale = randf_range(1.0 - pitch_variation, 1.0 + pitch_variation)
	
	if parent_node:
		parent_node.add_child(player)
		player.position = Vector3.ZERO
	else:
		get_tree().root.add_child(player)
		player.global_position = position
	
	player.stream = stream
	player.play()
	player.finished.connect(player.queue_free)
	print("[SoundManager] Playing 3D sound: %s at %s" % [final_path, position])

## Play 3D sound at a specific position or attached to a node
func play_sound_3d(stream_path: String, position: Vector3 = Vector3.ZERO, parent_node: Node3D = null, volume_db: float = 0.0):
	# Get stream from cache or load it
	var stream = _get_cached_stream(stream_path)
	if not stream:
		return
	
	var player = AudioStreamPlayer3D.new()
	player.bus = sfx_bus_name
	player.volume_db = volume_db
	player.stream = stream
	
	if parent_node:
		# Attach to parent node (follows it)
		parent_node.add_child(player)
		player.position = Vector3.ZERO
	else:
		# Place at world position
		get_tree().root.add_child(player)
		player.global_position = position
	
	player.play()
	player.finished.connect(player.queue_free)

## Play 3D sound with a pre-loaded AudioStream resource
func play_sound_3d_stream(stream: AudioStream, position: Vector3 = Vector3.ZERO, parent_node: Node3D = null, volume_db: float = 0.0):
	var player = AudioStreamPlayer3D.new()
	player.bus = sfx_bus_name
	player.volume_db = volume_db
	player.stream = stream
	
	if parent_node:
		parent_node.add_child(player)
		player.position = Vector3.ZERO
	else:
		get_tree().root.add_child(player)
		player.global_position = position
	
	player.play()
	player.finished.connect(player.queue_free)
#endregion

#region Legacy Compatibility Functions
## Legacy sound functions for backward compatibility
func play_sound_legacy(sfx_player: PackedScene, stream: String):
	var player = sfx_player.instantiate()
	get_tree().root.add_child(player)
	player.stream = load(stream)
	player.play()
	while player.is_playing:
		await get_tree().process_frame
	player.queue_free()

func play_sound_from_player(sfx_player: AudioStreamPlayer2D, stream: String):
	sfx_player.stream = load(stream)
	sfx_player.play()
#endregion
