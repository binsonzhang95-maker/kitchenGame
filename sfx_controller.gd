## Small, instance-owned UI/gameplay SFX controller.
##
## This intentionally plays local phone/desktop feedback only.  Its string IDs
## are not hardware sound-number IDs and it does not create toy voice, network,
## or TTS audio.
class_name SFXController
extends Node

const SFX_IDS := [
	"ui_click",
	"ui_back",
	"card_not_needed",
	"card_unknown",
	"step_complete",
	"dish_complete",
	"toy_connected",
	"toy_disconnected",
]

const PATH_PREFIX := "res://assets/audio/sfx/"
const DEFAULT_VOLUME := 0.6
const DEFAULT_CHANNELS := 4
const MAX_CHANNELS := 8
const DEBUG_EVENT_HISTORY_LIMIT := 32

var _path_overrides: Dictionary = {}
var _asset_cache: Dictionary = {}
var _attempted_ids: Dictionary = {}
var _missing_ids: Dictionary = {}
var _invalid_ids: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _last_used: Array[int] = []
var _use_counter := 0
var _bus_name := ""
var _bus_created := false
var _owned_bus_marker: AudioEffect
var _is_setup := false
var _enabled := true
var _volume := DEFAULT_VOLUME
var _played_ids: Array[String] = []
var _played_event_count := 0
var _play_counts: Dictionary = {}


func _init(path_overrides: Dictionary = {}, channel_count: int = DEFAULT_CHANNELS) -> void:
	_path_overrides = _valid_overrides(path_overrides)
	# A fixed, small pool is deliberate: rapid feedback replaces the oldest voice.
	channel_count = clampi(channel_count, 1, MAX_CHANNELS)
	for index in range(channel_count):
		_last_used.append(-index - 1)


func _ready() -> void:
	setup()


## Creates this controller's bus and fixed player pool once it is in the tree.
## Calling it earlier is safe and does not allocate an audio bus.
func setup() -> void:
	if _is_setup or not is_inside_tree():
		return
	_bus_name = _create_unique_bus()
	_bus_created = true
	for index in range(_last_used.size()):
		var player := AudioStreamPlayer.new()
		player.bus = _bus_name
		player.name = "SFXChannel%d" % index
		add_child(player)
		_players.append(player)
	_is_setup = true
	_apply_bus_settings()


## Plays one of SFX_IDS. Returns false for disabled, invalid, or unavailable SFX.
func play(id: String) -> bool:
	if not SFX_IDS.has(id):
		_invalid_ids[id] = true
		return false
	setup()
	if not _is_setup or not _enabled:
		return false
	if not _has_owned_bus():
		# The named bus may have been removed and recreated by another owner.
		# Stop our voices rather than allowing a stale route to reach that bus.
		_stop_players()
		return false
	var stream := _load_stream(id)
	if stream == null:
		return false
	var player := _next_player()
	player.stop()
	player.stream = stream
	player.play()
	_use_counter += 1
	_last_used[_players.find(player)] = _use_counter
	_played_event_count += 1
	if _played_ids.size() == DEBUG_EVENT_HISTORY_LIMIT:
		_played_ids.pop_front()
	_played_ids.append(id)
	_play_counts[id] = int(_play_counts.get(id, 0)) + 1
	return true


## Enables/disables only this instance's SFX bus; music and Master are untouched.
func set_enabled(value: bool) -> void:
	_enabled = value
	if _is_setup:
		_apply_bus_settings()


## Sets local SFX volume in linear 0..1. NaN/Infinity leave the current value.
func set_volume(value: float) -> void:
	if is_nan(value) or is_inf(value):
		return
	_volume = clampf(value, 0.0, 1.0)
	if _is_setup:
		_apply_bus_settings()


## Clears positive and negative resource caches, then re-attempts the known IDs.
## It never changes enabled or volume settings.
func refresh_assets() -> void:
	_asset_cache.clear()
	_attempted_ids.clear()
	_missing_ids.clear()
	for id in SFX_IDS:
		_load_stream(id)


## A snapshot for diagnostics/tests. Returned arrays/dictionaries are detached.
func diagnostics() -> Dictionary:
	return {
		"bus_name": _bus_name,
		"enabled": _enabled,
		"volume": _volume,
		"missing_ids": _missing_ids.keys(),
		"invalid_ids": _invalid_ids.keys(),
		"cached_ids": _attempted_ids.keys(),
		"channel_count": _players.size(),
	}


