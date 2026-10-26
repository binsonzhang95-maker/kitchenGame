extends SceneTree
## Headless GUI geometry/input regression. It owns a unique, private save slot.

const Main = preload("res://multi_main.gd")
const DEFAULT_SCREENSHOT_DIR := "res://verification/widescreen"
var app: Variant
var save_path := ""
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("RESPONSIVE_UI_FAIL " + label)

func _run() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(Vector2i(2496, 1152))
		await process_frame
	save_path = "user://responsive_ui_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	app = Main.new()
	app.save_path = save_path
	app.seed_guests = false
	app.player_mode = false
	root.add_child(app)
	await process_frame
	var viewport := Vector2(2496, 1152)
	var insets := {"left":150, "right":150, "bottom":60}
	app.set_responsive_layout_for_test(viewport, insets)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		_capture_viewport()
	var content: Rect2 = app.responsive_layout.content_rect
	_check(app.room.position == content.position + Vector2(0, 80) * float(app.responsive_layout.scale), "room is transformed once from the shared content origin")
	for table: Dictionary in app.model.tables:
		var screen: Vector2 = app.room.get_global_transform_with_canvas() * Vector2(table.center)
		_check(content.grow(0.1).has_point(screen), "table %d remains inside safe content" % int(table.id))
	var table_twenty: Vector2 = app.room.get_global_transform_with_canvas() * Vector2(app.model.tables[19].center)
	_click(table_twenty)
	await process_frame
	_check(app.selected_table == 20, "real transformed pointer selects table 20")
	app.hud.toggle_settings()
	_check(app.hud.settings_root.size == viewport and app.hud.settings_root.visible, "settings veil covers the full viewport")
	app.hud.close_overlay()
	app.cooking_view.apply_layout(app.responsive_layout)
	_check_kitchen_side_strips(app.responsive_layout, "wide safe area")
	for slot: Dictionary in app.cooking_view.ingredient_slots:
		_check(content.grow(0.1).encloses(slot.button.get_global_rect()), "kitchen ingredient control remains in safe content")
	app.toy_simulator.open()
	app.toy_simulator.apply_layout(app.responsive_layout)
	var toy_panel := app.toy_simulator.root.find_child("ToySimulatorPanel", true, false) as Control
	_check(toy_panel != null and content.grow(0.1).encloses(toy_panel.get_global_rect()), "simulator panel remains complete in safe content")
	app.toy_simulator.close()
	app._pause()
	_check(app.pause_overlay.visible and app.pause_overlay.size == viewport, "restaurant pause shield covers side extensions")
	app._pause()
	var compact_viewport := Vector2(1280, 960)
	var compact_insets := {"left":40.0, "right":40.0, "bottom":30.0}
	app.set_responsive_layout_for_test(compact_viewport, compact_insets)
	_check(float(app.responsive_layout.scale) < 1.0, "compact safe area uses a scale below one")
	_check_kitchen_side_strips(app.responsive_layout, "compact safe scale")
	app.set_responsive_layout_for_test(Vector2(1536, 1152))
	_check(app.room.position == Vector2(0, 80) and app.room.scale == Vector2.ONE, "resize back restores exact 4:3 room transform")
	await _cleanup()
	print("RESPONSIVE_UI_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

func _cleanup() -> void:
	if is_instance_valid(app) and is_instance_valid(app.music): app.music.queue_free()
	if is_instance_valid(app): app.queue_free()
	await process_frame
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path + suffix))
		_check(not FileAccess.file_exists(save_path + suffix), "private test artifact cleaned: " + suffix)

func _capture_viewport() -> void:
	var directory := _screenshot_directory()
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("responsive_viewport.png")
	var image := root.get_texture().get_image()
	_check(image != null and not image.is_empty() and image.save_png(path) == OK, "wide viewport capture is written")


func _screenshot_directory() -> String:
	var requested := OS.get_environment("KITCHEN_SCREENSHOT_DIR").strip_edges()
	if requested.is_empty(): requested = DEFAULT_SCREENSHOT_DIR
	return ProjectSettings.globalize_path(requested) if requested.begins_with("res://") or requested.begins_with("user://") else requested


func _check_kitchen_side_strips(layout: Dictionary, label: String) -> void:
	var view = app.cooking_view
	var content: Rect2 = layout.content_rect
	var viewport: Vector2 = layout.viewport
	var scale: float = float(layout.scale)
	var room_top := content.position.y + 80.0 * scale
	var strip_width := 384.0 * scale
	var left_gap := content.position.x
	var right_gap := viewport.x - content.end.x
	_check(view.side_left_clip.clip_contents and view.side_right_clip.clip_contents, label + " side strips clip their outer side")
	_check(_near(view.side_left.scale.x, scale) and _near(view.side_right.scale.x, scale), label + " side source slices use layout scale")
	_check(_near(view.side_left.get_global_rect().end.x, content.position.x) and _near(view.side_right.get_global_rect().position.x, content.end.x), label + " side source inner edges meet the central panorama")
	_check(_near(view.side_left_clip.position.y, room_top) and _near(view.side_right_clip.position.y, room_top), label + " side strips share room top")
	_check(_near(view.side_left_clip.size.x, left_gap) and _near(view.side_right_clip.size.x, right_gap), label + " side clip geometry matches both gaps")
	if left_gap < strip_width:
		_check(view.side_left.position.x < 0.0 and _near(view.side_right.position.x, 0.0), label + " narrow gaps crop only the outer source edges")


func _near(a: float, b: float) -> bool:
	return is_equal_approx(a, b) or absf(a - b) < 0.05
