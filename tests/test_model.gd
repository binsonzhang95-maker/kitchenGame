extends SceneTree
## Run only after Godot execution is authorized:
## godot --headless --path <project> --script res://tests/test_model.gd

const Model = preload("res://game_model.gd")
var failures: int = 0
var assertions: int = 0


func _initialize() -> void:
	_test_two_customers()
	_test_pause_and_invalid_actions()
	_test_pause_resume_timer()
	_test_timeouts()
	_test_next_customer_after_timeout()
	_test_restore_validation()
	_test_all_phase_snapshots()
	_test_disk_round_trip()
	print("MODEL_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + description)


func _perform(model, action: String, next_phase: String) -> void:
	_expect(model.advance(action), action + " accepted")
	_expect(model.phase == next_phase, action + " enters " + next_phase)
	_expect(not model.advance(action), action + " duplicate rejected")


func _to_checkout(model) -> void:
	model.tick(2.0)
	_expect(model.phase == "queued", "arrival reaches queue")
	_perform(model, "seat", "seating")
	model.tick(1.5)
	_perform(model, "order", "awaiting_cook")
	_perform(model, "cook", "cooking")
	model.tick(4.0)
	_perform(model, "serve_food", "serving_food")
	model.tick(3.0)
	_expect(model.food_delivered, "food marked delivered")
	_perform(model, "serve_drink", "serving_drink")
	model.tick(3.0)
	_expect(model.drink_delivered, "drink marked delivered")
	model.tick(5.0)
	_expect(model.phase == "drinking", "eating reaches drinking")
	model.tick(2.4)
	_expect(model.phase == "checkout", "drinking reaches checkout")


func _finish_cleaning(model) -> void:
	model.tick(2.0)
	_expect(model.phase == "dirty", "used table requires cleanup")
	_expect(not model.advance("next"), "dirty table blocks next guest")
	_perform(model, "clean", "collecting")
	model.tick(1.6)
	_expect(model.phase == "wiping" and model.dishes_collected, "collect completes before wipe")
	model.tick(1.6)
	_expect(model.phase == "ready_next" and not model.table_used, "wipe frees table")


func _test_two_customers() -> void:
	var model = Model.new()
	for guest: int in range(2):
		_to_checkout(model)
		_perform(model, "pay", "leaving")
		_expect(model.coins == (guest + 1) * 38, "one reward per customer")
		_expect(model.served == guest + 1, "one served count per customer")
		for repeated: int in range(20):
			_expect(not model.advance("pay"), "rapid duplicate payment rejected %d" % repeated)
		_finish_cleaning(model)
		if guest == 0:
			_perform(model, "next", "entering")
	_expect(model.coins == 76 and model.served == 2 and model.lost == 0, "two complete cycles pay 76")


func _test_pause_and_invalid_actions() -> void:
	var model = Model.new()
	model.tick(2.0)
	model.paused = true
	var before: Dictionary = model.to_dict()
	model.tick(120.0)
	_expect(not model.advance("seat"), "paused action rejected")
	_expect(model.to_dict() == before, "pause freezes all state")
	model.paused = false
	_expect(not model.advance("pay"), "queue cannot pay")
	_expect(not model.advance(""), "empty action rejected")
	_expect(not model.advance("unknown"), "unknown action rejected")
	model.tick(-1.0)
	_expect(model.elapsed == 0.0, "negative delta ignored")
	_perform(model, "seat", "seating")


func _test_timeouts() -> void:
	var waiting = Model.new()
	waiting.tick(2.0)
	waiting.tick(Model.MAX_PATIENCE)
	_expect(waiting.phase == "leaving" and waiting.lost == 1, "queue patience expires")
	_expect(waiting.coins == 0 and not waiting.paid, "timeout pays nothing")
	waiting.tick(2.0)
	_expect(waiting.phase == "ready_next", "unseated guest leaves table clean")
	waiting.tick(500.0)
	_expect(waiting.lost == 1, "timeout counted only once")
	var seated = Model.new()
	seated.tick(2.0)
	seated.advance("seat")
	seated.tick(1.5)
	seated.tick(Model.MAX_PATIENCE)
	_expect(seated.phase == "leaving" and seated.lost == 1, "seated patience expires")
	seated.tick(2.0)
	_expect(seated.phase == "dirty", "seated timeout still needs cleanup")
	var checkout = Model.new()
	_to_checkout(checkout)
	checkout.tick(Model.MAX_PATIENCE)
	_expect(not checkout.advance("pay"), "expired checkout cannot be paid")
	_expect(checkout.coins == 0 and checkout.lost == 1, "expired checkout has no revenue")


func _test_pause_resume_timer() -> void:
	var model = Model.new()
	model.tick(2.0)
	model.advance("seat")
	model.tick(1.5)
	model.advance("order")
	model.advance("cook")
	model.tick(0.75)
	model.paused = true
	var before: Dictionary = model.to_dict()
	model.tick(120.0)
	_expect(model.to_dict() == before, "pause freezes a timed cooking phase")
	_expect(model.available_action().is_empty(), "paused model exposes no action")
	var resumed = Model.new()
	_expect(resumed.restore(before), "paused timer snapshot restores")
	resumed.tick(120.0)
	_expect(resumed.to_dict() == before, "restored pause stays frozen")
	resumed.paused = false
	resumed.tick(3.25)
	_expect(resumed.phase == "food_ready", "unpause completes exactly the remaining cooking time")
	_expect(is_equal_approx(resumed.patience, Model.MAX_PATIENCE - 4.0), "paused time consumes no patience")
	_expect(resumed.advance("serve_food"), "actions resume after unpause")


func _test_next_customer_after_timeout() -> void:
	# Both unseated and seated timeouts must free the table and preserve counters.
	for seated: bool in [false, true]:
		var model = Model.new()
		model.tick(2.0)
		if seated:
			model.advance("seat")
			model.tick(1.5)
		model.tick(Model.MAX_PATIENCE)
		_expect(model.phase == "leaving", "timeout begins departure")
		for repeated: int in range(10):
			_expect(not model.advance("pay"), "timeout never permits late payment %d" % repeated)
		if seated:
			_finish_cleaning(model)
		else:
			model.tick(2.0)
		_expect(model.phase == "ready_next", "timeout finishes ready for another guest")
		_perform(model, "next", "entering")
		_expect(model.customer_id == 2 and model.lost == 1 and model.served == 0 and model.coins == 0, "next preserves timeout counters")
		_expect(model.patience == Model.MAX_PATIENCE and not model.paid and not model.food_delivered and not model.drink_delivered and not model.dishes_collected and not model.table_used, "next clears previous guest flags")
		var restored = Model.new()
		_expect(restored.restore(model.to_dict()), "post-timeout next guest snapshot restores")
		_to_checkout(restored)
		_perform(restored, "pay", "leaving")
		_expect(restored.coins == 38 and restored.served == 1 and restored.lost == 1 and restored.customer_id == 2, "successful guest after timeout pays once")
		_finish_cleaning(restored)
		_expect(not restored.advance("pay") and restored.coins == 38, "cleanup cannot re-pay successful guest")


func _test_restore_validation() -> void:
	var model = Model.new()
	var before: Dictionary = model.to_dict()
	var corrupt: Dictionary = before.duplicate(true)
	corrupt["coins"] = 38
	_expect(not model.restore(corrupt), "inconsistent balance rejected")
	_expect(model.to_dict() == before, "invalid restore is atomic")
	corrupt = before.duplicate(true)
	corrupt["phase"] = "imaginary"
	_expect(not model.restore(corrupt), "unknown phase rejected")
	corrupt = before.duplicate(true)
	corrupt["patience"] = -1.0
	_expect(not model.restore(corrupt), "negative patience rejected")
	_expect(not model.restore({}), "missing fields rejected")
	_expect(model.to_dict() == before, "all invalid restores leave state untouched")
	_to_checkout(model)
	model.advance("pay")
	var restored = Model.new()
	_expect(restored.restore(model.to_dict()), "paid snapshot restored")
	_expect(not restored.advance("pay") and restored.coins == 38, "restore does not duplicate payment")
	_finish_cleaning(restored)
	_expect(model.restore(restored.to_dict()), "cleaned snapshot restored")
	_expect(model.phase == "ready_next", "restore preserves cleaned table")


func _test_all_phase_snapshots() -> void:
	var model = Model.new()
	var seen: Dictionary = {}
	for step: int in range(300):
		seen[model.phase] = true
		var clone = Model.new()
		_expect(clone.restore(model.to_dict()), "snapshot valid at " + model.phase)
		_expect(clone.to_dict() == model.to_dict(), "snapshot exact at " + model.phase)
		if model.phase == "ready_next":
			break
		var action: String = model.available_action()
		if not action.is_empty():
			model.advance(action)
		else:
			model.tick(0.25)
	_expect(seen.size() == Model.ALL_PHASES.size(), "visited and restored every phase")


func _test_disk_round_trip() -> void:
	# Unique disposable files; never touch the live save slot.
	var path: String = "user://model_test_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var model = Model.new()
	_to_checkout(model)
	model.advance("pay")
	_expect(model.save_to(path) == OK, "initial disk save succeeds")
	model.tick(0.7)
	model.paused = true
	_expect(model.save_to(path) == OK, "disk save succeeds")
	var reopened = Model.new()
	_expect(reopened.load_from(path), "new model loads disk save")
	_expect(reopened.to_dict() == model.to_dict(), "save preserves complete snapshot")
	_expect(not reopened.advance("pay") and reopened.coins == 38, "reopen cannot repay")
	reopened.paused = false
	reopened.tick(1.3)
	_expect(reopened.phase == "dirty", "reopen resumes remaining departure time")
	var removal: Error = DirAccess.remove_absolute(path)
	_expect(removal == OK, "disposable test save removed")
