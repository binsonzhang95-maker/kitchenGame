extends SceneTree
## Execute only through the parent's authorized isolated Godot test workflow.
## Optional -- --full-loop waits a complete real-time track plus two seconds.
const Music = preload("res://music_controller.gd")
var failures: int = 0
var assertions: int = 0
var temporary_paths: Array[String] = []
var music
var full_loop: bool = false


func _initialize() -> void:
	full_loop = "--full-loop" in OS.get_cmdline_user_args()
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MUSIC_TEST_FAIL: " + message)


func _bus_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for index: int in range(AudioServer.bus_count):
		result[str(AudioServer.get_bus_name(index))] = {"db": AudioServer.get_bus_volume_db(index), "mute": AudioServer.is_bus_mute(index), "send": str(AudioServer.get_bus_send(index))}
	return result


func _run() -> void:
	var base: String = "/tmp/mori_music_test_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var path: String = base + ".audio.json"
	var bad_path: String = base + "_invalid.audio.json"
	temporary_paths.assign([path, path + ".tmp", bad_path, bad_path + ".tmp"])
	for target: String in temporary_paths:
		if FileAccess.file_exists(target):
			_check(false, "private test filename collision")
			quit(2)
			return
	var existing_buses: Dictionary = _bus_snapshot()
	music = Music.acquire(self, path, "res://__missing_music_for_test__.ogg")
	var same_frame = Music.acquire(self, path, "res://__missing_music_for_test__.ogg")
	_check(same_frame == music, "same-frame scene acquisitions reuse pending singleton")
	await process_frame
	await process_frame
	_check(not music.available and music.start_count == 0, "missing track is quietly not ready")
	_check(music.save_allowed and music.enabled and is_equal_approx(music.volume, 0.35), "new private settings use gentle enabled defaults")
	_check(root.get_node_or_null("MoriMusicController") == music, "singleton is attached to root")
	_check(music.get_child_count() == 1 and music.player is AudioStreamPlayer, "controller owns one player")
	music = Music.acquire(self, path, Music.DEFAULT_TRACK)
	await process_frame
	_check(music.player.volume_db == 0.0, "player has no second attenuation")
	var bus: int = AudioServer.get_bus_index(music.bus_name)
	_check(bus >= 0 and music.player.bus == music.bus_name, "player routes only to its music bus")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bus), linear_to_db(0.35)), "default music bus is about -9.12 dB")
	if music.available:
		await create_timer(0.2).timeout
		_check(music.player.stream is AudioStreamOggVorbis and music.player.stream.loop, "OGG loop is enabled on private stream")
		_check(music.player.playing and music.start_count == 1, "track starts exactly once")
		var starts: int = music.start_count
		music.set_paused(true)
		var paused_position: float = music.player.get_playback_position()
		await create_timer(0.25).timeout
		_check(music.player.stream_paused and absf(music.player.get_playback_position() - paused_position) < 0.06, "pause holds playback position")
		for repetition: int in range(12):
			music.set_paused(true)
			music.set_paused(false)
			music.set_enabled(false)
			music.set_enabled(true)
		_check(music.start_count == starts and not music.player.stream_paused, "repeated pause/resume/toggles never replay or layer music")
		var duplicate = Music.acquire(self, path, Music.DEFAULT_TRACK)
		_check(duplicate == music and music.start_count == starts, "scene rebuild reuses playing singleton")
		var length: float = music.player.stream.get_length()
		_check(length > 1.0, "track has a measurable duration")
		music.player.seek(maxf(0.0, length - 0.25))
		await create_timer(0.8).timeout
		_check(music.player.playing and music.player.get_playback_position() < 2.0 and music.start_count == starts, "quick boundary check loops without replay")
	else:
		print("MUSIC_ASSET_NOT_READY asset_checks=skipped path=" + Music.DEFAULT_TRACK)
		if full_loop:
			_check(false, "full-loop mode requires the actual music asset")
	music.set_volume(0.27)
	_check(is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(bus)), 0.27), "volume changes only the music bus")
	music.set_volume(0.0)
	_check(AudioServer.is_bus_mute(bus), "zero volume truly mutes the music bus")
	music.set_volume(0.27)
	music.set_enabled(false)
	_check(music.save_settings() == OK, "settings save to injected private path")
	_check(FileAccess.file_exists(path), "private settings file exists")
	music.queue_free()
	await process_frame
	await process_frame
	music = Music.acquire(self, path, Music.DEFAULT_TRACK)
	await process_frame
	await process_frame
	_check(not music.enabled and is_equal_approx(music.volume, 0.27), "new controller restores settings from private file")
	_check(music.start_count == 0, "disabled reopened settings do not start playback")
	music.set_enabled(true)
	if full_loop and music.available:
		await _wait_full_loop()
	var bad_bytes: String = "{\"version\":1,\"enabled\":true,\"volume\":4}"
	var bad_file: FileAccess = FileAccess.open(bad_path, FileAccess.WRITE)
	_check(bad_file != null, "create deliberately invalid private settings")
	if bad_file != null:
		bad_file.store_string(bad_bytes)
		bad_file.close()
		music = Music.acquire(self, bad_path, Music.DEFAULT_TRACK)
		_check(not music.save_allowed, "invalid settings are protected from overwrite")
		_check(music.save_settings() == ERR_INVALID_DATA, "saving over invalid settings is rejected")
		_check(FileAccess.get_file_as_string(bad_path) == bad_bytes, "bad settings bytes remain unchanged")
	for name: String in existing_buses:
		var index: int = AudioServer.get_bus_index(name)
		_check(index >= 0 and is_equal_approx(AudioServer.get_bus_volume_db(index), float(existing_buses[name].db)) and AudioServer.is_bus_mute(index) == existing_buses[name].mute and str(AudioServer.get_bus_send(index)) == existing_buses[name].send, "pre-existing bus remains unchanged: " + name)
	music.queue_free()
	await process_frame
	await process_frame
	# The dedicated mixing thread releases stopped OGG playback asynchronously.
	await create_timer(0.2).timeout
	for target: String in temporary_paths:
		if FileAccess.file_exists(target):
			_check(DirAccess.remove_absolute(target) == OK, "remove only private test file")
	print("MUSIC_TEST_RESULT assertions=%d failures=%d full_loop=%s" % [assertions, failures, str(full_loop)])
	quit(0 if failures == 0 else 1)


