extends RefCounted
## Shared isolated fixtures. No IO or engine launch at construction.
const Model = preload("res://multi_model.gd")


static func controlled(dispatch: bool = true):
	var model = Model.new()
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_cook = true
	model.auto_dispatch = dispatch
	return model


static func until(model, predicate: Callable, seconds: float = 60.0) -> bool:
	for step: int in range(ceili(seconds / 0.1)):
		if predicate.call():
			return true
		model.tick(0.1)
	return bool(predicate.call())


static func all_clear(model) -> bool:
	if not model.customers.is_empty() or not model.tasks.is_empty():
		return false
	for table: Dictionary in model.tables:
		if table.phase != "free":
			return false
	for worker: Dictionary in model.workers:
		if worker.state != "idle":
			return false
	return true


static func manual_actions(model) -> void:
	for table: Dictionary in model.tables:
		var action: String = str(model.table_action(int(table.id)))
		if action in ["order", "pay", "clean"]:
			model.act(int(table.id), action)


static func persistence_fixture():
	var model = controlled()
	model.spawn_customer("cat")
	model.assign_next(1)
	for step: int in range(3000):
		manual_actions(model)
		model.tick(0.1)
		if int(model.served) == 1 and all_clear(model):
			break
	if int(model.served) != 1 or not all_clear(model):
		return null
	model.auto_dispatch = false
	model.spawn_customer("dog")
	model.assign_next(20)
	for step: int in range(1200):
		if model.table_action(20) == "order":
			model.act(20, "order")
		model.tick(0.1)
		if not model.tasks.is_empty():
			break
	if model.tasks.is_empty() or not model.claim_task(1, int(model.tasks[0].id)):
		return null
	model.tick(0.1)
	model.paused = true
	return model


static func same(left: Variant, right: Variant) -> bool:
	if (typeof(left) == TYPE_INT or typeof(left) == TYPE_FLOAT) and (typeof(right) == TYPE_INT or typeof(right) == TYPE_FLOAT):
		return absf(float(left) - float(right)) <= 0.00001
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or not same(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index: int in range(left.size()):
			if not same(left[index], right[index]):
				return false
		return true
	return left == right
