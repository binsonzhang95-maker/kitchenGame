extends SceneTree
## Real GUI evidence capture for G11. This intentionally uses Main plus its
## model's normal admissions, routing, actions and worker lifecycle; it never
## edits actor coordinates, paths, table phases, or animation clocks.
const Main = preload("res://multi_main.gd")
const WATCHDOG_SECONDS := 50.0

var app: Variant
var output_path := ""
var started_ms := 0
var captured := false
var paid_started := false
var saw_stand_up := false

func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("requires GUI rendering; do not run with --headless")
		return
	output_path = _argument("--out=")
	if output_path.is_empty():
		_fail("missing absolute --out=/…/g11.png")
		return
	app = Main.new()
	app.seed_guests = false
	app.save_allowed = false
	app.save_path = "user://g11_preview_private_%d.json" % OS.get_process_id()
	# Select the ordinary non-player lifecycle before Main._ready() enables its
	# default interactive/player modes.  The fixture still drives real model
	# actions; this merely prevents the UI-only modes from disabling auto-cook or
	# paying before the departure observation below can see it.
	app.menu_kind = "classic"
	app.interactive_cooking = false
	app.player_mode = false
	root.add_child(app)
	await process_frame
	var insets := _insets()
	if not insets.is_empty():
		app.set_responsive_layout_for_test(root.get_visible_rect().size, insets)
	app.model.open_for_arrivals = false
	app.model.auto_seat = false
	app.model.auto_dispatch = true
	app.model.auto_cook = true
	app.model.max_customers = 8
	var hall: int = app.model.spawn_party(3, ["cat", "dog", "panda"])
	var private_room: int = app.model.spawn_party(3, ["capybara", "hamster", "cat"])
	var bar: int = app.model.spawn_customer("dog")
	var ordinary: int = app.model.spawn_customer("hamster")
	if hall < 1 or private_room < 1 or bar < 1 or ordinary < 1:
		_fail("normal preview admissions were rejected")
		return
	if not app.model.assign_next(1) or not app.model.assign_next(15) or not app.model.assign_next(19) or not app.model.assign_next(2):
		_fail("normal preview seating routes could not be assigned")
		return
	while true:
		await process_frame
		# `frame_post_draw` can stop arriving when a native window is occluded even
		# though the SceneTree keeps processing.  The normal frame event gives this
		# fixture a watchdog that can actually fire; capture still reads the real
		# viewport texture produced by the preceding rendered frame.
		if Time.get_ticks_msec() - started_ms > int(WATCHDOG_SECONDS * 1000.0):
			_fail("timed out before genuine route/action preview became ready")
			return
		var violations: Array[String] = app.model.validate_invariants()
		if not violations.is_empty():
			_fail("model invariant failure: " + "; ".join(violations))
			return
		for table_id: int in [1, 15, 19, 2]:
			if app.model.table_action(table_id) == "order": app.model.act(table_id, "order")
		if not captured and _all_arrived() and _has_eating_table() and float(app.model.tables[0].elapsed) > 0.38:
			_capture()
		if captured:
			if app.model.table_action(1) == "pay":
				paid_started = app.model.act(1, "pay")
			for member: Dictionary in app.model.table_members(1):
				if str(member.get("transition", "")) == "stand_up":
					saw_stand_up = true
			if paid_started and saw_stand_up and not app.model.customers.has(1):
				print("G11_GUI_PREVIEW_EXIT_OK paid=true stand_up=true departed=true")
				await _cleanup()
				quit(0)
				return

func _all_arrived() -> bool:
	for table_id: int in [1, 15, 19, 2]:
		var members: Array = app.model.table_members(table_id)
		var expected := 1 if table_id in [19, 2] else 3
		if members.size() != expected: return false
		for member: Dictionary in members:
			if str(member.state) != "seated" or not (member.path as Array).is_empty(): return false
	return true

func _has_eating_table() -> bool:
	for table: Dictionary in app.model.tables:
		if str(table.phase) == "eating": return true
	return false

func _capture() -> void:
	var directory := output_path.get_base_dir()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(directory)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		_fail("cannot create evidence directory: %d" % mkdir_error)
		return
	var image: Image = root.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("GUI viewport returned no pixels")
		return
	var error := image.save_png(output_path)
	if error != OK:
		_fail("cannot write PNG: %d" % error)
		return
	print("G11_GUI_PREVIEW_OK path=%s viewport=%dx%d world_width=%.1f tables=hall/private/bar/ordinary normal_routes=true" % [output_path, image.get_width(), image.get_height(), app.model.floor.layout_width])
	captured = true

func _argument(prefix: String) -> String:
	for value: String in OS.get_cmdline_user_args():
		if value.begins_with(prefix): return value.trim_prefix(prefix)
	return ""

func _insets() -> Dictionary:
	var raw := _argument("--insets=")
	var parts := raw.split(",")
	if parts.size() != 4: return {}
	return {"left": parts[0].to_float(), "right": parts[1].to_float(), "top": parts[2].to_float(), "bottom": parts[3].to_float()}

func _cleanup() -> void:
	if is_instance_valid(app) and is_instance_valid(app.music): app.music.queue_free()
	if is_instance_valid(app): app.queue_free()
	await process_frame
	app = null

func _fail(reason: String) -> void:
	push_error("G11_GUI_PREVIEW_FAILED: " + reason)
	if is_instance_valid(app): app.queue_free()
	quit(1)
