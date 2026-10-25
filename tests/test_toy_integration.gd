extends SceneTree
## Real Main/UI acceptance for the local toy bridge.
## Run with a window and `-- --toy-simulator`; this never touches a player save.
const Main = preload("res://multi_main.gd")

var app: Variant
var save_path := ""
var checks := 0
var failures: Array[String] = []
var done := false
var watchdog: SceneTreeTimer

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error("TOY_MAIN_FAIL " + message)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "requires a graphical renderer")
		_finish()
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	watchdog = create_timer(90.0, true, false, true)
	watchdog.timeout.connect(func() -> void: _check(false, "total watchdog expired"); _finish())
	save_path = "user://toy_main_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	app = Main.new()
	app.save_path = save_path
	app.seed_guests = false
	app.player_mode = true
	app.interactive_cooking = true
	app.menu_kind = "p0"
	root.add_child(app)
	await process_frame
	# The actual command-line flag is exercised by CI; retain a local fallback so
	# an editor invocation still executes this Main integration.
	app.toy_simulator_enabled = true
	app.model.open_for_arrivals = false
	app.model.auto_seat = false
	app.model.auto_dispatch = false
	_check(app.save_path != Main.SAVE_PATH, "private save path is selected")
	_check(app.save_allowed, "private save starts writable")

	await _open_order("pumpkin_corn_soup")
	if done: return
	_check(app.cooking_view.visible and app.cooking_session != null, "real primary button opens kitchen")
	_key(KEY_F3)
	await process_frame
	_check(app.toy_simulator.is_open() and not app.cooking_view.is_processing_input(), "F3 opens simulator and shields kitchen Escape")
	_key(KEY_ESCAPE)
	await process_frame
	_check(not app.toy_simulator.is_open() and app.cooking_session != null and app.cooking_view.is_processing_input(), "Escape closes simulator before it cancels cooking")

	# A full event must arrive with all authority fields and a snapshot only aligns.
	app._toy_command("connect")
	var snapshot := _event("panel_snapshot", _snapshot())
	var aligned: Dictionary = app.receive_toy_event(snapshot)
	_check(aligned.feedback == "aligned" and not bool(aligned.committed), "complete snapshot aligns without an action")
	var no_fields: Dictionary = app.receive_toy_event({"type":"card", "category":"pumpkin", "zone":"cutting_board"})
	_check(no_fields.feedback == "invalid_event" and not bool(no_fields.committed), "incomplete full event is not repaired")

	# Cancel invalidates a captured old token; reopening must receive a new one.
	var before_cancel: Dictionary = _event("card", {"category":"pumpkin", "zone":"cutting_board"})
	await _tap("cancel")
	_check(app.cooking_session == null, "real cancel closes kitchen")
	await _open_existing_order()
	var sounds := _step_count()
	var old_token: Dictionary = app.receive_toy_event(before_cancel)
	_check(old_token.feedback == "stale" and _step_count() == sounds, "cancelled token cannot affect next order or success sound")

	# Reconnect requires fresh connection authority; a complete old event is stale.
	app._toy_command("connect")
	_check(app.receive_toy_event(_event("panel_snapshot", _snapshot())).feedback == "aligned", "new simulator aligns")
	var old_connection: Dictionary = _event("card", {"category":"pumpkin", "zone":"cutting_board"})
	app._toy_command("disconnect")
	app._toy_command("connect")
	_check(app.receive_toy_event(_event("panel_snapshot", _snapshot())).feedback == "aligned", "reconnection aligns again")
	sounds = _step_count()
	var stale_connection: Dictionary = app.receive_toy_event(old_connection)
	_check(stale_connection.feedback == "stale" and _step_count() == sounds, "old connection event is rejected silently")

	# First committed card, then a clear proves that the prior preparation epoch
	# cannot be replayed. Model rejection must roll the local Session back too.
	_check(bool(app.receive_toy_event(_event("card", {"category":"pumpkin", "zone":"cutting_board"})).committed), "candidate commits through Main")
	var stale_epoch: Dictionary = _event("card", {"category":"corn", "zone":"cutting_board"})
	await _tap("clear")
	sounds = _step_count()
	var old_epoch: Dictionary = app.receive_toy_event(stale_epoch)
	_check(old_epoch.feedback == "stale" and _step_count() == sounds, "clear invalidates old preparation authority")
	_check(bool(app.receive_toy_event(_event("card", {"category":"pumpkin", "zone":"cutting_board"})).committed), "post-clear event commits")
	var local_before: Dictionary = app.cooking_session.to_dict()
	var model_token: int = app.model.cooking_session_token
	app.model.cooking_session_token += 100
	sounds = _step_count()
	var rejected: Dictionary = app.receive_toy_event(_event("card", {"category":"corn", "zone":"cutting_board"}))
	_check(not bool(rejected.committed) and rejected.feedback == "commit_rejected" and app.cooking_session.to_dict() == local_before and _step_count() == sounds, "sync rejection rolls back without success feedback")
	app.model.cooking_session_token = model_token
	_check(bool(app.receive_toy_event(_event("card", {"category":"corn", "zone":"cutting_board"})).committed), "model restored accepts next event")
	_check(bool(app.receive_toy_event(_event("faucet", {"open":true})).committed), "water commits through Main")
	_check(bool(app.receive_toy_event(_event("cut")).committed), "cut commits through Main")
	_check(bool(app.receive_toy_event(_event("vessel", {"kind":"pot", "present":true})).committed), "vessel commits through Main")
	_check(bool(app.receive_toy_event(_event("stove", {"level":"medium"})).committed), "heat commits through Main")

	# A disconnection freezes both cooking and ready. Screen input resumes timer;
	# manual pause survives the source switch and remains separate from that hold.
	app._toy_command("disconnect")
	var frozen_elapsed: float = app.cooking_session.elapsed
	await _wait_seconds(0.20)
	_check(is_equal_approx(app.cooking_session.elapsed, frozen_elapsed), "disconnect freezes cooking timer")
	app._toy_command("screen")
	await _wait_until_phase("ready", 7000)
	_check(app.cooking_session != null and app.cooking_session.phase == "ready", "screen source resumes cooking timer")
	app._toy_command("connect")
	_check(app.receive_toy_event(_event("panel_snapshot", {"stove_level":"medium", "oven_level":"off", "oven_open":false, "vessel":"pot", "faucet_open":false})).feedback == "aligned", "ready simulator aligns")
	app._toy_command("disconnect")
	frozen_elapsed = app.cooking_session.elapsed
	await _wait_seconds(0.30)
	_check(app.cooking_session.phase == "ready" and is_equal_approx(app.cooking_session.elapsed, frozen_elapsed), "disconnect freezes ready timer too")
	app._toy_command("screen")
	await _tap("pause")
	_check(app.cooking_session.paused, "manual pause is active")
	app._toy_command("connect")
	app._toy_command("screen")
	await _wait_seconds(0.10)
	_check(app.cooking_session.paused, "manual pause survives screen switches")
	await _tap("pause")

	# The final complete_cooking rejection restores ready and has no dish sound.
	var dish_before := _dish_count()
	model_token = app.model.cooking_session_token
	app.model.cooking_session_token += 100
	await _tap("finish")
	_check(app.cooking_session != null and app.cooking_session.phase == "ready" and _dish_count() == dish_before, "completion rejection restores ready without dish success")
	app.model.cooking_session_token = model_token
	await _tap("finish")
	_check(app.cooking_session == null and _dish_count() == dish_before + 1, "pumpkin dish completes once")
	await _settle_frames(6)
	_check(_dish_count() == dish_before + 1 and _food_tasks() == 1, "post-completion frames do not duplicate food or dish sound")

	# Starting the next real order must also clear a still-visible completion card.
	app._show_completion_brief("drink")
	await _open_order("pan_fried_mushrooms")
	_check(not app.completion_card.visible and app.completion_tween == null, "new order clears prior completion feedback")
	await _finish_recipe("pan_fried_mushrooms")
	_check(app.cooking_session == null, "pan_fried_mushrooms returns from kitchen")
	await _settle_frames(4)

	# Complete each remaining P0 recipe through real kitchen buttons exactly once.
	for recipe: String in ["bake", "drink"]:
		await _open_order(recipe)
		await _finish_recipe(recipe)
		_check(app.cooking_session == null, recipe + " returns from kitchen")
		await _settle_frames(4)
	_check(_dish_count() == dish_before + 4, "four P0 final actions emitted exactly four dish sounds")

	# Completion feedback must keep legacy dishes neutral and only show matching
	# P0 art, without leaving a tween or card behind when the next order begins.
	for legacy_recipe: String in ["soup", "stir_fry"]:
		app._show_completion_brief(legacy_recipe)
		_check(app.completion_dish.texture == null, legacy_recipe + " completion does not borrow P0 dish art")
	var completion_assets := P0Assets.new()
	for p0_recipe: String in ["pumpkin_corn_soup", "pan_fried_mushrooms", "bake", "drink"]:
		app._show_completion_brief(p0_recipe)
		var asset_key := str({"pumpkin_corn_soup":"dish_pumpkin_corn_soup", "pan_fried_mushrooms":"dish_pan_fried_mushrooms", "bake":"dish_bake", "drink":"dish_drink"}[p0_recipe])
		_check(app.completion_dish.texture == completion_assets.texture(asset_key), p0_recipe + " completion uses matching P0 dish art")
	app.set_locale("zh_CN")
	app._show_completion_brief("pumpkin_corn_soup")
	var completion_label := app.completion_card.get_node("CompletionRecipe") as Label
	_check(app.completion_card.theme == Localization.theme("zh_CN") and completion_label.get_theme_font("font") != null, "Chinese completion card has embedded locale theme and font")
	app.set_locale("en")
	app._show_completion_brief("pumpkin_corn_soup")
	_check(app.completion_card.theme == Localization.theme("en") and completion_label.get_theme_font("font") != null, "English completion card refreshes locale theme and font")
	await _wait_seconds(0.50)
	_check(not app.completion_card.visible and app.completion_tween == null, "completion feedback naturally clears its card and tween")
	app.set_locale("zh_CN")
	_check(app.model.validate_invariants().is_empty(), "Main model invariants remain valid")
	_finish()

