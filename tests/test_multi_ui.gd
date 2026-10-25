extends SceneTree
## Real GUI acceptance test: private save, actual process/render frames, public UI handlers.
## Run only when authorized: Godot --path <project> --script res://tests/test_multi_ui.gd
## No direct mutation of guest/table phases, actor positions, or payment counters.
const Main = preload("res://multi_main.gd")
const Model = preload("res://multi_model.gd")
const TARGET_GUESTS: int = 34
const WATCHDOG_SECONDS: float = 180.0
const CAPTURE_OVERVIEW := "res://verification/multi_overview.png"
const CAPTURE_FINAL := "res://verification/multi_final.png"
const CAPTURE_BUBBLES := "res://verification/multi_bubbles.png"
const CAPTURE_GAMEPLAY := "res://verification/gameplay_scene.png"
const CAPTURE_BAR := "res://verification/bar_dining.png"
const CAPTURE_BAR_SERVICE := "res://verification/bar_service.png"

var app: Variant = null
var own_save_path: String = ""
var owns_save_slot: bool = false
var finished: bool = false
var assertions: int = 0
var failures: int = 0
var rendered_frames: int = 0
var invited: int = 0
var max_active: int = 0
var started_ms: int = 0
var previous_time_scale: float = 1.0
var pause_checked: bool = false
var save_checked: bool = false
var primary_bursts: int = 0
var batch_bursts: int = 0
var captured_overview: bool = false
var captured_bubbles: bool = false
var captured_gameplay: bool = false
var captured_bar: bool = false
var captured_bar_service: bool = false
var bubble_frames: Dictionary = {}
var bubble_emotions: Dictionary = {}
var bubble_peak: int = 0
var tables_used: Dictionary = {}
var species_seen: Dictionary = {}
var phases_seen: Dictionary = {}
var worker_claims_seen: Dictionary = {0: 0, 1: 0}
var last_progress_served: int = -1
var last_progress_wall: int = 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	previous_time_scale = Engine.time_scale
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MULTI_GUI_ASSERT_FAIL " + description)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_expect(false, "This test requires a graphical renderer, not --headless")
		_finish()
		return
	create_timer(WATCHDOG_SECONDS, true, false, true).timeout.connect(_on_watchdog)
	own_save_path = "user://multi_ui_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	_expect(own_save_path != Main.SAVE_PATH, "private slot differs from normal player slot")
	_expect(not FileAccess.file_exists(own_save_path), "private slot is new")
	if failures > 0:
		_finish()
		return
	owns_save_slot = true
	app = Main.new()
	# Historical manual-operation fixture; current player acceptance is test_order_only_ui.gd.
	app.player_mode = false
	# Before _ready(), so neither the normal slot nor seed guests are ever loaded.
	app.save_path = own_save_path
	app.seed_guests = false
	Engine.time_scale = 16.0
	root.add_child(app)
	_expect(app.save_path == own_save_path, "main accepted injected private slot")
	_expect(app.model.customers.is_empty() and int(app.model.served) == 0, "fresh test restaurant")
	_expect(bool(app.model.open_for_arrivals), "default arrivals enabled before UI toggle")
	app._toggle_arrivals()
	_expect(not bool(app.model.open_for_arrivals), "arrival button prevents uncounted automatic guests")
	_expect(not bool(app.model.auto_cook), "default cooking is a player decision")
	app._toggle_cooking()
	_expect(bool(app.model.auto_cook), "automatic kitchen enabled through UI")
	_expect(bool(app.model.auto_seat) and bool(app.model.auto_dispatch), "default seating and dispatch enabled")
	_expect(int(app.model.max_customers) == 6, "controlled six-guest concurrency")
	await _render_frame()
	_expect(app.dialogues.enabled and not app.bubble_layer.show_short_text, "expressions default on, words default off")
	_expect(not app.hud.settings_root.visible and not app.hud.debug_root.visible, "game view hides settings and developer dashboard by default")
	_expect(app.room.position == Vector2(0, 80), "restaurant fills scene-first viewport below small top bar")
	var economy_before_options: Dictionary = app.model.to_dict().duplicate(true)
	app._toggle_dialogues()
	_expect(not app.dialogues.enabled and app.dialogues.bubbles.is_empty(), "expression switch clears visible and queued dialogue")
	app._toggle_dialogues()
	app._toggle_short_text()
	_expect(app.bubble_layer.show_short_text and app.dialogues.show_short_text, "short-word switch enables both director and view")
	app._toggle_short_text()
	_expect(app.model.to_dict() == economy_before_options, "expression settings do not modify economic state")
	_expect(app.music.available and app.music.player.playing, "BGM resource loaded and single player started")
	_expect(app.music.player.stream.loop and app.music.player.bus == "Music", "BGM loops on isolated Music bus")
	var music_id: int = app.music.get_instance_id()
	var music_before: Dictionary = app.model.to_dict().duplicate(true)
	app._toggle_music()
	_expect(not app.music.enabled and app.music.player.stream_paused, "music off pauses existing playback")
	app._toggle_music()
	app._music_volume_changed(25.0)
	_expect(is_equal_approx(app.music.volume, 0.25), "UI volume controls Music bus")
	app._music_volume_changed(35.0)
	_expect(app.music.get_instance_id() == music_id and app.model.to_dict() == music_before, "music controls neither duplicate player nor alter game economy")
	var pointer := InputEventMouseButton.new()
	pointer.button_index = MOUSE_BUTTON_LEFT
	pointer.pressed = true
	pointer.position = app.room.position + app.model.tables[19].center
	pointer.global_position = pointer.position
	root.push_input(pointer, true)
	await _render_frame()
	_expect(int(app.selected_table) == 20, "viewport mouse event selects bar table 20")
	var release: InputEventMouseButton = pointer.duplicate()
	release.pressed = false
	root.push_input(release, true)
	print("MULTI_GUI_START pid=%d save=%s target=%d time_scale=16" % [OS.get_process_id(), own_save_path, TARGET_GUESTS])
	while not finished:
		await _render_frame()
		if finished:
			return
		_observe_and_validate()
		if failures > 0:
			_finish()
			return
		if not pause_checked and app.model.customers.size() >= 3 and int(app.model.chef.table_id) > 0 and not app.dialogues.bubbles.is_empty():
			await _check_pause_save_and_resume()
			if finished:
				return
			continue
		if not captured_overview and invited == 6 and app.model.customers.size() == 6 and _has_dining_guest():
			_capture(CAPTURE_OVERVIEW)
			captured_overview = true
		if not captured_bubbles and app.model.customers.size() >= 3 and _has_dining_guest() and not app.bubble_layer._visuals.is_empty():
			_capture(CAPTURE_BUBBLES)
			captured_bubbles = true
		if not captured_gameplay and _three_zones_active() and _has_dining_guest():
			_capture(CAPTURE_GAMEPLAY)
			captured_gameplay = true
		if not captured_bar and _bar_dining():
			_capture(CAPTURE_BAR)
			captured_bar = true
		if not captured_bar_service and _bar_service():
			_capture(CAPTURE_BAR_SERVICE)
			captured_bar_service = true
		if invited == TARGET_GUESTS and int(app.model.served) == TARGET_GUESTS and _restaurant_idle():
			_check_final_state()
			if failures == 0:
				_capture(CAPTURE_FINAL)
			_finish()
			return
		if float(app.cooldown) > 0.0:
			continue
		# Give guests service before inviting more, and never press an empty batch.
		if _count_actions("pay") > 0:
			_pay_batch_burst()
		elif _oldest_action_table("clean") > 0:
			_primary_burst(_oldest_action_table("clean"))
		elif _count_actions("order") > 0:
			# Exercise the selected-table path once; later orders use the batch control.
			if primary_bursts == 0:
				_primary_burst(_oldest_action_table("order"))
			else:
				_order_batch_burst()
		elif invited < TARGET_GUESTS and app.model.customers.size() < int(app.model.max_customers):
			_invite_burst()


