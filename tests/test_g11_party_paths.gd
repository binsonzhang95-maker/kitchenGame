extends SceneTree
const Layout = preload("res://floor_layout.gd")
const Floor = preload("res://floor_plan.gd")
const Model = preload("res://multi_model.gd")
var failures := 0
var assertions := 0


func _check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error("G11_PARTY_PATHS_FAIL: " + message)


func _actor_destination(actor: Dictionary) -> Vector2:
	var path: Array = actor.get("path", [])
	return Vector2(actor.pos) if path.is_empty() else Vector2(path[-1])


func _actor_route_is_safe(floor, actor: Dictionary, destination: Vector2) -> bool:
	if bool(actor.get("route_blocked", false)) or not _actor_destination(actor).is_equal_approx(destination):
		return false
	var path: Array = actor.get("path", [])
	var exceptions: Array[int] = []
	var table_id: int = int(actor.get("table_id", 0))
	var seat_index: int = int(actor.get("seat_index", -1))
	if table_id > 0 and seat_index >= 0 and destination.is_equal_approx(floor.seat_point(table_id, seat_index)):
		exceptions.append(floor.seat_key(table_id, seat_index))
	return floor.path_avoids_seats(Vector2(actor.pos), path, exceptions)


func _ground_is_clear(floor, position: Vector2) -> bool:
	if not floor.is_walkable(position):
		return false
	var ground: Rect2 = floor.actor_ground_footprint(position)
	for wall: Rect2 in floor.architecture_obstacles():
		if ground.intersects(wall):
			return false
	for decor: Dictionary in floor.decoration_definitions():
		if bool(decor.get("collision", false)) and ground.intersects(decor.get("footprint", Rect2())):
			return false
	return true


func _check_party_queue(model, party_id: int, queue_index: int, phase: String) -> void:
	var floor = model.floor
	var leader: Dictionary = model.customers[party_id]
	var leader_destination: Vector2 = floor.queue_point(queue_index)
	_check(_ground_is_clear(floor, leader_destination), "%s queue leader clears G11 source solids %d/%d" % [phase, floor.layout_width, queue_index])
	_check(_actor_route_is_safe(floor, leader, leader_destination), "%s queue leader route/destination %d/%d" % [phase, floor.layout_width, queue_index])
	for companion: Dictionary in leader.companions:
		var member_index: int = int(companion.member_index)
		var destination: Vector2 = leader_destination + Vector2(member_index * 10, -18)
		_check(_ground_is_clear(floor, destination), "%s queue companion clears G11 source solids %d/%d/%d" % [phase, floor.layout_width, queue_index, member_index])
		_check(_actor_route_is_safe(floor, companion, destination), "%s queue companion route/destination %d/%d/%d" % [phase, floor.layout_width, queue_index, member_index])


func _check_party_seating(model, party_id: int, table_id: int, phase: String) -> void:
	var floor = model.floor
	var leader: Dictionary = model.customers[party_id]
	_check(_actor_route_is_safe(floor, leader, floor.seat_point(table_id, 0)), "%s seat leader route/destination %d/%d" % [phase, floor.layout_width, table_id])
	_check(floor.is_walkable(Vector2(leader.pos)), "%s seat leader collision %d/%d" % [phase, floor.layout_width, table_id])
	for companion: Dictionary in leader.companions:
		var seat_index: int = int(companion.seat_index)
		_check(_actor_route_is_safe(floor, companion, floor.seat_point(table_id, seat_index)), "%s seat companion route/destination %d/%d/%d" % [phase, floor.layout_width, table_id, seat_index])
		_check(floor.is_walkable(Vector2(companion.pos)), "%s seat companion collision %d/%d/%d" % [phase, floor.layout_width, table_id, seat_index])


func _check_queue_party_contract(width: float) -> void:
	var model = Model.new(width)
	model.max_customers = 8
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	model.auto_cook = false
	for queue_index: int in range(8):
		var party_id: int = model.spawn_party(3, ["cat", "dog", "panda"])
		_check(party_id == queue_index + 1, "eight three-person parties spawn %d/%d" % [width, queue_index])
	for queue_index: int in range(8):
		_check_party_queue(model, queue_index + 1, queue_index, "initial")
	_check(model.validate_invariants().is_empty(), "initial queue is invariant-safe %d" % width)
	for tick_index: int in range(100):
		model.tick(0.1)
		for queue_index: int in range(8):
			_check_party_queue(model, queue_index + 1, queue_index, "queue-%d" % tick_index)
		if tick_index % 10 == 9:
			_check(model.validate_invariants().is_empty(), "queue remains invariant-safe at %0.1fs %d" % [float(tick_index + 1) * 0.1, width])
	for queue_index: int in range(8):
		var party: Dictionary = model.customers[queue_index + 1]
		_check(Vector2(party.pos).is_equal_approx(model.floor.queue_point(queue_index)) and party.path.is_empty() and not bool(party.route_blocked), "queue leader arrives without blockage %d/%d" % [width, queue_index])
		for companion: Dictionary in party.companions:
			var member_index: int = int(companion.member_index)
			var destination: Vector2 = model.floor.queue_point(queue_index) + Vector2(member_index * 10, -18)
			_check(Vector2(companion.pos).is_equal_approx(destination) and companion.path.is_empty() and not bool(companion.route_blocked), "queue companion arrives without blockage %d/%d/%d" % [width, queue_index, member_index])
	for table_id: int in range(1, 9):
		_check(model.floor.table_capacity(table_id) == 3, "G11 hall table remains three-seat %d/%d" % [width, table_id])
		_check(model.assign_next(table_id), "three-person queue party assigns to multi-seat table %d/%d" % [width, table_id])
		_check_party_seating(model, table_id, table_id, "planned")
	_check(model.validate_invariants().is_empty(), "planned three-seat parties are invariant-safe %d" % width)
	for tick_index: int in range(100):
		model.tick(0.1)
		for table_id: int in range(1, 9):
			_check_party_seating(model, table_id, table_id, "seating-%d" % tick_index)
		if tick_index % 10 == 9:
			_check(model.validate_invariants().is_empty(), "seating remains invariant-safe at %0.1fs %d" % [float(tick_index + 1) * 0.1, width])
	for table_id: int in range(1, 9):
		var members: Array[Dictionary] = model.table_members(table_id)
		_check(members.size() == 3 and int(members[0].seat_index) == 0 and int(members[1].seat_index) == 1 and int(members[2].seat_index) == 2, "three members occupy independent G11 seats %d/%d" % [width, table_id])
	_check(model.validate_invariants().is_empty(), "arrived three-seat parties are invariant-safe %d" % width)


