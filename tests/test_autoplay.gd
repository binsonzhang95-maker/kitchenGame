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


func _remove_fixture(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var audio_path := path + ".audio.json"
	if FileAccess.file_exists(audio_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(audio_path))


func _dispose(app: Variant) -> void:
	var own_music: Node = app.music
	app.free()
	if is_instance_valid(own_music):
		own_music.free()


func _driver_for(app: Variant) -> Autoplay:
	for child: Node in app.get_children():
		if child is Autoplay:
			return child
	return null


func _check_first_run_parties() -> void:
	const SEED_PATH := "user://test_autoplay_seed_fixture.json"
	_remove_fixture(SEED_PATH)
	var fresh = Main.new()
	fresh.save_path = SEED_PATH
	fresh.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(fresh)
	await process_frame
	_expect(fresh.model.customers.size() == 3, "fresh game seeds three parties")
	var expected := [["cat"], ["dog", "capybara"], ["panda", "hamster", "cat"]]
	for index: int in range(expected.size()):
		var guest: Dictionary = fresh.model.customers.get(index + 1, {})
		var members: Array = fresh.model.party_members(index + 1)
		_expect(int(guest.get("party_size", 0)) == index + 1 and members.size() == index + 1, "fresh party %d has %d real members" % [index + 1, index + 1])
		for member_index: int in range(members.size()):
			_expect(str(members[member_index].species) == str(expected[index][member_index]), "fresh party %d member %d uses supported side species" % [index + 1, member_index + 1])
			_expect(int(members[member_index].party_id) == index + 1 and int(members[member_index].member_index) == member_index, "fresh party %d member %d retains party identity" % [index + 1, member_index + 1])
	fresh._save()
	_expect(FileAccess.file_exists(SEED_PATH), "seed fixture saves through the normal save path")
	_dispose(fresh)
	await process_frame
	var restored = Main.new()
	restored.save_path = SEED_PATH
	restored.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(restored)
	await process_frame
	_expect(restored.model.customers.size() == 3 and int(restored.model.next_customer_id) == 4, "restored save does not add first-run parties")
	_dispose(restored)
	await process_frame
	_remove_fixture(SEED_PATH)


func _check_seed_and_device_policies() -> void:
	const EMPTY_PATH := "user://test_autoplay_empty_fixture.json"
	_remove_fixture(EMPTY_PATH)
	var empty = Main.new()
	empty.save_path = EMPTY_PATH
	empty.seed_guests = false
	empty.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(empty)
	await process_frame
	_expect(empty.model.customers.is_empty(), "seed_guests=false leaves a new game empty")
	_dispose(empty)
	await process_frame
	var device = Main.new()
	device.save_path = EMPTY_PATH
	device.seed_guests = false
	device.force_device_mode = true
	device.force_autoplay = true
	device.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(device)
	await process_frame
	_expect(device.device_mode and _driver_for(device) == null and device.player_mode and device.interactive_cooking, "device mode excludes autoplay")
	_dispose(device)
	await process_frame
	_remove_fixture(EMPTY_PATH)


func _run() -> void:
	await _check_first_run_parties()
	await _check_seed_and_device_policies()
	var real_save_before := _save_state(Main.SAVE_PATH)
	var app = Main.new()
	app.force_autoplay = true
	root.add_child(app)
	await process_frame
	var driver := _driver_for(app)
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