func _render_frame() -> void:
	await process_frame
	if finished:
		return
	await RenderingServer.frame_post_draw
	if not finished:
		rendered_frames += 1


func _observe_and_validate() -> void:
	var violations: Array[String] = app.model.validate_invariants()
	_expect(violations.is_empty(), "model invariants: " + "; ".join(violations))
	_expect(bool(app.save_allowed), "private test save remains writable")
	_expect(not str(app.save_label.text).contains("保存失败"), "UI reports no save failure")
	_expect(int(app.model.lost) == 0, "timely GUI service loses no guests")
	_expect(int(app.model.coins) == int(app.model.served) * 38, "displayed economy remains one payment per guest")
	_expect(int(app.model.next_customer_id) - 1 == invited, "only invitation handlers create counted guests")
	max_active = maxi(max_active, app.model.customers.size())
	bubble_peak = maxi(bubble_peak, app.bubble_layer._visuals.size())
	_expect(app.dialogues.bubbles.size() <= 3 and app.bubble_layer._visuals.size() <= 3, "expressions obey three-bubble limit")
	for visual: Dictionary in app.bubble_layer._visuals.values():
		var sprite: AnimatedSprite2D = visual.sprite
		bubble_frames[sprite.frame] = true
		bubble_emotions[str(sprite.animation)] = true
		_expect(not visual.label.visible and visual.label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "no words by default and label never intercepts clicks")
		_expect(sprite.sprite_frames.get_frame_count(sprite.animation) == 4, "actual atlas has four animation frames")
	for guest: Dictionary in app.model.customers.values():
		species_seen[str(guest.species)] = true
	for table: Dictionary in app.model.tables:
		phases_seen[str(table.phase)] = true
		if int(table.generation) > 0:
			tables_used[int(table.id)] = true
	for worker: Dictionary in app.model.workers:
		if int(worker.task_id) > 0:
			worker_claims_seen[int(worker.id)] = int(worker_claims_seen[int(worker.id)]) + 1
	var wall: int = Time.get_ticks_msec() - started_ms
	if int(app.model.served) != last_progress_served or wall - last_progress_wall > 10000:
		last_progress_served = int(app.model.served)
		last_progress_wall = wall
		print("MULTI_GUI_PROGRESS invited=%d served=%d active=%d tasks=%d tables_used=%d sim_seconds=%.2f wall_ms=%d" % [invited, int(app.model.served), app.model.customers.size(), app.model.tasks.size(), tables_used.size(), float(app.model.clock), wall])


