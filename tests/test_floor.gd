extends SceneTree
## Headless routing acceptance test. No save files and no gameplay mutations.
const Floor = preload("res://floor_plan.gd")
var assertions: int = 0
var failures: int = 0
var routes_checked: int = 0


func _initialize() -> void:
	_check_layout()
	_check_all_table_routes()
	_check_queue_and_staff_routes()
	_check_arbitrary_endpoints()
	_check_blocked_endpoints()
	_check_wall_portals()
	print("FLOOR_TEST_RESULT assertions=%d failures=%d routes=%d" % [assertions, failures, routes_checked])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("FLOOR_ASSERT_FAIL " + description)


func _check_layout() -> void:
	var definitions: Array[Dictionary] = Floor.table_definitions()
	_expect(definitions.size() == 20, "exactly twenty tables")
	var zones: Dictionary = {"hall": 0, "private": 0, "bar": 0}
	var ids: Dictionary = {}
	for item: Dictionary in definitions:
		var id: int = int(item["id"])
		_expect(not ids.has(id), "unique table id %d" % id)
		ids[id] = true
		zones[item["zone"]] += 1
		_expect(Floor.table_center(id) == item["center"], "canonical center %d" % id)
		_expect(Floor.is_walkable(Floor.seat_point(id)), "seat is walkable %d" % id)
		_expect(Floor.is_walkable(Floor.service_point(id)), "service is walkable %d" % id)
		_expect(not Floor.is_walkable(Floor.table_center(id) + Vector2(0, 32)), "table ground footprint blocks walking %d" % id)
	_expect(zones == {"hall": 14, "private": 4, "bar": 2}, "zone distribution 14/4/2")
	# A caller may annotate its table records without corrupting the canonical layout.
	var original_center: Vector2 = definitions[0]["center"]
	definitions[0]["center"] = Vector2.ZERO
	_expect(Floor.table_center(1) == original_center, "definitions are independent copies")


func _check_all_table_routes() -> void:
	for id: int in range(1, 21):
		_check_route(Floor.entrance_point(), Floor.seat_point(id), "entry to seat %d" % id)
		_check_route(Floor.seat_point(id), Floor.entrance_point(), "seat to exit %d" % id)
		_check_route(Floor.kitchen_point(), Floor.service_point(id), "kitchen to service %d" % id)
		_check_route(Floor.service_point(id), Floor.kitchen_point(), "service to kitchen %d" % id)
	# Adjacent orders must also be reachable without crossing their table furniture.
	for id: int in range(1, 21):
		var next: int = id % 20 + 1
		_check_route(Floor.service_point(id), Floor.service_point(next), "successive service %d to %d" % [id, next])


func _check_queue_and_staff_routes() -> void:
	for index: int in range(8):
		_check_route(Floor.entrance_point(), Floor.queue_point(index), "entry to queue %d" % index)
		for id: int in [1, 10, 14, 15, 18, 19, 20]:
			_check_route(Floor.queue_point(index), Floor.seat_point(id), "queue %d to table %d" % [index, id])
	for home: Vector2 in [Floor.worker_home(0), Floor.worker_home(1)]:
		_check_route(home, Floor.kitchen_point(), "staff home to kitchen")
		for id: int in range(1, 21):
			_check_route(Floor.service_point(id), home, "staff return from table %d" % id)


func _check_arbitrary_endpoints() -> void:
	var points: Array[Vector2] = [Floor.entrance_point() + Vector2(-0.75, -0.25), Floor.worker_home(0) + Vector2(1.5, 0.25), Floor.kitchen_point() + Vector2(40.25, 4.5), Floor.service_point(20) + Vector2(-0.25, 0.5)]
	for start: Vector2 in points:
		for finish: Vector2 in points:
			_check_route(start, finish, "non-grid endpoints")
	# Resume movement from the middle of an existing path segment.
	var path: Array[Vector2] = Floor.route(Floor.entrance_point(), Floor.seat_point(20))
	for index: int in range(1, path.size()):
		var middle: Vector2 = path[index - 1].lerp(path[index], 0.37)
		_check_route(middle, Floor.kitchen_point(), "resume from route middle")


