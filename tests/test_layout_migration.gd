extends SceneTree
## Synthetic snapshots from frozen pre-visual V2 code. Never opens player files.
const Model = preload("res://multi_model.gd")
const Floor = preload("res://floor_plan.gd")
const OldModel = preload("res://tests/fixtures/legacy_v2_model.gd")
const OldFloor = preload("res://tests/fixtures/legacy_v2_floor.gd")
const Support = preload("res://tests/multi_test_support.gd")
var failures: int = 0
var assertions: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("LAYOUT_MIGRATION_FAIL: " + message)


func _old_model():
	var model = OldModel.new()
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	model.auto_cook = false
	return model


func _until(model, predicate: Callable, seconds: float = 90.0) -> bool:
	for step: int in range(ceili(seconds / 0.1)):
		if predicate.call():
			return true
		model.tick(0.1)
	return bool(predicate.call())


func _semantic(snapshot: Dictionary) -> Dictionary:
	var result: Dictionary = snapshot.duplicate(true)
	result.erase("version")
	# V2/V3 did not contain an interactive kitchen. Normalize only absent new
	# metadata to its required V4 defaults; never erase values from the result.
	# A non-default session, policy, token or return-pause would still fail.
	var defaults: Dictionary = {"interactive_cooking": false, "active_cooking": {}, "cooking_return_paused": false, "cooking_session_seq": 0, "cooking_session_token": 0}
	for key: String in defaults:
		if not result.has(key): result[key] = defaults[key]
	var recipes: Array[String] = ["soup", "stir_fry", "bake", "drink"]
	for table: Dictionary in result.tables:
		table.erase("center")
		if not table.has("recipe_id"):
			# Old saves had no recipes. Occupied tables get the guest's stable
			# recipe; departed cleaning tables get an unused table-ID placeholder.
			var identity: int = int(table.guest_id) if int(table.guest_id) > 0 else int(table.id)
			table.recipe_id = "" if table.phase == "free" else recipes[(identity - 1) % recipes.size()]
	for guest: Dictionary in result.customers.values():
		for key: String in ["pos", "path", "route_blocked"]:
			guest.erase(key)
	for worker: Dictionary in result.workers:
		for key: String in ["pos", "path", "route_blocked"]:
			worker.erase(key)
	return result


func _migrate(old, label: String):
	_check(old.validate_invariants().is_empty(), label + " fixture is valid on the old floor")
	var source: Dictionary = old.to_dict()
	_check(int(source.version) == 2, label + " fixture is genuinely V2")
	var before: Dictionary = source.duplicate(true)
	var serialized: Dictionary = JSON.parse_string(JSON.stringify(source))
	var serialized_before: Dictionary = serialized.duplicate(true)
	var result = Model.new()
	var accepted: bool = result.restore(serialized)
	_check(accepted, label + " migration accepts legitimate V2 snapshot")
	if not accepted:
		return null
	_check(Support.same(source, before), label + " source snapshot is unchanged")
	_check(Support.same(serialized, serialized_before), label + " caller's decoded V2 dictionary is unchanged")
	_check(int(result.to_dict().version) == 4, label + " output schema is explicitly V4")
	_check(Support.same(_semantic(result.to_dict()), _semantic(source)), label + " business state, timers, patience and claims are unchanged")
	_check(result.validate_invariants().is_empty(), label + " relocated actors and task references are valid")
	for table: Dictionary in result.tables:
		_check((table.center as Vector2).is_equal_approx(Floor.table_center(int(table.id))), label + " table uses new canonical center")
	var reopened = Model.new()
	_check(reopened.restore(JSON.parse_string(JSON.stringify(result.to_dict()))), label + " migrated V4 snapshot reopens")
	_check(Support.same(reopened.to_dict(), result.to_dict()), label + " V4 reopen never reruns layout migration")
	return result


func _finish(model, expected_coins: int) -> void:
	model.paused = false
	model.auto_dispatch = true
	model.auto_cook = true
	for step: int in range(3000):
		Support.manual_actions(model)
		model.tick(0.1)
		if Support.all_clear(model):
			break
	_check(Support.all_clear(model), "migrated workload eventually releases every table/task/worker")
	_check(model.coins == expected_coins, "migrated workload pays the expected amount exactly once")
	_check(model.validate_invariants().is_empty(), "completed migrated workload remains valid")


