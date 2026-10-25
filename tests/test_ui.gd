extends SceneTree
## GUI integration test; launch only after Godot execution is authorized.
## godot --path <project> --script res://tests/test_ui.gd
## Optional screenshot: append -- --capture
## This script never opens or deletes the player's normal save slot.

const Main = preload("res://main.gd")
const WATCHDOG_SECONDS: float = 90.0
const REQUIRED_PHASES: Array[String] = [
	"entering", "queued", "seating", "ordering", "awaiting_cook", "cooking",
	"food_ready", "serving_food", "waiting_drink", "serving_drink", "eating",
	"drinking", "checkout", "leaving", "dirty", "collecting", "wiping", "ready_next",
]
const PRIMARY_NEXT: Dictionary = {
	"queued": "seating", "ordering": "awaiting_cook", "awaiting_cook": "cooking",
	"food_ready": "serving_food", "waiting_drink": "serving_drink",
	"checkout": "leaving", "dirty": "collecting", "ready_next": "entering",
}
const CAPTURE_PATH: String = "res://verification/ui_two_customers.png"

var app: Variant = null
var own_save_path: String = ""
var assertions: int = 0
var failures: int = 0
var rendered_frames: int = 0
var finished: bool = false
var pause_checked: bool = false
var dining_captured: bool = false
var owns_save_slot: bool = false
var visited: Dictionary = {1: {}, 2: {}}
var duplicate_checks: Dictionary = {}
var previous_time_scale: float = 1.0
var started_ms: int = 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	previous_time_scale = Engine.time_scale
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("UI_ASSERT_FAIL " + description)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_expect(false, "GUI rendering is required; do not run this test with --headless")
		_finish()
		return
	# Real-time watchdog remains active even while gameplay time is paused.
	create_timer(WATCHDOG_SECONDS, true, false, true).timeout.connect(_on_watchdog)
	own_save_path = "user://ui_test_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	_expect(not FileAccess.file_exists(own_save_path) and not FileAccess.file_exists(own_save_path + ".tmp"), "fresh private test save slot")
	if failures > 0:
		_finish()
		return
	owns_save_slot = true
	app = Main.new()
	# Set this BEFORE add_child: Main._ready() may load/autosave immediately.
	app.save_path = own_save_path
	Engine.time_scale = 8.0
	root.add_child(app)
	_expect(app.save_path == own_save_path, "main uses the private save slot")
	_expect(app.model.customer_id == 1 and app.model.coins == 0, "new game starts clean")
	print("UI_TEST_START save=%s time_scale=8" % own_save_path)
	while not finished:
		await _render_frame()
		if finished:
			return
		_observe_rendered_phase()
		if failures > 0:
			_finish()
			return
		var phase: String = str(app.model.phase)
		var guest: int = int(app.model.customer_id)
		if guest == 2 and phase == "eating" and float(app.model.elapsed) > 1.0 and not dining_captured and "--capture" in OS.get_cmdline_user_args():
			_capture_frame("res://verification/ui_dining.png")
			dining_captured = true
		if phase == "cooking" and guest == 1 and not pause_checked:
			await _check_pause_and_resume()
			if finished:
				return
			continue
		if phase == "leaving" and float(app.action_cooldown) <= 0.0 and not duplicate_checks.has(guest):
			_expect(bool(app.model.paid), "guest %d leaves after payment, not timeout" % guest)
			_expect(bool(app.primary.disabled), "payment cannot be clicked again after cooldown")
			var before: Dictionary = app.model.to_dict().duplicate(true)
			for repeat: int in range(8):
				app._primary()
			_expect(app.model.to_dict() == before, "guest %d late repeated payment handler is harmless" % guest)
			duplicate_checks[guest] = true
		if phase == "ready_next" and guest == 2:
			_check_final_state()
			if failures == 0 and "--capture" in OS.get_cmdline_user_args():
				_capture_frame()
			_finish()
			return
		# Honor the real UI's cooldown/disabled state; never advance the model directly.
		if PRIMARY_NEXT.has(phase) and not bool(app.primary.disabled):
			_click_primary_burst(phase)


func _render_frame() -> void:
	# process_frame is before node _process; frame_post_draw is after that tick and draw.
	await process_frame
	if finished:
		return
	await RenderingServer.frame_post_draw
	if not finished:
		rendered_frames += 1


func _observe_rendered_phase() -> void:
	var guest: int = int(app.model.customer_id)
	var phase: String = str(app.model.phase)
	_expect(guest in [1, 2], "test never starts an unintended third guest")
	if not visited.has(guest):
		return
	var guest_phases: Dictionary = visited[guest]
	if not guest_phases.has(phase):
		var next_index: int = guest_phases.size()
		_expect(next_index < REQUIRED_PHASES.size(), "phase count stays bounded")
		if next_index < REQUIRED_PHASES.size():
			_expect(phase == REQUIRED_PHASES[next_index], "guest %d renders every phase in order; got %s, expected %s" % [guest, phase, REQUIRED_PHASES[next_index]])
		guest_phases[phase] = rendered_frames
		print("UI_PHASE guest=%d phase=%s rendered_frame=%d wall_ms=%d" % [guest, phase, rendered_frames, Time.get_ticks_msec() - started_ms])


