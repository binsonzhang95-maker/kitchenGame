extends SceneTree
## P0 recipe and runtime-menu contracts. Uses no save outside Godot's private test path.
const Session = preload("res://cooking_session.gd")
const Model = preload("res://multi_model.gd")
var assertions: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("P0_RECIPE_FAIL: " + label)


func _roundtrip(session, label: String) -> void:
	var encoded: String = JSON.stringify(session.to_dict())
	var decoded: Variant = JSON.parse_string(encoded)
	var restored = Session.new()
	_check(decoded is Dictionary and restored.restore(decoded), label + " JSON restores")
	_check(JSON.stringify(restored.to_dict()) == encoded, label + " JSON is exact")


func _new(recipe_id: String):
	var session = Session.new()
	_check(session.setup({"table_id": 1, "guest_id": 1, "generation": 1}, recipe_id), recipe_id + " starts")
	_roundtrip(session, recipe_id + " initial")
	return session


func _act(session, action: String) -> void:
	_check(action in session.available_actions(), str(session.recipe_id) + " exposes " + action)
	_check(session.act(action), str(session.recipe_id) + " accepts " + action)
	_roundtrip(session, str(session.recipe_id) + " after " + action)


func _finish(session) -> void:
	if session.phase == "cooking":
		session.tick(session.cook_duration())
		_roundtrip(session, str(session.recipe_id) + " ready")
	_check(session.phase == "ready", str(session.recipe_id) + " reaches ready")
	_act(session, str(Session.RECIPES[session.recipe_id].final_action))
	_check(session.completed and not session.act(str(Session.RECIPES[session.recipe_id].final_action)), str(session.recipe_id) + " completes uniquely")


func _test_sessions() -> void:
	for heat: String in Session.HEAT_LEVELS:
		var soup = _new("pumpkin_corn_soup")
		_check(not soup.act("add_mushroom") and not soup.act("pot"), "pumpkin soup rejects wrong or skipped actions")
		_act(soup, "add_corn")
		_check(not soup.act("add_corn"), "pumpkin soup rejects duplicate ingredient")
		_act(soup, "add_water")
		_act(soup, "add_pumpkin")
		_check(not soup.act("heat_high"), "pumpkin soup requires cutting and pot")
		_act(soup, "cut")
		_act(soup, "pot")
		_act(soup, "heat_" + heat)
		_finish(soup)
		var mushrooms = _new("pan_fried_mushrooms")
		_check(not mushrooms.act("cut") and not mushrooms.act("add_corn"), "mushrooms have no cut step or foreign ingredient")
		_act(mushrooms, "add_mushroom")
		_check(mushrooms.phase == "vessel" and "cut" not in mushrooms.available_actions(), "mushrooms proceed directly to pan")
		_act(mushrooms, "pan")
		_act(mushrooms, "heat_" + heat)
		_check(not mushrooms.act("stir"), "mushrooms never reuse stir as flip")
		_finish(mushrooms)
	var retry = _new("pan_fried_mushrooms")
	_act(retry, "add_mushroom")
	_act(retry, "pan")
	_act(retry, "heat_medium")
	retry.tick(retry.cook_duration() + Session.READY_WINDOW)
	_check(retry.phase == "retry", "mushrooms enter retry after ready window")
	_act(retry, "retry")
	_check(retry.ingredients == ["mushroom"] and retry.vessel == "pan" and retry.heat_level.is_empty(), "retry keeps mushroom prep")
	_act(retry, "heat_small")
	_finish(retry)
	var paused = _new("pumpkin_corn_soup")
	_act(paused, "add_pumpkin")
	paused.set_paused(true)
	_check(paused.available_actions() == ["cancel"], "pause permits only cancellation")
	_act(paused, "cancel")
	_check(paused.cancelled and paused.cancelled_from == "ingredients", "cancel records P0 unfinished step")


func _wait(model, predicate: Callable) -> bool:
	for index: int in range(900):
		if predicate.call():
			return true
		model.tick(0.1)
	return bool(predicate.call())


func _p0_model():
	var model = Model.new()
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	_check(model.set_order_menu(Model.P0_MENU), "P0 menu is accepted")
	return model


func _ordered_p0_model():
	var model = _p0_model()
	_check(model.spawn_customer("cat") > 0 and model.assign_next(1), "P0 guest is assigned")
	_check(_wait(model, func() -> bool: return model.table_action(1) == "order"), "P0 guest reaches table")
	_check(model.act(1, "order"), "P0 order opens")
	model.enable_interactive_cooking()
	return model


