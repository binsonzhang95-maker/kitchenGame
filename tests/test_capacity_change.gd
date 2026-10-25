extends SceneTree
## Regression: lowering the admission cap preserves existing guests and saveability.
const Model = preload("res://multi_model.gd")
var failures: int = 0


func _initialize() -> void:
	var model = Model.new()
	model.open_for_arrivals = false
	model.auto_seat = false
	model.max_customers = 20
	for index: int in range(8):
		_check(model.spawn_customer() > 0, "spawn guest %d at capacity 20" % index)
	_check(model.customers.size() == 8, "eight existing guests")
	model.max_customers = 6
	_check(model.customers.size() == 8, "lowering cap does not remove guests")
	_check(model.validate_invariants().is_empty(), "lowered cap remains valid")
	var snapshot: Dictionary = model.to_dict()
	var json_data: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_check(json_data is Dictionary, "snapshot survives JSON encoding")
	var restored = Model.new()
	if json_data is Dictionary:
		_check(restored.restore(json_data), "lowered-cap snapshot restores")
	_check(restored.max_customers == 6 and restored.customers.size() == 8, "restore preserves cap and all guests")
	_check(restored.validate_invariants().is_empty(), "restored lowered cap remains valid")
	var before_rejected: int = restored.rejected
	_check(restored.spawn_customer() == -1, "new guest rejected while above admission cap")
	_check(restored.customers.size() == 8 and restored.rejected == before_rejected + 1, "rejection does not change current guest count")
	print("CAPACITY_CHANGE_TEST_RESULT failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("CAPACITY_CHANGE_FAIL: " + message)