func _click_primary_burst(phase: String) -> void:
	var guest: int = int(app.model.customer_id)
	var coins_before: int = int(app.model.coins)
	var served_before: int = int(app.model.served)
	_expect(not bool(app.primary.disabled), "primary is enabled before %s" % phase)
	app._primary()
	_expect(str(app.model.phase) == str(PRIMARY_NEXT[phase]), "primary advances %s exactly once" % phase)
	_expect(bool(app.primary.disabled), "primary disables immediately after %s" % phase)
	var after_one: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8):
		app._primary()
	_expect(app.model.to_dict() == after_one, "rapid click burst cannot cross the next phase after %s" % phase)
	if phase == "checkout":
		_expect(int(app.model.coins) == coins_before + 38, "guest %d receives exactly one payment" % guest)
		_expect(int(app.model.served) == served_before + 1, "guest %d counted exactly once" % guest)
	else:
		_expect(int(app.model.coins) == coins_before, "nonpayment action does not change coins")


func _check_pause_and_resume() -> void:
	pause_checked = true
	app._pause()
	_expect(bool(app.model.paused), "pause handler pauses gameplay")
	var frozen: Dictionary = app.model.to_dict().duplicate(true)
	var animation_before: float = float(app.anim_clock)
	var elapsed_before: float = float(app.model.elapsed)
	# This timer ignores Engine.time_scale; actual app _process frames still run.
	await create_timer(0.35, true, false, true).timeout
	if finished:
		return
	await _render_frame()
	if finished:
		return
	_expect(bool(app.pause_overlay.visible), "pause overlay is rendered")
	_expect(bool(app.primary.disabled), "paused primary is disabled")
	for repeat: int in range(8):
		app._primary()
	_expect(app.model.to_dict() == frozen, "real process frames and clicks leave paused model unchanged")
	_expect(float(app.anim_clock) == animation_before, "animation clock freezes while paused")
	app._pause()
	_expect(not bool(app.model.paused), "pause handler resumes gameplay")
	await _render_frame()
	if finished:
		return
	_expect(not bool(app.pause_overlay.visible), "pause overlay hides after resume")
	_expect(float(app.model.elapsed) > elapsed_before or str(app.model.phase) != "cooking", "real process tick resumes after pause")
	print("UI_PAUSE_RESUME_OK")


func _check_final_state() -> void:
	for guest: int in [1, 2]:
		var guest_phases: Dictionary = visited[guest]
		for phase: String in REQUIRED_PHASES:
			_expect(guest_phases.has(phase), "guest %d rendered %s" % [guest, phase])
		_expect(duplicate_checks.has(guest), "guest %d rejects payment after cooldown" % guest)
	_expect(pause_checked, "pause/resume exercised through handlers")
	_expect(int(app.model.coins) == 76, "two guests produce exactly 76 coins")
	_expect(int(app.model.served) == 2, "two guests served")
	_expect(int(app.model.lost) == 0, "no guest timed out")
	_expect(not bool(app.model.table_used) and bool(app.model.dishes_collected), "second table is clean and free")
	_expect(str(app.model.phase) == "ready_next", "test stops before inviting guest three")
	_expect(str(app.coins_label.text).contains("76"), "real UI coin label displays 76")
	_expect(FileAccess.file_exists(own_save_path), "autosave writes the private test slot")
	print("UI_FINAL_STATE coins=%d served=%d lost=%d phase=%s" % [int(app.model.coins), int(app.model.served), int(app.model.lost), str(app.model.phase)])


func _capture_frame(path: String = CAPTURE_PATH) -> void:
	# Called immediately after an already completed frame_post_draw.
	var directory: String = ProjectSettings.globalize_path("res://verification")
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(directory)
	_expect(directory_error == OK or directory_error == ERR_ALREADY_EXISTS, "capture directory is writable")
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return
	var capture: Image = root.get_texture().get_image()
	_expect(capture != null and not capture.is_empty(), "rendered viewport can be captured")
	if capture == null or capture.is_empty():
		return
	var save_error: Error = capture.save_png(path)
	_expect(save_error == OK, "optional screenshot saved")
	if save_error == OK:
		print("UI_CAPTURE " + ProjectSettings.globalize_path(path))


func _on_watchdog() -> void:
	if finished:
		return
	var phase: String = str(app.model.phase) if is_instance_valid(app) else "not_created"
	_expect(false, "real-time watchdog expired in phase " + phase)
	_finish()


func _finish() -> void:
	if finished:
		return
	finished = true
	Engine.time_scale = previous_time_scale
	# Stop autosave before removing only this run's two exact slot paths.
	if is_instance_valid(app):
		app.set_process(false)
		app.free()
		app = null
	if owns_save_slot:
		for suffix: String in ["", ".tmp"]:
			var path: String = own_save_path + suffix
			if FileAccess.file_exists(path):
				var cleanup_error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
				_expect(cleanup_error == OK, "remove only this run's private test slot")
	print("UI_TEST_RESULT assertions=%d failures=%d rendered_frames=%d wall_ms=%d" % [assertions, failures, rendered_frames, Time.get_ticks_msec() - started_ms])
	quit(0 if failures == 0 else 1)
