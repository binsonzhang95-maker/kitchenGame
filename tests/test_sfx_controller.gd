extends SceneTree

const Controller = preload("res://sfx_controller.gd")
const IDS := [
	"ui_click", "ui_back", "card_not_needed", "card_unknown",
	"step_complete", "dish_complete", "toy_connected", "toy_disconnected",
]

var _failures: Array[String] = []
var _assertions := 0
var _master_index := -1
var _master_muted := false
var _master_volume := 0.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_master_index = AudioServer.get_bus_index("Master")
	if _master_index != -1:
		_master_muted = AudioServer.is_bus_mute(_master_index)
		_master_volume = AudioServer.get_bus_volume_db(_master_index)
		AudioServer.set_bus_mute(_master_index, true)
	await _test_real_assets()
	await _test_play_controls_and_pool()
	await _test_early_setup_and_limits()
	await _test_missing_cache_and_refresh()
	await _test_bus_ownership()
	if _master_index != -1:
		AudioServer.set_bus_mute(_master_index, _master_muted)
		AudioServer.set_bus_volume_db(_master_index, _master_volume)
	# Playback teardown is asynchronous to the mixer.  All controllers above
	# have been freed; allow one short real-time mix window before process exit.
	await create_timer(0.15).timeout
	if _failures.is_empty():
		print("PASS: SFXController behavior tests (%d assertions)" % _assertions)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("FAIL: SFXController behavior tests (%d failures, %d assertions)" % [_failures.size(), _assertions])
		quit(1)


func _test_real_assets() -> void:
	for id in IDS:
		var stream := ResourceLoader.load("res://assets/audio/sfx/%s.ogg" % id, "AudioStream") as AudioStream
		_check(stream != null, "%s imports as AudioStream" % id)
		if stream != null:
			_check(stream.get_length() > 0.0, "%s has positive duration" % id)


func _test_play_controls_and_pool() -> void:
	var before_files := DirAccess.get_files_at("user://")
	var controller := Controller.new({}, 2)
	root.add_child(controller)
	await process_frame
	_check(controller.diagnostics().channel_count == 2, "controller creates a bounded two-channel pool")
	_check(is_equal_approx(controller.get_debug_state().volume, 0.6), "default SFX volume is gentle")
	var bus_count := AudioServer.bus_count
	controller.setup()
	_check(AudioServer.bus_count == bus_count, "repeated setup does not leave another bus")
	for id in IDS:
		_check(controller.play(id), "valid ID %s plays" % id)
	var state := controller.get_debug_state()
	_check(state.played_ids.size() == IDS.size(), "one debug play record per successful play")
	_check(state.played_event_count == IDS.size(), "total debug play count records successful plays")
	_check(not controller.play("../../arbitrary.ogg"), "invalid ID does not play arbitrary path")
	_check(controller.get_debug_state().played_ids.size() == IDS.size(), "invalid ID makes no play record")
	controller.set_enabled(false)
	_check(not controller.play("ui_click"), "disabled controller does not play")
	controller.set_enabled(true)
	_check(controller.play("ui_click"), "re-enabled controller plays")
	controller.set_volume(-5.0)
	_check(is_zero_approx(controller.get_debug_state().volume), "volume clamps at zero")
	controller.set_volume(5.0)
	_check(is_equal_approx(controller.get_debug_state().volume, 1.0), "volume clamps at one")
	controller.set_volume(0.35)
	controller.set_volume(NAN)
	_check(is_equal_approx(controller.get_debug_state().volume, 0.35), "NaN does not contaminate volume")
	controller.set_volume(INF)
	_check(is_equal_approx(controller.get_debug_state().volume, 0.35), "Infinity does not contaminate volume")
	_check(DirAccess.get_files_at("user://") == before_files, "SFX API creates no user/player files")
	var bus_name: String = controller.diagnostics().bus_name
	controller.queue_free()
	await process_frame
	_check(AudioServer.get_bus_index(bus_name) == -1, "owned bus is released with controller")


func _test_early_setup_and_limits() -> void:
	var before_bus_count := AudioServer.bus_count
	var early := Controller.new()
	early.setup()
	_check(AudioServer.bus_count == before_bus_count, "setup outside the tree does not allocate a bus")
	early.free()
	_check(AudioServer.bus_count == before_bus_count, "free after early setup leaks no bus")
	var controller := Controller.new({}, Controller.MAX_CHANNELS + 100)
	root.add_child(controller)
	await process_frame
	_check(controller.diagnostics().channel_count == Controller.MAX_CHANNELS, "oversized channel count clamps to the fixed pool limit")
	var play_total := Controller.DEBUG_EVENT_HISTORY_LIMIT + 5
	for index in range(play_total):
		_check(controller.play("ui_click"), "ring-buffer play %d succeeds" % index)
	var state := controller.get_debug_state()
	_check(state.played_ids.size() == Controller.DEBUG_EVENT_HISTORY_LIMIT, "debug event history has its explicit fixed limit")
	_check(state.played_event_history_limit == Controller.DEBUG_EVENT_HISTORY_LIMIT, "debug state exposes the event-history limit")
	_check(state.played_event_count == play_total, "debug event total remains auditable after ring eviction")
	_check(state.played_ids[0] == "ui_click" and state.played_ids[-1] == "ui_click", "debug event history retains recent successful IDs")
	controller.queue_free()
	await process_frame


