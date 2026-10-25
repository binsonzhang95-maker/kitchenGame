extends SceneTree
## Actual GUI inputs only; this process owns its private save, audio, and window.
const Main = preload("res://multi_main.gd")
const Support = preload("res://tests/multi_test_support.gd")
var app: Variant
var path: String = ""
var owned: bool = false
var done: bool = false
var checks: int = 0
var failures: int = 0
var frames: int = 0
var started: int = 0
var old_scale: float = 1.0
var frozen: Dictionary = {}
var completed: Dictionary = {}
var phases: Dictionary = {}

func _initialize() -> void:
	started = Time.get_ticks_msec()
	old_scale = Engine.time_scale
	call_deferred("_run")

func _check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("COOKING_GUI_FAIL " + description)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "graphical renderer required")
		_finish()
		return
	root.title = "动物餐厅 · 隔离做菜测试（静音）"
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	create_timer(150.0, true, false, true).timeout.connect(_timeout)
	path = "user://cooking_ui_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		_check(not FileAccess.file_exists(path + suffix), "fresh private slot " + suffix)
	_check(path != Main.SAVE_PATH, "normal save is never selected")
	if failures > 0:
		_finish()
		return
	owned = true
	Engine.time_scale = 10.0
	_new_main()
	for recipe: String in ["soup", "stir_fry", "bake", "drink"]:
		var table_id: int = 0
		while table_id == 0 and not done:
			await _frame()
			if done: return
			for table: Dictionary in app.model.tables:
				if app.model.table_action(int(table.id)) == "order":
					table_id = int(table.id)
					break
		await _open(table_id)
		if done or failures > 0:
			_finish()
			return
		_check(app.cooking_session.recipe_id == recipe, "guest rotation selects " + recipe)
		var guest_id: int = int(app.cooking_session.binding.guest_id)
		if recipe == "soup":
			await _tap("add_potato")
			var selected: Dictionary = app.cooking_session.to_dict().duplicate(true)
			_click(_button("add_potato").get_global_rect().get_center())
			_check(app.cooking_session.to_dict() == selected, "disabled repeated ingredient cannot be added")
			await _tap("add_water")
			_check(app.cooking_session.ingredients.size() == 1 and app.cooking_session.water_added, "water occupies no ingredient slot")
			await _tap("clear")
			_check(app.cooking_session.ingredients.is_empty() and not app.cooking_session.water_added, "clear resets food and water")
			await _tap("add_potato")
			frozen.clear()
			await _tap("cancel")
			_check(app.cooking_session == null and app.model.tables[table_id - 1].phase == "awaiting_cook", "cancel retains unfulfilled order")
			while float(app.cooldown) > 0.0 and not done: await _frame()
			await _open(table_id)
			if done: return
			_check(int(app.cooking_session.binding.guest_id) == guest_id and app.cooking_session.ingredients.is_empty(), "reentry restarts same bound recipe without fulfilling it")
		var ingredients: Array = {"soup":["potato", "carrot", "water"], "stir_fry":["egg", "tomato"], "bake":["bread", "cheese"], "drink":["coffee", "milk", "ice"]}[recipe]
		for ingredient: String in ingredients:
			await _tap("add_" + ingredient)
			if done: return
			_check(app.cooking_session.ingredients.size() <= 3, "ingredient limit maintained")
		if recipe in ["soup", "stir_fry"]: await _tap("cut")
		if recipe != "drink":
			await _tap({"soup":"pot", "stir_fry":"pan", "bake":"oven"}[recipe])
			if recipe == "soup" and not done: _capture("heat")
			if recipe != "bake": await _tap("heat_high")
			if recipe == "bake": await _restore_paused()
			await _until_phase("ready")
		if done: return
		_capture({"stir_fry":"fry"}.get(recipe, recipe))
		if recipe == "soup":
			await _until_phase("retry")
			if done: return
			_check(app.cooking_session.ingredients.size() == 2 and app.cooking_session.water_added and app.cooking_session.cut_done, "overheating retains prepared ingredients for retry")
			_check(not app.model.tables[table_id - 1].food and app.model.coins == 0, "failed cooking delivers no food or income")
			await _tap("retry")
			_check(app.cooking_session.phase == "heat", "retry resumes heat selection")
			await _tap("heat_medium")
			await _until_phase("ready")
		if done: return
		var finish_action: String = {"soup":"finish", "stir_fry":"stir", "bake":"takeout", "drink":"stir"}[recipe]
		var finish_point: Vector2 = _button(finish_action).get_global_rect().get_center()
		frozen.clear()
		await _tap(finish_action)
		_check(app.cooking_session == null and not app.cooking_view.visible, "completion returns to restaurant")
		var accepted: Dictionary = app.model.to_dict().duplicate(true)
		for repeat: int in range(6): _click(finish_point)
		_check(app.model.to_dict() == accepted, "repeated completion clicks cannot duplicate food or payment")
		completed[guest_id] = table_id
		print("COOKING_GUI_RECIPE_OK " + recipe)
	while not done:
		await _frame()
		if done: return
		var all_clean: bool = int(app.model.served) == 4
		for table_id: int in completed.values(): all_clean = all_clean and app.model.tables[table_id - 1].phase == "free"
		if all_clean: break
	_check(app.model.coins == 152 and app.model.served == 4, "four completed recipes automatically yield 152 coins")
	for guest_id: int in completed: _check(app.model.paid_ledger.has(str(guest_id)), "completed guest paid once")
	_check(phases.has("collecting") and phases.has("wiping"), "automatic collection and wiping rendered")
	_check(app.model.open_for_arrivals, "automatic arrivals remain enabled")
	_finish()

