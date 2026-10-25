extends SceneTree
## Isolated model/session contract checks. This test never opens the normal save.
const Model = preload("res://multi_model.gd")
const Session = preload("res://cooking_session.gd")
const Support = preload("res://tests/multi_test_support.gd")
const CROSS_SAVE := "user://cooking_cross_process_test_v4.json"
var assertions: int = 0
var failures: int = 0
var completed_sections: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(ok: bool, description: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		printerr("COOKING_INTEGRATION_FAIL: " + description)

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if "--write-cooking-checkpoint" in args:
		_write_checkpoint()
	elif "--read-cooking-checkpoint" in args:
		_read_checkpoint()
	else:
		_test_policy_and_freeze()
		_test_binding_cancel_and_replay()
		_test_all_recipes_and_service()
		_test_atomic_restore_and_legacy()
		_test_private_file_roundtrip()
		_expect(completed_sections == 5, "every integration section completed")
	print("COOKING_INTEGRATION_RESULT assertions=%d failures=%d sections=%d" % [assertions, failures, completed_sections])
	quit(0 if failures == 0 else 1)

func _wait(model, predicate: Callable, seconds: float = 60.0) -> bool:
	for index: int in range(int(seconds / 0.1)):
		if predicate.call(): return true
		model.tick(0.1)
	return bool(predicate.call())

func _ordered_model(recipe_index: int = 0):
	var model = Model.new()
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	for index: int in range(recipe_index + 1):
		_expect(model.spawn_customer() > 0, "fixture customer spawned")
		_expect(model.assign_next(index + 1), "fixture table reserved")
	var table_id: int = recipe_index + 1
	_expect(_wait(model, func() -> bool: return model.table_action(table_id) == "order"), "fixture reaches real seated ordering")
	_expect(model.act(table_id, "order"), "real order accepted")
	model.enable_interactive_cooking()
	_expect(model.tables[table_id - 1].recipe_id == Model.RECIPE_IDS[recipe_index], "four recipes rotate by guest identity")
	_expect(model.validate_invariants().is_empty(), "ordered fixture invariants")
	return model

func _session(model):
	var session = Session.new()
	_expect(session.restore(model.active_cooking), "active session decodes")
	return session

func _finish_recipe(session) -> void:
	var actions: Array = {
		"soup": ["add_potato", "add_carrot", "add_water", "cut", "pot", "heat_medium"],
		"stir_fry": ["add_egg", "add_tomato", "cut", "pan", "heat_medium"],
		"bake": ["add_bread", "add_cheese", "oven"],
		"drink": ["add_coffee", "add_milk", "add_ice"],
	}[session.recipe_id]
	for action: String in actions:
		if action in session.available_actions():
			_expect(session.act(action), "recipe action " + action)
	if session.phase == "cooking": session.tick(session.cook_duration() + 0.25)
	_expect(session.phase == "ready", "recipe waits for explicit finish")
	var finish: String = "finish" if session.recipe_id == "soup" else ("takeout" if session.recipe_id == "bake" else "stir")
	_expect(session.act(finish) and session.completed, "explicit recipe completion")

func _test_policy_and_freeze() -> void:
	var legacy = Model.new()
	_expect(not legacy.interactive_cooking, "pure model defaults to legacy policy")
	var model = _ordered_model()
	model.auto_cook = true
	model.tick(5.0)
	_expect(not model.auto_cook and model.tables[0].phase == "awaiting_cook" and model.tasks.is_empty(), "interactive policy rejects timer cooking")
	_expect(not model.cook_next() and not model.act(1, "cook"), "legacy cook entry points disabled")
	_expect(model.begin_cooking(1), "begin kitchen")
	var before: Dictionary = model.to_dict()
	model.tick(80.0)
	_expect(model.to_dict() == before, "business entirely frozen during cooking")
	var session = _session(model)
	_expect(session.act("add_potato"), "add ingredient during business pause")
	session.set_paused(true)
	var paused: Dictionary = session.to_dict()
	session.tick(25.0)
	_expect(session.to_dict() == paused, "kitchen pause independent of frozen business")
	_expect(model.sync_cooking(session.to_dict(), model.cooking_session_token), "paused session sync")
	_expect(model.cancel_cooking(model.cooking_session_token) and not model.paused, "cancel restores original running state")
	model.paused = true
	_expect(model.begin_cooking(1), "begin from an already paused business")
	_expect(model.cancel_cooking(model.cooking_session_token) and model.paused, "cancel restores original paused state")
	completed_sections += 1

func _test_binding_cancel_and_replay() -> void:
	var model = _ordered_model()
	_expect(model.begin_cooking(1), "start bound session")
	var old_token: int = model.cooking_session_token
	var old_session = _session(model)
	_finish_recipe(old_session)
	var finished: Dictionary = old_session.to_dict()
	_expect(model.cancel_cooking(old_token), "cancel leaves order intact")
	_expect(model.tables[0].phase == "awaiting_cook" and not model.tables[0].food and model.coins == 0 and model.tasks.is_empty(), "cancel creates no meal, task or money")
	_expect(model.begin_cooking(1), "same order can restart")
	_expect(model.cooking_session_token > old_token, "restart creates fresh persistent token")
	var state: Dictionary = model.to_dict()
	_expect(not model.complete_cooking(finished, old_token), "stale completion cannot finish restarted order")
	_expect(not model.sync_cooking(finished, old_token) and not model.cancel_cooking(old_token), "stale sync/cancel rejected")
	_expect(model.to_dict() == state, "stale callbacks do not mutate state")
	var wrong: Dictionary = finished.duplicate(true)
	wrong.binding.generation = int(wrong.binding.generation) + 1
	_expect(not model.complete_cooking(wrong, model.cooking_session_token), "wrong occupancy generation rejected")
	wrong = finished.duplicate(true)
	wrong.binding.guest_id = int(wrong.binding.guest_id) + 1
	_expect(not model.complete_cooking(wrong, model.cooking_session_token), "wrong customer rejected")
	wrong = finished.duplicate(true)
	wrong.binding.table_id = 2
	_expect(not model.complete_cooking(wrong, model.cooking_session_token), "wrong table rejected")
	var session = _session(model)
	_finish_recipe(session)
	var token: int = model.cooking_session_token
	_expect(model.complete_cooking(session.to_dict(), token), "current valid session completes")
	for index: int in range(8):
		_expect(not model.complete_cooking(session.to_dict(), token), "repeated completion rejected")
	_expect(model.tasks.size() == 1 and model.tasks[0].kind == "food" and model.coins == 0, "exactly one food task and no premature payment")
	_expect(model.validate_invariants().is_empty(), "completion preserves model invariants")
	completed_sections += 1

func _test_all_recipes_and_service() -> void:
	for recipe_index: int in range(4):
		var model = _ordered_model(recipe_index)
		var table_id: int = recipe_index + 1
		_expect(model.begin_cooking(table_id), "begin each recipe")
		var session = _session(model)
		_finish_recipe(session)
		_expect(model.complete_cooking(session.to_dict(), model.cooking_session_token), "each recipe queues its own meal")
		_expect(model.tables[table_id-1].phase == "food_ready" and model.tasks.size() == 1, "food ready only after explicit completion")
		_expect(model.validate_invariants().is_empty(), "each recipe invariant check")
	var restaurant = _ordered_model()
	restaurant.max_customers = 1
	_expect(restaurant.begin_cooking(1), "start full service order")
	var meal = _session(restaurant)
	_finish_recipe(meal)
	_expect(restaurant.complete_cooking(meal.to_dict(), restaurant.cooking_session_token), "release complete meal")
	restaurant.enable_player_mode()
	_expect(_wait(restaurant, func() -> bool: return restaurant.served == 1 and restaurant.tables[0].phase == "free", 90.0), "automatic food, drink, payment, departure and cleanup")
	_expect(restaurant.coins == 38 and restaurant.paid_ledger.size() == 1, "one guest paid exactly once")
	_expect(restaurant.validate_invariants().is_empty(), "service closed loop invariants")
	completed_sections += 1

func _test_atomic_restore_and_legacy() -> void:
	var model = _ordered_model()
	_expect(model.begin_cooking(1), "start persistence session")
	var session = _session(model)
	_expect(session.act("add_potato") and session.act("add_water"), "partial cooking state")
	session.set_paused(true)
	_expect(model.sync_cooking(session.to_dict(), model.cooking_session_token), "sync partial paused state")
	var valid: Dictionary = model.to_dict()
	var restored = Model.new()
	_expect(restored.restore(valid), "schema4 active session restore")
	_expect(restored.to_dict() == valid and restored.paused, "snapshot roundtrip preserves all business and kitchen state")
	var tampered: Array[Dictionary] = []
	var bad: Dictionary = valid.duplicate(true)
	bad.active_cooking.binding.generation += 1
	tampered.append(bad)
	bad = valid.duplicate(true)
	bad.paused = false
	tampered.append(bad)
	bad = valid.duplicate(true)
	bad.cooking_session_token = 0
	tampered.append(bad)
	bad = valid.duplicate(true)
	bad.tables[0].recipe_id = "unknown"
	tampered.append(bad)
	bad = valid.duplicate(true)
	bad.version = 3
	tampered.append(bad)
	for snapshot: Dictionary in tampered:
		var before: Dictionary = restored.to_dict()
		_expect(not restored.restore(snapshot), "malformed or downgraded cooking save rejected")
		_expect(restored.to_dict() == before, "invalid restore is atomic")
	var legacy_model = _ordered_model()
	legacy_model.interactive_cooking = false
	_expect(legacy_model.act(1, "cook"), "legacy automatic cook fixture")
	var legacy_v3: Dictionary = legacy_model.to_dict()
	legacy_v3.version = 3
	for key: String in ["interactive_cooking", "active_cooking", "cooking_return_paused", "cooking_session_seq", "cooking_session_token"]:
		legacy_v3.erase(key)
	for table: Dictionary in legacy_v3.tables: table.erase("recipe_id")
	var migrated = Model.new()
	_expect(migrated.restore(legacy_v3), "real V3 schema loads")
	migrated.enable_interactive_cooking()
	_expect(migrated.tables[0].phase == "awaiting_cook" and int(migrated.chef.table_id) == -1 and not migrated.auto_cook, "legacy active timer becomes an uncompleted interactive order")
	_expect(migrated.coins == legacy_model.coins and migrated.customers == legacy_model.customers, "V3 preserves economy and customers")
	_expect(migrated.validate_invariants().is_empty(), "migrated model valid")
	completed_sections += 1

func _test_private_file_roundtrip() -> void:
	var path: String = "user://cooking_integration_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var model = _ordered_model(2)
	_expect(model.begin_cooking(3), "start file checkpoint")
	var session = _session(model)
	_expect(session.act("add_bread") and session.act("add_cheese") and session.act("oven"), "bake checkpoint preparation")
	session.tick(2.0)
	session.set_paused(true)
	_expect(model.sync_cooking(session.to_dict(), model.cooking_session_token), "sync baking progress")
	_expect(model.save_to(path) == OK, "write private checkpoint")
	var loaded = Model.new()
	_expect(loaded.load_from(path), "load private checkpoint")
	if not Support.same(loaded.to_dict(), model.to_dict()):
		var differences: Array[String] = []
		_snapshot_differences(model.to_dict(), loaded.to_dict(), "save", differences)
		for difference: String in differences:
			printerr("COOKING_ROUNDTRIP_DIFF: " + difference)
	_expect(Support.same(loaded.to_dict(), model.to_dict()), "file roundtrip includes every field, allowing only JSON float roundoff")
	for key: String in ["version", "attempts"]:
		_expect(typeof(loaded.active_cooking[key]) == TYPE_INT, "restored session counter has integer type: " + key)
	for key: String in ["table_id", "guest_id", "generation"]:
		_expect(typeof(loaded.active_cooking.binding[key]) == TYPE_INT, "restored binding has integer type: " + key)
	var resumed_session = _session(loaded)
	_expect(loaded.sync_cooking(resumed_session.to_dict(), loaded.cooking_session_token), "restored live session can sync and save again")
	_expect(loaded.save_to(path) == OK, "restored session writes a healthy second checkpoint")
	_expect(DirAccess.remove_absolute(path) == OK, "remove private test save")
	completed_sections += 1

func _snapshot_differences(before: Variant, after: Variant, path: String, differences: Array[String]) -> void:
	if differences.size() >= 20: return
	if before is Dictionary and after is Dictionary:
		for key: Variant in before:
			if not after.has(key):
				differences.append(path + "." + str(key) + " missing")
			else:
				_snapshot_differences(before[key], after[key], path + "." + str(key), differences)
		for key: Variant in after:
			if not before.has(key): differences.append(path + "." + str(key) + " added")
	elif before is Array and after is Array:
		if before.size() != after.size(): differences.append(path + " array size changed")
		for index: int in range(mini(before.size(), after.size())):
			_snapshot_differences(before[index], after[index], path + "[%d]" % index, differences)
	elif before != after or typeof(before) != typeof(after):
		var left: String = String.num(before, 17) if before is float else str(before)
		var right: String = String.num(after, 17) if after is float else str(after)
		differences.append("%s: %s (%d) -> %s (%d)" % [path, left, typeof(before), right, typeof(after)])

func _write_checkpoint() -> void:
	var model = _ordered_model(2)
	_expect(model.begin_cooking(3), "cross-process begin")
	var session = _session(model)
	_expect(session.act("add_bread") and session.act("add_cheese") and session.act("oven"), "cross-process baking actions")
	session.tick(2.0)
	session.set_paused(true)
	_expect(model.sync_cooking(session.to_dict(), model.cooking_session_token), "cross-process sync")
	_expect(model.save_to(CROSS_SAVE) == OK, "cross-process private file written")

func _read_checkpoint() -> void:
	var model = Model.new()
	_expect(model.load_from(CROSS_SAVE), "second process loads private checkpoint")
	var session = _session(model)
	_expect(session.recipe_id == "bake" and session.phase == "cooking" and session.paused and is_equal_approx(session.elapsed, 2.0), "second process restores exact kitchen checkpoint")
	session.set_paused(false)
	_finish_recipe(session)
	var token: int = model.cooking_session_token
	_expect(model.complete_cooking(session.to_dict(), token), "second process completes restored recipe")
	_expect(not model.complete_cooking(session.to_dict(), token) and model.tasks.size() == 1, "second process blocks repeat completion")
	_expect(DirAccess.remove_absolute(CROSS_SAVE) == OK, "remove cross-process test file")
