extends SceneTree
## Isolated graphical check for the P0 hall dishes.  It owns no save slot and
## renders only local Model/View instances, never the player-facing main scene.

const Model = preload("res://multi_model.gd")
const HallView = preload("res://multi_view.gd")
const CAPTURE_DIR := "res://verification"

var checks := 0
var failures := 0
var finished := false
var watchdog: SceneTreeTimer


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("P0_HALL_FAIL " + message)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "requires a real Godot window")
		_finish()
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	watchdog = create_timer(30.0, true, false, true)
	watchdog.timeout.connect(func() -> void:
		_check(false, "bounded visual-test watchdog expired")
		_finish()
	)
	await _test_render_plans()
	if not finished:
		await _capture_dishes()
	if not finished:
		await _capture_place_frames("rabbit", "p0_hall_rabbit_place.png")
	if not finished:
		await _capture_place_frames("fox", "p0_hall_fox_place.png")
	_finish()


func _screen_model() -> Variant:
	var model = Model.new()
	for table: Dictionary in model.tables:
		table.center = Vector2(-3000,-3000)
		table.phase = "free"
		table.food = false
		table.drink = false
	for worker: Dictionary in model.workers:
		worker.pos = Vector2(-3000,-3000)
	model.chef.table_id = -1
	return model


func _view(model, offset: Vector2 = Vector2.ZERO) -> Variant:
	var view = HallView.new()
	view.model = model
	view.selected_table = 0
	view.position = offset
	root.add_child(view)
	await process_frame
	# The test deliberately composes its own sparse scene, not a player hall.
	view.background = null
	view.queue_redraw()
	return view


func _release_anchor(metadata: Dictionary) -> Vector2:
	var frames: Array = metadata.place_dish.frames
	var anchor: Array = frames[2].hand_anchor
	for event: Dictionary in metadata.place_dish.get("events",[]):
		var event_anchor: Array = event.get("anchor",[])
		if int(event.get("frame",-1)) == 2 and event_anchor.size() == 2:
			anchor = event_anchor
	return Vector2(anchor[0],anchor[1])


