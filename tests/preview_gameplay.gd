extends SceneTree
## Hall-only visual preview, not a claim that all twenty tables passed acceptance.
## Uses a real graphical renderer, existing gameplay handlers, and a private save.
const Main = preload("res://multi_main.gd")
const CAPTURE_PATH := "res://verification/visual_hall_preview.png"
const WATCHDOG_SECONDS: float = 45.0
const TARGET_INVITED: int = 6
var app: Variant = null
var save_path: String = ""
var owns_save_slot: bool = false
var finished: bool = false
var result_code: int = 1
var invited: int = 0
var rendered_frames: int = 0
var started_ms: int = 0
var previous_time_scale: float = 1.0
var last_progress_ms: int = 0
var pay_hold_until: float = -1.0

func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	previous_time_scale = Engine.time_scale
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("requires an actual graphical renderer; headless cannot produce this preview")
		return
	create_timer(WATCHDOG_SECONDS, true, false, true).timeout.connect(_on_watchdog)
	save_path = "user://preview_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	if save_path == Main.SAVE_PATH:
		_fail("private save unexpectedly equals the normal player slot")
		return
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix):
			_fail("refusing to reuse a pre-existing preview slot")
			return
	owns_save_slot = true
	app = Main.new()
	# Historical manual-operation preview, not the current order-only acceptance.
	app.player_mode = false
	app.save_path = save_path
	app.seed_guests = false
	Engine.time_scale = 4.0
	root.add_child(app)
	var preview_insets := _requested_insets()
	if not preview_insets.is_empty():
		var logical_size := root.get_visible_rect().size
		var render_size := Vector2(root.get_texture().get_width(), root.get_texture().get_height())
		preview_insets.left *= logical_size.x / render_size.x
		preview_insets.right *= logical_size.x / render_size.x
		preview_insets.top *= logical_size.y / render_size.y
		preview_insets.bottom *= logical_size.y / render_size.y
		app.set_responsive_layout_for_test(logical_size, preview_insets)
	if not app.model.customers.is_empty() or int(app.model.served) != 0:
		_fail("preview did not begin with a fresh private restaurant")
		return
	if app.model.open_for_arrivals: app._toggle_arrivals()
	if not app.model.auto_seat: app._toggle_seating()
	if not app.model.auto_dispatch: app._toggle_dispatch()
	if not app.model.auto_cook: app._toggle_cooking()
	print("HALL_PREVIEW_START preview_only=true pid=%d save=%s time_scale=4" % [OS.get_process_id(), save_path])
	while not finished:
		await _render_frame()
		if finished: return
		var violations: Array[String] = app.model.validate_invariants()
		if not violations.is_empty():
			_fail("invalid gameplay state: " + "; ".join(violations))
			return
		if not app.save_allowed or str(app.save_label.text).contains("保存失败"):
			_fail("private preview save could not be written")
			return
		for table: Dictionary in app.model.tables:
			if int(table.generation) > 0 and (str(table.zone) != "hall" or int(table.id) > 6):
				_fail("preview left the intended first-six hall tables")
				return
		if int(app.model.lost) > 0:
			_fail("a preview guest timed out before the hall scene was ready")
			return
		var actionable_table: int = _capture_action_table()
		if invited == TARGET_INVITED and actionable_table > 0 and _has_dining_guest() and not app.bubble_layer._visuals.is_empty():
			app.hud.settings_root.visible = false
			app.hud.debug_root.visible = false
			app._select_table(actionable_table)
			await _render_frame()
			if finished: return
			if _has_dining_guest() and not app.bubble_layer._visuals.is_empty() and not app.primary.disabled and _visible_quick_action_available():
				_capture()
				return
		var now: int = Time.get_ticks_msec()
		if now - last_progress_ms >= 5000:
			last_progress_ms = now
			print("HALL_PREVIEW_PROGRESS invited=%d active=%d served=%d bubbles=%d simulation_seconds=%.2f wall_seconds=%.2f" % [invited, app.model.customers.size(), app.model.served, app.bubble_layer._visuals.size(), app.model.clock, (now - started_ms) / 1000.0])
		if app.cooldown > 0.0: continue
		if invited < TARGET_INVITED:
			var before_id: int = int(app.model.next_customer_id)
			app._invite()
			if int(app.model.next_customer_id) == before_id + 1: invited += 1
		elif _has_action("order"):
			app._order_all()
		elif _has_action("pay"):
			# A short ordinary wait lets a checkout action and another guest's natural
			# expression overlap. No stages, actor positions, money, or bubble data change.
			if pay_hold_until < 0.0: pay_hold_until = float(app.model.clock) + 4.0
			if float(app.model.clock) >= pay_hold_until:
				app._pay_all()
				pay_hold_until = -1.0
		else:
			pay_hold_until = -1.0