func _count_actions(action: String) -> int:
	var count: int = 0
	for table: Dictionary in app.model.tables:
		if app.model.table_action(int(table.id)) == action:
			count += 1
	return count


func _oldest_action_table(action: String) -> int:
	var id: int = -1
	var oldest: float = -1.0
	for table: Dictionary in app.model.tables:
		if app.model.table_action(int(table.id)) == action and float(table.elapsed) > oldest:
			id = int(table.id)
			oldest = float(table.elapsed)
	return id


func _primary_burst(table_id: int) -> void:
	app._select_table(table_id)
	_expect(int(app.selected_table) == table_id, "table selection updates the UI")
	_expect(not bool(app.primary.disabled), "selected table action is enabled")
	var action: String = app.model.table_action(table_id)
	var before: Dictionary = app.model.to_dict().duplicate(true)
	if primary_bursts == 0:
		var space := InputEventKey.new()
		space.keycode = KEY_SPACE
		space.pressed = true
		app.hud.toggle_settings()
		app._unhandled_key_input(space)
		_expect(app.model.to_dict() == before, "settings overlay blocks hidden table keyboard action")
		app.hud.close_overlay()
	app._primary()
	_expect(app.model.to_dict() != before, "selected-table action %s changes state" % action)
	_expect(float(app.cooldown) > 0.0 and bool(app.primary.disabled), "primary immediately locks after one click")
	var after: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8):
		app._primary()
	_expect(app.model.to_dict() == after, "repeated primary cannot cross phases or create duplicate tasks")
	primary_bursts += 1


func _order_batch_burst() -> void:
	var expected: int = _count_actions("order")
	_expect(expected > 0, "order batch is nonempty")
	app._order_all()
	_expect(_count_actions("order") == 0, "all eligible orders recorded once")
	var after: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8):
		app._order_all()
	_expect(app.model.to_dict() == after, "repeated order batches do not reenter")
	batch_bursts += 1


func _pay_batch_burst() -> void:
	var expected: int = _count_actions("pay")
	var coins: int = int(app.model.coins)
	var served: int = int(app.model.served)
	app._pay_all()
	_expect(int(app.model.coins) == coins + expected * 38, "pay batch credits each guest exactly once")
	_expect(int(app.model.served) == served + expected, "pay batch counts each served guest once")
	var after: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8):
		app._pay_all()
	_expect(app.model.to_dict() == after, "rapid repeated payment cannot add coins")
	batch_bursts += 1


func _invite_burst() -> void:
	var next_id: int = int(app.model.next_customer_id)
	app._invite()
	_expect(int(app.model.next_customer_id) == next_id + 1, "invite adds exactly one guest")
	if int(app.model.next_customer_id) == next_id + 1:
		invited += 1
	var after: Dictionary = app.model.to_dict().duplicate(true)
	for repeat: int in range(8):
		app._invite()
	_expect(app.model.to_dict() == after, "invite burst honors UI cooldown")
	batch_bursts += 1