func _test_render_plans() -> void:
	var model = _screen_model()
	var table: Dictionary = model.tables[0]
	table.center = Vector2(300,500)
	var view = await _view(model)
	var expected: Dictionary = {
		"pumpkin_corn_soup":"food/dishes/pumpkin_corn_soup_32.png",
		"pan_fried_mushrooms":"food/dishes/pan_seared_mushrooms_32.png",
		"bake":"food/dishes/cheese_toast_32.png",
		"drink":"food/dishes/iced_latte_32.png",
	}
	for recipe_id: String in expected:
		table.recipe_id = recipe_id
		var plan: Dictionary = view.food_render_plan(table)
		var texture: Texture2D = load("res://assets/" + plan.texture_path)
		_check(plan.recipe_art and plan.texture_path == expected[recipe_id], recipe_id + " resolves to its shipped 32px dish")
		_check(texture != null and texture.get_size() == Vector2(32,32), recipe_id + " plan loads a real 32px texture")
		_check(plan.dish_anchor == Vector2(16,30) and plan.table_anchor == table.center + Vector2(45,-8) * view.SCALE and plan.table_origin == plan.table_anchor-plan.dish_anchor*view.SCALE, recipe_id + " uses the authored tabletop anchor")
	table.recipe_id = "soup"
	var soup_plan: Dictionary = view.food_render_plan(table)
	_check(not bool(soup_plan.recipe_art) and soup_plan.texture_path == "props/dish.png" and soup_plan.dish_anchor == Vector2(17,16), "legacy soup remains the generic dish with its original hand anchor")
	table.recipe_id = "stir_fry"
	var stir_fry_plan: Dictionary = view.food_render_plan(table)
	_check(not bool(stir_fry_plan.recipe_art) and stir_fry_plan.texture_path == "props/dish.png" and stir_fry_plan.dish_anchor == Vector2(17,16), "legacy stir_fry remains the generic dish with its original hand anchor")
	table.recipe_id = "pumpkin_corn_soup"
	var recipe_plan: Dictionary = view.food_render_plan(table)
	_check(soup_plan.table_origin+soup_plan.dish_anchor*view.SCALE == soup_plan.table_anchor and recipe_plan.table_origin+recipe_plan.dish_anchor*view.SCALE == recipe_plan.table_anchor and soup_plan.table_anchor == recipe_plan.table_anchor, "legacy generic and 32px dishes align their authored bottom anchor on the table")
	table.recipe_id = "pumpkin_corn_soup"
	table.phase = "drinking"
	var empty_plate_plan: Dictionary = view.table_food_render_plan(table)
	_check(empty_plate_plan.texture_path == "cleanup/props/empty_plate.png" and empty_plate_plan.dish_anchor == Vector2(17,16), "post-service drinking still renders the empty plate at the generic plate anchor")
	for species: String in ["rabbit","fox"]:
		var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/actions/%s/animation.json" % species))
		var frames: Array = metadata.place_dish.frames
		for frame: int in [0,1]:
			var plan: Dictionary = view.food_render_plan(table,species,0.01 if frame == 0 else 0.19)
			var authored: Array = frames[frame].hand_anchor
			_check(bool(plan.attached) and plan.hand_anchor == Vector2(authored[0],authored[1]), species + " frame %d uses its JSON hand anchor" % frame)
			var expected_handheld_origin: Vector2 = plan.table_anchor-_release_anchor(metadata)*view.SCALE+Vector2(authored[0],authored[1])*view.SCALE-plan.dish_anchor*view.SCALE
			_check(plan.handheld_origin == expected_handheld_origin and plan.handheld_origin+plan.dish_anchor*view.SCALE == plan.animation_origin+Vector2(authored[0],authored[1])*view.SCALE, species + " frame %d draws the 32px dish from its JSON hand coordinate" % frame)
		table.recipe_id = "soup"
		var legacy_handheld_plan: Dictionary = view.food_render_plan(table,species,0.01)
		var legacy_authored: Array = frames[0].hand_anchor
		var expected_legacy_origin: Vector2 = legacy_handheld_plan.table_anchor-_release_anchor(metadata)*view.SCALE+Vector2(legacy_authored[0],legacy_authored[1])*view.SCALE-Vector2(17,16)*view.SCALE
		_check(legacy_handheld_plan.dish_anchor == Vector2(17,16) and legacy_handheld_plan.handheld_origin == expected_legacy_origin, species + " keeps the generic dish at its real JSON hand coordinate")
		table.recipe_id = "pumpkin_corn_soup"
		var released: Dictionary = view.food_render_plan(table,species,0.41)
		_check(not bool(released.attached) and released.release_anchor == _release_anchor(metadata), species + " release frame leaves only the table dish")
		_check(view.action_metadata.has(species) and view.place_dish_anchor_cache.has(species), species + " action metadata and anchors are cached after first use")
		_check(bool(metadata.carry_walk.dish_baked_in), species + " carry walk is baked in, so hall adds no second dish")
	view.queue_free()
	await process_frame


func _capture_dishes() -> void:
	var model = _screen_model()
	var recipes: Array[String] = ["pumpkin_corn_soup","pan_fried_mushrooms","bake","drink"]
	for index: int in range(recipes.size()):
		var table: Dictionary = model.tables[index]
		table.center = Vector2(220 + (index % 2) * 560,380 + (index / 2) * 390)
		table.phase = "eating"
		table.recipe_id = recipes[index]
		table.food = true
	var view = await _view(model)
	await _capture("p0_hall_dishes.png")
	view.queue_free()
	await process_frame


func _place_model(species: String, elapsed: float) -> Variant:
	var model = _screen_model()
	var table: Dictionary = model.tables[0]
	table.center = Vector2(260,530)
	table.phase = "serving_food"
	table.recipe_id = "pan_fried_mushrooms"
	model.workers[0].species = species
	model.workers[0].state = "working"
	model.workers[0].task_id = 1
	model.workers[0].elapsed = elapsed
	model.tasks.append({"id":1,"table_id":1,"kind":"food"})
	return model


func _capture_place_frames(species: String, path: String) -> void:
	var first = await _view(_place_model(species,0.01))
	var second = await _view(_place_model(species,0.19),Vector2(650,0))
	await _capture(path)
	first.queue_free()
	second.queue_free()
	await process_frame


func _capture(filename: String) -> void:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	_check(directory_error == OK or directory_error == ERR_ALREADY_EXISTS, "verification directory exists")
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	var path := CAPTURE_DIR + "/" + filename
	_check(image != null and not image.is_empty() and image.save_png(path) == OK, "actual hall window capture " + filename)


func _finish() -> void:
	if finished:
		return
	finished = true
	print("P0_HALL_TEST_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
