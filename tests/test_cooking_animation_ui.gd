extends SceneTree
## Real-window regression for transient kitchen animation.  It owns one private
## save slot and never reads, closes, or signals another Godot process.

const Main = preload("res://multi_main.gd")
const SAVE_PREFIX := "user://cooking_animation_ui_"

var app: Variant
var save_path := ""
var done := false
var checks := 0
var failures := 0
var frames := 0
var started := 0
var prior_scale := 1.0
var private_paths: Array[String] = []


func _initialize() -> void:
	started = Time.get_ticks_msec()
	prior_scale = Engine.time_scale
	call_deferred("_run")


func _check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("COOKING_ANIMATION_UI_FAIL " + description)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "graphical renderer required")
		_finish()
		return
	root.title = "动物餐厅 · 厨房动画隔离测试（静音）"
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	create_timer(120.0, true, false, true).timeout.connect(_timeout)
	Engine.time_scale = 1.0
	_new_private_slot()
	await _open_recipe(0)
	if done: return
	await _test_soup()
	if done: return
	_new_private_slot()
	await _open_recipe(1)
	if done: return
	await _test_stir_fry()
	if done: return
	_new_private_slot()
	await _open_recipe(2)
	if done: return
	await _test_bake_static()
	if done: return
	_new_private_slot()
	await _open_recipe(3)
	if done: return
	await _test_drink_static()
	_finish()


func _new_main() -> void:
	app = Main.new()
	app.menu_kind = "classic"
	app.save_path = save_path
	app.seed_guests = false
	app.player_mode = true
	app.interactive_cooking = true
	root.add_child(app)


func _new_private_slot() -> void:
	save_path = SAVE_PREFIX + "%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	private_paths.append(save_path)


func _free_main() -> void:
	if not is_instance_valid(app): return
	app.set_process(false)
	var music: Node = app.music
	app.free()
	app = null
	if is_instance_valid(music): music.free()


func _open_recipe(recipe_index: int) -> void:
	_free_main()
	_new_main()
	await _frame()
	app.model.open_for_arrivals = false
	app.model.auto_seat = false
	app.model.auto_dispatch = false
	for index in range(recipe_index + 1):
		_check(app.model.spawn_customer() > 0 and app.model.assign_next(index + 1), "fixture binds table for recipe %d" % recipe_index)
		if failures > 0:
			_finish()
			return
	var table_id := recipe_index + 1
	var deadline := Time.get_ticks_msec() + 5000
	while not done and app.model.table_action(table_id) != "order" and Time.get_ticks_msec() < deadline:
		await _frame()
	_check(app.model.table_action(table_id) == "order", "fixture reaches ordering for recipe %d" % recipe_index)
	if failures > 0:
		_finish()
		return
	_check(app.model.act(table_id, "order"), "fixture accepts bound order for recipe %d" % recipe_index)
	_check(app._begin_cooking(table_id), "kitchen opens for recipe %d" % recipe_index)
	await _frame()
	_check(app.cooking_view.visible and app.cooking_session != null, "real kitchen view is visible")


