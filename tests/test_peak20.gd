extends SceneTree
const Model = preload("res://multi_model.gd")
var assertions: int = 0
var failures: int = 0
func check(value: bool, reason: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(reason)
func _initialize() -> void:
	var model = Model.new()
	model.open_for_arrivals = false
	model.max_customers = 20
	model.auto_cook = true
	for i in range(20):
		check(model.spawn_customer() > 0, "peak20 admit")
		model.tick(0.9)
	check(model.customers.size() == 20, "twenty concurrent guests admitted")
	var occupied: int = 0
	for table in model.tables:
		if table.guest_id > 0: occupied += 1
	check(occupied == 20, "all twenty tables reserved concurrently")
	for step in range(6000):
		for table in model.tables:
			var action: String = model.table_action(table.id)
			if action in ["order", "pay", "clean"]: model.act(table.id, action)
		model.tick(0.1)
		check(model.validate_invariants().is_empty(), "peak20 invariants")
		if model.customers.is_empty() and model.tasks.is_empty() and model.chef.table_id == -1: break
	check(model.served + model.lost == 20, "all peak guests resolved")
	check(model.coins == 38 * model.served, "exact paid income under peak load")
	for table in model.tables:
		check(table.phase == "free", "all peak tables cleaned and released")
	check(model.tasks.is_empty(), "no peak task stranded")
	print("PEAK20_RESULT assertions=%d failures=%d served=%d lost=%d coins=%d simulation_seconds=%.1f" % [assertions,failures,model.served,model.lost,model.coins,model.clock])
	quit(0 if failures == 0 else 1)