func _new_main() -> void:
	app = Main.new()
	app.menu_kind = "classic"
	app.save_path = path
	app.seed_guests = false
	app.player_mode = true
	app.interactive_cooking = true
	root.add_child(app)

func _business() -> Dictionary:
	var data: Dictionary = app.model.to_dict()
	var result: Dictionary = {}
	for key: String in ["clock", "tables", "customers", "workers", "tasks", "coins", "served", "lost", "chef"]: result[key] = data[key]
	return result

func _frame() -> void:
	await process_frame
	if done: return
	await RenderingServer.frame_post_draw
	if done: return
	frames += 1
	_check(app.model.validate_invariants().is_empty(), "live model invariants")
	_check(app.save_allowed and not str(app.save_label.text).contains("保存失败"), "private save healthy")
	if not frozen.is_empty(): _check(Support.same(_business(), frozen), "restaurant freezes throughout cooking")
	for table: Dictionary in app.model.tables: phases[str(table.phase)] = true
	if failures > 0: _finish()

func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

func _open(table_id: int) -> void:
	while not done:
		var table: Dictionary = app.model.tables[table_id - 1]
		var guest: Dictionary = app.model.customers[int(table.guest_id)]
		for point: Vector2 in [Vector2(guest.pos) - Vector2(0, 40), Vector2(table.center), Vector2(table.center) + Vector2(0, 40)]:
			var screen: Vector2 = app.room.get_global_transform_with_canvas() * point
			if app.hud.popup.visible and app.hud.popup.get_global_rect().has_point(screen): continue
			if app.room._table_at_point(point) == table_id:
				_click(screen)
				await _frame()
				if done: return
				_check(app.selected_table == table_id and app.primary.is_visible_in_tree() and not app.primary.disabled, "real guest pointer exposes kitchen entry")
				_click(app.primary.get_global_rect().get_center())
				_check(app.cooking_session != null and app.cooking_view.visible, "real order button opens kitchen")
				if app.cooking_session == null:
					_finish()
					return
				frozen = _business().duplicate(true)
				await _frame()
				return
		await _frame()

func _button(action: String) -> Button:
	if action == "clear": return app.cooking_view.clear_button
	if action == "cancel": return app.cooking_view.cancel_button
	if action == "pause": return app.cooking_view.pause_button
	if action == "add_water": return app.cooking_view.water_button
	for slot: Dictionary in app.cooking_view.ingredient_slots:
		if slot.action == action: return slot.button
	return app.cooking_view.action_buttons.get(action)