func _run() -> void:
	_check(Model.SAVE_VERSION == 4, "current schema includes the new layout and interactive kitchen")
	_check(Floor.SIZE == Vector2(1536, 1024), "new floor dimensions are active")
	_check(Floor.table_center(1) != OldFloor.table_center(1), "fixtures use a distinct old layout")
	_test_queue_walking_and_cooking()
	_test_unseated_departures()
	_test_service_claims()
	_test_paid_and_cleaning()
	_test_rejections_and_v1()
	print("LAYOUT_MIGRATION_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _test_queue_walking_and_cooking() -> void:
	var queued = _old_model()
	queued.spawn_customer("cat")
	queued.spawn_customer("dog")
	queued.tick(0.2)
	queued.paused = true
	var migrated = _migrate(queued, "queued paused guests")
	if migrated != null:
		_check(migrated.paused and migrated.queue_ids().size() == 2, "queued pause and ordering survive")
		for index: int in range(2):
			_check((migrated.customers[index + 1].pos as Vector2).is_equal_approx(Floor.queue_point(index)), "queued guest is at new queue anchor")
	var walking = _old_model()
	walking.spawn_customer("panda")
	walking.assign_next(20)
	walking.tick(0.3)
	migrated = _migrate(walking, "reserved walking guest")
	if migrated != null:
		_check(migrated.customers[1].state == "walking" and migrated.tables[19].phase == "reserved", "walking reservation is not released")
		_check((migrated.customers[1].pos as Vector2).is_equal_approx(Floor.entrance_point()), "walking route restarts at new entrance")
	_check(_until(walking, func() -> bool: return walking.table_action(20) == "order"), "old guest reaches seated ordering")
	_migrate(walking, "seated ordering guest")
	walking.act(20, "order")
	walking.act(20, "cook")
	walking.tick(1.2)
	migrated = _migrate(walking, "partially cooked order")
	if migrated != null:
		_check(migrated.chef.table_id == 20 and is_equal_approx(migrated.chef.elapsed, walking.chef.elapsed), "chef ownership and elapsed cooking time survive")
		_finish(migrated, 38)


func _food_fixture():
	var model = _old_model()
	model.spawn_customer("cat")
	model.assign_next(20)
	if not _until(model, func() -> bool: return model.table_action(20) == "order"):
		_check(false, "food fixture reaches ordering")
		return null
	model.act(20, "order")
	model.act(20, "cook")
	model.tick(4.2)
	_check(model.tasks.size() == 1 and model.tables[19].phase == "food_ready", "old food task is queued")
	return model


func _test_unseated_departures() -> void:
	for reserve: bool in [false, true]:
		var old = _old_model()
		old.spawn_customer("dog")
		if reserve:
			old.assign_next(20)
			old.tick(0.3)
		old.customers[1].patience = 0.05
		old.tick(0.1)
		_check(old.customers.has(1) and old.customers[1].state == "leaving", "unseated timeout is captured before exit")
		var migrated = _migrate(old, "unseated departure reserved=%s" % str(reserve))
		if migrated != null:
			_check(migrated.lost == 1 and not migrated.customers[1].paid, "timeout reason survives migration")
			if reserve:
				_check(not migrated.tables[19].used and migrated.tables[19].phase == "leaving", "unused reservation is retained until exit")
			_finish(migrated, 0)


func _test_service_claims() -> void:
	var old = _food_fixture()
	if old == null or old.tasks.is_empty():
		return
	_migrate(old, "queued food task")
	_check(old.claim_task(1, int(old.tasks[0].id)), "fox claims old food task")
	_migrate(old, "claimed food to kitchen")
	_check(_until(old, func() -> bool: return old.workers[1].state == "to_table"), "old worker picks up food")
	_migrate(old, "claimed food traveling to table")
	_check(_until(old, func() -> bool: return old.workers[1].state == "working"), "old worker arrives at service point")
	old.tick(0.2)
	var migrated = _migrate(old, "claimed food partially placed")
	if migrated != null:
		_check(migrated.workers[1].path.is_empty() and (migrated.workers[1].pos as Vector2).is_equal_approx(Floor.service_point(20)), "working worker stays at the new service point")
		_finish(migrated, 38)
	_check(_until(old, func() -> bool: return old.workers[1].state == "returning"), "old worker completes food delivery")
	_migrate(old, "returning worker and queued drink")
	old.auto_dispatch = true
	_check(_until(old, func() -> bool: return old.tables[19].phase == "eating"), "old drink delivery completes")
	_migrate(old, "seated eating guest")
	_check(_until(old, func() -> bool: return old.tables[19].phase == "drinking"), "old guest starts drinking")
	_migrate(old, "seated drinking guest")


func _test_paid_and_cleaning() -> void:
	var old = _food_fixture()
	if old == null:
		return
	old.auto_dispatch = true
	_check(_until(old, func() -> bool: return old.tables[19].phase == "checkout", 120.0), "old guest reaches checkout")
	_migrate(old, "unpaid checkout")
	_check(old.act(20, "pay"), "old checkout pays once")
	var paid = _migrate(old, "paid guest leaving")
	if paid != null:
		_check(not paid.act(20, "pay") and paid.coins == 38, "migration cannot duplicate a paid checkout")
		_finish(paid, 38)
	_check(_until(old, func() -> bool: return old.tables[19].phase == "dirty"), "old paid guest exits")
	old.auto_dispatch = false
	_migrate(old, "dirty table after paid departure")
	_check(old.act(20, "clean"), "old cleanup is queued")
	_migrate(old, "queued cleanup")
	_check(_until(old, func() -> bool: return old.workers[0].state == "idle"), "rabbit is available for cleanup")
	_check(old.claim_task(0, int(old.tasks[0].id)), "rabbit claims cleanup")
	_migrate(old, "claimed cleanup traveling")
	_check(_until(old, func() -> bool: return old.tables[19].phase == "collecting"), "old cleanup starts collecting")
	old.tick(0.2)
	var collecting = _migrate(old, "partially collected dishes")
	if collecting != null:
		_finish(collecting, 38)
	_check(_until(old, func() -> bool: return old.tables[19].phase == "wiping"), "old cleanup starts wiping")
	var wiping = _migrate(old, "partially wiped table")
	if wiping != null:
		_finish(wiping, 38)


func _test_rejections_and_v1() -> void:
	var old = _old_model()
	old.spawn_customer("cat")
	var target = Model.new()
	var before: Dictionary = target.to_dict()
	var wrong_centers: Dictionary = old.to_dict()
	wrong_centers.tables[0].center = [0.0, 0.0]
	_check(not target.restore(wrong_centers), "V2 source must have the actual old canonical table layout")
	_check(Support.same(target.to_dict(), before), "rejected migration leaves current model unchanged")
	var wrong_claim: Dictionary = old.to_dict()
	wrong_claim.workers[0].state = "working"
	wrong_claim.workers[0].task_id = 900
	_check(not target.restore(wrong_claim), "migration rejects missing worker task instead of dropping it")
	_check(Support.same(target.to_dict(), before), "invalid claim migration is atomic")
	var mislabeled: Dictionary = old.to_dict()
	mislabeled.version = 3
	_check(not target.restore(mislabeled), "V3 never silently treats legacy geometry as V2")
	var legacy: Dictionary = {"version": 1, "phase": "ready_next", "coins": 76, "served": 2, "lost": 1, "customer_id": 3, "paused": true}
	_check(target.restore(legacy), "existing completed V1 migration remains supported")
	_check(target.coins == 76 and target.served == 2 and target.lost == 1 and target.paused, "V1 statistics and pause survive")
	_check(int(target.to_dict().version) == 4, "V1 migration now writes V4")
	before = target.to_dict()
	legacy.phase = "eating"
	_check(not target.restore(legacy) and Support.same(target.to_dict(), before), "mid-service V1 remains explicitly rejected")