func _check_blocked_endpoints() -> void:
	_expect(Floor.route(Vector2(-1, 200), Floor.entrance_point()).is_empty(), "outside endpoint rejected")
	_expect(Floor.route(Floor.table_center(1) + Vector2(0, 32), Floor.entrance_point()).is_empty(), "cannot snap out through table")
	_expect(Floor.route(Floor.entrance_point(), Floor.table_center(20) + Vector2(0, 32)).is_empty(), "cannot snap into table")
	_expect(not Floor.segment_is_walkable(Floor.table_center(1) + Vector2(-80, 32), Floor.table_center(1) + Vector2(80, 32)), "straight crossing blocked")
	_expect(not Floor.is_walkable(Vector2(NAN, 5)), "non-finite endpoint rejected")


func _check_wall_portals() -> void:
	_expect(Floor.segment_is_walkable(Vector2(280, 190), Vector2(380, 190)), "private first door crosses its opened floor connector")
	_expect(Floor.segment_is_walkable(Vector2(250, 380), Vector2(380, 380)), "private second door uses actual open band")
	_expect(Floor.segment_is_walkable(Vector2(240, 608), Vector2(380, 608)), "private third door uses actual open band")
	_expect(Floor.segment_is_walkable(Vector2(228, 850), Vector2(380, 850)), "private fourth door uses actual open band")
	_expect(not Floor.segment_is_walkable(Vector2(280, 208), Vector2(380, 208)), "first door closed lower edge stays solid")
	_expect(not Floor.segment_is_walkable(Vector2(260, 418), Vector2(380, 418)), "second door closed lower edge stays solid")
	_expect(not Floor.segment_is_walkable(Vector2(240, 652), Vector2(380, 652)), "third door closed lower edge stays solid")
	_expect(not Floor.segment_is_walkable(Vector2(228, 901), Vector2(380, 901)), "fourth door closed lower edge stays solid")
	_expect(Floor.segment_is_walkable(Vector2(1210, 490), Vector2(1330, 490)), "bar passage connects through actual wall gap")
	_expect(Floor.is_walkable(Vector2(1260, 490)), "v4 removed bar pier is now visibly open floor")
	_expect(not Floor.segment_is_walkable(Vector2(1210, 440), Vector2(1330, 440)), "bar wall above the opening cannot be crossed")
	_expect(not Floor.segment_is_walkable(Vector2(1210, 530), Vector2(1330, 530)), "bar wall below y520 cannot be crossed")
	_expect(not Floor.segment_is_walkable(Vector2(260, 208), Vector2(260, 374)), "private separating wall cannot be crossed")
	_expect(not Floor.is_walkable(Vector2(700, 120)), "back kitchen wall is not customer floor")


func _check_route(start: Vector2, finish: Vector2, description: String) -> void:
	routes_checked += 1
	var path: Array[Vector2] = Floor.route(start, finish)
	_expect(not path.is_empty(), description + " exists")
	if path.is_empty():
		return
	_expect(path[0].distance_to(start) < 0.001, description + " starts exactly")
	_expect(path[-1].distance_to(finish) < 0.001, description + " ends exactly")
	var length: float = 0.0
	for index: int in range(1, path.size()):
		var a: Vector2 = path[index - 1]
		var b: Vector2 = path[index]
		length += a.distance_to(b)
		_expect(Floor.segment_is_walkable(a, b), description + " segment clears obstacles")
		var samples: int = maxi(1, ceili(a.distance_to(b) / 2.0))
		for sample: int in range(samples + 1):
			_expect(Floor.is_walkable(a.lerp(b, float(sample) / samples)), description + " sample is walkable")
	_expect(length <= 2.0 * (Floor.SIZE.x + Floor.SIZE.y), description + " bounded detour")
