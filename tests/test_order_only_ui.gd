extends SceneTree
## Isolated, graphical acceptance test. Only real order/pause/settings/save inputs.
## The normal save and any already-running game process are never accessed.
const Main = preload("res://multi_main.gd")
const Model = preload("res://multi_model.gd")
const TARGET_SERVED: int = 34
const WATCHDOG_SECONDS: float = 180.0
const CAPTURE_PATH: String = "res://verification/order_only_gameplay.png"

var app: Variant
var own_save_path: String = ""
var owns_slot: bool = false
var finished: bool = false
var assertions: int = 0
var failures: int = 0
var frames: int = 0
var started_ms: int = 0
var previous_time_scale: float = 1.0
var orders: Dictionary = {}
var tables_seen: Dictionary = {}
var species_seen: Dictionary = {}
var phases_seen: Dictionary = {}
var worker_seen: Dictionary = {}
var bubble_seen: bool = false
var captured: bool = false
var restored: bool = false
var last_served: int = -1


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	previous_time_scale = Engine.time_scale
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("ORDER_ONLY_GUI_FAIL " + description)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_expect(false, "actual graphical renderer required")
		_finish()
		return
	root.title = "动物餐厅 · 隔离点单测试（静音）"
	# AudioServer is local to this test process. Do not persist this test mute.
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	create_timer(WATCHDOG_SECONDS, true, false, true).timeout.connect(_watchdog)
	own_save_path = "user://order_only_ui_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	_expect(own_save_path != Main.SAVE_PATH, "private slot differs from normal save")
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		_expect(not FileAccess.file_exists(own_save_path + suffix), "new private slot: " + suffix)
	if failures > 0:
		_finish()
		return
	owns_slot = true
	Engine.time_scale = 12.0
	_new_main()
	_expect(app.model.customers.is_empty() and app.model.served == 0, "no seed guests or existing progress")
	await _frame()
	await _frame()
	if finished: return
	_expect(app.player_mode and app.model.player_mode, "production player mode active")
	_expect(app.dialogues.enabled and not app.bubble_layer.show_short_text, "animated expressions default on without words")
	_expect(app.music.available and app.music.player.playing, "private instance BGM loads and plays under process mute")
	_expect(not app.hud.debug_root.visible and not app.hud.settings_root.visible, "normal game hides developer controls")
	await _check_settings()
	if finished or failures > 0:
		_finish()
		return
	# Automatic arrivals/seating run normally; withhold the sole player action.
	while _next_order() == 0 and not finished:
		await _frame()
		if not finished: _observe()
	if finished: return
	var unconfirmed_id: int = _next_order()
	var waiting_since: float = float(app.model.clock)
	while float(app.model.clock) - waiting_since < 5.0 and not finished:
		await _frame()
		if finished: return
		_observe()
		_expect(app.model.coins == 0 and app.model.served == 0, "unconfirmed guests produce no revenue")
		_expect(int(app.model.chef.table_id) == -1 and app.model.tasks.is_empty(), "unconfirmed guests produce no cooking or delivery")
		for table: Dictionary in app.model.tables:
			_expect(table.phase in ["free", "reserved", "ordering"], "no automatic order: " + str(table.phase))
	_expect(app.model.table_action(unconfirmed_id) == "order", "first guest still awaits confirmation after five simulation seconds")
	print("ORDER_ONLY_GUI_MANUAL_ORDER_GATE_OK sim=%.2f" % float(app.model.clock))
	while not finished:
		await _frame()
		if finished: return
		_observe()
		if failures > 0:
			_finish()
			return
		if not restored and orders.size() >= 3 and _processing():
			await _check_restore()
			continue
		if int(app.model.served) >= TARGET_SERVED and captured and restored:
			_check_final()
			_finish()
			return
		if float(app.cooldown) <= 0.0:
			var table_id: int = _next_order()
			if table_id > 0:
				await _confirm_order(table_id)


func _new_main() -> void:
	app = Main.new()
	# Inject before _ready: never load the normal slot, even on restore.
	app.save_path = own_save_path
	app.seed_guests = false
	app.player_mode = true
	app.interactive_cooking = false # This test covers the order-only (auto-cook) mode.
	root.add_child(app)


