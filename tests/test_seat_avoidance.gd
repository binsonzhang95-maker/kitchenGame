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
	# Static Floor is the deliberately frozen V4 facade, used only below for
	# migration fixtures. Runtime geometry tests use _runtime_safe/Floor.create.
	return not path.is_empty() and Floor.path_avoids_seats(start, path.slice(1), exceptions)


func _runtime_safe(layout, path: Array, start: Vector2, exceptions: Array[int] = []) -> bool:
	return not path.is_empty() and layout.path_avoids_seats(start, path.slice(1), exceptions)


func _check_floor_routes() -> void:
	var layout = Floor.create()
	# Regression: an actor just inside table 1's left reservation edge must get
	# one legal exit prefix, never a blanket table-1 exemption for the route.
	var reservation: Rect2 = layout.seat_reservation(1)
	var edge_start := reservation.position + Vector2(1.0, reservation.size.y * 0.5)
	var edge_service: Vector2 = layout.service_point(1)
	var edge_route: Array[Vector2] = layout.route_avoiding_seats(edge_start, edge_service)
	_check(not edge_route.is_empty() and edge_route[0].is_equal_approx(edge_start) and edge_route[-1].is_equal_approx(edge_service), "inside-edge actor reaches table-1 service with exact endpoints")
	_check(_runtime_safe(layout, edge_route, edge_start), "inside-edge actor gets one-way exit prefix without re-entering table 1")
	var edge_destination: Vector2 = edge_route[-1] if not edge_route.is_empty() else edge_start
	_check(not edge_destination.is_equal_approx(edge_start), "inside-edge actor route makes physical progress instead of teleporting or blocking")
	var safe_return: Array[Vector2] = layout.route_avoiding_seats(layout.service_point(1), layout.worker_home(0))
	_check(_runtime_safe(layout, safe_return, layout.service_point(1)), "table-1 worker return detours around seat reservation")
	for id: int in range(1, 21):
		var exceptions: Array[int] = [id]
		var to_seat: Array[Vector2] = layout.route_avoiding_seats(layout.entrance_point(), layout.seat_point(id), exceptions)
		_check(_runtime_safe(layout, to_seat, layout.entrance_point(), exceptions), "entry reaches only its own seat %d" % id)
		var leave: Array[Vector2] = layout.route_avoiding_seats(layout.seat_point(id), layout.entrance_point())
		_check(_runtime_safe(layout, leave, layout.seat_point(id)), "leaving route exits without reusing seat %d" % id)
		var kitchen_to_service: Array[Vector2] = layout.route_avoiding_seats(layout.kitchen_point(), layout.service_point(id))
		var service_to_home: Array[Vector2] = layout.route_avoiding_seats(layout.service_point(id), layout.worker_home(id % 2))
		_check(_runtime_safe(layout, kitchen_to_service, layout.kitchen_point()), "kitchen reaches service point %d" % id)
		_check(_runtime_safe(layout, service_to_home, layout.service_point(id)), "service returns home %d" % id)
	_check_non_grid_seat_exits(layout)


func _check_non_grid_seat_exits(layout) -> void:
	var checked: int = 0
	for id: int in range(1, 21):
		var reservation: Rect2 = layout.seat_reservation(id)
		var candidates: Array[Vector2] = [
			reservation.position + Vector2(1.25, reservation.size.y * 0.49),
			reservation.position + Vector2(reservation.size.x * 0.31, 2.75),
			reservation.position + Vector2(reservation.size.x * 0.67, reservation.size.y - 2.25),
		]
		var start := Vector2(-1, -1)
		for candidate: Vector2 in candidates:
			if layout.is_walkable(candidate):
				start = candidate
				break
		if not layout.is_walkable(start):
			continue # Some visual chair support areas overlap immutable furniture.
		checked += 1
		for destination: Vector2 in [layout.service_point(id), layout.kitchen_point(), layout.worker_home(id % 2), layout.entrance_point()]:
			var route: Array[Vector2] = layout.route_avoiding_seats(start, destination)
			_check(not route.is_empty() and route[0].is_equal_approx(start) and route[-1].is_equal_approx(destination), "non-grid seat exit preserves endpoints %d" % id)
			_check(_runtime_safe(layout, route, start), "non-grid seat exit avoids all reservations after prefix %d" % id)
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
		_check(_runtime_safe(model.floor, guest.path, guest.pos, [id]), "live arrival avoids other seats %d" % id)
		# Timeout uses the production leave transition while the guest still has
		# table_id, proving that this is not treated as an own-seat exception.
		guest.patience = 0.01
		model.tick(0.1)
		guest = model.customers.get(guest_id, {})
		_check(not guest.is_empty() and guest.state == "leaving", "live guest begins leaving %d" % id)
		if not guest.is_empty():
			_check(_runtime_safe(model.floor, guest.path, guest.pos), "live leave avoids every seat %d" % id)
	_check(model.validate_invariants().is_empty(), "concurrent live leave routes retain model invariants")


