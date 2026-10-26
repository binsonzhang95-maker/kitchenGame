extends SceneTree
## Responsive bridge, wide hall and pause input regression.  This owns its
## private save/audio state and captures only to the sibling logs directory.

const Main = preload("res://multi_main.gd")
const ResponsiveLayout = preload("res://responsive_layout.gd")
const DEFAULT_SCREENSHOT_DIR := "res://verification/widescreen"

var app: Variant
var save_path := ""
var checks := 0
var failures := 0
var done := false

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("WIDESCREEN_REGRESSION_FAIL " + label)

func _run() -> void:
	_test_web_safe_data()
	if DisplayServer.get_name() == "headless":
		_check(false, "graphical renderer required for real pointer and captures")
		_finish()
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	create_timer(75.0, true, false, true).timeout.connect(func():
		if not done:
			_check(false, "watchdog expired")
			_finish())
	save_path = "user://widescreen_regression_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	app = Main.new()
	app.save_path = save_path
	app.seed_guests = false
	app.player_mode = true
	app.interactive_cooking = true
	root.add_child(app)
	await _frame()
	for spec: Dictionary in [
		{"name":"lobby_4_3", "size":Vector2i(1536, 1152), "insets":{}},
		{"name":"lobby_16_9", "size":Vector2i(2048, 1152), "insets":{}},
		{"name":"lobby_19_5_9", "size":Vector2i(2496, 1152), "insets":{}}
	]:
		DisplayServer.window_set_size(spec.size)
		await _frame()
		app.set_responsive_layout_for_test(Vector2(spec.size), spec.insets)
		await _frame()
		_check(app.room.position == app.responsive_layout.room_rect.position and app.room.scale == Vector2.ONE * float(app.responsive_layout.scale), str(spec.name) + " room uses layout room_rect")
		_capture(str(spec.name))
		await _restaurant_pause_click_path(str(spec.name))
	# A real bottom safe area shrinks the card's layout parent. Its child keeps
	# its own pop scale, so a resize cannot replace it with an unscaled transform.
	var safe_viewport := Vector2(2496, 1152)
	app.set_responsive_layout_for_test(safe_viewport, {"left":150.0, "right":150.0, "bottom":60.0})
	await _frame()
	app._show_completion_brief("drink")
	await _frame()
	var parent_rect: Rect2 = app.completion_layout.get_global_rect()
	var expected_center: Vector2 = app.responsive_layout.content_rect.get_center() + Vector2(0, -402.0 * float(app.responsive_layout.scale))
	_check(parent_rect.get_center().distance_to(expected_center) < 1.1, "safe completion parent stays at the design center")
	_check(app.completion_card.scale.x < 1.0 and app.completion_layout.scale.x < 1.0, "pop scale is nested below safe layout scale")
	_capture("completion_safearea")
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	_click(app.hud.settings_button.get_global_rect().get_center())
	await _frame()
	_check(app.model.paused and app.hud.settings_root.visible, "safe paused settings opens from a real pointer click")
	_capture("settings_safearea")
	_click(Vector2(12, 100))
	await _frame()
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	await _open_drink_kitchen()
	if app.cooking_session != null:
		await _capture_kitchen_side_regressions()
		await _kitchen_pause_click_path()
	_finish()

func _test_web_safe_data() -> void:
	var explicit_zero := ResponsiveLayout.web_safe_insets_from_data({"safe":{"left":0.0,"right":0.0,"top":0.0,"bottom":0.0},"width":1000.0,"height":500.0,"host_known":true,"css_nonzero":false,"mobile":true}, Vector2(2000, 1000))
	_check(explicit_zero == {"left":0.0,"right":0.0,"top":0.0,"bottom":0.0}, "explicit host zero bypasses mobile fallback")
	var css := ResponsiveLayout.web_safe_insets_from_data({"safe":{"left":10.0,"right":20.0,"top":5.0,"bottom":15.0},"width":1000.0,"height":500.0,"host_known":false,"css_nonzero":true,"mobile":true}, Vector2(2000, 1000))
	_check(css == {"left":20.0,"right":40.0,"top":10.0,"bottom":30.0}, "CSS canvas dimensions convert once at 2x")
	var portrait_css := ResponsiveLayout.web_safe_insets_from_data({"safe":{"left":10.0,"right":20.0,"top":5.0,"bottom":15.0},"width":1000.0,"height":500.0,"host_known":false,"css_nonzero":true,"mobile":true}, Vector2(500, 1000))
	_check(portrait_css == {"left":5.0,"right":10.0,"top":10.0,"bottom":30.0}, "CSS conversion keeps independent horizontal and vertical ratios")
	var fallback := ResponsiveLayout.web_safe_insets_from_data({"safe":{"left":0.0,"right":0.0,"top":0.0,"bottom":0.0},"width":1000.0,"height":500.0,"host_known":false,"css_nonzero":false,"mobile":true}, Vector2(2000, 1000))
	_check(fallback == {"left":150.0,"right":150.0,"top":0.0,"bottom":60.0}, "unknown mobile CSS zero uses only the documented fallback")
	var invalid: Dictionary = ResponsiveLayout.calculate(Vector2(1536, 1152), {"left":null,"right":"0","top":NAN,"bottom":INF}).safe_insets
	_check(invalid == {"left":0.0,"right":0.0,"top":0.0,"bottom":0.0}, "null strings NaN and Infinity are not valid insets")
	var negative: Dictionary = ResponsiveLayout.calculate(Vector2(1536, 1152), {"bottom":-12.0}).safe_insets
	_check(negative.bottom == 0.0, "negative inset clamps to zero")