func _frame() -> void:
	await process_frame
	if finished: return
	await RenderingServer.frame_post_draw
	if not finished: frames += 1


func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		root.push_input(event, true)


func _check_settings() -> void:
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(app.model.paused, "real pause button works")
	var frozen: Dictionary = app.model.to_dict().duplicate(true)
	_click(app.hud.settings_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(app.hud.settings_root.visible, "real settings button opens settings")
	for control: Button in [app.hud.invite_button, app.hud.pay_button, app.next_cook_button, app.hud.debug_order_button, app.hud.debug_dispatch_button, app.arrival_button, app.seat_button, app.dispatch_button, app.auto_cook_button]:
		_expect(not control.is_visible_in_tree() and control.disabled, "manual/automation control hidden and locked: " + control.text)
	_expect(not _settings_has_automation(app.hud.settings_root), "ordinary settings expose no automation switches or manual service")
	var music_id: int = app.music.get_instance_id()
	_click(app.music_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(not app.music.enabled and app.music.player.stream_paused, "settings music switch works")
	_click(app.music_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(app.music.enabled and app.music.get_instance_id() == music_id, "music switch reuses one player")
	_expect(app.model.to_dict() == frozen, "settings leave paused economic state unchanged")
	_expect(FileAccess.file_exists(own_save_path + ".audio.json"), "audio settings use only private slot")
	_click(Vector2(20, 100))
	await _frame()
	if finished: return
	_expect(not app.hud.settings_root.visible, "settings backdrop closes overlay")
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(not app.model.paused and not app.music.player.stream_paused, "real pause button resumes simulation and music")


func _settings_has_automation(node: Node) -> bool:
	if node is Button:
		for forbidden: String in ["自动迎客", "自动分桌", "自动派工", "自动做饭", "迎客", "收钱", "做饭", "派出服务员", "批量点单", "收拾"]:
			if str(node.text).contains(forbidden): return true
	for child: Node in node.get_children():
		if _settings_has_automation(child): return true
	return false


func _next_order() -> int:
	var selected: int = 0
	var oldest: float = -1.0
	for table: Dictionary in app.model.tables:
		if app.model.table_action(int(table.id)) == "order" and float(table.elapsed) > oldest:
			selected = int(table.id)
			oldest = float(table.elapsed)
	return selected


func _confirm_order(table_id: int) -> void:
	var table: Dictionary = app.model.tables[table_id - 1]
	var guest: Dictionary = app.model.customers[int(table.guest_id)]
	# Pick a currently exposed body/table point; walking guests and expression
	# bubbles intentionally reject clicks. Selection itself still uses real input.
	var point := Vector2(-1, -1)
	var candidates: Array[Vector2] = [Vector2(guest.pos) - Vector2(0, 40), Vector2(table.center), Vector2(table.center) + Vector2(0, 40), Vector2(guest.pos) + Vector2(-24, -40), Vector2(guest.pos) + Vector2(24, -40)]
	for local_point: Vector2 in candidates:
		var screen_point: Vector2 = app.room.get_global_transform_with_canvas() * local_point
		if app.hud.popup.visible and app.hud.popup.get_global_rect().has_point(screen_point): continue
		if int(app.room._table_at_point(local_point)) == table_id:
			point = screen_point
			break
	if point.x < 0.0: return
	_click(point)
	await _frame()
	if finished: return
	_expect(int(app.selected_table) == table_id and app.hud._selection_open, "real customer pointer selects table %d" % table_id)
	_expect(app.hud.popup.visible and app.hud.demand_row.visible, "waiting order popup displays meal and drink")
	_expect(app.primary.is_visible_in_tree() and not app.primary.disabled, "only order confirmation is actionable")
	if failures > 0: return
	if not captured and _dining():
		_capture()
	var guest_id: int = int(table.guest_id)
	var button_point: Vector2 = app.primary.get_global_rect().get_center()
	_click(button_point)
	_expect(app.model.table_action(table_id) != "order", "real confirmation consumes one order")
	_expect(not orders.has(guest_id), "guest is confirmed exactly once")
	orders[guest_id] = true
	var accepted: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8): _click(button_point)
	_expect(app.model.to_dict() == accepted, "duplicate confirmation clicks cannot add orders, tasks, or revenue")
	_expect(not app.primary.visible or app.primary.disabled, "confirmed popup exposes no manual cooking/payment/cleanup")


func _observe() -> void:
	var violations: Array[String] = app.model.validate_invariants()
	_expect(violations.is_empty(), "model invariants: " + "; ".join(violations))
	_expect(app.model.open_for_arrivals and app.model.auto_seat and app.model.auto_cook and app.model.auto_dispatch, "automatic service remains enabled")
	_expect(int(app.model.coins) == int(app.model.served) * 38, "automatic payment credits exactly once per guest")
	_expect(int(app.model.lost) == 0, "timely confirmation loses no guests")
	_expect(app.save_allowed and not str(app.save_label.text).contains("保存失败"), "private autosave remains healthy")
	_expect(not app.hud.debug_root.visible, "test never opens developer controls")
	for table: Dictionary in app.model.tables:
		phases_seen[str(table.phase)] = true
		if int(table.generation) > 0: tables_seen[int(table.id)] = true
	for guest: Dictionary in app.model.customers.values(): species_seen[str(guest.species)] = true
	for worker: Dictionary in app.model.workers:
		if int(worker.task_id) > 0: worker_seen[int(worker.id)] = true
	if not app.bubble_layer._visuals.is_empty(): bubble_seen = true
	_expect(app.bubble_layer._visuals.size() <= 3, "expression overlay stays within capacity")
	if int(app.model.served) != last_served:
		last_served = int(app.model.served)
		print("ORDER_ONLY_GUI_PROGRESS served=%d coins=%d confirmed=%d active=%d tables=%d species=%d sim=%.2f" % [last_served, int(app.model.coins), orders.size(), app.model.customers.size(), tables_seen.size(), species_seen.size(), float(app.model.clock)])


func _processing() -> bool:
	for task: Dictionary in app.model.tasks:
		if task.state == "claimed": return true
	return false


func _dining() -> bool:
	for table: Dictionary in app.model.tables:
		if table.phase in ["eating", "drinking"]: return true
	return false


func _check_restore() -> void:
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(app.model.paused and app.pause_overlay.visible, "pause covers processing restaurant")
	var frozen: Dictionary = app.model.to_dict().duplicate(true)
	var expressions: Dictionary = app.dialogues.to_debug().duplicate(true)
	var view_clock: float = float(app.clock)
	await create_timer(0.25, true, false, true).timeout
	await _frame()
	if finished: return
	_expect(app.model.to_dict() == frozen and float(app.clock) == view_clock, "real rendered frames freeze paused simulation and movement")
	_expect(app.dialogues.to_debug() == expressions and app.music.player.stream_paused, "pause freezes expressions and BGM")
	_key(KEY_S)
	_expect(FileAccess.file_exists(own_save_path), "actual save shortcut writes private processing checkpoint")
	_expect(not str(app.save_label.text).contains("保存失败"), "processing checkpoint reports success")
	_free_main()
	# Release this instance completely before constructing another GUI or player.
	await create_timer(0.75, true, false, true).timeout
	if finished: return
	_new_main()
	await _frame()
	await _frame()
	if finished: return
	_expect(app.model.paused and app.pause_overlay.visible, "fresh GUI restores saved pause state")
	_expect(_same(app.model.to_dict(), frozen), "fresh GUI restores complete guests, routes, claimed tasks, kitchen, and economy")
	_expect(_processing() and app.model.validate_invariants().is_empty(), "restored task claims remain valid")
	# A paused restore never starts BGM, and stream_paused reads false on a player with no playback.
	_expect(app.music.settings_path == own_save_path + ".audio.json" and app.music.paused and (not app.music.player.playing or app.music.player.stream_paused), "restored music uses private settings and stays paused")
	_click(app.pause_button.get_global_rect().get_center())
	await _frame()
	if finished: return
	_expect(not app.model.paused and float(app.model.clock) > float(frozen.clock), "restored GUI resumes through actual pause button")
	_expect(app.music.player.playing and not app.music.player.stream_paused, "restored BGM resumes under test-only Master mute")
	restored = true
	print("ORDER_ONLY_GUI_PAUSED_PROCESSING_RESTORE_OK")


func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int): return absf(float(a) - float(b)) < 0.00001
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]): return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size(): return false
		for index: int in range(a.size()):
			if not _same(a[index], b[index]): return false
		return true
	return a == b


