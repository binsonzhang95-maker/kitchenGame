extends SceneTree
## Isolated headless acceptance suite. Never opens the normal player save.
const Model = preload("res://multi_model.gd")
const Floor = preload("res://floor_plan.gd")
const Support = preload("res://tests/multi_test_support.gd")
var assertions: int = 0
var failures: int = 0
var route_samples: int = 0
var started_ms: int = 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	call_deferred("_run")


func _run() -> void:
	_test_initial_capacity_and_auto_seat()
	_test_claim_and_fifo()
	_test_timeouts_and_cancellation()
	_test_pause_and_persistence()
	_test_legacy_migration()
	_test_forty_customers()
	print("MULTI_TEST_RESULT assertions=%d failures=%d route_samples=%d wall_ms=%d" % [assertions, failures, route_samples, Time.get_ticks_msec() - started_ms])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MULTI_ASSERT_FAIL " + description)


func _check_state(model, label: String, paths: bool = false) -> void:
	var errors: Array[String] = model.validate_invariants()
	_expect(errors.is_empty(), label + ": " + "; ".join(errors))
	_expect(int(model.coins) == int(model.served) * 38, label + ": revenue identity")
	var owners: Dictionary = {}
	for table: Dictionary in model.tables:
		var guest: int = int(table.guest_id)
		if guest > 0:
			_expect(not owners.has(guest), label + ": guest has exactly one reservation")
			owners[guest] = int(table.id)
	if not paths:
		return
	var actors: Array = []
	actors.append_array(model.customers.values())
	actors.append_array(model.workers)
	for actor: Dictionary in actors:
		route_samples += 1
		var previous: Vector2 = actor.pos
		_expect(Floor.is_walkable(previous), label + ": actor stays outside furniture")
		_expect(not bool(actor.route_blocked), label + ": actor has a valid destination route")
		for point: Vector2 in actor.path:
			_expect(Floor.segment_is_walkable(previous, point), label + ": entire pending path avoids furniture")
			previous = point


func _wait(model, predicate: Callable, label: String, seconds: float = 60.0) -> bool:
	var reached: bool = Support.until(model, predicate, seconds)
	_expect(reached, label)
	return reached


func _test_initial_capacity_and_auto_seat() -> void:
	var model = Support.controlled()
	_expect(model.tables.size() == 20 and model.customers.is_empty(), "construction creates 20 free tables and no guests")
	_expect(int(model.chef.table_id) == -1 and model.workers.size() == 2, "chef and two workers begin idle")
	model.max_customers = 20
	for index: int in range(8):
		_expect(model.spawn_customer() == index + 1, "queue accepts guest %d" % (index + 1))
	_expect(model.spawn_customer() == -1, "ninth guest refused by eight-place queue")
	_expect(model.customers.size() == 8 and model.queue_ids().size() == 8 and int(model.rejected) == 1, "queue refusal preserves capacity")
	for guest: Dictionary in model.customers.values():
		_expect(int(guest.table_id) == 0, "unassigned guest uses table_id zero")
	_check_state(model, "full queue", true)
	var capped = Support.controlled()
	capped.max_customers = 1
	_expect(capped.spawn_customer() > 0 and capped.spawn_customer() == -1, "active-customer cap enforced independently")
	var automatic = Support.controlled()
	automatic.auto_seat = true
	automatic.spawn_customer()
	automatic.spawn_customer()
	automatic.tick(1.2)
	_expect(automatic.queue_ids().is_empty(), "auto seating reserves separate tables")
	_expect(int(automatic.tables[0].guest_id) != int(automatic.tables[1].guest_id), "automatic reservations are unique")
	_check_state(automatic, "automatic seating", true)
	print("MULTI_CASE capacity_auto_seat PASS_IF_NO_ASSERTIONS")


func _queued_food_model(count: int = 1):
	var model = Support.controlled(false)
	var preferred: Array[int] = [20, 1, 15]
	for index: int in range(count):
		model.spawn_customer()
		model.assign_next(preferred[index])
	for step: int in range(900):
		for table: Dictionary in model.tables:
			if model.table_action(int(table.id)) == "order":
				model.act(int(table.id), "order")
		model.tick(0.1)
		if model.tasks.size() == count:
			return model
	_expect(false, "fixture queues %d food tasks" % count)
	return model


