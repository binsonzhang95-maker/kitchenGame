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
		var viewport := await _set_test_viewport(spec.size, spec.insets)
		_check(app.room.position == app.responsive_layout.room_rect.position and app.room.scale == Vector2.ONE * float(app.responsive_layout.scale), str(spec.name) + " room uses layout room_rect")
		_check(Vector2(app.responsive_layout.viewport).is_equal_approx(viewport), str(spec.name) + " layout uses the drawable viewport")
		_capture(str(spec.name))
		await _restaurant_pause_click_path(str(spec.name))
	# A real bottom safe area shrinks the card's layout parent. Its child keeps
	# its own pop scale, so a resize cannot replace it with an unscaled transform.
	var safe_viewport := _actual_viewport_size()
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
		await _capture_kitchen_panorama_regressions()
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
	if image != null and not image.is_empty():
		_check(Vector2(image.get_width(), image.get_height()).is_equal_approx(_actual_viewport_size()), "capture " + name + " matches drawable viewport")

func _screenshot_directory() -> String:
	var requested := OS.get_environment("KITCHEN_SCREENSHOT_DIR").strip_edges()
	if requested.is_empty(): requested = DEFAULT_SCREENSHOT_DIR
	return ProjectSettings.globalize_path(requested) if requested.begins_with("res://") or requested.begins_with("user://") else requested

func _set_test_viewport(requested: Vector2i, insets: Dictionary = {}) -> Vector2:
	DisplayServer.window_set_size(requested)
	await _frame()
	var drawable := _actual_viewport_size()
	app.set_responsive_layout_for_test(drawable, insets)
	await _frame()
	return drawable

func _actual_viewport_size() -> Vector2:
	var texture := root.get_texture()
	if texture != null and texture.get_width() > 0 and texture.get_height() > 0:
		return Vector2(texture.get_width(), texture.get_height())
	return root.get_visible_rect().size

func _capture_kitchen_panorama_regressions() -> void:
	for spec: Dictionary in [
		{"name":"kitchen_16_9", "size":Vector2i(2048, 1152), "insets":{}},
		{"name":"kitchen_safe_scale", "size":Vector2i(2496, 1152), "insets":{"left":150.0, "right":150.0, "bottom":60.0}},
	]:
		var viewport := await _set_test_viewport(spec.size, spec.insets)
		_check(Vector2(app.responsive_layout.viewport).is_equal_approx(viewport), str(spec.name) + " kitchen layout uses the drawable viewport")
		_check_kitchen_panorama(app.responsive_layout, str(spec.name))
		_capture(str(spec.name))

func _check_kitchen_panorama(layout: Dictionary, label: String) -> void:
	var view = app.cooking_view
	var content: Rect2 = layout.content_rect
	var viewport_rect := Rect2(Vector2.ZERO, layout.viewport)
	_check(view.background_image.texture != null and view.background_image.texture.resource_path.ends_with("kitchen_background_panorama_2304x1024.png"), label + " uses the kitchen panorama texture")
	_check(view.background_image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED, label + " panorama uses aspect cover")
	_check(viewport_rect.grow(0.1).encloses(view.background_image.get_global_rect()) and view.background_image.get_global_rect().grow(0.1).encloses(viewport_rect), label + " panorama global rect covers the complete viewport")
	_check(content.grow(0.1).encloses(view.cancel_button.get_global_rect()) and content.grow(0.1).encloses(view.pause_button.get_global_rect()), label + " header controls use safe left and right edges")
	for slot: Dictionary in view.ingredient_slots:
		_check(content.grow(0.1).encloses(slot.button.get_global_rect()), label + " ingredient target remains in safe content")
	for button: Button in view.action_buttons.values():
		_check(content.grow(0.1).encloses(button.get_global_rect()), label + " action target remains in safe content")
	var appliance_screen: Vector2 = view.root_control.get_global_transform_with_canvas() * view._appliance_rect().get_center()
	_check(content.grow(0.1).encloses(view.utensil_image.get_global_rect()), label + " cookware remains in safe content")
	_check(view.ingredient_slots[0].button.get_global_rect().get_center().x < appliance_screen.x, label + " ingredient station stays left of cookware")
	if not view.action_buttons.is_empty():
		_check(appliance_screen.x < view.action_bar.get_global_rect().get_center().x, label + " actual action station stays right of cookware")
		_check(content.grow(0.1).encloses(view.action_surface.get_global_rect()), label + " actual action surface remains in safe content")

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
