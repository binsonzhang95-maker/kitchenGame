extends SceneTree
## Seat-reservation regression. Uses live model transitions as well as Floor
## routes; it neither writes a save nor opens the normal game.
const Floor = preload("res://floor_plan.gd")
const Model = preload("res://multi_model.gd")
const Support = preload("res://tests/multi_test_support.gd")

var assertions: int = 0
var failures: int = 0


func _initialize() -> void:
	_check_floor_routes()
	_check_live_seating_and_leaving()
	_check_restored_legacy_routes()
	_check_peak_progress()
	print("SEAT_AVOIDANCE_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _check(value: bool, reason: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error("SEAT_AVOIDANCE_FAIL " + reason)


func _safe(path: Array, start: Vector2, exceptions: Array[int] = []) -> bool:
	return not path.is_empty() and Floor.path_avoids_seats(start, path.slice(1), exceptions)


func _check_floor_routes() -> void:
	# Regression: 509,357 is just inside table 1's left reservation edge. Its
	# nearest grid point (504,360) is already outside, so a legal exit prefix
	# must not turn into a blanket table-1 exemption for the later BFS route.
	var edge_start := Vector2(509, 357)
	var edge_service: Vector2 = Floor.service_point(1)
	var edge_route: Array[Vector2] = Floor.route_avoiding_seats(edge_start, edge_service)
	_check(not edge_route.is_empty() and edge_route[0].is_equal_approx(edge_start) and edge_route[-1].is_equal_approx(edge_service), "inside-edge actor reaches table-1 service with exact endpoints")
	_check(_safe(edge_route, edge_start), "inside-edge actor gets one-way exit prefix without re-entering table 1")
	var edge_destination: Vector2 = edge_route[-1] if not edge_route.is_empty() else edge_start
	_check(not edge_destination.is_equal_approx(edge_start), "inside-edge actor route makes physical progress instead of teleporting or blocking")
	var old_return: Array[Vector2] = Floor.route(Floor.service_point(1), Floor.worker_home(0))
	_check(not Floor.path_avoids_seats(Floor.service_point(1), old_return.slice(1)), "old table-1 worker return crosses its seated support area")
	var safe_return: Array[Vector2] = Floor.route_avoiding_seats(Floor.service_point(1), Floor.worker_home(0))
	_check(_safe(safe_return, Floor.service_point(1)), "table-1 worker return detours around seat reservation")
	for id: int in range(1, 21):
		var to_seat: Array[Vector2] = Floor.route_avoiding_seats(Floor.entrance_point(), Floor.seat_point(id), [id])
		_check(_safe(to_seat, Floor.entrance_point(), [id]), "entry reaches only its own seat %d" % id)
		var leave: Array[Vector2] = Floor.route_avoiding_seats(Floor.seat_point(id), Floor.entrance_point())
		_check(_safe(leave, Floor.seat_point(id)), "leaving route exits without reusing seat %d" % id)
		var kitchen_to_service: Array[Vector2] = Floor.route_avoiding_seats(Floor.kitchen_point(), Floor.service_point(id))
		var service_to_home: Array[Vector2] = Floor.route_avoiding_seats(Floor.service_point(id), Floor.worker_home(id % 2))
		_check(_safe(kitchen_to_service, Floor.kitchen_point()), "kitchen reaches service point %d" % id)
		_check(_safe(service_to_home, Floor.service_point(id)), "service returns home %d" % id)
	_check_non_grid_seat_exits()


func _check_non_grid_seat_exits() -> void:
	var checked: int = 0
	for id: int in range(1, 21):
		var reservation: Rect2 = Floor.seat_reservation(id)
		var candidates: Array[Vector2] = [
			reservation.position + Vector2(1.25, reservation.size.y * 0.49),
			reservation.position + Vector2(reservation.size.x * 0.31, 2.75),
			reservation.position + Vector2(reservation.size.x * 0.67, reservation.size.y - 2.25),
		]
		var start := Vector2(-1, -1)
		for candidate: Vector2 in candidates:
			if Floor.is_walkable(candidate):
				start = candidate
				break
		if not Floor.is_walkable(start):
			continue # Some visual chair support areas overlap immutable furniture.
		checked += 1
		for destination: Vector2 in [Floor.service_point(id), Floor.kitchen_point(), Floor.worker_home(id % 2), Floor.entrance_point()]:
			var route: Array[Vector2] = Floor.route_avoiding_seats(start, destination)
			_check(not route.is_empty() and route[0].is_equal_approx(start) and route[-1].is_equal_approx(destination), "non-grid seat exit preserves endpoints %d" % id)
			_check(_safe(route, start), "non-grid seat exit avoids all reservations after prefix %d" % id)
	_check(checked == 20, "all twenty non-grid seat edge/interior samples are statically walkable")


func _check_live_seating_and_leaving() -> void:
	var model = Support.controlled(false)
	model.max_customers = 20
	for id: int in range(1, 21):
		var guest_id: int = model.spawn_customer()
		_check(guest_id > 0 and model.assign_next(id), "live guest reserves table %d" % id)
		if guest_id <= 0:
			continue
		var guest: Dictionary = model.customers[guest_id]
		_check(_safe(guest.path, guest.pos, [id]), "live arrival avoids other seats %d" % id)
		# Timeout uses the production leave transition while the guest still has
		# table_id, proving that this is not treated as an own-seat exception.
		guest.patience = 0.01
		model.tick(0.1)
		guest = model.customers.get(guest_id, {})
		_check(not guest.is_empty() and guest.state == "leaving", "live guest begins leaving %d" % id)
		if not guest.is_empty():
			_check(_safe(guest.path, guest.pos), "live leave avoids every seat %d" % id)
	_check(model.validate_invariants().is_empty(), "concurrent live leave routes retain model invariants")


func _check_restored_legacy_routes() -> void:
	var source = Model.new()
	source.open_for_arrivals = false
	source.paused = true
	var legacy_path: Array[Vector2] = Floor.route(Floor.service_point(1), Floor.worker_home(0))
	source.workers[0].state = "returning"
	source.workers[0].pos = Floor.service_point(1)
	source.workers[0].path = legacy_path
	var snapshot: Dictionary = source.to_dict().duplicate(true)
	var restored = Model.new()
	_check(restored.restore(snapshot), "paused V4 static-only route restores")
	_check(Support.same(restored.to_dict(), snapshot), "paused V4 restore preserves position and old path exactly")
	restored.paused = false
	restored.tick(1.0)
	var worker: Dictionary = restored.workers[0]
	_check(not worker.pos.is_equal_approx(Floor.service_point(1)) and worker.pos.distance_to(Floor.service_point(1)) <= 262.51, "legacy worker exits by movement without teleport")
	_check(Floor.path_avoids_seats(worker.pos, worker.path), "legacy crossing is replanned before a multi-segment tick")
	worker.pos = Floor.service_point(1)
	worker.path = legacy_path.duplicate()
	_check(not restored.validate_invariants().is_empty(), "after first repair, a new seat-crossing route is rejected by invariants")
	var inside = Model.new()
	inside.open_for_arrivals = false
	inside.paused = true
	inside.workers[0].state = "returning"
	inside.workers[0].pos = Floor.seat_point(1)
	inside.workers[0].path = Floor.route(Floor.seat_point(1), Floor.worker_home(0))
	var inside_snapshot: Dictionary = inside.to_dict().duplicate(true)
	var restored_inside = Model.new()
	_check(restored_inside.restore(inside_snapshot), "old actor inside newly reserved seat restores")
	_check(Support.same(restored_inside.to_dict(), inside_snapshot), "inside-seat restore does not relocate actor")
	restored_inside.paused = false
	restored_inside.tick(0.1)
	var exiting: Dictionary = restored_inside.workers[0]
	_check(not exiting.pos.is_equal_approx(Floor.seat_point(1)) and exiting.pos.distance_to(Floor.seat_point(1)) <= 26.26, "inside-seat actor takes a short physical exit")
	_check(Floor.path_avoids_seats(exiting.pos, exiting.path), "exiting actor subsequently avoids all reservations")


func _check_peak_progress() -> void:
	var model = Support.controlled()
	model.max_customers = 20
	for id: int in range(1, 21):
		var guest_id: int = model.spawn_customer()
		if guest_id > 0:
			model.assign_next(id)
	for step: int in range(2400):
		Support.manual_actions(model)
		model.tick(0.1)
		if model.customers.is_empty() and model.tasks.is_empty():
			break
	_check(model.validate_invariants().is_empty(), "20-table service remains internally consistent")
	_check(int(model.served) + int(model.lost) == 20, "20-table service does not strand guests")