func _check_pause_save_and_resume() -> void:
	pause_checked = true
	app._pause()
	_expect(bool(app.model.paused), "pause handler pauses all simulation")
	var frozen: Dictionary = app.model.to_dict().duplicate(true)
	var view_clock: float = float(app.clock)
	_expect(app.music.player.stream_paused, "game pause also pauses music")
	var music_position: float = app.music.player.get_playback_position()
	var expression_snapshot: Dictionary = app.dialogues.to_debug().duplicate(true)
	var expression_frames: Dictionary = {}
	for id in app.bubble_layer._visuals:
		expression_frames[id] = app.bubble_layer._visuals[id].sprite.frame
	await create_timer(0.30, true, false, true).timeout
	if finished:
		return
	await _render_frame()
	if finished:
		return
	_expect(bool(app.pause_overlay.visible), "pause overlay has been rendered")
	app._invite()
	app._order_all()
	app._pay_all()
	app._primary()
	app._dispatch()
	_expect(app.model.to_dict() == frozen, "real frames and public action handlers leave paused model unchanged")
	_expect(float(app.clock) == view_clock, "view animation clock freezes")
	_expect(app.music.player.stream_paused and absf(app.music.player.get_playback_position() - music_position) < 0.08, "paused BGM does not advance")
	_expect(app.dialogues.to_debug() == expression_snapshot, "expression duration, cooldown and pending replies freeze")
	for id in expression_frames:
		_expect(app.bubble_layer._visuals.has(id) and app.bubble_layer._visuals[id].sprite.frame == expression_frames[id], "AnimatedSprite2D expression frame freezes")
	app._manual_save()
	_expect(FileAccess.file_exists(own_save_path), "private manual save exists")
	_expect(not str(app.save_label.text).contains("保存失败"), "private manual save reports success")
	var reopened = Model.new()
	var loaded: bool = reopened.load_from(own_save_path)
	_expect(loaded, "saved concurrent restaurant loads in a fresh model")
	if loaded:
		_expect(reopened.validate_invariants().is_empty(), "concurrent save restores consistent task ownership and routes")
		_expect(bool(reopened.paused), "saved pause state restored")
		_expect(is_equal_approx(float(reopened.clock), float(app.model.clock)), "saved simulation time restored")
		_expect(int(reopened.next_customer_id) == invited + 1 and reopened.customers.size() == app.model.customers.size(), "saved guest and sequence identities restored")
		_expect(reopened.tasks.size() == app.model.tasks.size() and reopened.coins == app.model.coins, "saved tasks and coins restored")
	save_checked = loaded
	app._pause()
	_expect(not bool(app.model.paused), "resume handler unpauses simulation")
	_expect(not app.music.player.stream_paused and app.music.player.playing, "resume continues existing BGM playback")
	await _render_frame()
	if finished:
		return
	_expect(not bool(app.pause_overlay.visible), "pause overlay hides after resume")
	_expect(float(app.clock) > view_clock, "real frame advances after resume")
	print("MULTI_GUI_PAUSE_SAVE_RESUME_OK")


func _has_dining_guest() -> bool:
	for table: Dictionary in app.model.tables:
		if table.phase in ["eating", "drinking"]:
			return true
	return false


func _restaurant_idle() -> bool:
	if not app.model.customers.is_empty() or not app.model.tasks.is_empty() or int(app.model.chef.table_id) != -1:
		return false
	for table: Dictionary in app.model.tables:
		if table.phase != "free":
			return false
	for worker: Dictionary in app.model.workers:
		if worker.state != "idle":
			return false
	return true