func _test_model_sync_and_menu() -> void:
	var model = _ordered_p0_model()
	_check(model.tables[0].recipe_id == "pumpkin_corn_soup", "P0 guest one orders pumpkin soup")
	_check(model.begin_cooking(1), "P0 cooking begins")
	var session = Session.new()
	_check(session.restore(model.active_cooking), "P0 active cooking decodes")
	for action: String in ["add_pumpkin", "add_corn", "add_water", "cut", "pot", "heat_medium"]:
		_act(session, action)
		_check(model.sync_cooking(session.to_dict(), model.cooking_session_token), "model syncs P0 step " + action)
	_finish(session)
	var token: int = model.cooking_session_token
	_check(model.complete_cooking(session.to_dict(), token), "P0 completed food queues once")
	_check(not model.complete_cooking(session.to_dict(), token) and model.tasks.size() == 1, "P0 completion cannot duplicate task")
	var menu_before: String = model.recipe_for_guest(1) + "/" + model.recipe_for_guest(2)
	_check(not model.set_order_menu([]) and not model.set_order_menu(["soup", "soup"]) and not model.set_order_menu(["unknown"]), "empty duplicate and unknown menus reject")
	_check(model.recipe_for_guest(1) + "/" + model.recipe_for_guest(2) == menu_before, "invalid menu has no side effect")
	var invalid: Dictionary = model.to_dict()
	invalid.tables[0].recipe_id = "unknown"
	_check(not model.restore(invalid), "invalid V4 restore is rejected")
	_check(model.recipe_for_guest(1) + "/" + model.recipe_for_guest(2) == menu_before, "failed restore retains explicit menu")
	var mushroom_model = _p0_model()
	_check(mushroom_model.spawn_customer("cat") > 0 and mushroom_model.assign_next(1), "mushroom fixture first guest assigned")
	_check(mushroom_model.spawn_customer("dog") > 0 and mushroom_model.assign_next(2), "mushroom fixture second guest assigned")
	_check(_wait(mushroom_model, func() -> bool: return mushroom_model.table_action(2) == "order"), "mushroom guest reaches table")
	_check(mushroom_model.act(2, "order"), "mushroom order opens")
	mushroom_model.enable_interactive_cooking()
	_check(mushroom_model.tables[1].recipe_id == "pan_fried_mushrooms" and mushroom_model.begin_cooking(2), "mushroom cooking begins")
	var mushroom_session = Session.new()
	_check(mushroom_session.restore(mushroom_model.active_cooking), "mushroom active cooking decodes")
	for action: String in ["add_mushroom", "pan", "heat_high"]:
		_act(mushroom_session, action)
		_check(mushroom_model.sync_cooking(mushroom_session.to_dict(), mushroom_model.cooking_session_token), "model syncs mushroom step " + action)
	_finish(mushroom_session)
	var mushroom_token: int = mushroom_model.cooking_session_token
	_check(mushroom_model.complete_cooking(mushroom_session.to_dict(), mushroom_token), "mushroom completion queues once")
	_check(not mushroom_model.complete_cooking(mushroom_session.to_dict(), mushroom_token) and mushroom_model.tasks.size() == 1, "mushroom completion cannot duplicate task")


func _test_historical_mapping_and_v4() -> void:
	var old = _p0_model()
	old.max_customers = 8
	for table_id: int in range(1, 9):
		_check(old.spawn_customer() > 0 and old.assign_next(table_id), "legacy fixture assigns guest " + str(table_id))
	var v3: Dictionary = old.to_dict()
	v3.version = 3
	for key: String in ["interactive_cooking", "active_cooking", "cooking_return_paused", "cooking_session_seq", "cooking_session_token"]:
		v3.erase(key)
	for table: Dictionary in v3.tables:
		table.erase("recipe_id")
	var migrated = _p0_model()
	_check(migrated.restore(v3), "V3 snapshot restores under P0 runtime menu")
	for table_id: int in range(1, 9):
		_check(migrated.tables[table_id - 1].recipe_id == Model.RECIPE_IDS[(table_id - 1) % Model.RECIPE_IDS.size()], "V3 guest keeps classic mapping " + str(table_id))
	var source = Model.new()
	source.open_for_arrivals = false
	source.auto_seat = false
	source.auto_dispatch = false
	_check(source.spawn_customer() > 0 and source.assign_next(1), "classic V4 soup fixture assigned")
	_check(_wait(source, func() -> bool: return source.table_action(1) == "order") and source.act(1, "order"), "classic V4 soup ordered")
	source.enable_interactive_cooking()
	_check(source.begin_cooking(1), "classic V4 soup has an active session")
	var target = _p0_model()
	_check(target.restore(source.to_dict()), "V4 active classic soup restores under P0")
	_check(target.tables[0].recipe_id == "soup" and target.active_cooking.recipe_id == "soup", "V4 retains stored old soup ID")
	var stir_source = Model.new()
	stir_source.open_for_arrivals = false
	stir_source.auto_seat = false
	stir_source.auto_dispatch = false
	_check(stir_source.spawn_customer() > 0 and stir_source.assign_next(1), "classic V4 stir fixture first guest assigned")
	_check(stir_source.spawn_customer() > 0 and stir_source.assign_next(2), "classic V4 stir fixture second guest assigned")
	_check(_wait(stir_source, func() -> bool: return stir_source.table_action(2) == "order") and stir_source.act(2, "order"), "classic V4 stir ordered")
	stir_source.enable_interactive_cooking()
	_check(stir_source.begin_cooking(2), "classic V4 stir has an active session")
	var stir_target = _p0_model()
	_check(stir_target.restore(stir_source.to_dict()), "V4 active classic stir restores under P0")
	_check(stir_target.tables[1].recipe_id == "stir_fry" and stir_target.active_cooking.recipe_id == "stir_fry", "V4 retains stored old stir ID")


func _run() -> void:
	_test_sessions()
	_test_model_sync_and_menu()
	_test_historical_mapping_and_v4()
	print("P0_RECIPE_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)