func _check_restored_legacy_routes() -> void:
	var source = Model.new()
	source.open_for_arrivals = false
	var legacy_path: Array[Vector2] = Floor.route(Floor.service_point(1), Floor.worker_home(0))
	var snapshot: Dictionary = _v4_worker_snapshot(source, Floor.service_point(1), legacy_path)
	var restored = Model.new()
	_check(restored.restore(snapshot), "genuine frozen V4 route migrates")
	var worker: Dictionary = restored.workers[0]
	_check(_runtime_safe(restored.floor, worker.path, worker.pos), "migrated V4 route is regenerated on the V5 floor")
	var before: Dictionary = restored.to_dict()
	var forged: Dictionary = before.duplicate(true)
	# Find a legal furniture-only V5 route which crosses another seat.  The
	# candidate proves the V5 parser cannot use the V3/V4 legacy exemption.
	var unsafe_route := _unsafe_returning_route(restored.floor)
	_check(not unsafe_route.is_empty(), "test fixture finds a furniture-valid seat crossing")
	if unsafe_route.is_empty():
		return
	var unsafe_start: Vector2 = unsafe_route.pop_front()
	forged.workers[0].pos = [unsafe_start.x, unsafe_start.y]
	forged.workers[0].path = []
	for point: Vector2 in unsafe_route:
		forged.workers[0].path.append([point.x, point.y])
	_check(not restored.restore(forged), "V5 seat-crossing route is rejected without legacy exemption")
	_check(Support.same(restored.to_dict(), before), "rejected V5 route leaves current model unchanged")


func _v4_worker_snapshot(source, position: Vector2, path: Array[Vector2]) -> Dictionary:
	# Freeze the actual V4 geometry and remove V5 geometry fields.  This is not
	# a relabelled V5 snapshot: every table/worker coordinate is old-map data.
	var snapshot: Dictionary = source.to_dict().duplicate(true)
	snapshot.version = 4
	snapshot.erase("layout_width")
	snapshot.erase("layout_revision")
	for index: int in range(snapshot.tables.size()):
		var center: Vector2 = Floor.table_center(index + 1)
		snapshot.tables[index].center = [center.x, center.y]
	for index: int in range(snapshot.workers.size()):
		var home: Vector2 = Floor.worker_home(index)
		snapshot.workers[index].pos = [home.x, home.y]
		snapshot.workers[index].path = []
	snapshot.workers[0].state = "returning"
	snapshot.workers[0].pos = [position.x, position.y]
	snapshot.workers[0].path = []
	for point: Vector2 in path:
		snapshot.workers[0].path.append([point.x, point.y])
	return snapshot


func _unsafe_returning_route(layout) -> Array[Vector2]:
	var home: Vector2 = layout.worker_home(0)
	for y: float in [280.0, 340.0, 430.0, 490.0, 570.0, 645.0, 730.0, 800.0, 900.0, 985.0]:
		for x: float in [80.0, 180.0, 320.0, 480.0, 640.0, 800.0, 960.0, 1120.0, 1280.0, 1440.0]:
			var start := Vector2(x, y)
			if not layout.is_walkable(start):
				continue
			var path: Array[Vector2] = layout.route(start, home)
			if not path.is_empty() and not layout.path_avoids_seats(start, path.slice(1)):
				path.push_front(start)
				return path
	return []


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