func _test_soup() -> void:
	_check(app.cooking_session.recipe_id == "soup", "soup fixture is bound")
	await _tap("add_potato")
	await _tap("add_carrot")
	await _tap("add_water")
	var pour_start: Dictionary = app.cooking_view.animation_debug_state()
	_check(pour_start.clip == "pour_water" and pour_start.playing and not app.cooking_view.water_flow.visible, "classic soup add-water visibly starts the original pour_water one-shot, not P0 faucet flow")
	var pour_regions := await _sample_regions("pour_water", 0.21)
	_check(pour_regions.size() >= 2 and pour_regions[0] != pour_regions[1], "classic soup pour_water renders distinct authored frames")
	_capture("pour_water")
	await _tap("pause")
	var paused_pour: Dictionary = app.cooking_view.animation_debug_state()
	await create_timer(0.36, true, false, true).timeout
	await _frame()
	var held_pour: Dictionary = app.cooking_view.animation_debug_state()
	_check(held_pour.playing and held_pour.region == paused_pour.region, "classic pour_water remains fixed while session is paused")
	await _tap("pause")
	await create_timer(0.12, true, false, true).timeout
	await _frame()
	_check(app.cooking_view.animation_debug_state().clip == "pour_water", "classic pour_water resumes from its preserved frame")
	await _wait_action("cut")
	var cut_point: Vector2 = _button("cut").get_global_rect().get_center()
	_click(cut_point)
	_click(cut_point)
	await _frame()
	_check(app.cooking_session.phase == "vessel" and app.cooking_session.cut_done and app.cooking_session.vessel.is_empty(), "same-coordinate double click cannot jump cut directly into pot")
	var chop_regions := await _sample_regions("chop", 0.21)
	_check(chop_regions.size() >= 2 and chop_regions[0] != chop_regions[1], "chop uses distinct Atlas regions across rendered frames")
	_capture("chop")
	# Cancel while the one-shot is still eligible to be active, then re-enter the
	# same order.  No old transient feedback may cross that session boundary.
	await _tap("cancel")
	_check(app.cooking_session == null and not app.cooking_view.visible, "cancel hides kitchen and clears feedback")
	while not done and app.cooldown > 0.0: await _frame()
	_check(app._begin_cooking(1), "cancelled soup re-enters the same order")
	await _frame()
	_check(not bool(app.cooking_view.animation_debug_state().playing), "re-entry does not replay an old single-shot")
	await _tap("add_potato")
	await _tap("add_carrot")
	await _tap("add_water")
	# Save during a visual one-shot, rebuild only this test's Main, and verify
	# that the committed water step restores without replaying or re-submitting.
	var before_save: Dictionary = app.cooking_session.to_dict().duplicate(true)
	_key(KEY_S)
	await _frame()
	_free_main()
	await create_timer(0.12, true, false, true).timeout
	_new_main()
	await _frame()
	_check(app.cooking_session != null and app.cooking_session.to_dict() == before_save, "rebuild restores committed water state exactly")
	_check(not bool(app.cooking_view.animation_debug_state().playing) and app.cooking_session.water_added, "rebuild does not replay saved one-shot or submit again")
	await _tap("cut")
	await _tap("pot")
	await _tap("heat_medium")
	var soup_before: Dictionary = app.cooking_session.to_dict().duplicate(true)
	await create_timer(1.38, true, false, true).timeout
	await _frame()
	var soup_visual: Dictionary = app.cooking_view.animation_debug_state()
	_check(soup_visual.clip == "stir" and soup_visual.loop and soup_visual.playing, "only cooking soup loops the soup stir clip")
	_check(app.cooking_session.ingredients == soup_before.ingredients and not app.cooking_session.completed, "multiple soup loop periods add no ingredients and complete no order")
	_capture("soup_loop")
	# Reach the ready window independently before the existing overcook case:
	# the visual loop must end as soon as cooking becomes ready.
	app.cooking_session.tick(maxf(0.0, app.cooking_session.cook_duration() - app.cooking_session.elapsed))
	app._refresh()
	await _frame()
	_check(app.cooking_session.phase == "ready" and not bool(app.cooking_view.animation_debug_state().playing), "ready exits soup loop back to static cookware")
	app.cooking_session.tick(100.0)
	app._refresh()
	await _frame()
	_check(app.cooking_session.phase == "retry" and not bool(app.cooking_view.animation_debug_state().playing), "ready/retry exits soup loop back to static cookware")


func _test_stir_fry() -> void:
	_check(app.cooking_session.recipe_id == "stir_fry", "stir-fry fixture is bound")
	await _tap("add_egg")
	await _tap("add_tomato")
	await _tap("cut")
	await _frame()
	_check(not bool(app.cooking_view.animation_debug_state().playing) and not app.cooking_view.utensil_image.texture is AtlasTexture, "tomato cut never reuses the potato-carrot chop artwork")
	await _tap("pan")
	await _tap("heat_medium")
	var fry_before: Dictionary = app.cooking_session.to_dict().duplicate(true)
	await create_timer(1.38, true, false, true).timeout
	await _frame()
	var fry_visual: Dictionary = app.cooking_view.animation_debug_state()
	_check(fry_visual.clip == "stir_fry" and fry_visual.loop and fry_visual.playing, "only cooking stir-fry loops the stir-fry clip")
	_check(app.cooking_session.ingredients == fry_before.ingredients and not app.cooking_session.completed, "multiple stir-fry loops do not change the session")
	_capture("stir_fry_loop")
	# Clear while the loop is live.  It must remove transient frames and the
	# short action lock so a newly selected ingredient is clickable immediately.
	await _tap("clear")
	var egg_button := _button("add_egg")
	_check(app.cooking_session.phase == "ingredients" and not bool(app.cooking_view.animation_debug_state().playing) and egg_button != null and not egg_button.disabled, "reselect clears stir-fry loop and its short action lock")