func _test_claim_and_fifo() -> void:
	var model = _queued_food_model(3)
	if model.tasks.size() != 3:
		return
	var initial_ids: Array[int] = []
	for task: Dictionary in model.tasks:
		initial_ids.append(int(task.id))
	_expect(model.claim_task(0, initial_ids[0]), "first worker wins task claim")
	_expect(not model.claim_task(1, initial_ids[0]), "second worker cannot claim the same task")
	_expect(int(model.workers[0].task_id) == initial_ids[0] and int(model.workers[1].task_id) == -1, "one task has exactly one owner")
	model.auto_dispatch = true
	model.tick(0.1)
	_expect(int(model.workers[1].task_id) == initial_ids[1], "dispatcher picks next FIFO task, independent of table ID")
	var ever_claimed: Dictionary = {}
	var previous_queued: Dictionary = {}
	for step: int in range(2400):
		for task: Dictionary in model.tasks:
			if task.state == "claimed":
				ever_claimed[int(task.id)] = true
				if previous_queued.has(int(task.id)):
					for other: Dictionary in model.tasks:
						_expect(other.state != "queued" or int(other.id) > int(task.id), "new claims do not starve older queued tasks")
		previous_queued.clear()
		for task: Dictionary in model.tasks:
			if task.state == "queued":
				previous_queued[int(task.id)] = true
		Support.manual_actions(model)
		model.tick(0.1)
		if step % 10 == 0:
			_check_state(model, "FIFO dispatch", true)
		if int(model.served) == 3 and Support.all_clear(model):
			break
	for id: int in initial_ids:
		_expect(ever_claimed.has(id), "original queued task %d is eventually served" % id)
	_expect(int(model.served) == 3 and int(model.lost) == 0 and Support.all_clear(model), "FIFO workload completes without starvation or leaked claims")
	print("MULTI_CASE claims_fifo PASS_IF_NO_ASSERTIONS")


func _test_timeouts_and_cancellation() -> void:
	var queued = Support.controlled()
	queued.spawn_customer()
	queued.tick(50.0)
	_expect(int(queued.lost) == 1 and queued.customers.is_empty() and int(queued.coins) == 0, "queued timeout departs without payment")
	_expect(Support.all_clear(queued), "queued timeout leaves every table free")
	_check_state(queued, "queue timeout", true)
	var seated = Support.controlled()
	var seated_id: int = seated.spawn_customer()
	seated.assign_next(8)
	if _wait(seated, func() -> bool: return seated.table_action(8) == "order", "guest reaches ordering"):
		seated.customers[seated_id].patience = 0.05
		seated.tick(0.1)
		_expect(int(seated.lost) == 1 and seated.tables[7].phase == "leaving", "seated timeout keeps reservation until exit")
		_wait(seated, func() -> bool: return seated.customers.is_empty(), "seated timeout reaches exit")
		_expect(seated.tables[7].phase == "dirty" and int(seated.tables[7].guest_id) == 0, "used timed-out seat needs cleanup")
		_expect(seated.act(8, "clean"), "timed-out seat can be cleaned")
		_wait(seated, func() -> bool: return Support.all_clear(seated), "cleanup releases timed-out table")
	_check_state(seated, "seated timeout", true)
	var claimed = _queued_food_model()
	if not claimed.tasks.is_empty():
		var task_id: int = int(claimed.tasks[0].id)
		var table_id: int = int(claimed.tasks[0].table_id)
		var guest_id: int = int(claimed.tasks[0].guest_id)
		_expect(claimed.claim_task(0, task_id), "timeout fixture owns a claimed service task")
		claimed.customers[guest_id].patience = 0.05
		claimed.tick(0.1)
		_expect(claimed.tasks.is_empty(), "customer timeout cancels claimed order")
		_expect(int(claimed.workers[0].task_id) == -1 and claimed.workers[0].state in ["idle", "returning"], "cancelled task releases worker ownership")
		_expect(not claimed.claim_task(1, task_id), "cancelled task cannot be reclaimed")
		_expect(not bool(claimed.tables[table_id - 1].food), "cancelled delivery cannot create food")
		_check_state(claimed, "claimed cancellation", true)
	var cooking = Support.controlled(false)
	cooking.auto_cook = false
	var cooking_id: int = cooking.spawn_customer()
	cooking.assign_next(2)
	if _wait(cooking, func() -> bool: return cooking.table_action(2) == "order", "cooking timeout fixture seated"):
		cooking.act(2, "order")
		cooking.act(2, "cook")
		cooking.tick(0.2)
		cooking.customers[cooking_id].patience = 0.05
		cooking.tick(0.1)
		_expect(int(cooking.chef.table_id) == -1 and cooking.tasks.is_empty(), "timeout cancels chef's current order")
		_check_state(cooking, "chef cancellation", true)
	print("MULTI_CASE timeout_cancellation PASS_IF_NO_ASSERTIONS")


