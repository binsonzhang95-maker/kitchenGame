extends RefCounted
## Small, visual-only player for the four supplied kitchen action clips.
## It deliberately owns no recipe, inventory, economy, or controller state.

const ART_ROOT := "res://cooking_art/animations"
const CLIP_NAMES: Array[String] = ["chop", "pour_water", "stir_fry", "stir"]
const FRAME_SIZE := Vector2i(256, 256)
const ANCHOR := Vector2i(128, 242)

var clip_id: String = ""
var playing: bool = false
var paused: bool = false
var completed: bool = false
var looped: bool = false
var last_error: String = ""

var _metadata: Dictionary = {}
var _atlas_frames: Array[AtlasTexture] = []
var _durations_ms: Array[float] = []
var _cycle_duration_ms: float = 0.0
var _elapsed_ms: float = 0.0
var _frame_index: int = 0
var _completion_reported: bool = false


## Loads and validates the clip metadata and every texture it names.
## The displayed frames remain full 256x256 atlas regions; no tight cropping occurs.
func load_clip(requested_clip: String) -> bool:
	_clear()
	if requested_clip not in CLIP_NAMES:
		return _fail("Unknown cooking clip: " + requested_clip)
	var clip_root := ART_ROOT.path_join(requested_clip)
	var metadata_path := clip_root.path_join("animation.json")
	if not FileAccess.file_exists(metadata_path):
		return _fail("Missing animation metadata: " + metadata_path)
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(metadata_path)) != OK or not parser.data is Dictionary:
		return _fail("Invalid animation metadata: " + metadata_path)
	var data: Dictionary = parser.data
	var validation_error := _validate_metadata(data, requested_clip)
	if not validation_error.is_empty():
		return _fail(validation_error)

	var sheet_path := clip_root.path_join(str(data.sheet))
	var sheet := _load_texture(sheet_path)
	if sheet == null:
		return _fail("Missing or unreadable animation sheet: " + sheet_path)
	if sheet.get_width() != FRAME_SIZE.x * 4 or sheet.get_height() != FRAME_SIZE.y:
		return _fail("Unexpected animation sheet size: " + sheet_path)

	var loaded_frames: Array[AtlasTexture] = []
	var loaded_durations: Array[float] = []
	for index in range(4):
		var frame: Dictionary = data.frames[index]
		var frame_path := clip_root.path_join(str(frame.file))
		var source_frame := _load_texture(frame_path)
		if source_frame == null:
			return _fail("Missing or unreadable animation frame: " + frame_path)
		if source_frame.get_width() != FRAME_SIZE.x or source_frame.get_height() != FRAME_SIZE.y:
			return _fail("Unexpected animation frame size: " + frame_path)
		var atlas_frame := AtlasTexture.new()
		atlas_frame.atlas = sheet
		atlas_frame.region = Rect2(index * FRAME_SIZE.x, 0, FRAME_SIZE.x, FRAME_SIZE.y)
		loaded_frames.append(atlas_frame)
		loaded_durations.append(float(data.durations_ms[index]))

	clip_id = requested_clip
	_metadata = data.duplicate(true)
	_atlas_frames = loaded_frames
	_durations_ms = loaded_durations
	for duration_ms: float in _durations_ms:
		_cycle_duration_ms += duration_ms
	looped = bool(data.loop)
	return true


## Starts a fresh non-looping playback, regardless of the source clip default.
func play_once() -> bool:
	if clip_id.is_empty():
		return false
	looped = false
	return replay()


## Starts a fresh looping playback, regardless of the source clip default.
func play_loop() -> bool:
	if clip_id.is_empty():
		return false
	looped = true
	return replay()


## Restarts the selected clip in its currently selected playback mode.
func replay() -> bool:
	if clip_id.is_empty() or _atlas_frames.is_empty():
		return false
	_elapsed_ms = 0.0
	_frame_index = 0
	playing = true
	paused = false
	completed = false
	_completion_reported = false
	return true


## Stops and resets visual state to frame zero. It does not emit completion.
func stop() -> void:
	_elapsed_ms = 0.0
	_frame_index = 0
	playing = false
	paused = false
	completed = false
	_completion_reported = false


func set_paused(value: bool) -> void:
	paused = value


