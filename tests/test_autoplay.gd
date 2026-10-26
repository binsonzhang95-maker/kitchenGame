extends SceneTree
## Headless autoplay integration: real Main setup, isolated save policy, 600 frames.
const Main = preload("res://multi_main.gd")
const Autoplay = preload("res://autoplay.gd")

var assertions := 0
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("AUTOPLAY_FAIL " + description)


func _save_state(path: String) -> Dictionary:
	return {
		"exists": FileAccess.file_exists(path),
		"modified": FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0,
		"bytes": FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray(),
	}


func _run() -> void:
	var real_save_before := _save_state(Main.SAVE_PATH)
	var app = Main.new()
	app.force_autoplay = true
	root.add_child(app)
	await process_frame
	var driver: Autoplay
	for child: Node in app.get_children():
		if child is Autoplay:
			driver = child
			break
	_expect(driver != null, "autoplay driver is attached")
	_expect(not app.player_mode and not app.interactive_cooking and app.seed_guests, "autoplay disables player cooking and seeds guests")
	_expect(not app.save_allowed and app.save_path == "user://autoplay_demo.json", "autoplay uses the protected demo save slot")
	_expect(app.model.auto_cook, "automatic cooking is enabled after the first frame")
	app.process_mode = Node.PROCESS_MODE_DISABLED
	if driver != null:
		for frame: int in range(600):
			app._process(0.1)
			driver._process(0.1)
			await process_frame
	_expect(app.model.served > 0 and app.model.coins > 0, "at least one order is cooked, served, and paid")
	_expect(_save_state(Main.SAVE_PATH) == real_save_before, "real player save is untouched")
	print("AUTOPLAY_TEST_RESULT assertions=%d failures=%d served=%d coins=%d frames=600" % [assertions, failures, int(app.model.served), int(app.model.coins)])
	var own_music: Node = app.music
	app.free()
	if is_instance_valid(own_music): own_music.free()
	await process_frame
	quit(0 if failures == 0 else 1)