func _test_missing_cache_and_refresh() -> void:
	var recovery_file := "sfx_controller_refresh_%d.tres" % Time.get_ticks_usec()
	var recovery_path := "user://%s" % recovery_file
	var controller := Controller.new({"ui_click": recovery_path})
	root.add_child(controller)
	await process_frame
	_check(not controller.play("ui_click"), "missing overridden asset fails safely")
	_check(not controller.play("ui_click"), "missing asset remains negatively cached")
	_check(controller.diagnostics().missing_ids == ["ui_click"], "missing diagnostic is recorded once")
	controller.set_enabled(false)
	controller.set_volume(0.25)
	_check(_save_recovery_stream(recovery_path), "test restores a valid missing SFX resource")
	controller.refresh_assets()
	_check(not controller.diagnostics().missing_ids.has("ui_click"), "refresh retries the restored asset and clears its missing diagnostic")
	_check(not controller.diagnostics().enabled and is_equal_approx(controller.diagnostics().volume, 0.25), "refresh preserves settings")
	controller.set_enabled(true)
	_check(controller.play("ui_click"), "restored asset plays after refresh")
	controller.queue_free()
	await process_frame
	var recovery_dir := DirAccess.open("user://")
	_check(recovery_dir != null and recovery_dir.remove(recovery_file) == OK, "recovery test cleans up its temporary asset")


func _test_bus_ownership() -> void:
	# An externally owned base name must remain untouched; controller picks a suffix.
	AudioServer.add_bus()
	var external_index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(external_index, "MoriSFX")
	var first := Controller.new()
	var second := Controller.new()
	root.add_child(first)
	root.add_child(second)
	await process_frame
	var first_bus: String = first.diagnostics().bus_name
	var second_bus: String = second.diagnostics().bus_name
	_check(first_bus != "MoriSFX" and second_bus != "MoriSFX", "external base bus causes suffix allocation")
	_check(first_bus != second_bus, "live controllers own distinct buses")
	first.queue_free()
	await process_frame
	_check(AudioServer.get_bus_index(second_bus) != -1, "freeing one controller leaves the other's bus")
	_check(AudioServer.get_bus_index("MoriSFX") != -1, "freeing controller does not delete external bus")
	second.queue_free()
	await process_frame
	_check(AudioServer.get_bus_index(first_bus) == -1 and AudioServer.get_bus_index(second_bus) == -1, "both owned buses are cleaned")
	AudioServer.remove_bus(AudioServer.get_bus_index("MoriSFX"))
	# The controller must not delete an external bus that replaces its own name.
	var replaced := Controller.new()
	root.add_child(replaced)
	await process_frame
	var replaced_name: String = replaced.diagnostics().bus_name
	var owned_index := AudioServer.get_bus_index(replaced_name)
	AudioServer.remove_bus(owned_index)
	AudioServer.add_bus()
	var replacement_index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(replacement_index, replaced_name)
	AudioServer.set_bus_mute(replacement_index, false)
	AudioServer.set_bus_volume_db(replacement_index, -17.0)
	replaced.set_volume(0.25)
	replaced.set_enabled(false)
	_check(
		is_equal_approx(replaced.diagnostics().volume, 0.25) and not replaced.diagnostics().enabled,
		"settings remain locally recorded after bus ownership is lost"
	)
	_check(
		is_equal_approx(AudioServer.get_bus_volume_db(replacement_index), -17.0)
		and not AudioServer.is_bus_mute(replacement_index),
		"settings do not alter an externally recreated same-name bus"
	)
	replaced.set_enabled(true)
	var play_count_before: int = int(replaced.get_debug_state().played_event_count)
	_check(not replaced.play("ui_click"), "play fails after controller loses bus ownership")
	_check(replaced.get_debug_state().played_event_count == play_count_before, "lost bus ownership records no successful play")
	_check(
		is_equal_approx(AudioServer.get_bus_volume_db(replacement_index), -17.0)
		and not AudioServer.is_bus_mute(replacement_index),
		"play and later settings leave the external replacement unchanged"
	)
	replaced.queue_free()
	await process_frame
	_check(AudioServer.get_bus_index(replaced_name) != -1, "externally recreated same-name bus is not deleted")
	AudioServer.remove_bus(AudioServer.get_bus_index(replaced_name))


func _save_recovery_stream(path: String) -> bool:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = 8000
	stream.stereo = false
	stream.data = PackedByteArray([128, 128, 128, 128, 128, 128, 128, 128])
	return ResourceSaver.save(stream, path) == OK


func _check(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append("FAIL: " + message)
