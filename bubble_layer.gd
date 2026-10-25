extends Node2D
## Room-local, visual-only expression bubbles. No model writes or input handling.
## Manifest: {"animations":{"hungry":{"texture":"res://...png",
## "rects":[[x,y,w,h],[x,y,w,h],[x,y,w,h],[x,y,w,h]],"fps":6,
## "duration_ms":[220,220,220,300],"loop":true,"anchor":[32,60]}}}

const EMOTIONS: Array[String] = ["hungry", "question", "ok", "wait", "upset", "sorry", "love", "bye"]
const ROOM_SIZE: Vector2 = Vector2(1536, 1024)
const DISPLAY_SIZE: float = 64.0
const SHORT_TEXT_SIZE: Vector2 = Vector2(80, 28)
const STANDING_HEAD_OFFSET: float = 99.0
const SEATED_HEAD_OFFSET: float = 90.0
const MAX_BUBBLES: int = 3
const EDGE: float = 4.0
const OFFSETS: Array[Vector2] = [Vector2.ZERO, Vector2(-88, 0), Vector2(88, 0), Vector2(0, -100), Vector2(-88, -100), Vector2(88, -100), Vector2(0, 100), Vector2(-88, 100), Vector2(88, 100), Vector2(-176, 0), Vector2(176, 0), Vector2(-176, -100), Vector2(176, -100)]

@export var manifest_path: String = "res://expression_bubbles/manifest.json"
@export var show_short_text: bool = false

var _frames: SpriteFrames
var _frame_sizes: Dictionary = {}
var _frame_durations: Dictionary = {}
var _anchors: Dictionary = {}
var _visuals: Dictionary = {}
var _load_attempted: bool = false
var _warned: bool = false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 10
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	if not _load_attempted:
		reload_manifest()


## Call once after installing/replacing assets; sync() never polls the filesystem.
## Returns true if at least one valid emotion can render. Missing emotions stay hidden.
func reload_manifest() -> bool:
	_load_attempted = true
	clear_bubbles()
	_frames = SpriteFrames.new()
	_frames.remove_animation(&"default")
	_frame_sizes.clear()
	_frame_durations.clear()
	_anchors.clear()
	if not FileAccess.file_exists(manifest_path):
		_warn_once("missing expression manifest: " + manifest_path)
		return false
	var file: FileAccess = FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		_warn_once("cannot read expression manifest: " + manifest_path)
		return false
	var parser := JSON.new()
	var error: Error = parser.parse(file.get_as_text())
	file.close()
	if error != OK or not parser.data is Dictionary:
		_warn_once("invalid expression manifest: " + manifest_path)
		return false
	var animations: Variant = parser.data.get("animations")
	if not animations is Dictionary:
		_warn_once("expression manifest needs an animations object")
		return false
	var unavailable: Array[String] = []
	for emotion: String in EMOTIONS:
		var entry: Variant = animations.get(emotion)
		if not entry is Dictionary or not _load_animation(emotion, entry):
			unavailable.append(emotion)
	if not unavailable.is_empty():
		_warn_once("unavailable expression animations: " + ", ".join(unavailable))
	return not _frame_sizes.is_empty()