func _test_bake_static() -> void:
	_check(app.cooking_session.recipe_id == "bake", "bake fixture is bound")
	await _tap("add_bread")
	await _tap("add_cheese")
	await _tap("oven")
	await _frame()
	_check(_has_static_p0_layer("/utensils/oven"), "oven keeps its supplied static state")
	_capture("oven_static")


func _test_drink_static() -> void:
	_check(app.cooking_session.recipe_id == "drink", "drink fixture is bound")
	await _tap("add_coffee")
	await _tap("add_milk")
	await _tap("add_ice")
	await _frame()
	_check(_has_static_p0_layer("/utensils/cup"), "iced latte never shows a soup pot or animation atlas")
	_capture("drink_static")


func _has_static_p0_layer(path_fragment: String) -> bool:
	for layer: TextureRect in app.cooking_view._art_layers:
		var texture: Texture2D = layer.texture
		if layer.visible and texture != null and not texture is AtlasTexture and texture.resource_path.contains(path_fragment):
			return true
	return false


func _button(action: String) -> Button:
	if action == "pause": return app.cooking_view.pause_button
	if action == "cancel": return app.cooking_view.cancel_button
	return app.cooking_view.button_for_action(action)


func _wait_action(action: String) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	var button := _button(action)
	while not done and (button == null or button.disabled or not button.is_visible_in_tree()) and Time.get_ticks_msec() < deadline:
		await _frame()
		button = _button(action)


func _tap(action: String) -> void:
	await _wait_action(action)
	var button := _button(action)
	_check(button != null and button.is_visible_in_tree() and not button.disabled, "real control becomes clickable: " + action)
	if action not in ["pause", "cancel", "clear"]:
		_check(_button_has_image(button), "real icon-only action has a visible image: " + action)
	if button == null or button.disabled:
		_finish()
		return
	_click(button.get_global_rect().get_center())
	await _frame()


func _button_has_image(button: Button) -> bool:
	if button == null: return false
	for child: Node in button.get_children():
		if child is TextureRect and (child as TextureRect).texture != null:
			return true
	return false


func _sample_regions(expected_clip: String, delay: float) -> Array[Rect2]:
	var result: Array[Rect2] = []
	await _frame()
	var first: Dictionary = app.cooking_view.animation_debug_state()
	_check(first.clip == expected_clip and first.playing, expected_clip + " starts as a real visual player")
	result.append(Rect2(first.region))
	await create_timer(delay, true, false, true).timeout
	await _frame()
	var second: Dictionary = app.cooking_view.animation_debug_state()
	if second.clip == expected_clip and second.playing:
		result.append(Rect2(second.region))
	return result


func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)


func _key(keycode: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.pressed = down
		root.push_input(event, true)


func _frame() -> void:
	await process_frame
	if done: return
	await RenderingServer.frame_post_draw
	if done: return
	frames += 1
	_check(app != null and app.model.validate_invariants().is_empty(), "live kitchen model invariants")
	if failures > 0: _finish()


func _capture(name: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://verification"))
	_check(error == OK or error == ERR_ALREADY_EXISTS, "verification directory exists")
	var image := root.get_texture().get_image()
	var target := "res://verification/cooking_animation_" + name + ".png"
	_check(image != null and not image.is_empty() and image.save_png(target) == OK, "actual GUI screenshot " + target)
	print("COOKING_ANIMATION_UI_CAPTURE " + ProjectSettings.globalize_path(target))


func _timeout() -> void:
	if not done:
		_check(false, "total GUI timeout")
		_finish()


func _finish() -> void:
	if done: return
	done = true
	_free_main()
	Engine.time_scale = prior_scale
	await create_timer(0.15, true, false, true).timeout
	for path: String in private_paths:
		for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
			if FileAccess.file_exists(path + suffix):
				_check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix)) == OK, "private slot cleanup " + suffix)
	print("COOKING_ANIMATION_UI_RESULT assertions=%d failures=%d frames=%d wall_ms=%d" % [checks, failures, frames, Time.get_ticks_msec() - started])
	quit(0 if failures == 0 else 1)