func _test_pause_and_persistence() -> void:
	var model = Support.persistence_fixture()
	_expect(model != null, "prepare paid guest plus second claimed task fixture")
	if model == null:
		return
	_check_state(model, "claimed snapshot", true)
	var snapshot: Dictionary = model.to_dict().duplicate(true)
	model.tick(100.0)
	_expect(model.spawn_customer() == -1, "pause prevents arrivals")
	_expect(not model.claim_task(0, int(model.tasks[0].id)), "pause prevents task claims")
	_expect(not model.act(20, "pay"), "pause prevents actions")
	_expect(Support.same(model.to_dict(), snapshot), "pause freezes entire model and pending routes")
	var restored = Model.new()
	_expect(restored.restore(snapshot), "V2 accepts full claimed snapshot")
	_expect(Support.same(restored.to_dict(), snapshot), "V2 round-trip retains complete state")
	_expect(int(restored.workers[1].task_id) == int(restored.tasks[0].id), "restored worker retains exact task ownership")
	var before: Dictionary = restored.to_dict().duplicate(true)
	var bad: Dictionary = before.duplicate(true)
	bad.tables[0].guest_id = bad.tables[19].guest_id
	_expect(not restored.restore(bad), "duplicate table reservation is rejected")
	_expect(Support.same(restored.to_dict(), before), "failed restore is atomic")
	var slot: String = "user://multi_test_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	if FileAccess.file_exists(slot) or FileAccess.file_exists(slot + ".tmp"):
		_expect(false, "unique disposable save path has no collision")
		return
	_expect(model.save_to(slot) == OK, "save complete V2 state to private slot")
	var loaded = Model.new()
	_expect(loaded.load_from(slot), "read private V2 slot")
	_expect(Support.same(loaded.to_dict(), snapshot), "disk round-trip preserves claimed routes, flags, clocks, and ledgers")
	for suffix: String in ["", ".tmp"]:
		if FileAccess.file_exists(slot + suffix):
			_expect(DirAccess.remove_absolute(ProjectSettings.globalize_path(slot + suffix)) == OK, "remove only private test slot")
	loaded.paused = false
	loaded.auto_dispatch = true
	var clock_before: float = float(loaded.clock)
	loaded.tick(0.1)
	_expect(float(loaded.clock) > clock_before, "restored paused state can resume")
	for step: int in range(2400):
		Support.manual_actions(loaded)
		loaded.tick(0.1)
		if int(loaded.served) == 2 and Support.all_clear(loaded):
			break
	_expect(int(loaded.coins) == 76 and int(loaded.served) == 2 and Support.all_clear(loaded), "restored claimed task finishes exactly once")
	_check_state(loaded, "restored completion", true)
	print("MULTI_CASE pause_v2_persistence PASS_IF_NO_ASSERTIONS")