func _load_animation(emotion: String, entry: Dictionary) -> bool:
	var path: String = str(entry.get("texture", ""))
	var rects: Variant = entry.get("rects")
	var rate: Variant = entry.get("fps", 6.0)
	if not path.begins_with("res://") or not ResourceLoader.exists(path):
		return false
	if not rects is Array or rects.size() != 4 or not _number(rate) or float(rate) <= 0.0:
		return false
	var texture: Texture2D = load(path) as Texture2D
	if texture == null:
		return false
	var regions: Array[Rect2] = []
	var frame_size := Vector2.ZERO
	for raw: Variant in rects:
		if not raw is Array or raw.size() != 4:
			return false
		for component: Variant in raw:
			if not _number(component):
				return false
		var region := Rect2(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		if region.position.x < 0 or region.position.y < 0 or region.size.x <= 0 or region.size.y <= 0:
			return false
		if region.end.x > texture.get_width() or region.end.y > texture.get_height():
			return false
		if not regions.is_empty() and region.size != frame_size:
			return false
		frame_size = region.size
		regions.append(region)
	var times: Variant = entry.get("duration_ms", [])
	var durations: Array[float] = []
	if not times is Array or (not times.is_empty() and times.size() != regions.size()):
		return false
	for index: int in range(regions.size()):
		var duration: Variant = times[index] if not times.is_empty() else 1000.0 / float(rate)
		if not _number(duration) or float(duration) <= 0.0:
			return false
		durations.append(float(duration))
	var loops: Variant = entry.get("loop", true)
	var anchor: Variant = entry.get("anchor", [32, 60])
	if not loops is bool or not anchor is Array or anchor.size() != 2 or not _number(anchor[0]) or not _number(anchor[1]):
		return false
	var anchor_point := Vector2(float(anchor[0]), float(anchor[1]))
	if anchor_point.x < 0 or anchor_point.y < 0 or anchor_point.x > frame_size.x or anchor_point.y > frame_size.y:
		return false
	var animation := StringName(emotion)
	_frames.add_animation(animation)
	_frames.set_animation_speed(animation, float(rate))
	_frames.set_animation_loop(animation, bool(loops))
	for index: int in range(regions.size()):
		var frame := AtlasTexture.new()
		frame.atlas = texture
		frame.region = regions[index]
		frame.filter_clip = true
		_frames.add_frame(animation, frame, durations[index] * float(rate) / 1000.0)
	_frame_sizes[emotion] = frame_size
	_frame_durations[emotion] = durations
	_anchors[emotion] = anchor_point
	return true


## Call after director.tick() each frame. Animation time is entirely director-owned.
## Bubble records: id, speaker guest:N/worker:N, emotion, duration, remaining,
## plus optional elapsed and short_text. Paused models keep their last displayed frame.
func sync(director, model) -> void:
	if not _load_attempted:
		reload_manifest()
	if director == null or model == null or _frame_sizes.is_empty():
		clear_bubbles()
		return
	var ordered: Array[Dictionary] = []
	for raw: Variant in director.bubbles:
		if raw is Dictionary:
			ordered.append(raw)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("id", 0)) < int(b.get("id", 0)))
	var keep: Dictionary = {}
	var speakers: Dictionary = {}
	var occupied: Array[Rect2] = []
	for bubble: Dictionary in ordered:
		if keep.size() >= MAX_BUBBLES:
			break
		var id: int = int(bubble.get("id", 0))
		var emotion: String = str(bubble.get("emotion", ""))
		var speaker: String = str(bubble.get("speaker", ""))
		if id <= 0 or keep.has(id) or speakers.has(speaker) or not _frame_sizes.has(emotion) or float(bubble.get("remaining", 0.0)) <= 0.0:
			continue
		var anchor: Vector2 = _speaker_anchor(speaker, model)
		if not anchor.is_finite():
			continue
		var text: String = str(bubble.get("short_text", "")).strip_edges().replace("\n", "").replace("\r", "")
		text = text.left(4) if show_short_text and text.length() >= 2 else ""
		var size: Vector2 = _frame_sizes[emotion]
		var scale_factor: float = DISPLAY_SIZE / maxf(size.x, size.y)
		var image_anchor: Vector2 = _anchors[emotion] * scale_factor
		var box := Rect2(-image_anchor, size * scale_factor)
		var label_position := Vector2(-SHORT_TEXT_SIZE.x * 0.5, box.end.y)
		if not text.is_empty():
			box = box.merge(Rect2(label_position, SHORT_TEXT_SIZE))
		var previous: Dictionary = _visuals.get(id, {})
		var position_hint: Vector2 = previous.get("offset", Vector2.ZERO)
		var place: Vector2 = _place(anchor, box, occupied, position_hint)
		if not place.is_finite():
			continue
		var visual: Dictionary = previous if not previous.is_empty() else _create_visual(id)
		var sprite: AnimatedSprite2D = visual.sprite
		var label: Label = visual.label
		var elapsed: float = maxf(0.0, float(bubble.get("elapsed", float(bubble.get("duration", 0.0)) - float(bubble.get("remaining", 0.0)))))
		if bool(model.paused) and previous.has("elapsed"):
			elapsed = float(previous.elapsed)
		if not is_finite(elapsed):
			elapsed = 0.0
		var animation := StringName(emotion)
		if sprite.animation != animation:
			sprite.animation = animation
		sprite.scale = Vector2.ONE * scale_factor
		sprite.position = size * scale_factor * 0.5 - image_anchor
		sprite.set_frame_and_progress(_frame_at(emotion, elapsed), 0.0)
		label.text = text
		label.position = label_position
		label.visible = not text.is_empty()
		visual.node.position = place
		visual.offset = place - anchor
		visual.elapsed = elapsed
		_visuals[id] = visual
		keep[id] = true
		speakers[speaker] = true
		occupied.append(Rect2(place + box.position, box.size))
	for id: Variant in _visuals.keys():
		if not keep.has(id):
			_remove_visual(id)