func _tap(action: String) -> void:
	if done: return
	var button: Button = _button(action)
	var deadline: int = Time.get_ticks_msec() + 3000
	# The kitchen now has a deliberately short pointer cooldown after a normal
	# step.  Wait for the real button to become clickable; do not bypass it with
	# direct session calls, and keep a bounded failure path for regressions.
	while not done and button != null and (not button.is_visible_in_tree() or button.disabled) and Time.get_ticks_msec() < deadline:
		await _frame()
		button = _button(action)
	_check(button != null and button.is_visible_in_tree() and not button.disabled, "available real kitchen control: " + action)
	if button == null or button.disabled:
		_finish()
		return
	_click(button.get_global_rect().get_center())
	await _frame()

func _until_phase(phase: String) -> void:
	while not done and app.cooking_session.phase != phase: await _frame()

func _restore_paused() -> void:
	await _tap("pause")
	if done: return
	var session: Dictionary = app.cooking_session.to_dict().duplicate(true)
	_check(session.paused and app.cooking_view.pause_overlay.visible, "kitchen pause visible")
	await create_timer(0.2, true, false, true).timeout
	await _frame()
	if done: return
	_check(app.cooking_session.to_dict() == session, "paused preparation timer remains exact")
	var key := InputEventKey.new()
	key.keycode = KEY_S
	key.pressed = true
	root.push_input(key, true)
	key = key.duplicate()
	key.pressed = false
	root.push_input(key, true)
	var saved: Dictionary = app.model.to_dict().duplicate(true)
	_free_main()
	await create_timer(0.75, true, false, true).timeout
	if done: return
	_new_main()
	await _frame()
	if done: return
	_check(app.cooking_session != null and app.cooking_view.visible and app.cooking_session.paused, "new GUI restores paused kitchen")
	_check(Support.same(app.model.to_dict(), saved) and Support.same(app.cooking_session.to_dict(), session), "save restores recipe, ingredients, timer, binding and restaurant")
	await _tap("pause")
	print("COOKING_GUI_PAUSED_RESTORE_OK")

func _capture(name: String) -> void:
	var has_appliance := app.cooking_view.utensil_image.texture != null
	for layer: TextureRect in app.cooking_view._art_layers:
		has_appliance = has_appliance or layer.visible and layer.texture != null
	_check((app.cooking_view.art_status().required_missing as Dictionary).is_empty() and has_appliance, "supplied kitchen artwork loaded")
	_check(app.cooking_view.utensil_image.size == Vector2(512, 512) and app.cooking_session.ingredients.size() >= 2 and not app.cooking_view.action_buttons.is_empty(), "capture shows ingredients, large appliance, and current operation")
	var error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://verification"))
	_check(error == OK or error == ERR_ALREADY_EXISTS, "capture directory available")
	var image: Image = root.get_texture().get_image()
	var target: String = "res://verification/cooking_" + name + ".png"
	_check(image != null and not image.is_empty() and image.save_png(target) == OK, "actual GUI capture " + target)
	print("COOKING_GUI_CAPTURE " + ProjectSettings.globalize_path(target))

func _free_main() -> void:
	if not is_instance_valid(app): return
	app.set_process(false)
	var music: Node = app.music
	app.free()
	app = null
	if is_instance_valid(music): music.free()

func _timeout() -> void:
	if not done:
		_check(false, "real-time watchdog expired")
		_finish()

func _finish() -> void:
	if done: return
	done = true
	_free_main()
	Engine.time_scale = old_scale
	await create_timer(0.75, true, false, true).timeout
	if owned:
		for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
			if FileAccess.file_exists(path + suffix): _check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix)) == OK, "private slot cleanup")
	print("COOKING_GUI_RESULT assertions=%d failures=%d frames=%d wall_ms=%d" % [checks, failures, frames, Time.get_ticks_msec() - started])
	quit(0 if failures == 0 else 1)