## Read-only-by-copy testing/telemetry state; it never queries the audio device.
## played_ids is the most recent DEBUG_EVENT_HISTORY_LIMIT successful plays.
func get_debug_state() -> Dictionary:
	return {
		"played_ids": _played_ids.duplicate(),
		"played_event_history_limit": DEBUG_EVENT_HISTORY_LIMIT,
		"played_event_count": _played_event_count,
		"play_counts": _play_counts.duplicate(true),
		"channel_count": _players.size(),
		"bus_name": _bus_name,
		"enabled": _enabled,
		"volume": _volume,
	}


func _exit_tree() -> void:
	_stop_players(true)
	_players.clear()
	_asset_cache.clear()
	if _bus_created:
		_remove_owned_bus()
		_bus_created = false
		_owned_bus_marker = null
		_is_setup = false


func _valid_overrides(overrides: Dictionary) -> Dictionary:
	var valid := {}
	for id in SFX_IDS:
		if overrides.has(id) and overrides[id] is String:
			valid[id] = overrides[id]
	return valid


func _path_for(id: String) -> String:
	return str(_path_overrides.get(id, PATH_PREFIX + id + ".ogg"))


func _load_stream(id: String) -> AudioStream:
	if _attempted_ids.has(id):
		return _asset_cache.get(id) as AudioStream
	_attempted_ids[id] = true
	var path := _path_for(id)
	if not ResourceLoader.exists(path, "AudioStream"):
		_asset_cache[id] = null
		_missing_ids[id] = true
		return null
	# This controller owns its cache so refresh_assets() can genuinely retry a
	# changed resource instead of retaining ResourceLoader's global cached copy.
	var loaded := ResourceLoader.load(path, "AudioStream", ResourceLoader.CACHE_MODE_IGNORE)
	var stream := loaded as AudioStream
	_asset_cache[id] = stream
	if stream == null:
		# Kept as a set: a missing asset is diagnostic information once, not spam.
		_missing_ids[id] = true
	return stream


func _next_player() -> AudioStreamPlayer:
	var oldest_index := 0
	var oldest_use := _last_used[0]
	for index in range(1, _players.size()):
		if _last_used[index] < oldest_use:
			oldest_index = index
			oldest_use = _last_used[index]
	return _players[oldest_index]


func _create_unique_bus() -> String:
	var suffix := 0
	while true:
		var candidate := "MoriSFX" if suffix == 0 else "MoriSFX%d" % suffix
		if AudioServer.get_bus_index(candidate) == -1:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, candidate)
			# A neutral instance-owned effect distinguishes this bus from a later
			# external bus that reuses the same name.
			_owned_bus_marker = AudioEffectAmplify.new()
			_owned_bus_marker.volume_db = 0.0
			AudioServer.add_bus_effect(index, _owned_bus_marker)
			return candidate
		suffix += 1
	return "" # Satisfies static return analysis; the loop always returns above.


func _apply_bus_settings() -> void:
	if not _has_owned_bus():
		return
	var index := AudioServer.get_bus_index(_bus_name)
	AudioServer.set_bus_mute(index, not _enabled)
	# Godot's linear_to_db(0) is -inf; use a finite practical silence instead.
	AudioServer.set_bus_volume_db(index, -80.0 if is_zero_approx(_volume) else linear_to_db(_volume))


func _has_owned_bus() -> bool:
	if not _bus_created or _owned_bus_marker == null:
		return false
	var index := AudioServer.get_bus_index(_bus_name)
	if index == -1:
		return false
	for effect_index in range(AudioServer.get_bus_effect_count(index)):
		if is_same(AudioServer.get_bus_effect(index, effect_index), _owned_bus_marker):
			return true
	return false


func _stop_players(clear_streams: bool = false) -> void:
	for player in _players:
		if is_instance_valid(player):
			player.stop()
			if clear_streams:
				# stop() only ends scheduling; the child can otherwise keep its stream
				# (and its decoder/playback) alive until the audio thread catches up.
				player.stream = null


func _remove_owned_bus() -> void:
	var index := AudioServer.get_bus_index(_bus_name)
	if index == -1 or _owned_bus_marker == null:
		return
	for effect_index in range(AudioServer.get_bus_effect_count(index)):
		if is_same(AudioServer.get_bus_effect(index, effect_index), _owned_bus_marker):
			AudioServer.remove_bus_effect(index, effect_index)
			AudioServer.remove_bus(index)
			return
