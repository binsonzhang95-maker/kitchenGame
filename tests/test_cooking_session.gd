extends SceneTree
## Pure session tests: no scene, player save, restaurant mutation, or file IO.
const Session = preload("res://cooking_session.gd")
var assertions: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_binding_and_status()
	for heat: String in Session.HEAT_LEVELS:
		_test_soup(heat)
	_test_stir_fry_and_bake()
	_test_drink_sequence()
	_test_retry_and_clear()
	_test_pause_and_cancel()
	_test_bad_snapshots()
	print("COOKING_SESSION_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("COOKING_SESSION_ASSERT_FAIL " + label)


func _new(recipe: String):
	var session = Session.new()
	_expect(session.setup({"table_id": 20, "guest_id": 42, "generation": 3}, recipe), "bind known recipe " + recipe)
	_roundtrip(session, recipe + " initial")
	return session


func _roundtrip(session, label: String) -> void:
	var encoded: String = JSON.stringify(session.to_dict())
	var data: Variant = JSON.parse_string(encoded)
	var decoded_before: String = JSON.stringify(data)
	var restored = Session.new()
	_expect(data is Dictionary and restored.restore(data), label + " accepts JSON roundtrip")
	_expect(JSON.stringify(restored.to_dict()) == encoded, label + " preserves all fields exactly")
	_expect(JSON.stringify(data) == decoded_before, label + " leaves the caller snapshot unchanged")


func _act(session, action: String) -> void:
	_expect(action in session.available_actions(), action + " is visibly available")
	_expect(session.act(action), action + " succeeds")
	_expect(session.is_bound_to(20, 42, 3), action + " preserves order identity")
	_roundtrip(session, str(session.recipe_id) + " after " + action)


func _prepare(recipe: String, heat: String = "medium"):
	var session = _new(recipe)
	var sequence: Array = {
		"soup": ["add_potato", "add_carrot", "add_water", "cut", "pot", "heat_" + heat],
		"stir_fry": ["add_egg", "add_tomato", "cut", "pan", "heat_" + heat],
		"bake": ["add_bread", "add_cheese", "oven"],
	}[recipe]
	for action: String in sequence:
		_act(session, action)
	return session


func _test_binding_and_status() -> void:
	var session = Session.new()
	_roundtrip(session, "empty session")
	_expect(not session.setup({"table_id": 21, "guest_id": 1, "generation": 1}, "soup"), "reject nonexistent table")
	_expect(not session.setup({"table_id": 1, "guest_id": 0, "generation": 1}, "soup"), "reject missing guest identity")
	_expect(not session.setup({"table_id": 1, "guest_id": 1, "generation": 0}, "soup"), "reject unreserved table generation")
	_expect(not session.setup({"table_id": 1, "guest_id": 1, "generation": 1}, "anything"), "reject arbitrary recipes")
	_expect(session.phase == "idle" and session.binding.is_empty(), "bad setup leaves session unbound")
	_expect(session.setup({"table_id": 20, "guest_id": 42, "generation": 3}, "soup"), "valid setup after a gentle error")
	_expect(not session.setup({"table_id": 19, "guest_id": 43, "generation": 4}, "bake"), "an active session cannot be rebound to another order")
	_expect(session.is_bound_to(20, 42, 3) and not session.is_bound_to(20, 42, 4), "generation is part of the order identity")
	var view: Dictionary = session.status()
	_expect(view.step_count == 4 and view.steps.size() == 4 and view.max_slots == 3, "UI receives four visible steps and three ingredient slots")
	_expect(view.required_ingredients == ["potato", "carrot"] and "add_water" in view.actions, "soup exposes water separately from its ingredient list")
	view.binding.table_id = 1
	view.ingredients.append("cheese")
	_expect(session.is_bound_to(20, 42, 3) and session.ingredients.is_empty(), "UI status is a detached read-only view")
	_expect(not session.to_dict().has("coins") and not session.to_dict().has("served"), "session owns no restaurant economy")


func _test_soup(heat: String) -> void:
	var session = _new("soup")
	_act(session, "add_carrot")
	_expect(not session.act("add_cheese") and session.ingredients == ["carrot"], "foreign ingredient rejection preserves selected ingredients")
	_expect(not session.act("add_carrot") and session.ingredients.size() == 1, "duplicate ingredient does not consume another slot")
	_act(session, "add_water")
	_expect(not session.act("add_water"), "duplicate water is rejected")
	_act(session, "add_potato")
	_expect(session.ingredients.size() == 2 and session.status().slots_used == 2 and session.water_added, "water occupies no ingredient slot")
	_expect(not session.act("pot") and not session.act("heat_high"), "cutting and pot steps cannot be skipped")
	_act(session, "cut")
	_act(session, "pot")
	_act(session, "heat_" + heat)
	var duration: float = session.cook_duration()
	session.tick(duration - 0.25)
	_expect(session.phase == "cooking" and not session.act("finish"), "soup cannot finish before ready")
	_roundtrip(session, "soup partly heated " + heat)
	session.tick(0.25)
	_expect(session.phase == "ready" and is_equal_approx(float(session.status().ready_remaining), 12.0), "ready begins with a generous twelve-second window")
	_roundtrip(session, "soup just ready " + heat)
	session.tick(11.75)
	_expect(session.phase == "ready", "completion remains available near the end of the broad window")
	_act(session, "finish")
	_expect(session.completed and not session.cancelled, "soup reaches completed once")
	_expect(not session.act("finish") and not session.act("cancel") and session.completed, "finished soup cannot finish twice or be cancelled afterward")


func _test_stir_fry_and_bake() -> void:
	for recipe: String in ["stir_fry", "bake"]:
		var session = _prepare(recipe)
		var finish: String = "stir" if recipe == "stir_fry" else "takeout"
		_expect(not session.act(finish), "cannot finish " + recipe + " while cooking")
		session.tick(session.cook_duration())
		_roundtrip(session, recipe + " ready")
		_expect(session.phase == "ready" and not session.act("finish"), recipe + " accepts only its own finishing action")
		_act(session, finish)
		_expect(session.completed and session.attempts == 1, recipe + " completes in one attempt")


func _test_drink_sequence() -> void:
	var session = _new("drink")
	_expect(session.ingredient_options() == ["coffee"], "drink begins with coffee only")
	_expect(not session.act("add_milk") and not session.act("add_ice") and session.ingredients.is_empty(), "out-of-order drink ingredients are rejected without consuming anything")
	_act(session, "add_coffee")
	_expect(not session.act("add_coffee"), "drink rejects duplicate coffee")
	_act(session, "add_milk")
	_act(session, "add_ice")
	_expect(session.ingredients == ["coffee", "milk", "ice"] and session.status().slots_used == 3, "drink uses exactly three unique ordered slots")
	var before: String = JSON.stringify(session.to_dict())
	session.tick(1000.0)
	_expect(JSON.stringify(session.to_dict()) == before, "cold drink has no heat timeout or precise timing requirement")
	_expect(not session.act("add_water") and not session.act("add_potato"), "no fourth or unrelated drink ingredient can be added")
	_act(session, "stir")
	_expect(session.completed and session.elapsed == 0.0 and session.attempts == 0, "drink completes through stirring without a cooking clock")


func _test_retry_and_clear() -> void:
	for recipe: String in ["soup", "stir_fry", "bake"]:
		var session = _prepare(recipe)
		var original_ingredients: Array = session.ingredients.duplicate()
		var original_water: bool = session.water_added
		var original_cut: bool = session.cut_done
		session.tick(session.cook_duration() + Session.READY_WINDOW + 100.0)
		_expect(session.phase == "retry" and not session.completed, recipe + " large tick cannot skip through an expired ready window")
		_expect(session.ingredients == original_ingredients and session.water_added == original_water, recipe + " overcooking never consumes materials")
		_roundtrip(session, recipe + " overcooked")
		_act(session, "retry")
		_expect(session.ingredients == original_ingredients and session.cut_done == original_cut and session.water_added == original_water, recipe + " retry preserves ingredient preparation")
		_expect(session.elapsed == 0.0 and session.heat_level.is_empty(), recipe + " retry resets only the cooking attempt")
		_act(session, "oven" if recipe == "bake" else "heat_small")
		session.tick(session.cook_duration())
		_act(session, "takeout" if recipe == "bake" else ("finish" if recipe == "soup" else "stir"))
		_expect(session.completed and session.attempts == 2, recipe + " retries successfully without another ingredient selection")
	var cleared = _prepare("soup")
	cleared.tick(1.0)
	_act(cleared, "clear")
	_expect(cleared.phase == "ingredients" and cleared.ingredients.is_empty() and not cleared.water_added and not cleared.cut_done, "clear resets ingredients, water, and cutting")
	_expect(cleared.vessel.is_empty() and cleared.heat_level.is_empty() and cleared.elapsed == 0.0, "clear resets vessel, heat, and progress")
	_expect(cleared.is_bound_to(20, 42, 3), "clear cannot change the bound customer or table generation")


func _test_pause_and_cancel() -> void:
	var session = _prepare("soup")
	session.tick(1.25)
	session.set_paused(true)
	var before: String = JSON.stringify(session.to_dict())
	session.tick(1000.0)
	_expect(JSON.stringify(session.to_dict()) == before, "the mini-game's own pause freezes its timer completely")
	_expect(session.available_actions() == ["cancel"], "paused game offers no cooking action but remains cancellable")
	_roundtrip(session, "paused cooking")
	session.set_paused(false)
	session.tick(0.25)
	_expect(is_equal_approx(session.elapsed, 1.5), "resuming continues the same cooking attempt")
	session.set_paused(true)
	_act(session, "cancel")
	_expect(session.cancelled and not session.completed and session.cancelled_from == "cooking", "cancel records unfinished state without completing an order")
	before = JSON.stringify(session.to_dict())
	session.tick(1000.0)
	_expect(JSON.stringify(session.to_dict()) == before, "cancelled session cannot continue cooking")
	_expect(not session.act("retry") and not session.act("finish"), "cancelled session cannot revive or finish")


func _reject_unchanged(target, data: Dictionary, label: String) -> void:
	var before: String = JSON.stringify(target.to_dict())
	_expect(not target.restore(data), label + " is rejected")
	_expect(JSON.stringify(target.to_dict()) == before, label + " leaves the target session unchanged")


func _test_bad_snapshots() -> void:
	var source = _prepare("soup")
	source.tick(1.0)
	var snapshot: Dictionary = source.to_dict()
	var target = _new("drink")
	var changes: Array = [
		["version", 2], ["recipe_id", "custom"], ["phase", "unknown"], ["ingredients", ["potato", "potato"]],
		["ingredients", ["potato", "carrot", "water"]], ["ingredients", ["potato", "carrot", "egg", "milk"]],
		["water_added", false], ["cut_done", false], ["vessel", "pan"], ["heat_level", "extreme"],
		["elapsed", -0.01], ["elapsed", NAN], ["elapsed", 6.0], ["attempts", 0], ["paused", "false"],
		["completed", true], ["cancelled", true], ["phase", "completed"], ["message", "x".repeat(501)],
		["binding", {"table_id": 21, "guest_id": 42, "generation": 3}],
		["binding", {"table_id": 20, "guest_id": 42, "generation": 0}],
	]
	for change: Array in changes:
		var bad: Dictionary = snapshot.duplicate(true)
		bad[change[0]] = change[1]
		_reject_unchanged(target, bad, "invalid " + str(change[0]))
	var missing: Dictionary = snapshot.duplicate(true)
	missing.erase("water_added")
	_reject_unchanged(target, missing, "missing required field")
	var drink = _new("drink")
	drink.act("add_coffee")
	drink.act("add_milk")
	var wrong_order: Dictionary = drink.to_dict()
	wrong_order.ingredients = ["milk", "coffee"]
	_reject_unchanged(target, wrong_order, "drink snapshot with wrong ingredient order")
	source.tick(source.cook_duration() - source.elapsed)
	var expired: Dictionary = source.to_dict()
	expired.elapsed = source.cook_duration() + Session.READY_WINDOW
	_reject_unchanged(target, expired, "ready snapshot beyond its completion window")