func _capture() -> void:
	_expect(_dining() and app.hud.demand_row.visible and app.primary.is_visible_in_tree(), "capture contains dining and pending order confirmation")
	var error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://verification"))
	_expect(error == OK or error == ERR_ALREADY_EXISTS, "verification directory available")
	if error != OK and error != ERR_ALREADY_EXISTS: return
	var pixels: Image = root.get_texture().get_image()
	_expect(pixels != null and not pixels.is_empty(), "actual viewport pixels available")
	if pixels == null or pixels.is_empty(): return
	error = pixels.save_png(CAPTURE_PATH)
	_expect(error == OK, "gameplay screenshot saved")
	captured = error == OK
	if captured: print("ORDER_ONLY_GUI_CAPTURE " + ProjectSettings.globalize_path(CAPTURE_PATH))


func _check_final() -> void:
	_expect(int(app.model.served) >= TARGET_SERVED and orders.size() >= TARGET_SERVED, "at least 34 guests complete through order-only input")
	_expect(int(app.model.coins) == int(app.model.served) * 38 and app.model.paid_ledger.size() == int(app.model.served), "automatic revenue agrees with unique payment ledger")
	_expect(tables_seen.size() == 20, "automatic seating uses all twenty tables")
	_expect(species_seen.size() == 17, "all seventeen guest species rendered")
	for species: String in Model.SPECIES: _expect(species_seen.has(species), "guest species observed: " + species)
	for phase: String in ["ordering", "cooking", "serving_food", "serving_drink", "eating", "drinking", "collecting", "wiping"]:
		_expect(phases_seen.has(phase), "automatic rendered phase observed: " + phase)
	_expect(worker_seen.size() == 2, "both staff perform automatic work")
	_expect(bubble_seen and captured and restored, "expressions, gameplay capture, and GUI processing restore covered")
	_expect(str(app.hud.money_label.text) == str(app.model.coins), "normal HUD shows automatic revenue")
	_expect(app.model.open_for_arrivals, "automatic arrivals remain on at completion")
	_key(KEY_S)
	var reopened = Model.new()
	_expect(reopened.load_from(own_save_path), "final private save reopens")
	_expect(_same(reopened.to_dict(), app.model.to_dict()), "final private save contains complete active restaurant")
	print("ORDER_ONLY_GUI_FINAL served=%d coins=%d active=%d tables=%d species=%d orders=%d" % [int(app.model.served), int(app.model.coins), app.model.customers.size(), tables_seen.size(), species_seen.size(), orders.size()])


func _watchdog() -> void:
	if finished: return
	_expect(false, "wall-clock watchdog expired; served=%d confirmed=%d" % [int(app.model.served) if is_instance_valid(app) else -1, orders.size()])
	_finish()


func _free_main() -> void:
	if not is_instance_valid(app): return
	app.set_process(false)
	var own_music: Node = app.music
	app.free()
	app = null
	if is_instance_valid(own_music): own_music.free()


func _finish() -> void:
	if finished: return
	finished = true
	_free_main()
	Engine.time_scale = previous_time_scale
	await create_timer(0.75, true, false, true).timeout
	if owns_slot:
		for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
			var path: String = own_save_path + suffix
			if FileAccess.file_exists(path):
				_expect(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK, "remove only this run's private file: " + suffix)
	print("ORDER_ONLY_GUI_RESULT assertions=%d failures=%d frames=%d wall_ms=%d" % [assertions, failures, frames, Time.get_ticks_msec() - started_ms])
	quit(0 if failures == 0 else 1)
