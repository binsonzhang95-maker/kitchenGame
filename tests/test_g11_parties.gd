extends SceneTree
const Model = preload("res://multi_model.gd")
const Support = preload("res://tests/multi_test_support.gd")
var failures := 0

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("G11_PARTY_FAIL " + message)

func _initialize() -> void:
	var model = Model.new()
	model.open_for_arrivals = false
	model.auto_dispatch = false
	model.auto_cook = false
	var empty_members: Array[Dictionary] = model.table_members(1)
	_check(empty_members.is_empty(), "empty table exposes a typed empty member list")
	var party := model.spawn_party(3, ["cat", "dog", "panda"])
	_check(party == 1 and model.customers.size() == 1, "one leader owns the group")
	_check(model.party_members(party).size() == 3, "public party view has no duplicate leader")
	_check(not model.assign_next(19), "bar rejects a three-person group")
	_check(model.table_action(19) == "", "undersized bar does not advertise assignment")
	_check(model.assign_next(1), "hall accepts party")
	for step: int in range(300):
		model.tick(0.1)
		if model.tables[0].phase == "ordering": break
	_check(model.tables[0].phase == "ordering", "all members arrive before ordering")
	var members := model.table_members(1)
	_check(members.size() == 3 and int(members[1].seat_index) == 1 and int(members[2].seat_index) == 2, "individual seats are exposed")
	var descriptor := model.party_members(party)
	descriptor[0].path.append(Vector2(1, 1))
	_check(not model.party_members(party)[0].path.has(Vector2(1, 1)), "party descriptor paths are copies")
	model.tick(0.2)
	_check(float(model.party_members(party)[0].arrival) > 0.0 and float(model.party_members(party)[1].arrival) > 0.0, "arrival clock starts only once whole group is seated")
	model.tick(0.8)
	_check(model.act(1, "order") and model.act(1, "cook"), "mixed party places one group order")
	model.tick(4.1)
	_check(model.tasks.size() == 1 and model.claim_task(0, int(model.tasks[0].id)), "food service task is claimed")
	_check(Support.until(model, func() -> bool: return model.tables[0].phase == "waiting_drink", 20.0), "one food service completes for group")
	_check(model.tasks.size() == 1 and model.claim_task(1, int(model.tasks[0].id)), "drink service task is claimed")
	_check(Support.until(model, func() -> bool: return model.tables[0].phase == "eating", 20.0), "one drink service completes for group")
	model.tick(5.1)
	model.tick(2.1)
	_check(model.table_action(1) == "pay" and model.act(1, "pay"), "mixed party checks out once")
	_check(model.coins == Model.MEAL_PRICE and model.served == 1 and model.paid_ledger.size() == 1 and not model.act(1, "pay"), "party payment settles once")
	var partial_departure: Dictionary = {}
	for step: int in range(160):
		model.tick(0.1)
		if model.customers.has(party):
			var departing_members: Array[Dictionary] = model.party_members(party)
			var departed_count := 0
			for member: Dictionary in departing_members:
				if bool(member.get("departed", false)):
					departed_count += 1
			if departed_count > 0 and departed_count < departing_members.size():
				partial_departure = model.to_dict()
				break
	_check(not partial_departure.is_empty(), "mixed party reaches a genuine partial departure")
	if not partial_departure.is_empty():
		for width: float in [1536.0, 2496.0]:
			var restored = Model.new(width)
			_check(restored.restore(partial_departure) and restored.validate_invariants().is_empty(), "partial departing party restores at width %d" % width)
	_check(Support.until(model, func() -> bool: return not model.customers.has(party), 30.0), "whole paid party exits before table release")
	_check(model.tables[0].phase == "dirty" and model.act(1, "clean") and model.claim_task(0, int(model.tasks[0].id)), "party table begins one cleanup")
	_check(Support.until(model, func() -> bool: return model.tables[0].phase == "free", 30.0), "party lifecycle reaches a reusable table")

	var cursor = Model.new()
	cursor.open_for_arrivals = false
	cursor.auto_dispatch = false
	cursor.auto_cook = false
	cursor.spawn_party(2, ["cat", "dog"])
	cursor.next_table_cursor = 18 # table 19 is a one-seat bar
	cursor.tick(0.9)
	_check(cursor.customers[1].state == "walking" and int(cursor.customers[1].table_id) == 1, "auto seat scans past undersized bars to ordinary tables")

	var atomic = Model.new()
	atomic.open_for_arrivals = false
	atomic.auto_seat = false
	var bad_party := atomic.spawn_party(2, ["cat", "dog"])
	atomic.customers[bad_party].companions[0].seat_index = 99 # fixture-only unroutable member
	var before := atomic.to_dict()
	_check(not atomic.assign_next(1) and Support.same(atomic.to_dict(), before), "unroutable member leaves assignment snapshot unchanged")
	_check(model.validate_invariants().is_empty(), "party state remains internally valid")
	print("G11_PARTIES_RESULT failures=%d" % failures)
	quit(0 if failures == 0 else 1)
