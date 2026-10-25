extends SceneTree
## Real-window regression for the local-only simulator. No Main, save, or device API.
const ToyView = preload("res://toy_simulator_view.gd")
const Localization = preload("res://localization.gd")
const CookingSession = preload("res://cooking_session.gd")

var view: CanvasLayer
var events: Array[Dictionary] = []
var commands: Array[String] = []
var checks := 0
var failures: Array[String] = []
var done := false

func _init() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "real graphical window required")
		_finish()
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	create_timer(30.0, true, false, true).timeout.connect(func():
		if not done:
			_check(false, "window watchdog expired")
			_finish())
	Localization.set_locale("zh_CN")
	var session = CookingSession.new()
	_check(session.setup({"table_id":1, "guest_id":1, "generation":1}, "pumpkin_corn_soup"), "real cooking session is available for simulator status")
	view = ToyView.new()
	root.add_child(view)
	view.event_requested.connect(func(type: String, payload: Dictionary): events.append({"type":type, "payload":payload.duplicate(true)}))
	view.command_requested.connect(func(command: String): commands.append(command))
	await process_frame
	view.open()
	view.sync({"connection":"aligning", "token":"toy-one"}, session.status())
	await _frame()
	_check(view.is_open() and view.button_for_event("snapshot") != null, "standalone view opens with stable controls")
	await create_timer(0.06, true, false, true).timeout
	var aligning_rotation: float = view.state_icon.rotation
	_check(not is_zero_approx(aligning_rotation), "aligning state icon rotates")
	_check(view.button_for_event("drink_coffee").size.x >= 48.0 and view.button_for_event("drink_ice").size.y >= 48.0, "all compact drink targets remain 48 design pixels")
	var pumpkin_art := view.button_for_event("card_pumpkin").find_child("Art", true, false) as TextureRect
	_check(pumpkin_art.texture != null and pumpkin_art.texture.resource_path.contains("food/ingredients/pumpkin_whole_64"), "pumpkin card uses its ingredient artwork")
	var corn_art := view.button_for_event("card_corn").find_child("Art", true, false) as TextureRect
	_check(corn_art.texture != null and corn_art.texture.resource_path.contains("food/ingredients/corn_whole_64"), "corn card is not a pot substitute")
	_check_button_artwork()
	_click("zone_stove")
	_click("card_pot")
	_click("stove_high")
	_click("oven_door")
	_click("oven_medium")
	_click("faucet")
	_click("drink_coffee")
	_click("drink_milk")
	_click("drink_ice")
	await _frame()
	_check(_last("card").payload == {"category":"pot", "zone":"stove"}, "physical pot card emits semantic zone payload")
	_check(_has_event("stove", {"level":"high"}) and _has_event("oven_door", {"open":true}) and _has_event("oven_level", {"level":"medium"}) and _has_event("faucet", {"open":true}), "physical controls emit their current semantic values")
	_check(_has_event("drink_button", {"ingredient":"coffee"}) and _has_event("drink_button", {"ingredient":"milk"}) and _has_event("drink_button", {"ingredient":"ice"}), "three drink controls remain independent")
	var pan_icon := view.button_for_event("vessel_pan").find_child("Icon", true, false) as TextureRect
	var pan_selected := view.button_for_event("vessel_pan").find_child("Selected", true, false) as TextureRect
	_check(pan_icon.texture != null and pan_icon.texture.resource_path.ends_with("reuse_pan.png") and not pan_selected.visible, "pan button uses the real reusable pan art with an off-state badge")
	_click("vessel_pan")
	await _frame()
	_check(pan_selected.visible and pan_icon.texture.resource_path.ends_with("reuse_pan.png"), "pan on-state keeps pan art and shows its selected badge")
	_click("snapshot")
	await _frame()
	var snapshot: Dictionary = _last("panel_snapshot").payload
	_check(snapshot == {"stove_level":"high", "oven_level":"medium", "oven_open":true, "vessel":"pan", "faucet_open":true}, "snapshot keeps all real physical values after clicks")
	view.sync({"connection":"disconnected", "token":"toy-one", "panel":{"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false}}, session.status())
	_check(view._panel == snapshot, "disconnect does not erase local physical controls")
	view.sync({"connection":"aligning", "token":"toy-one"}, session.status())
	_click("snapshot")
	await _frame()
	_check(_last("panel_snapshot").payload == snapshot, "alignment snapshot reports held state without an action")
	var rotation_before_connected: float = view.state_icon.rotation
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, session.status(), "action_candidate")
	await _frame()
	_check(absf(view.state_icon.rotation - rotation_before_connected) <= 0.02, "connected state icon is steady after alignment")
	_check(view.feedback_icon.texture.resource_path.ends_with("finger_ready_32.png"), "candidate feedback uses neutral ready artwork")
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, session.status(), "committed")
	_check(view.feedback_icon.texture.resource_path.contains("recognition_success") and view._feedback_text("committed") == "已提交", "only explicit committed feedback shows success")
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, session.status(), "unknown_card")
	var unknown_text: String = view.feedback_label.text
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, session.status(), "read_failed")
	_check(unknown_text != view.feedback_label.text and view.feedback_label.text == "读卡失败" and view.feedback_badge.text == "!", "unknown and read-failed feedback are distinct short messages and marks")
	for feedback in ["aligned", "panel_aligned", "panel_updated", "stale", "duplicate"]:
		view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, session.status(), feedback)
		_check(view.feedback_icon.texture.resource_path.ends_with("target_arrow_32.png"), "%s uses neutral synchronization artwork" % feedback)
	session.set_paused(true)
	view.sync({"connection":"aligning", "token":"toy-one", "panel":snapshot}, session.status(), "paused")
	var paused_rotation: float = view.state_icon.rotation
	var paused_time: float = view._feedback_time
	await create_timer(0.15, true, false, true).timeout
	await _frame()
	_check(is_equal_approx(view._feedback_time, paused_time) and is_equal_approx(view.state_icon.rotation, paused_rotation), "manual pause freezes feedback animation time and icon angle")
	session.set_paused(false)
	_check(session.act("add_pumpkin") and session.act("add_corn") and session.act("add_water") and session.act("cut") and session.act("pot") and session.act("heat_medium"), "real session reaches cooking through its actions")
	session.tick(1.2)
	var cooking_status := session.status()
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, cooking_status, "action_candidate")
	_check(view.need_icon.texture.resource_path.ends_with("timer_track.png") and view.need_label.text == "等待 %d 秒" % ceili(maxf(0.0, float(cooking_status.duration) - float(cooking_status.elapsed))), "cooking hint uses real duration and elapsed with ceil remaining seconds")
	session.tick(session.cook_duration())
	var ready_status := session.status()
	view.sync({"connection":"connected", "token":"toy-one", "panel":snapshot}, ready_status, "action_candidate")
	_check("finish" in ready_status.actions and view.need_icon.texture.resource_path.ends_with("completion.png") and view.need_label.text == "完成", "ready soup exposes real finish action with completion icon")
	await _frame()
	_capture("res://verification/p0_toy_cn.png")
	Localization.set_locale("en")
	await _frame()
	_check(not _contains_cjk(view.root) and not _contains_cjk_tooltips(view.root) and not _contains_raw_key(view.root), "English labels and tooltips contain no Chinese or raw keys")
	_check(view.state_label.text == "Connected" and view.feedback_label.text == "Ready to confirm" and view.button_for_event("read_failed").tooltip_text == "Simulate card read failure", "language switch refreshes short status, feedback, and read-failed tooltip")
	_capture("res://verification/p0_toy_en.png")
	view.sync({"connection":"connected", "token":"toy-two", "panel":{"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false}}, session.status())
	_check(view._panel == {"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false} and view.feedback_label.text.is_empty(), "new token resets prior order panel and feedback")
	_click("close")
	await _frame()
	_check(not view.is_open(), "simulator has a real close path")
	_finish()

func _click(id: String) -> void:
	var button: Button = view.button_for_event(id)
	_check(button != null and button.is_visible_in_tree() and not button.disabled, "clickable control: " + id)
	if button == null or button.disabled:
		return
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = button.get_global_rect().get_center()
		event.global_position = event.position
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)

func _frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func _check_button_artwork() -> void:
	for id: String in view._buttons:
		var button: Button = view.button_for_event(id)
		for child in _texture_rects(button):
			var image := child as TextureRect
			var inside: bool = button.get_global_rect().encloses(image.get_global_rect())
			_check(image.texture != null and not image.texture.resource_path.is_empty(), "%s artwork loads" % id)
			_check(inside and image.expand_mode == TextureRect.EXPAND_IGNORE_SIZE and image.stretch_mode == TextureRect.STRETCH_SCALE, "%s artwork has a fixed in-button complete rect" % id)

func _texture_rects(node: Node) -> Array[TextureRect]:
	var images: Array[TextureRect] = []
	for child in node.get_children():
		if child is TextureRect: images.append(child as TextureRect)
		images.append_array(_texture_rects(child))
	return images

func _last(type: String) -> Dictionary:
	for index in range(events.size() - 1, -1, -1):
		if str(events[index].type) == type:
			return events[index]
	return {}

func _has_event(type: String, payload: Dictionary) -> bool:
	for event in events:
		if str(event.type) == type and event.payload == payload:
			return true
	return false

func _capture(path: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://verification"))
	_check(error == OK or error == ERR_ALREADY_EXISTS, "verification directory exists")
	var image := root.get_texture().get_image()
	_check(image != null and not image.is_empty() and image.save_png(ProjectSettings.globalize_path(path)) == OK, "actual window capture: " + path)

func _contains_cjk(node: Node) -> bool:
	if node is Label and _has_cjk((node as Label).text): return true
	if node is Button and _has_cjk((node as Button).text): return true
	for child in node.get_children():
		if _contains_cjk(child): return true
	return false

func _contains_cjk_tooltips(node: Node) -> bool:
	if node is Control and _has_cjk((node as Control).tooltip_text): return true
	for child in node.get_children():
		if _contains_cjk_tooltips(child): return true
	return false

func _has_cjk(value: String) -> bool:
	for index in value.length():
		var point := value.unicode_at(index)
		if point >= 0x4e00 and point <= 0x9fff: return true
	return false

func _contains_raw_key(node: Node) -> bool:
	if node is Label and _has_raw_key((node as Label).text): return true
	if node is Button and _has_raw_key((node as Button).text): return true
	if node is Control and _has_raw_key((node as Control).tooltip_text): return true
	for child in node.get_children():
		if _contains_raw_key(child): return true
	return false

func _has_raw_key(value: String) -> bool:
	return value.contains("ui_") or value.contains("category_") or value.contains("zone_")

func _finish() -> void:
	if done: return
	done = true
	if is_instance_valid(view):
		view.queue_free()
	if failures.is_empty():
		print("PASS: Toy view window tests (%d checks)" % checks)
		quit(0)
		return
	for failure in failures:
		printerr("TOY_VIEW_FAIL: " + failure)
	print("FAIL: Toy view window tests (%d failures, %d checks)" % [failures.size(), checks])
	quit(1)
