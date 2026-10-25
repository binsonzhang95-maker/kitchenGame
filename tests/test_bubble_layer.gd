extends SceneTree
## Run with --headless --path PROJECT --script res://tests/test_bubble_layer.gd.
## Reads shipped assets only. No saves, normal gameplay scene, or filesystem writes.
const BubbleLayer = preload("res://bubble_layer.gd")

var assertions: int = 0
var failures: int = 0
var completed_sections: int = 0
var layer

class FakeDirector:
	extends RefCounted
	var bubbles: Array[Dictionary] = []

class FakeModel:
	extends RefCounted
	var paused: bool = false
	var customers: Dictionary = {
		1: {"state": "walking", "pos": Vector2(420, 300), "table_id": 1},
		2: {"state": "seated", "pos": Vector2(900, 500), "table_id": 1},
		3: {"state": "queued", "pos": Vector2(420, 300), "table_id": 0},
		4: {"state": "leaving", "pos": Vector2(420, 300), "table_id": 0},
	}
	var tables: Array[Dictionary] = [{"center": Vector2(600, 350)}]
	var workers: Array[Dictionary] = [{"id": 0, "pos": Vector2(420, 300)}, {"id": 1, "pos": Vector2(420, 300)}]

class InputSink:
	extends Node
	var clicks: int = 0
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			clicks += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	layer = BubbleLayer.new()
	root.add_child(layer)
	await process_frame
	_expect(layer._frames != null and layer._frame_sizes.size() == 8, "all eight actual asset animations loaded")
	if layer._frames == null or layer._frame_sizes.size() != 8:
		_finish()
		return
	_test_assets()
	_test_timing_and_pause()
	_test_follow_and_purity()
	_test_capacity_bounds_and_overlap()
	await _test_no_input_interception()
	_expect(completed_sections == 5, "all five test sections completed without an early script error")
	_finish()