func _requested_insets() -> Dictionary:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--insets="):
			continue
		var parts := argument.trim_prefix("--insets=").split(",")
		if parts.size() == 4:
			return {"left":parts[0].to_float(), "right":parts[1].to_float(), "top":parts[2].to_float(), "bottom":parts[3].to_float()}
	return {}

func _render_frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	rendered_frames += 1

func _has_dining_guest() -> bool:
	for table: Dictionary in app.model.tables:
		if table.phase in ["eating", "drinking"] and table.guest_id > 0: return true
	return false

func _has_action(action: String) -> bool:
	for table: Dictionary in app.model.tables:
		if app.model.table_action(table.id) == action: return true
	return false

func _capture_action_table() -> int:
	if app.cooldown > 0.0 or app.model.paused: return -1
	# Prefer checkout, then a table popup action; the removed global bottom bar is never required.
	for action: String in ["pay", "order", "cook"]:
		for table: Dictionary in app.model.tables:
			if int(table.id) <= 6 and app.model.table_action(table.id) == action: return int(table.id)
	return -1

func _visible_quick_action_available() -> bool:
	return app.primary.is_visible_in_tree() and not app.primary.disabled

func _capture() -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://verification"))
	if error != OK and error != ERR_ALREADY_EXISTS:
		_fail("cannot create preview output directory: %d" % error)
		return
	var pixels: Image = root.get_texture().get_image()
	if pixels == null or pixels.is_empty():
		_fail("actual rendered viewport pixels are unavailable")
		return
	error = pixels.save_png(CAPTURE_PATH)
	if error != OK:
		_fail("cannot save real viewport screenshot: %d" % error)
		return
	print("HALL_PREVIEW_OK preview_only=true served=%d active=%d bubble_count=%d selected_table=%d selected_action=%s quick_action_enabled=true viewport=%dx%d frames=%d simulation_seconds=%.2f path=%s" % [app.model.served, app.model.customers.size(), app.bubble_layer._visuals.size(), app.selected_table, app.model.table_action(app.selected_table), pixels.get_width(), pixels.get_height(), rendered_frames, app.model.clock, ProjectSettings.globalize_path(CAPTURE_PATH)])
	_finish(0)

func _on_watchdog() -> void:
	if finished: return
	var status: String = "application not ready"
	if is_instance_valid(app):
		status = "invited=%d active=%d served=%d bubbles=%d sim=%.2f" % [invited, app.model.customers.size(), app.model.served, app.bubble_layer._visuals.size(), app.model.clock]
	_fail("45-second real-time deadline reached without a dining, bubble and actionable-control capture: " + status)

func _fail(reason: String) -> void:
	if finished: return
	push_error("HALL_PREVIEW_FAILED: " + reason)
	_finish(1)

func _finish(code: int) -> void:
	if finished: return
	finished = true
	result_code = code
	Engine.time_scale = previous_time_scale
	if is_instance_valid(app):
		app.set_process(false)
		var preview_music: Node = app.music
		app.free()
		app = null
		if is_instance_valid(preview_music): preview_music.free()
	# Audio is stopped before cleanup, and the mixing thread gets a real interval.
	await create_timer(0.75, true, false, true).timeout
	if owns_save_slot:
		for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
			var path: String = save_path + suffix
			if FileAccess.file_exists(path):
				var error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
				if error != OK:
					push_error("HALL_PREVIEW_CLEANUP_FAILED: private file removal error %d" % error)
					result_code = 1
	print("HALL_PREVIEW_EXIT code=%d preview_only=true wall_ms=%d" % [result_code, Time.get_ticks_msec() - started_ms])
	quit(result_code)
