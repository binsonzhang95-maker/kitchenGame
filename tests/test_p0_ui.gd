extends SceneTree
## Isolated real-window smoke for P0 art, language and runtime menu policy.
const Main = preload("res://multi_main.gd")
var app: Variant
var save_path := ""
var failures := 0
var done := false
var watchdog: SceneTreeTimer
func _check(ok: bool, what: String) -> void:
	if not ok: failures += 1; push_error("P0_UI_FAIL " + what)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if DisplayServer.get_name() == "headless": _check(false, "requires a real graphical window"); _finish(); return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	watchdog = create_timer(90.0, true, false, true)
	watchdog.timeout.connect(func() -> void: _check(false, "total wall-clock watchdog expired"); _finish())
	save_path = "user://p0_ui_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	app = Main.new(); app.save_path = save_path; app.seed_guests = false; app.player_mode = true; app.interactive_cooking = true
	root.add_child(app); await process_frame
	app.model.open_for_arrivals = false; app.model.auto_seat = false; app.model.auto_dispatch = false
	for index in range(4):
		var expected: String = ["pumpkin_corn_soup", "pan_fried_mushrooms", "bake", "drink"][index]
		# Keep the first two on the public P0 rotation; deterministic single-item
		# menus then target the two legacy/new visual paths without touching orders already seated.
		if index >= 2: app.model.set_order_menu([expected])
		if index == 0: app.set_locale("en")
		await _open(index + 1)
		if done: return
		_check(app.cooking_session.recipe_id == expected, "P0 guest has " + expected)
		_capture("kitchen_standby_" + expected)
		if index == 0:
			await process_frame; await RenderingServer.frame_post_draw
			_check(app.cooking_session.recipe_id == expected and app.cooking_view.recipe_label.text.contains("Pumpkin"), "English switches without changing session")
			_capture("kitchen_en")
			app.set_menu_kind("classic"); _check(app.cooking_session.recipe_id == expected, "menu change leaves active order intact")
			app.set_menu_kind("p0"); app.set_locale("zh_CN")
			await _tap("add_pumpkin"); await _tap("add_corn"); await _tap("add_water")
			_check(app.cooking_view.water_flow.visible and app.cooking_view.water_flow.texture != null and app.cooking_view.water_icon.texture.resource_path.contains("tap_open"), "pumpkin soup uses the independent faucet flow")
			await _tap("clear")
			_check(app.cooking_session.ingredients.is_empty(), "reselect clears P0 ingredients")
			await _tap("add_pumpkin"); await _tap("pause"); _check(app.cooking_session.paused, "pause stops P0 session"); await _tap("cancel")
			_check(app.cooking_session == null, "cancel removes P0 visual layers")
			_check(app._begin_cooking(index + 1), "resume cancelled P0 order")
			await process_frame
		await _finish_recipe(expected)
	app.set_locale("en"); app.cooking_view.visible = false; app.hud.settings_root.visible = true
	await process_frame; await process_frame; await RenderingServer.frame_post_draw; _capture("settings_en")
	_finish()
func _open(table_id: int) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while app.model.spawn_customer() <= 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if Time.get_ticks_msec() >= deadline:
		_check(false, "customer spawn deadline")
		return
	var target := table_id
	for table: Dictionary in app.model.tables:
		if table.phase == "free": target = int(table.id); break
	_check(app.model.assign_next(target), "assign table %d" % target)
	while app.model.table_action(target) != "order" and Time.get_ticks_msec() < deadline:
		app.model.tick(0.1)
		await process_frame
	if app.model.table_action(target) != "order":
		_check(false, "order readiness deadline")
		return
	if table_id == 1:
		app.selected_table = target; app.hud.select_table(); app._refresh(); await process_frame; _capture("order")
	_check(app.model.act(target, "order") and app._begin_cooking(target), "open kitchen %d" % target)
	await process_frame
func _button(action: String) -> Button:
	if action == "clear": return app.cooking_view.clear_button
	if action == "cancel": return app.cooking_view.cancel_button
	if action == "pause": return app.cooking_view.pause_button
	if action == "add_water": return app.cooking_view.water_button
	for slot: Dictionary in app.cooking_view.ingredient_slots:
		if slot.action == action: return slot.button
	return app.cooking_view.action_buttons.get(action)
func _tap(action: String) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	var button := _button(action)
	while button != null and (button.disabled or not button.is_visible_in_tree()) and Time.get_ticks_msec() < deadline:
		await process_frame; button = _button(action)
	_check(button != null and not button.disabled, "real P0 button " + action)
	if button == null or button.disabled: return
	if action not in ["pause", "cancel", "clear"]:
		_check(_button_has_image(button), "P0 icon-only action has an image: " + action)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new(); event.position = button.get_global_rect().get_center(); event.global_position = event.position; event.button_index = MOUSE_BUTTON_LEFT; event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0; event.pressed = down; root.push_input(event, true)
	await process_frame

func _button_has_image(button: Button) -> bool:
	for child: Node in button.get_children():
		if child is TextureRect and (child as TextureRect).texture != null: return true
	return false
func _finish_recipe(recipe: String) -> void:
	var actions: Array = {"pumpkin_corn_soup":["add_pumpkin","add_corn","add_water","cut","pot","heat_medium","finish"], "pan_fried_mushrooms":["add_mushroom","pan","heat_medium","flip"], "bake":["add_bread","add_cheese","oven","takeout"], "drink":["add_coffee","add_milk","add_ice","stir"]}[recipe]
	for action_value: Variant in actions:
		var action := str(action_value)
		await _tap(action)
		if action.begins_with("heat_") or action == "oven":
			_capture(recipe + "_cooking")
			var deadline := Time.get_ticks_msec() + 12000
			while app.cooking_session != null and app.cooking_session.phase == "cooking" and Time.get_ticks_msec() < deadline:
				await process_frame
			_check(app.cooking_session != null and app.cooking_session.phase == "ready", recipe + " reaches ready before capture")
			if app.cooking_session == null or app.cooking_session.phase != "ready": return
			_capture(recipe)
		elif action == "add_ice" and recipe == "drink":
			_check(app.cooking_session != null and app.cooking_session.phase == "ready", "latte reaches ready before capture")
			_capture(recipe)
	_check(app.cooking_session == null, "completed " + recipe)
func _capture(name: String) -> void:
	var dir := ProjectSettings.globalize_path("res://verification")
	DirAccess.make_dir_recursive_absolute(dir)
	var image := root.get_texture().get_image()
	_check(image != null and image.save_png("res://verification/p0_" + name + ".png") == OK, "capture " + name)
func _finish() -> void:
	if done: return
	done = true
	if is_instance_valid(app): app.free()
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path + suffix))
	print("P0_UI_RESULT failures=%d" % failures)
	quit(0 if failures == 0 else 1)