func _snapshot() -> Dictionary:
	return {"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false}

func _event(type: String, body: Dictionary = {}) -> Dictionary:
	var value: Dictionary = app.input_adapter.event_envelope()
	value["type"] = type
	for key: String in body: value[key] = body[key]
	return value

func _open_order(recipe: String) -> void:
	app.model.set_order_menu([recipe])
	var table_id := 0
	for table: Dictionary in app.model.tables:
		if table.phase == "free": table_id = int(table.id); break
	_check(table_id > 0, "free table for " + recipe)
	if table_id == 0: return
	_check(app.model.spawn_customer() > 0 and app.model.assign_next(table_id), "seed order table for " + recipe)
	var deadline := Time.get_ticks_msec() + 3000
	while app.model.table_action(table_id) != "order" and Time.get_ticks_msec() < deadline:
		app.model.tick(0.1)
		await process_frame
	_check(app.model.table_action(table_id) == "order", "order is ready for " + recipe)
	app.selected_table = table_id
	app.hud.select_table()
	app._refresh()
	await _wait_cooldown()
	_click(app.primary.get_global_rect().get_center())
	await process_frame

func _open_existing_order() -> void:
	var table_id := 0
	for table: Dictionary in app.model.tables:
		if table.phase == "awaiting_cook": table_id = int(table.id); break
	_check(table_id > 0, "cancelled order remains available")
	if table_id == 0: return
	app.selected_table = table_id
	app.hud.select_table()
	app._refresh()
	await _wait_cooldown()
	_click(app.primary.get_global_rect().get_center())
	await process_frame
	_check(app.cooking_session != null, "existing order reopens through primary button")

func _finish_recipe(recipe: String) -> void:
	var actions: Array = {
		"pan_fried_mushrooms":["add_mushroom", "pan", "heat_medium", "flip"],
		"bake":["add_bread", "add_cheese", "oven", "takeout"],
		"drink":["add_coffee", "add_milk", "add_ice", "stir"],
	}[recipe]
	for action: String in actions:
		await _tap(action)
		if action in ["heat_medium", "oven"]: await _wait_until_phase("ready", 9000)

func _button(action: String) -> Button:
	if action == "cancel": return app.cooking_view.cancel_button
	if action == "pause": return app.cooking_view.pause_button
	return app.cooking_view.button_for_action(action)

func _tap(action: String) -> void:
	await _wait_cooldown()
	var deadline := Time.get_ticks_msec() + 3000
	var button := _button(action)
	while button != null and (button.disabled or not button.is_visible_in_tree()) and Time.get_ticks_msec() < deadline:
		await process_frame
		button = _button(action)
	_check(button != null and not button.disabled and button.is_visible_in_tree(), "real kitchen button " + action)
	if button != null and not button.disabled: _click(button.get_global_rect().get_center())
	await process_frame

func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event, true)

func _wait_cooldown() -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while app != null and app.cooldown > 0.0 and Time.get_ticks_msec() < deadline:
		await process_frame

func _wait_until_phase(phase: String, limit_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + limit_ms
	while app.cooking_session != null and app.cooking_session.phase != phase and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(app.cooking_session != null and app.cooking_session.phase == phase, "bounded wait reaches " + phase)

func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds, true, false, true).timeout

func _settle_frames(count: int) -> void:
	for index in count: await process_frame

func _step_count() -> int:
	return int(app.sfx.get_debug_state().get("play_counts", {}).get("step_complete", 0))

func _dish_count() -> int:
	return int(app.sfx.get_debug_state().get("play_counts", {}).get("dish_complete", 0))

func _food_tasks() -> int:
	var count := 0
	for task: Dictionary in app.model.tasks:
		if task.kind == "food": count += 1
	return count

func _finish() -> void:
	if done: return
	done = true
	if is_instance_valid(app): app.free()
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix): DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path + suffix))
	if failures.is_empty(): print("PASS: Toy Main integration (%d checks)" % checks)
	else:
		for failure: String in failures: printerr("TOY_MAIN_FAIL: " + failure)
		print("FAIL: Toy Main integration (%d failures, %d checks)" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