func _finish() -> void:
	if is_instance_valid(layer):
		root.remove_child(layer)
		layer.free()
	print("BUBBLE_LAYER_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("BUBBLE_LAYER_ASSERT_FAIL " + description)


func _bubble(id: int, speaker: String, emotion: String = "hungry", elapsed: float = 0.0) -> Dictionary:
	return {"id": id, "speaker": speaker, "emotion": emotion, "short_text": "期待美味", "duration": 20.0, "remaining": 20.0 - elapsed, "elapsed": elapsed}


func _test_assets() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://expression_bubbles/manifest.json"))
	_expect(layer._frames.get_animation_names().size() == 8, "no extra placeholder animation")
	_expect(not layer.show_short_text, "short words are off by default")
	for emotion: String in BubbleLayer.EMOTIONS:
		var name := StringName(emotion)
		var metadata: Dictionary = manifest.animations[emotion]
		_expect(layer._frames.has_animation(name), "has " + emotion)
		_expect(layer._frames.get_frame_count(name) == 4, "four frames for " + emotion)
		_expect(layer._frames.get_animation_loop(name) == bool(metadata.loop), "loop metadata for " + emotion)
		for index: int in range(4):
			var texture: Texture2D = layer._frames.get_frame_texture(name, index)
			_expect(texture is AtlasTexture and texture.get_size() == Vector2(64, 64), "64px atlas frame %s:%d" % [emotion, index])
			var seconds: float = layer._frames.get_frame_duration(name, index) / layer._frames.get_animation_speed(name)
			_expect(is_equal_approx(seconds, float(metadata.duration_ms[index]) / 1000.0), "duration weight %s:%d" % [emotion, index])
	completed_sections += 1


func _test_timing_and_pause() -> void:
	layer.clear_bubbles()
	var director = FakeDirector.new()
	var model = FakeModel.new()
	director.bubbles.append(_bubble(1, "guest:1"))
	# Real hungry clip is 220/220/220/300ms: the fourth frame is deliberately longer.
	for sample: Array in [[0.0, 0], [0.219, 0], [0.221, 1], [0.441, 2], [0.661, 3], [0.90, 3], [0.961, 0]]:
		director.bubbles[0].elapsed = sample[0]
		layer.sync(director, model)
		_expect(layer._visuals[1].sprite.frame == int(sample[1]), "nonuniform clip frame at %.3fs" % sample[0])
	_expect(not layer._visuals[1].sprite.is_playing(), "sprite never advances from its own clock")
	director.bubbles[0].emotion = "ok"
	director.bubbles[0].elapsed = 4.0
	layer.sync(director, model)
	_expect(layer._visuals[1].sprite.frame == 3, "non-looping ok stops at final frame")
	director.bubbles[0].emotion = "wait"
	director.bubbles[0].elapsed = 0.301
	layer.sync(director, model)
	_expect(layer._visuals[1].sprite.frame == 1, "wait uses 300ms frames")
	model.paused = true
	director.bubbles[0].elapsed = 0.901
	layer.sync(director, model)
	_expect(layer._visuals[1].sprite.frame == 1, "pause freezes displayed frame even if input elapsed changes")
	model.paused = false
	layer.sync(director, model)
	_expect(layer._visuals[1].sprite.frame == 3, "resume uses director elapsed")
	director.bubbles[0].erase("elapsed")
	director.bubbles[0].remaining = 19.699
	layer.sync(director, model)
	_expect(layer._visuals[1].sprite.frame == 1, "duration minus remaining fallback")
	director.bubbles[0].remaining = 0.0
	layer.sync(director, model)
	_expect(layer._visuals.is_empty(), "expired bubble disappears")
	completed_sections += 1


func _test_follow_and_purity() -> void:
	layer.clear_bubbles()
	var director = FakeDirector.new()
	var model = FakeModel.new()
	director.bubbles.append(_bubble(2, "guest:1"))
	var before: Dictionary = {"customers": model.customers.duplicate(true), "tables": model.tables.duplicate(true), "workers": model.workers.duplicate(true), "bubbles": director.bubbles.duplicate(true)}
	layer.sync(director, model)
	_expect(layer._visuals[2].node.position == Vector2(420, 201), "96px walking actor tail follows foot position minus 99")
	_expect(layer._visuals[2].sprite.position == Vector2(0, -28), "64px image uses actual tail anchor 32,60")
	_expect(not layer._visuals[2].label.visible, "default icon has no short text")
	_expect(model.customers == before.customers and model.tables == before.tables and model.workers == before.workers and director.bubbles == before.bubbles, "sync does not mutate model or director")
	model.customers[1].pos += Vector2(40, 20)
	layer.sync(director, model)
	_expect(layer._visuals[2].node.position == Vector2(460, 221), "walking bubble moves with speaker")
	director.bubbles[0].speaker = "guest:2"
	layer.sync(director, model)
	_expect(layer._visuals[2].node.position == Vector2(600, 260), "96px seated actor bubble follows table center minus 90")
	director.bubbles[0].speaker = "worker:0"
	layer.sync(director, model)
	_expect(layer._visuals[2].node.position == Vector2(420, 201), "worker bubble follows worker foot position minus 99")
	model.workers[0].pos += Vector2(24, 12)
	layer.sync(director, model)
	_expect(layer._visuals[2].node.position == Vector2(444, 213), "worker bubble tracks subsequent motion")
	layer.position = Vector2(0, 80)
	_expect(layer._visuals[2].node.global_position == Vector2(444, 293), "room placement adds its 80px top offset exactly once")
	layer.position = Vector2.ZERO
	director.bubbles[0].speaker = "guest:999"
	layer.sync(director, model)
	_expect(layer._visuals.is_empty(), "departed speaker leaves no visual")
	director.bubbles[0].speaker = "guest:1"
	director.bubbles[0].emotion = "missing_asset"
	layer.sync(director, model)
	_expect(layer._visuals.is_empty(), "missing emotion has no placeholder text")
	completed_sections += 1


func _test_capacity_bounds_and_overlap() -> void:
	layer.clear_bubbles()
	var director = FakeDirector.new()
	var model = FakeModel.new()
	layer.show_short_text = true
	director.bubbles.assign([_bubble(10, "guest:1"), _bubble(11, "guest:3"), _bubble(12, "worker:0"), _bubble(13, "worker:1")])
	_expect(BubbleLayer.ROOM_SIZE == Vector2(1536, 1024), "bounds match the new full-resolution room")
	for point: Vector2 in [Vector2(420, 300), Vector2(0, 0), Vector2(1536, 0), Vector2(0, 1024), Vector2(1536, 1024)]:
		layer.clear_bubbles()
		model.customers[1].pos = point
		model.customers[3].pos = point
		model.workers[0].pos = point
		model.workers[1].pos = point
		layer.sync(director, model)
		_expect(layer._visuals.size() == 3, "three of four colocated bubbles at " + str(point))
		_expect(not layer._visuals.has(13), "stable oldest three IDs win capacity")
		var boxes: Array[Rect2] = []
		for visual: Dictionary in layer._visuals.values():
			var box: Rect2 = _visual_bounds(visual)
			_expect(box.position.x >= 4 and box.position.y >= 4 and box.end.x <= 1532 and box.end.y <= 1020, "whole sprite and text remain within 1536x1024 room")
			_expect(visual.label.visible and visual.label.text.length() == 4, "optional words render without separate background")
			_expect(visual.label.get_theme_font_size("font_size") == 16 and visual.label.size == Vector2(80, 28), "four optional words have 16px font and padded readable bounds")
			for other: Rect2 in boxes:
				_expect(not box.grow(3.9).intersects(other), "bubbles have a four-pixel gap")
			boxes.append(box)
		var positions: Dictionary = {}
		for id: Variant in layer._visuals:
			positions[id] = layer._visuals[id].node.position
		layer.sync(director, model)
		for id: Variant in positions:
			_expect(layer._visuals[id].node.position == positions[id], "unchanged input keeps stable placement")
	layer.show_short_text = false
	completed_sections += 1


func _visual_bounds(visual: Dictionary) -> Rect2:
	var sprite: AnimatedSprite2D = visual.sprite
	var texture: Texture2D = sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)
	var size: Vector2 = texture.get_size() * sprite.scale
	var result := Rect2(visual.node.position + sprite.position - size * 0.5, size)
	if visual.label.visible:
		result = result.merge(Rect2(visual.node.position + visual.label.position, visual.label.size))
	return result


func _test_no_input_interception() -> void:
	layer.clear_bubbles()
	layer.show_short_text = true
	var director = FakeDirector.new()
	var model = FakeModel.new()
	director.bubbles.append(_bubble(30, "guest:1"))
	layer.sync(director, model)
	var visual: Dictionary = layer._visuals[30]
	_expect(not layer.is_processing_input() and not layer.is_processing_unhandled_input(), "layer does not handle input")
	_expect(visual.label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "short text does not intercept GUI mouse events")
	var sink := InputSink.new()
	root.add_child(sink)
	await process_frame
	root.notify_mouse_entered()
	var point: Vector2 = visual.node.position + visual.label.position + visual.label.size * 0.5
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		event.position = point
		event.global_position = point
		root.push_input(event, true)
	_expect(sink.clicks == 1, "click on visible short text reaches unhandled input")
	root.remove_child(sink)
	sink.free()
	layer.clear_bubbles()
	_expect(layer.get_child_count() == 0, "clearing detaches all visuals immediately")
	completed_sections += 1