## Advances deterministic visual time. Returns true exactly once when a one-shot ends.
func advance(delta_seconds: float) -> bool:
	if not playing or paused or not is_finite(delta_seconds) or delta_seconds <= 0.0:
		return false
	var next_ms := _elapsed_ms + delta_seconds * 1000.0
	if looped:
		_elapsed_ms = fposmod(next_ms, _cycle_duration_ms)
		_set_frame_from_elapsed()
		return false
	if next_ms < _cycle_duration_ms:
		_elapsed_ms = next_ms
		_set_frame_from_elapsed()
		return false
	_elapsed_ms = _cycle_duration_ms
	_frame_index = _atlas_frames.size() - 1
	playing = false
	completed = true
	if _completion_reported:
		return false
	_completion_reported = true
	return true


func current_frame() -> int:
	return _frame_index


func current_texture() -> Texture2D:
	return current_atlas_texture()


func current_atlas_texture() -> AtlasTexture:
	return _atlas_frames[_frame_index] if not _atlas_frames.is_empty() else null


func is_complete() -> bool:
	return completed


func metadata() -> Dictionary:
	return _metadata.duplicate(true)


func anchor() -> Vector2i:
	return ANCHOR


func _set_frame_from_elapsed() -> void:
	var cursor := 0.0
	for index in range(_durations_ms.size()):
		cursor += _durations_ms[index]
		if _elapsed_ms < cursor:
			_frame_index = index
			return
	_frame_index = _durations_ms.size() - 1


func _validate_metadata(data: Dictionary, expected_clip: String) -> String:
	if str(data.get("clip", "")) != expected_clip:
		return "Animation clip name does not match directory: " + expected_clip
	if str(data.get("sheet", "")) != "sheet.png":
		return "Animation sheet name is invalid: " + expected_clip
	if not _matches_integers(data.get("frame_size"), [FRAME_SIZE.x, FRAME_SIZE.y]):
		return "Animation frame size must be 256x256: " + expected_clip
	if not _is_integer(data.get("frame_count")) or int(data.frame_count) != 4:
		return "Animation frame count must be four: " + expected_clip
	if not _matches_integers(data.get("pivot"), [ANCHOR.x, ANCHOR.y]):
		return "Animation anchor must be (128,242): " + expected_clip
	if typeof(data.get("loop")) != TYPE_BOOL:
		return "Animation loop flag is missing: " + expected_clip
	if not data.get("durations_ms") is Array or data.durations_ms.size() != 4:
		return "Animation durations are missing: " + expected_clip
	if not data.get("frames") is Array or data.frames.size() != 4:
		return "Animation frame metadata is missing: " + expected_clip
	for index in range(4):
		var duration: Variant = data.durations_ms[index]
		if not _is_integer(duration) or float(duration) <= 0.0:
			return "Animation duration is invalid: " + expected_clip
		var frame_value: Variant = data.frames[index]
		if not frame_value is Dictionary:
			return "Animation frame metadata is invalid: " + expected_clip
		var frame: Dictionary = frame_value
		if not _is_integer(frame.get("index")) or int(frame.index) != index:
			return "Animation frame index is invalid: " + expected_clip
		if str(frame.get("file", "")) != "frames/%s_%02d.png" % [expected_clip, index]:
			return "Animation frame path is invalid: " + expected_clip
		if not _matches_integers(frame.get("rect"), [index * FRAME_SIZE.x, 0, FRAME_SIZE.x, FRAME_SIZE.y]):
			return "Animation atlas rect is invalid: " + expected_clip
		if not _matches_integers(frame.get("pivot"), [ANCHOR.x, ANCHOR.y]):
			return "Animation frame anchor is invalid: " + expected_clip
	return ""


func _matches_integers(value: Variant, expected: Array) -> bool:
	if not value is Array or value.size() != expected.size():
		return false
	for index in range(expected.size()):
		if not _is_integer(value[index]) or int(value[index]) != int(expected[index]):
			return false
	return true


func _is_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and is_equal_approx(float(value), roundf(float(value)))


func _load_texture(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path, "Texture2D") as Texture2D


func _clear() -> void:
	clip_id = ""
	playing = false
	paused = false
	completed = false
	looped = false
	last_error = ""
	_metadata.clear()
	_atlas_frames.clear()
	_durations_ms.clear()
	_cycle_duration_ms = 0.0
	_elapsed_ms = 0.0
	_frame_index = 0
	_completion_reported = false


func _fail(message: String) -> bool:
	last_error = message
	return false
