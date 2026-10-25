extends Node
## One persistent player per SceneTree; settings IO is always caller-injected.
## No autoload, normal save path, SFX bus, or economic save is referenced here.
const ROOT_NAME: String = "MoriMusicController"
const SCRIPT_PATH: String = "res://music_controller.gd"
const DEFAULT_TRACK: String = "res://assets/audio/komorebi_kitchen_loop.ogg"
const SETTINGS_VERSION: int = 1
const DEFAULT_VOLUME: float = 0.35
static var _instances: Dictionary = {}
static var _owned_bus_name: String = ""

var player: AudioStreamPlayer
var enabled: bool = true
var volume: float = DEFAULT_VOLUME
var paused: bool = false
var settings_path: String = ""
var track_path: String = DEFAULT_TRACK
var available: bool = false
var save_allowed: bool = false
var start_count: int = 0
var bus_name: String = "Music"
var _configured: bool = false
var _has_started: bool = false
var _tree_id: int = 0


static func acquire(tree: SceneTree, caller_settings_path: String, caller_track_path: String = DEFAULT_TRACK):
	if tree == null or tree.root == null:
		return null
	var tree_id: int = tree.get_instance_id()
	var existing = null
	if _instances.has(tree_id):
		existing = _instances[tree_id].get_ref()
	if existing == null:
		existing = tree.root.get_node_or_null(NodePath(ROOT_NAME))
	if existing != null and is_instance_valid(existing) and not existing.is_queued_for_deletion():
		if existing.get_script() != load(SCRIPT_PATH):
			return null
		existing._configure(caller_settings_path, caller_track_path)
		_instances[tree_id] = weakref(existing)
		return existing
	var controller = load(SCRIPT_PATH).new()
	controller.name = ROOT_NAME
	controller._tree_id = tree_id
	controller.process_mode = Node.PROCESS_MODE_ALWAYS
	controller._configure(caller_settings_path, caller_track_path)
	_instances[tree_id] = weakref(controller)
	# main._ready may run while root is adding the current scene. The registry
	# makes even two same-frame acquisitions reuse this pending singleton.
	tree.root.add_child.call_deferred(controller)
	return controller


func _ready() -> void:
	_apply_playback()


func _exit_tree() -> void:
	# Release the active playback before the audio mixing thread's final tick.
	if is_instance_valid(player):
		player.stop()
		player.stream = null
	_has_started = false
	available = false
	if _instances.has(_tree_id) and _instances[_tree_id].get_ref() == self:
		_instances.erase(_tree_id)


func _configure(caller_settings_path: String, caller_track_path: String) -> void:
	_ensure_player()
	if not _configured or settings_path != caller_settings_path:
		settings_path = caller_settings_path
		enabled = true
		volume = DEFAULT_VOLUME
		_read_settings()
	_configured = true
	if track_path != caller_track_path or not available:
		_load_track(caller_track_path)
	_apply_volume()
	_apply_playback()


func _ensure_player() -> void:
	if is_instance_valid(player):
		return
	_ensure_bus()
	player = AudioStreamPlayer.new()
	player.name = "MusicPlayer"
	player.bus = bus_name
	player.volume_db = 0.0
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)


func _ensure_bus() -> void:
	if not _owned_bus_name.is_empty() and AudioServer.get_bus_index(_owned_bus_name) >= 0:
		bus_name = _owned_bus_name
		return
	var candidate: String = "Music"
	var suffix: int = 1
	while AudioServer.get_bus_index(candidate) >= 0:
		candidate = "MoriMusic" if suffix == 1 else "MoriMusic%d" % suffix
		suffix += 1
	AudioServer.add_bus()
	var index: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, candidate)
	AudioServer.set_bus_send(index, "Master")
	_owned_bus_name = candidate
	bus_name = candidate


func _load_track(path: String) -> void:
	if _has_started:
		player.stop()
	_has_started = false
	available = false
	track_path = path
	player.stream = null
	# Missing resources are an expected setup state. No polling or warning spam.
	if path.is_empty() or not ResourceLoader.exists(path, "AudioStream"):
		return
	var source: Resource = ResourceLoader.load(path, "AudioStream")
	if not source is AudioStreamOggVorbis:
		return
	var stream: AudioStreamOggVorbis = source.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	player.stream = stream
	available = true


func set_enabled(value: bool) -> void:
	enabled = value
	_apply_playback()


func set_volume(value: float) -> void:
	if not is_finite(value):
		return
	volume = clampf(value, 0.0, 1.0)
	_apply_volume()


func set_paused(value: bool) -> void:
	paused = value
	_apply_playback()


func _apply_volume() -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0 or bus_name != _owned_bus_name:
		return
	AudioServer.set_bus_volume_db(index, -80.0 if volume == 0.0 else linear_to_db(volume))
	AudioServer.set_bus_mute(index, volume == 0.0)


func _apply_playback() -> void:
	if not available or not is_instance_valid(player) or not is_inside_tree():
		return
	var should_pause: bool = paused or not enabled
	if not _has_started and not should_pause:
		player.play()
		_has_started = true
		start_count += 1
	player.stream_paused = should_pause


func _settings_path_valid() -> bool:
	return not settings_path.is_empty() and not settings_path.begins_with("res://") and (settings_path.begins_with("user://") or settings_path.is_absolute_path())


func _read_settings() -> void:
	save_allowed = _settings_path_valid()
	if not save_allowed or not FileAccess.file_exists(settings_path):
		return
	var file: FileAccess = FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		save_allowed = false
		return
	var parser := JSON.new()
	var error: Error = parser.parse(file.get_as_text())
	file.close()
	if error != OK or not _valid_settings(parser.data):
		save_allowed = false
		return
	enabled = bool(parser.data.enabled)
	volume = float(parser.data.volume)


func _valid_settings(data: Variant) -> bool:
	if not data is Dictionary or typeof(data.get("enabled")) != TYPE_BOOL:
		return false
	var version: Variant = data.get("version")
	if (typeof(version) != TYPE_INT and typeof(version) != TYPE_FLOAT) or float(version) != SETTINGS_VERSION:
		return false
	var level: Variant = data.get("volume")
	return (typeof(level) == TYPE_INT or typeof(level) == TYPE_FLOAT) and is_finite(float(level)) and float(level) >= 0.0 and float(level) <= 1.0


func save_settings() -> Error:
	if not save_allowed or not _settings_path_valid():
		return ERR_INVALID_DATA
	var temporary: String = settings_path + ".tmp"
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": SETTINGS_VERSION, "enabled": enabled, "volume": volume}, "\t"))
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		return error
	return DirAccess.rename_absolute(temporary, settings_path)