func _check_queue_revision_contract(width: float) -> void:
	var g11 = Layout.new(width, Layout.revision_for_width(width))
	var g10 = Layout.new(width, Layout.g10_revision_for_width(width))
	var rev1 = Layout.new(width, Layout.legacy_revision_for_width(width))
	for queue_index: int in [0, 7]:
		_check(g11.queue_point(queue_index).is_equal_approx(Vector2(width * 0.5 + 112.0 + queue_index * 36, Layout.HEIGHT - 110)), "G11 rev3 queue contract %d/%d" % [width, queue_index])
		_check(g10.queue_point(queue_index).is_equal_approx(Vector2(width * 0.5 + 172.0 + queue_index * 36, Layout.HEIGHT - 110)), "G10 rev2 queue remains frozen %d/%d" % [width, queue_index])
		_check(rev1.queue_point(queue_index).is_equal_approx(Vector2(width * 0.5 - 126.0 + queue_index * 36, 985)), "rev1 queue remains frozen %d/%d" % [width, queue_index])


func _initialize() -> void:
	for width: float in [1536.0, 1688.0, 2048.0, 2496.0, 4096.0]:
		_check_queue_revision_contract(width)
		var floor: Variant = Floor.create(width)
		if not is_equal_approx(floor.layout_width, width) or floor.revision != Layout.revision_for_width(width):
			failures += 1
			push_error("G11_PARTY_PATHS_FAIL: invalid G11 layout construction %d" % width)
		for table_id: int in range(1, 21):
			for seat_index: int in range(floor.table_capacity(table_id)):
				var key: int = floor.seat_key(table_id, seat_index)
				var exceptions: Array[int] = [key]
				var path: Array = floor.route_avoiding_seats(floor.entrance_point(), floor.seat_point(table_id, seat_index), exceptions)
				_check(not path.is_empty() and floor.path_avoids_seats(floor.entrance_point(), path.slice(1), exceptions), "entry %d/%d/%d" % [width, table_id, seat_index])
				for offset: Vector2 in [Vector2.ZERO, Vector2(-8, -4), Vector2(8, 4)]:
					var exit_start: Vector2 = floor.seat_point(table_id, seat_index) + offset
					if not floor.is_walkable(exit_start):
						continue
					var leave: Array = floor.route_avoiding_seats(exit_start, floor.entrance_point())
					_check(not leave.is_empty() and floor.path_avoids_seats(exit_start, leave.slice(1)), "exit %d/%d/%d at %s" % [width, table_id, seat_index, offset])
			var service: Vector2 = floor.service_point(table_id)
			for ends: Array in [[floor.kitchen_point(), service], [service, floor.worker_home(0)]]:
				var service_path: Array = floor.route_avoiding_seats(ends[0], ends[1])
				_check(not service_path.is_empty() and floor.path_avoids_seats(ends[0], service_path.slice(1)), "service %d/%d from %s" % [width, table_id, ends[0]])
		for table_id: int in range(1, 21):
			for seat_index: int in range(floor.table_capacity(table_id)):
				var reservation: Rect2 = floor.seat_reservation(table_id, seat_index)
				var start := Vector2(-1, -1)
				for candidate: Vector2 in [reservation.position + Vector2(1.25, reservation.size.y * .49), reservation.position + Vector2(reservation.size.x * .31, 2.75), reservation.position + Vector2(reservation.size.x * .67, reservation.size.y - 2.25)]:
					if floor.is_walkable(candidate):
						start = candidate
						break
				if start.x < 0.0:
					failures += 1
					push_error("G11_PARTY_PATHS_FAIL: non-grid sample missing %d/%d/%d" % [width, table_id, seat_index])
					continue
				for destination: Vector2 in [floor.service_point(table_id), floor.kitchen_point(), floor.worker_home(table_id % 2), floor.entrance_point()]:
					var non_grid_path: Array = floor.route_avoiding_seats(start, destination)
					_check(not non_grid_path.is_empty() and floor.path_avoids_seats(start, non_grid_path.slice(1)), "non-grid %d/%d/%d to %s" % [width, table_id, seat_index, destination])
	for width: float in [1536.0, 1688.0, 2048.0, 2496.0, 4096.0]:
		_check_queue_party_contract(width)
	print("G11_PARTY_PATHS_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)