func _test_legacy_migration() -> void:
	var model = Model.new()
	var legacy: Dictionary = {"version": 1, "phase": "ready_next", "coins": 76, "served": 2, "lost": 1, "customer_id": 3, "paused": false, "elapsed": 0.0, "patience": 60.0, "paid": false, "food_delivered": false, "drink_delivered": false, "table_used": false, "dishes_collected": true}
	_expect(model.restore(legacy), "clean completed V1 snapshot migrates")
	_expect(int(model.coins) == 76 and int(model.served) == 2 and int(model.lost) == 1, "V1 statistics preserved")
	_expect(int(model.next_customer_id) == 4 and Support.all_clear(model), "V1 migration opens clean 20-table state")
	_check_state(model, "V1 migrated", true)
	var before: Dictionary = model.to_dict().duplicate(true)
	legacy.phase = "eating"
	_expect(not model.restore(legacy), "mid-service V1 snapshot explicitly rejected")
	_expect(Support.same(model.to_dict(), before), "rejected V1 snapshot leaves current state unchanged")
	legacy.phase = "ready_next"
	legacy.coins = 77
	_expect(not model.restore(legacy), "invalid legacy revenue rejected")
	print("MULTI_CASE legacy_migration PASS_IF_NO_ASSERTIONS")


func _test_forty_customers() -> void:
	var failures_before: int = failures
	var model = Support.controlled()
	model.auto_seat = true
	model.max_customers = 6
	var created: int = 0
	var covered_tables: Dictionary = {}
	var covered_species: Dictionary = {}
	var released_tables: Dictionary = {}
	var previous_phases: Dictionary = {}
	var completed: bool = false
	for step: int in range(30000):
		while created < 40 and model.customers.size() < 6:
			var id: int = model.spawn_customer()
			if id < 1:
				_expect(false, "refill accepts customer while below six-person cap")
				break
			created += 1
			covered_species[str(model.customers[id].species)] = true
		for table: Dictionary in model.tables:
			var table_id: int = int(table.id)
			if int(table.guest_id) > 0:
				covered_tables[table_id] = true
			if table.phase == "free" and previous_phases.get(table_id, "free") == "wiping":
				released_tables[table_id] = true
			previous_phases[table_id] = str(table.phase)
			var action: String = str(model.table_action(table_id))
			if action in ["order", "pay", "clean"]:
				var coins_before: int = int(model.coins)
				_expect(model.act(table_id, action), "manual %s accepted at table %d" % [action, table_id])
				_expect(not model.act(table_id, action), "duplicate %s rejected at table %d" % [action, table_id])
				if action == "pay":
					for repeat: int in range(8):
						_expect(not model.act(table_id, "pay"), "payment burst cannot pay twice")
					_expect(int(model.coins) == coins_before + 38, "one guest pays exactly 38")
		model.tick(0.1)
		_check_state(model, "40-guest run step %d" % step, step % 10 == 0)
		if failures > failures_before:
			break
		if created == 40 and int(model.served) == 40 and Support.all_clear(model):
			# Observe the final wipe-to-free transition after this tick too.
			for table: Dictionary in model.tables:
				if table.phase == "free" and previous_phases.get(int(table.id), "free") == "wiping":
					released_tables[int(table.id)] = true
			completed = true
			break
		if Time.get_ticks_msec() - started_ms > 180000:
			_expect(false, "180-second wall-clock watchdog")
			break
	_expect(completed and created == 40, "forty customers complete with six-person concurrency")
	_expect(int(model.served) == 40 and int(model.lost) == 0 and int(model.coins) == 1520, "forty payments total 1520 without loss")
	_expect(covered_tables.size() == 20, "all twenty tables receive reservations")
	_expect(released_tables.size() == 20, "all twenty tables complete cleanup and release")
	_expect(covered_species.size() == 17, "all seventeen customer species participate")
	_expect(Support.all_clear(model), "no task, worker, guest or table leaks after full run")
	print("MULTI_40_GUESTS served=%d lost=%d coins=%d tables=%d released=%d species=%d simulation_seconds=%.2f" % [int(model.served), int(model.lost), int(model.coins), covered_tables.size(), released_tables.size(), covered_species.size(), float(model.clock)])