func _frame_at(emotion: String, elapsed: float) -> int:
	var durations: Array = _frame_durations[emotion]
	var total_ms: float = 0.0
	for duration: float in durations:
		total_ms += duration
	var moment_ms: float = maxf(0.0, elapsed) * 1000.0
	if _frames.get_animation_loop(StringName(emotion)):
		moment_ms = fmod(moment_ms, total_ms)
	for index: int in range(durations.size()):
		if moment_ms < float(durations[index]):
			return index
		moment_ms -= float(durations[index])
	return durations.size() - 1


func _speaker_anchor(speaker: String, model) -> Vector2:
	var parts: PackedStringArray = speaker.split(":")
	if parts.size() != 2 or not parts[1].is_valid_int():
		return Vector2.INF
	var id: int = parts[1].to_int()
	if parts[0] == "worker":
		if id < 0 or id >= model.workers.size():
			return Vector2.INF
		return Vector2(model.workers[id].pos) - Vector2(0, STANDING_HEAD_OFFSET)
	if parts[0] != "guest" or not model.customers.has(id):
		return Vector2.INF
	var guest: Dictionary = model.customers[id]
	if str(guest.state) == "seated":
		var table_id: int = int(guest.get("table_id", 0))
		if table_id <= 0 or table_id > model.tables.size():
			return Vector2.INF
		return Vector2(model.tables[table_id - 1].center) - Vector2(0, SEATED_HEAD_OFFSET)
	return Vector2(guest.pos) - Vector2(0, STANDING_HEAD_OFFSET)


func _place(anchor: Vector2, box: Rect2, occupied: Array[Rect2], previous_offset: Vector2) -> Vector2:
	# Search around the bounded anchor so edge clamping cannot collapse every row.
	var bounded := Vector2(
		clampf(anchor.x, EDGE - box.position.x, ROOM_SIZE.x - EDGE - box.end.x),
		clampf(anchor.y, EDGE - box.position.y, ROOM_SIZE.y - EDGE - box.end.y)
	)
	var options: Array[Vector2] = [anchor + previous_offset]
	for offset: Vector2 in OFFSETS:
		options.append(bounded + offset)
	var tried: Array[Vector2] = []
	for candidate: Vector2 in options:
		var center: Vector2 = candidate
		center.x = clampf(center.x, EDGE - box.position.x, ROOM_SIZE.x - EDGE - box.end.x)
		center.y = clampf(center.y, EDGE - box.position.y, ROOM_SIZE.y - EDGE - box.end.y)
		center = center.round()
		if tried.has(center):
			continue
		tried.append(center)
		var bounds := Rect2(center + box.position, box.size)
		var blocked: bool = false
		for other: Rect2 in occupied:
			if bounds.grow(4.0).intersects(other):
				blocked = true
				break
		if not blocked:
			return center
	# Prefer omitting a low-priority bubble over overlap or covering room-external UI.
	return Vector2.INF


func _create_visual(id: int) -> Dictionary:
	var holder := Node2D.new()
	holder.name = "Bubble_%d" % id
	var sprite := AnimatedSprite2D.new()
	sprite.name = "Expression"
	sprite.sprite_frames = _frames
	sprite.centered = true
	sprite.speed_scale = 0.0
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.pause()
	holder.add_child(sprite)
	var label := Label.new()
	label.name = "ShortText"
	label.position = Vector2(-SHORT_TEXT_SIZE.x * 0.5, 32)
	label.size = SHORT_TEXT_SIZE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = true
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color("604d3d"))
	label.visible = false
	holder.add_child(label)
	add_child(holder)
	return {"node": holder, "sprite": sprite, "label": label}


func clear_bubbles() -> void:
	for id: Variant in _visuals.keys():
		_remove_visual(id)


func _remove_visual(id: Variant) -> void:
	var holder: Node2D = _visuals[id].node
	remove_child(holder)
	holder.queue_free()
	_visuals.erase(id)


func _warn_once(message: String) -> void:
	if not _warned:
		_warned = true
		push_warning("BubbleLayer: " + message)


func _number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