func _restaurant_pause_click_path(name: String) -> void:
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	_check(app.model.paused and app.pause_overlay.visible, name + " real down/up pauses with a full shield")
	var before: int = app.selected_table
	_click(Vector2(8, app.responsive_layout.room_rect.position.y + 100.0))
	await _frame()
	_check(app.selected_table == before, name + " side shield blocks hall click-through")
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	_check(not app.model.paused, name + " real down/up resumes")
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	_click(app.hud.settings_button.get_global_rect().get_center())
	await _frame()
	_check(app.hud.settings_root.visible, name + " paused settings remains reachable by pointer")
	_click(Vector2(12, 100))
	await _frame()
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()

func _open_drink_kitchen() -> void:
	app.model.open_for_arrivals = false
	app.model.auto_seat = false
	app.model.auto_dispatch = false
	app.model.set_order_menu(["drink"])
	var guest: int = app.model.spawn_customer()
	var table_id := 1
	for table: Dictionary in app.model.tables:
		if table.phase == "free": table_id = int(table.id); break
	_check(guest > 0 and app.model.assign_next(table_id), "kitchen setup assigns a private drink order")
	var deadline := Time.get_ticks_msec() + 3000
	while app.model.table_action(table_id) != "order" and Time.get_ticks_msec() < deadline:
		app.model.tick(0.1)
		await _frame()
	_check(app.model.table_action(table_id) == "order" and app.model.act(table_id, "order") and app._begin_cooking(table_id), "kitchen opens through the real model path")
	await _frame()

func _kitchen_pause_click_path() -> void:
	_click(app.cooking_view.pause_button.get_global_rect().get_center())
	await _frame()
	_check(app.cooking_session.paused and app.cooking_view.pause_overlay.visible, "kitchen real pointer pause opens its content shield")
	var paused_state: Dictionary = app.cooking_session.to_dict().duplicate(true)
	_click(Vector2(8, app.responsive_layout.room_rect.position.y + 120.0))
	await _frame()
	_check(app.cooking_session.to_dict() == paused_state, "kitchen side extension absorbs clicks while paused")
	_click(app.cooking_view.pause_button.get_global_rect().get_center())
	await _frame()
	_check(not app.cooking_session.paused, "kitchen real pointer resumes through the top escape route")

func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

func _frame() -> void:
	await process_frame
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw

func _capture(name: String) -> void:
	var directory := _screenshot_directory()
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("widescreen_" + name + ".png")
	var image := root.get_texture().get_image()
	_check(image != null and not image.is_empty() and image.save_png(path) == OK, "capture " + name)

func _screenshot_directory() -> String:
	var requested := OS.get_environment("KITCHEN_SCREENSHOT_DIR").strip_edges()
	if requested.is_empty(): requested = DEFAULT_SCREENSHOT_DIR
	return ProjectSettings.globalize_path(requested) if requested.begins_with("res://") or requested.begins_with("user://") else requested

func _capture_kitchen_side_regressions() -> void:
	for spec: Dictionary in [
		{"name":"kitchen_16_9", "size":Vector2i(2048, 1152), "insets":{}},
		{"name":"kitchen_safe_scale", "size":Vector2i(2496, 1152), "insets":{"left":150.0, "right":150.0, "bottom":60.0}},
	]:
		DisplayServer.window_set_size(spec.size)
		await _frame()
		app.set_responsive_layout_for_test(Vector2(spec.size), spec.insets)
		await _frame()
		_check_kitchen_side_strips(app.responsive_layout, str(spec.name))
		_capture(str(spec.name))

func _check_kitchen_side_strips(layout: Dictionary, label: String) -> void:
	var view = app.cooking_view
	var content: Rect2 = layout.content_rect
	var viewport: Vector2 = layout.viewport
	var scale: float = float(layout.scale)
	var room_top := content.position.y + 80.0 * scale
	var strip_width := 384.0 * scale
	var left_gap := content.position.x
	var right_gap := viewport.x - content.end.x
	_check(view.side_left_clip.clip_contents and view.side_right_clip.clip_contents, label + " clips side strips")
	_check(_near(view.side_left.scale.x, scale) and _near(view.side_right.scale.x, scale), label + " scales source strips uniformly")
	_check(_near(view.side_left.get_global_rect().end.x, content.position.x) and _near(view.side_right.get_global_rect().position.x, content.end.x), label + " joins both source strips to the countertop and floor")
	_check(_near(view.side_left_clip.position.y, room_top) and _near(view.side_right_clip.position.y, room_top), label + " aligns side strips to room top")
	_check(_near(view.side_left_clip.size.x, left_gap) and _near(view.side_right_clip.size.x, right_gap), label + " clips exactly to side gaps")
	if left_gap < strip_width:
		_check(view.side_left.position.x < 0.0 and _near(view.side_right.position.x, 0.0), label + " crops only outer source pixels when a gap is narrow")

func _near(a: float, b: float) -> bool:
	return is_equal_approx(a, b) or absf(a - b) < 0.05

func _finish() -> void:
	if done: return
	done = true
	if is_instance_valid(app) and is_instance_valid(app.music): app.music.queue_free()
	if is_instance_valid(app): app.queue_free()
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path + suffix))
	print("WIDESCREEN_REGRESSION checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