func _check_final_state() -> void:
	_expect(invited == TARGET_GUESTS and int(app.model.served) == TARGET_GUESTS, "all 34 invited guests served")
	_expect(int(app.model.coins) == TARGET_GUESTS * 38, "34 guests yield exactly 1292 coins")
	_expect(int(app.model.lost) == 0 and int(app.model.rejected) == 0, "controlled traffic causes no loss or rejection")
	_expect(max_active == 6, "real concurrent peak reaches six guests")
	_expect(tables_used.size() == 20, "all twenty tables assigned and released across rotations")
	_expect(species_seen.size() == 17, "all seventeen guest species rendered")
	for species: String in Model.SPECIES:
		_expect(species_seen.has(species), "observed guest species " + species)
	for phase: String in ["free", "reserved", "ordering", "cooking", "serving_food", "serving_drink", "eating", "drinking", "checkout", "leaving", "dirty", "collecting", "wiping"]:
		_expect(phases_seen.has(phase), "observed rendered table phase " + phase)
	for worker_id: int in [0, 1]:
		_expect(int(worker_claims_seen[worker_id]) > 0, "each of the two staff performs tasks")
	_expect(pause_checked and save_checked, "pause/resume and concurrent save restore exercised")
	_expect(primary_bursts >= TARGET_GUESTS, "selected-table cleanup and repeated click checks exercised")
	_expect(batch_bursts > TARGET_GUESTS, "batch controls exercised over multiple rounds")
	_expect(captured_overview, "active six-guest overview was captured")
	_expect(captured_bubbles and bubble_peak > 0, "actual animated expressions captured during dining")
	_expect(captured_gameplay, "actual guests occupy all three restaurant zones in captured game scene")
	_expect(captured_bar, "actual seated bar dining captured for visual furniture review")
	_expect(captured_bar_service, "actual bar delivery animation captured for visual contact review")
	_expect(bubble_frames.size() == 4, "all four expression frames rendered")
	_expect(bubble_emotions.size() >= 3, "multiple contextual expression types rendered")
	print("MULTI_GUI_EXPRESSIONS emotions=%d frames=%d peak=%d no_words=true" % [bubble_emotions.size(), bubble_frames.size(), bubble_peak])
	_expect(str(app.hud.money_label.text).contains("1292"), "visible game HUD shows final coins")
	_expect(not app.hud.debug_root.visible and not app.hud.settings_root.visible, "final screenshot is the game, not a developer panel")
	_expect(_restaurant_idle(), "all tables and tasks fully released at completion")
	app._manual_save()
	_expect(not str(app.save_label.text).contains("保存失败"), "final private save succeeds")
	var reopened = Model.new()
	_expect(reopened.load_from(own_save_path), "final private save reopens")
	_expect(int(reopened.coins) == 1292 and int(reopened.served) == 34, "final saved revenue and guest count exact")
	print("MULTI_GUI_FINAL coins=%d served=%d lost=%d tables_used=%d species=%d max_active=%d" % [int(app.model.coins), int(app.model.served), int(app.model.lost), tables_used.size(), species_seen.size(), max_active])


func _capture(path: String) -> void:
	var directory: String = ProjectSettings.globalize_path("res://verification")
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(directory)
	_expect(directory_error == OK or directory_error == ERR_ALREADY_EXISTS, "capture directory available")
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return
	var image: Image = root.get_texture().get_image()
	_expect(image != null and not image.is_empty(), "real viewport pixels available")
	if image == null or image.is_empty():
		return
	var error: Error = image.save_png(path)
	_expect(error == OK, "actual GUI screenshot saved")
	if error == OK:
		print("MULTI_GUI_CAPTURE " + ProjectSettings.globalize_path(path))


func _on_watchdog() -> void:
	if finished:
		return
	var status: String = "not created"
	if is_instance_valid(app):
		status = "invited=%d served=%d active=%d tasks=%d" % [invited, int(app.model.served), app.model.customers.size(), app.model.tasks.size()]
	_expect(false, "real-time watchdog expired: " + status)
	_finish()


func _finish() -> void:
	if finished:
		return
	finished = true
	Engine.time_scale = previous_time_scale
	if is_instance_valid(app):
		app.set_process(false)
		var test_music: Node = app.music
		app.free()
		if is_instance_valid(test_music): test_music.free()
		app = null
	if owns_save_slot and not own_save_path.is_empty():
		for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
			var path: String = own_save_path + suffix
			if FileAccess.file_exists(path):
				var cleanup_error: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
				_expect(cleanup_error == OK, "delete only this run's private save file")
	# Let the audio mixing thread release a stopped OGG playback before exit.
	await create_timer(0.25, true, false, true).timeout
	print("MULTI_GUI_RESULT assertions=%d failures=%d rendered_frames=%d wall_ms=%d" % [assertions, failures, rendered_frames, Time.get_ticks_msec() - started_ms])
	quit(0 if failures == 0 else 1)

func _three_zones_active() -> bool:
	var zones: Dictionary = {}
	for table in app.model.tables:
		if table.guest_id > 0 and table.phase not in ["reserved", "leaving", "dirty", "collecting", "wiping"]:
			zones[table.zone] = true
	return zones.size() == 3

func _bar_dining() -> bool:
	for table in app.model.tables:
		if table.zone == "bar" and table.phase in ["eating", "drinking"]:
			return true
	return false

func _bar_service() -> bool:
	for worker in app.model.workers:
		if worker.state != "working" or float(worker.elapsed) < 0.4:
			continue
		for task in app.model.tasks:
			if task.id == worker.task_id and task.table_id >= 19 and task.kind in ["food", "drink"]:
				return true
	return false
