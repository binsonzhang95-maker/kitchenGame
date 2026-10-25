extends SceneTree
## Read-only snapshot validation regression; no persistent files or GUI are used.
const Model = preload("res://multi_model.gd")
const Floor = preload("res://floor_plan.gd")
const Support = preload("res://tests/multi_test_support.gd")
var failures: int = 0
var assertions: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("SNAPSHOT_GUARD_FAIL: " + message)


func _reject_unchanged(model, snapshot: Dictionary, message: String) -> void:
	var before: Dictionary = model.to_dict()
	_check(not model.restore(snapshot), message)
	_check(Support.same(model.to_dict(), before), message + " leaves current state unchanged")


func _run() -> void:
	var model = Support.controlled()
	model.spawn_customer("cat")
	model.assign_next(1)
	# Reach dirty naturally. Do not enqueue cleanup until its travel snapshot is captured.
	var dirty: bool = false
	for step: int in range(3000):
		var action: String = model.table_action(1)
		if action in ["order", "pay"]:
			model.act(1, action)
		model.tick(0.1)
		if model.tables[0].phase == "dirty":
			dirty = true
			break
	_check(dirty, "fixture completes a meal and reaches dirty table")
	if not dirty:
		_finish()
		return
	_check(model.act(1, "clean"), "cleanup task enqueued")
	var traveling: bool = false
	for step: int in range(600):
		model.tick(0.1)
		for worker: Dictionary in model.workers:
			if worker.state == "to_table" and int(worker.task_id) > 0:
				traveling = true
		if traveling:
			break
	_check(traveling, "cleanup worker enters to_table")
	var probe = Model.new()
	_check(probe.restore(model.to_dict()), "legitimate claimed cleanup traveling snapshot restores")
	var collecting: bool = Support.until(model, func() -> bool: return model.tables[0].phase == "collecting", 60.0)
	_check(collecting, "cleanup worker arrives and starts collecting")
	if not collecting:
		_finish()
		return
	model.paused = true
	var snapshot: Dictionary = model.to_dict()
	_check(probe.restore(snapshot), "legitimate collecting snapshot restores")
	var worker_id: int = int(model.tasks[0].worker_id)
	_check(worker_id >= 0 and worker_id < 2, "cleanup has a valid worker")
	if worker_id < 0 or worker_id >= 2:
		_finish()
		return
	var bad: Dictionary = snapshot.duplicate(true)
	bad.tables[0].phase = "dirty"
	_reject_unchanged(probe, bad, "working cleanup cannot restore a dirty table")
	bad = snapshot.duplicate(true)
	bad.workers[worker_id].state = "to_table"
	_reject_unchanged(probe, bad, "traveling cleanup cannot restore a collecting table")
	bad = snapshot.duplicate(true)
	bad.tables[0].phase = "dirty"
	bad.workers[worker_id].state = "to_kitchen"
	var kitchen: Vector2 = Floor.kitchen_point()
	bad.workers[worker_id].pos = [kitchen.x, kitchen.y]
	bad.workers[worker_id].path = []
	_reject_unchanged(probe, bad, "cleanup cannot use a kitchen pickup state")
	bad = snapshot.duplicate(true)
	# This zero-length path is geometrically valid but impossible once working starts.
	bad.workers[worker_id].path = [bad.workers[worker_id].pos.duplicate()]
	_reject_unchanged(probe, bad, "working worker cannot retain a movement path")
	model.paused = false
	_check(Support.until(model, func() -> bool: return model.tables[0].phase == "wiping", 5.0), "normal cleanup reaches wiping")
	_check(probe.restore(model.to_dict()), "legitimate wiping snapshot restores")
	_check(Support.until(probe, func() -> bool: return Support.all_clear(probe), 60.0), "restored wiping finishes and releases table and worker")
	_check(probe.validate_invariants().is_empty(), "restored completed cleanup remains valid")
	_finish()


func _finish() -> void:
	print("SNAPSHOT_GUARD_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)