func _wait_full_loop() -> void:
	music.set_paused(false)
	music.set_enabled(true)
	music.player.seek(0.0)
	var length: float = music.player.stream.get_length()
	var minimum_seconds: int = ceili(length) + 2
	var maximum_seconds: int = ceili(length * 1.5) + 5
	var starts: int = music.start_count
	var previous: float = music.player.get_playback_position()
	var wraps: int = 0
	var began: int = Time.get_ticks_msec()
	var completed: bool = false
	print("MUSIC_FULL_LOOP_BEGIN duration=%.3f minimum_real_seconds=%d maximum_wait_seconds=%d start_count=%d" % [length, minimum_seconds, maximum_seconds, starts])
	for elapsed: int in range(1, maximum_seconds + 1):
		await create_timer(1.0).timeout
		var position: float = music.player.get_playback_position()
		_check(music.player.playing and not music.player.stream_paused, "full-loop playback active at real second %d" % elapsed)
		_check(music.start_count == starts, "full-loop does not call play again at second %d" % elapsed)
		if position + 1.0 < previous:
			wraps += 1
		previous = position
		var actual_wall: float = (Time.get_ticks_msec() - began) / 1000.0
		completed = actual_wall >= float(minimum_seconds) and wraps >= 1
		if elapsed % 15 == 0 or elapsed == maximum_seconds or completed:
			print("MUSIC_FULL_LOOP_PROGRESS elapsed=%d actual_wall=%.3f position=%.3f wraps=%d start_count=%d" % [elapsed, actual_wall, position, wraps, music.start_count])
		if completed:
			break
	var real_seconds: float = (Time.get_ticks_msec() - began) / 1000.0
	_check(real_seconds >= float(minimum_seconds), "waited at least a complete track plus two seconds in real time")
	_check(wraps >= 1, "observed natural loop position wrap after complete real-time playback")
	_check(completed, "natural full-track loop completed before bounded timeout")
	print("MUSIC_FULL_LOOP_DONE real_seconds=%.3f wraps=%d start_count=%d completed=%s" % [real_seconds, wraps, music.start_count, str(completed)])
