extends SceneTree
## Pure model/geometry coverage for the real landscape map; no UI or saves.
const Floor = preload("res://floor_plan.gd")
const FloorLayout = preload("res://floor_layout.gd")
const Model = preload("res://multi_model.gd")
const Support = preload("res://tests/multi_test_support.gd")

var failures := 0
var assertions := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error("WIDE_V5_FAIL: " + message)

func _run() -> void:
	var route_build_usec := 0
	var occupied_route_usec := 0
	for width: float in [1536.0, 2496.0, 4096.0]:
		var layout = Floor.create(width)
		_check(layout.SIZE == Vector2(width, 1072), "world size %d" % width)
		_check(layout.table_definitions().size() == 20, "twenty tables %d" % width)
		_check(layout.architecture_obstacles().size() >= 10, "room/bar/front-wall obstacles exist %d" % width)
		_check(layout.table_center(15).is_equal_approx(Vector2(188,164)) and is_equal_approx(layout.table_center(19).x, width - 184.0), "current fixed side strips retain authored tables %d" % width)
		var g10 = FloorLayout.new(width, FloorLayout.g10_revision_for_width(width))
		_check(g10.table_center(15).is_equal_approx(Vector2(175,170)), "G10 rev2 retains historic private table 15 %d" % width)
		for table_id: int in range(1, 21):
			var definition: Dictionary = layout.table_definitions()[table_id - 1]
			var footprint := Rect2(Vector2(definition.center) + Vector2(-53,18), Vector2(106,28))
			if str(definition.zone) == "bar": footprint = Rect2(Vector2(definition.center) + Vector2(-48,24), Vector2(96,44))
			for wall: Rect2 in layout.architecture_obstacles():
				_check(not footprint.intersects(wall) and not layout.seat_reservation(table_id).intersects(wall), "table/actor ground footprint clears architecture %d/%d" % [width,table_id])
			_check(_footprint_clears_architecture(layout, layout.service_point(table_id)), "service footprint clears architecture %d/%d" % [width, table_id])
		var room_doors: Array[Vector2] = [Vector2(152,197), Vector2(349,410), Vector2(575,641), Vector2(809,896)]
		var first_started := Time.get_ticks_usec()
		var first_exceptions: Array[int] = [1]
		var first_path: Array[Vector2] = layout.route_avoiding_seats(layout.entrance_point(), layout.seat_point(1), first_exceptions)
		route_build_usec += Time.get_ticks_usec() - first_started
		_check(not first_path.is_empty(), "first route builds lazily %d" % width)
		var occupied_started := Time.get_ticks_usec()
		for id: int in range(1, 21):
			var exceptions: Array[int] = [id]
			var entry: Array[Vector2] = layout.route_avoiding_seats(layout.entrance_point(), layout.seat_point(id), exceptions)
			var service: Array[Vector2] = layout.route_avoiding_seats(layout.kitchen_point(), layout.service_point(id))
			var return_path: Array[Vector2] = layout.route_avoiding_seats(layout.service_point(id), layout.worker_home(id % 2))
			_check(not entry.is_empty() and layout.path_avoids_seats(layout.entrance_point(), entry.slice(1), exceptions), "entry path %d/%d" % [width, id])
			if id >= 15 and id <= 18:
				_check(_path_crosses_x_in_y(entry, 332.0, room_doors[id - 15]), "private route uses room opening %d/%d" % [width,id])
			var leave: Array[Vector2] = layout.route_avoiding_seats(layout.seat_point(id), layout.entrance_point())
			_check(not leave.is_empty() and layout.path_avoids_seats(layout.seat_point(id), leave.slice(1)), "leave path %d/%d" % [width, id])
			_check(not service.is_empty() and layout.path_avoids_seats(layout.kitchen_point(), service.slice(1)), "service path %d/%d" % [width, id])
			_check(not return_path.is_empty() and layout.path_avoids_seats(layout.service_point(id), return_path.slice(1)), "return path %d/%d" % [width, id])
			_check(_path_footprints_clear(layout, layout.entrance_point(), entry) and _path_footprints_clear(layout, layout.seat_point(id), leave) and _path_footprints_clear(layout, layout.kitchen_point(), service) and _path_footprints_clear(layout, layout.service_point(id), return_path), "all moving footprints clear architecture %d/%d" % [width, id])
		occupied_route_usec += Time.get_ticks_usec() - occupied_started
		for queue_index: int in range(8):
			_check(not layout.route_avoiding_seats(layout.entrance_point(), layout.queue_point(queue_index)).is_empty(), "queue path %d/%d" % [width, queue_index])
		# Queue sprites are 96px high with their support near the bottom.  Neither
		# their visible pixels nor their table click hit area reaches final row.
		_check(layout.queue_point(0).y - 90.0 > layout.table_center(8).y + 82.0, "queue clears final-row visual and click target %d" % width)
		_check(layout.segment_is_walkable(layout.entrance_point(), Vector2(width * 0.5, 934.0)), "doorway-to-hall segment has no invisible strip %d" % width)
		_check(_path_crosses_y_in_x(first_path, 948.0, Vector2(width * 0.5 - 60.0, width * 0.5 + 60.0)), "entering route passes through visible doorway %d" % width)
		_check(not layout.is_walkable(Vector2(width * 0.5, 180.0)) and layout.is_walkable(Vector2(width * 0.5, 257.0)), "wall/kitchen is not walkable %d" % width)
	print("WIDE_V5_LAYOUT_FIRST_ROUTE_USEC total=%d widths=3" % route_build_usec)
	print("WIDE_V5_OCCUPIED_ROUTE_USEC total=%d routes=240" % occupied_route_usec)
	var one = Model.new(1536.0)
	var two = Model.new(2560.0)
	_check(not one.floor.table_center(1).is_equal_approx(two.floor.table_center(1)), "model floors are isolated")
	var money: int = one.coins
	var clock: float = one.clock
	_check(one.relayout(2560.0), "relayout accepts changed legal width")
	_check(one.coins == money and one.clock == clock and one.validate_invariants().is_empty(), "relayout preserves business state")
	_check(one.relayout(1536.0) and one.validate_invariants().is_empty(), "relayout round trip")
	var unchanged: Dictionary = one.to_dict()
	_check(one.relayout(1536.0) and Support.same(one.to_dict(), unchanged), "same-width relayout is an explicit no-op")
	var snapshot: Dictionary = one.to_dict()
	var old_v5: Dictionary = _freeze_open_floor_v5(snapshot, FloorLayout.legacy_revision_for_width(float(snapshot.layout_width)))
	_check(int(old_v5.version) == 5 and old_v5.customers.is_empty(), "frozen open-floor fixture is genuine V5")
	var same_width_old = Model.new(1536.0)
	_check(same_width_old.restore(old_v5) and same_width_old.floor.revision == FloorLayout.revision_for_width(1536.0), "old V5 same-width save validates then migrates")
	var cross_width_old = Model.new(2496.0)
	_check(cross_width_old.restore(old_v5) and is_equal_approx(cross_width_old.floor.layout_width, 2496.0), "old V5 cross-width save validates then migrates")
	var reopened = Model.new(4096.0)
	_check(reopened.restore(snapshot) and is_equal_approx(reopened.floor.layout_width, 4096.0), "V5 validates saved geometry then targets receiver width")
	var forged: Dictionary = snapshot.duplicate(true)
	forged.layout_width = 999.0
	_check(not reopened.restore(forged), "V5 rejects invalid width")
	forged = snapshot.duplicate(true)
	forged.layout_revision = int(forged.layout_revision) + 1
	_check(not reopened.restore(forged), "V5 rejects invalid revision")
	var restore_before: Dictionary = reopened.to_dict()
	forged = snapshot.duplicate(true)
	forged.tables[0].zone = "bar"
	_check(not reopened.restore(forged) and Support.same(reopened.to_dict(), restore_before), "V5 rejects mismatched table zone without mutating receiver")
	forged = snapshot.duplicate(true)
	forged.tables[19].label = "大厅 20"
	_check(not reopened.restore(forged), "V5 rejects mismatched table label")
	# A genuine vacant V4 snapshot uses the frozen b082 table/worker anchors.
	# It must be checked there before the model relocates it to FloorLayout.
	var legacy: Dictionary = snapshot.duplicate(true)
	legacy.version = 4
	legacy.erase("layout_width")
	legacy.erase("layout_revision")
	for index: int in range(legacy.tables.size()):
		var center: Vector2 = Floor.table_center(index + 1)
		legacy.tables[index].center = [center.x, center.y]
	for index: int in range(legacy.workers.size()):
		var home: Vector2 = Floor.worker_home(index)
		legacy.workers[index].pos = [home.x, home.y]
		legacy.workers[index].path = []
	var migrated = Model.new(2560.0)
	_check(migrated.restore(legacy) and is_equal_approx(migrated.floor.layout_width, 2560.0), "V4 validates frozen geometry then migrates")
	var bad_v4: Dictionary = legacy.duplicate(true)
	bad_v4.tables[0].center = [0.0, 0.0]
	_check(not migrated.restore(bad_v4), "forged V4 table coordinate is rejected")
	bad_v4 = legacy.duplicate(true)
	bad_v4.workers[0].pos = [0.0, 0.0]
	_check(not migrated.restore(bad_v4), "forged V4 worker coordinate is rejected")
	var cooking = Model.new()
	cooking.open_for_arrivals = false
	cooking.auto_seat = false
	cooking.auto_dispatch = false
	cooking.enable_interactive_cooking()
	cooking.spawn_customer("cat")
	cooking.assign_next(1)
	for step: int in range(80): cooking.tick(0.1)
	_check(cooking.table_action(1) == "order" and cooking.act(1, "order") and cooking.begin_cooking(1), "interactive cooking fixture starts")
	var cooking_before: Dictionary = cooking.active_cooking.duplicate(true)
	_check(cooking.relayout(2560.0) and cooking.paused and cooking.active_cooking == cooking_before, "relayout preserves paused active cooking")
	_test_moving_resize()
	_test_active_old_v5_migration()
	_test_edge_band_runtime_migration()
	_test_genuine_v4_kitchen_migration(cooking)
	_test_genuine_v4_claimed_task_migration()
	print("WIDE_V5_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _test_moving_resize() -> void:
	var resize_usec := 0
	var model = Model.new(1536.0)
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	model.auto_cook = false
	model.max_customers = 2
	var guest_id: int = model.spawn_customer("cat")
	_check(guest_id > 0 and model.assign_next(1), "moving-resize fixture assigns guest")
	model.tick(0.8)
	var guest: Dictionary = model.customers[guest_id]
	var old_patience: float = guest.patience
	var old_clock: float = model.clock
	var old_position: Vector2 = guest.pos
	_check(guest.state == "walking" and not old_position.is_equal_approx(model.floor.entrance_point()), "guest is physically moving before resize")
	for width: float in [2560.0, 4096.0, 1536.0]:
		var started := Time.get_ticks_usec()
		_check(model.relayout(width), "moving guest resize accepts %d" % width)
		resize_usec += Time.get_ticks_usec() - started
		guest = model.customers[guest_id]
		_check(guest.state == "walking" and not (guest.pos as Vector2).is_equal_approx(model.floor.entrance_point()), "resize does not reset guest to entrance %d" % width)
		_check(is_equal_approx(float(guest.patience), old_patience) and is_equal_approx(model.clock, old_clock), "resize keeps patience/clock %d" % width)
	for step: int in range(80):
		model.tick(0.1)
		if model.customers[guest_id].state == "seated":
			break
	_check(model.customers[guest_id].state == "seated" and model.validate_invariants().is_empty(), "repeated resize guest still arrives normally")
	model.tick(1.0)
	_check(model.act(1, "order") and model.act(1, "cook"), "moving-resize fixture makes a food task")
	for step: int in range(45): model.tick(0.1)
	_check(model.tasks.size() == 1 and model.claim_task(0, int(model.tasks[0].id)), "moving-resize fixture claims task")
	model.tick(0.35)
	var worker: Dictionary = model.workers[0]
	var worker_position: Vector2 = worker.pos
	var task_id: int = int(worker.task_id)
	_check(worker.state == "to_kitchen" and not worker_position.is_equal_approx(model.floor.kitchen_point()), "worker is moving before resize")
	var worker_resize_started := Time.get_ticks_usec()
	_check(model.relayout(2560.0), "claimed worker resize accepts")
	resize_usec += Time.get_ticks_usec() - worker_resize_started
	worker = model.workers[0]
	_check(worker.state == "to_kitchen" and int(worker.task_id) == task_id and not (worker.pos as Vector2).is_equal_approx(model.floor.worker_home(0)), "resize retains claimed worker progress")
	_check(model.validate_invariants().is_empty(), "claimed worker resize keeps invariants")
	print("WIDE_V5_RELAYOUT_USEC total=%d changed_widths=4" % resize_usec)


func _test_active_old_v5_migration() -> void:
	for revision: int in [FloorLayout.legacy_revision_for_width(1536.0), FloorLayout.g10_revision_for_width(1536.0)]:
		var old = FloorLayout.new(1536.0, revision)
		var label := "rev%d" % int(revision / FloorLayout.REVISION_VERSION_FACTOR)
		_check(old.revision == revision, "historical V5 fixture uses %s" % label)
		var source: Variant = _active_historic_v5_source(old)
		var seated_id := 1
		var walking_id := 2
		var queued_id := 3
		var departing_id := 4
		_check(source.customers[departing_id].state == "leaving" and source.validate_invariants().is_empty(), "%s queued/walking/departing source validates historically" % label)
		var snapshot: Dictionary = _freeze_open_floor_v5(source.to_dict(), revision)
		_check(int(snapshot.version) == 5 and int(snapshot.layout_revision) == revision and not snapshot.customers["1"].has("party_id"), "%s fixture has genuine V5 header and fields" % label)
		for width: float in [1536.0, 2496.0]:
			var target = Model.new(width)
			_check(target.restore(snapshot), "%s active V5 restores at width %d" % [label, width])
			_check(target.customers[queued_id].state == "queued" and (target.customers[queued_id].pos as Vector2).is_equal_approx(target.floor.queue_point(0)), "%s queued guest is re-queued %d" % [label, width])
			_check(target.customers[walking_id].state == "walking" and target.tables[14].guest_id == walking_id, "%s walking reservation survives %d" % [label, width])
			_check(target.customers[departing_id].state == "leaving" and not target.customers[departing_id].path.is_empty(), "%s departing guest is rerouted %d" % [label, width])
			_check(target.customers[seated_id].state == "seated" and target.tables[0].guest_id == seated_id and target.tables[0].used, "%s seated guest/table state survives %d" % [label, width])
			_check(target.validate_invariants().is_empty(), "%s target geometry validates %d" % [label, width])


func _active_historic_v5_source(old) -> Variant:
	var source = Model.new(1536.0)
	source.floor = old
	for index: int in range(source.tables.size()):
		var definition: Dictionary = old.table_definitions()[index]
		source.tables[index].center = definition.center
		source.tables[index].zone = definition.zone
		source.tables[index].label = definition.label
	for index: int in range(source.workers.size()):
		source.workers[index].pos = old.worker_home(index)
	source.open_for_arrivals = false
	source.auto_seat = false
	var seated_id: int = source.spawn_customer("dog")
	_check(seated_id > 0 and source.assign_next(1) and Support.until(source, func() -> bool: return source.customers[seated_id].state == "seated", 20.0), "historic source seats one guest")
	var walking_id: int = source.spawn_customer("cat")
	_check(walking_id > 0 and source.assign_next(15), "historic source starts walking guest")
	var queued_id: int = source.spawn_customer("panda")
	var departing_id: int = source.spawn_customer("otter")
	source.customers[departing_id].patience = 0.05
	source.tick(0.1)
	return source


func _test_edge_band_runtime_migration() -> void:
	# Only the restored terrace tables are right-edge anchored. Hall 13/14 now
	# belong to the expanding three-column centre.
	for table_id: int in [19, 20]:
		var model = _right_edge_returning_fixture(table_id)
		var worker: Dictionary = model.workers[0]
		var right_offset: float = model.floor.layout_width - float((worker.pos as Vector2).x)
		var tasks_before: Array = model.tasks.duplicate(true)
		var clock_before: float = model.clock
		_check(right_offset < FloorLayout.RIGHT_STRIP, "right service return enters terrace band %d" % table_id)
		for width: float in [4096.0, 1536.0, 2496.0]:
			_check(model.relayout(width), "right edge return relayout accepts %d/%d" % [table_id, width])
			worker = model.workers[0]
			_check(worker.state == "returning" and int(worker.task_id) == -1, "right edge return preserves worker state %d/%d" % [table_id, width])
			_check(is_equal_approx(model.floor.layout_width - float((worker.pos as Vector2).x), right_offset), "right edge offset stays anchored %d/%d" % [table_id, width])
			_check(Support.same(model.tasks, tasks_before) and is_equal_approx(model.clock, clock_before), "right edge relayout keeps task and timer %d/%d" % [table_id, width])
			_check(model.floor.path_avoids_seats(worker.pos, worker.path) and model.validate_invariants().is_empty(), "right edge regenerated return avoids seats %d/%d" % [table_id, width])
		var reopened = Model.new(4096.0)
		_check(reopened.restore(model.to_dict()), "right edge cross-width save restores %d" % table_id)
		worker = reopened.workers[0]
		_check(is_equal_approx(reopened.floor.layout_width - float((worker.pos as Vector2).x), right_offset) and Support.same(reopened.tasks, tasks_before) and is_equal_approx(reopened.clock, clock_before), "right edge cross-width save keeps anchor and business state %d" % table_id)
		_check(reopened.floor.path_avoids_seats(worker.pos, worker.path) and reopened.validate_invariants().is_empty(), "right edge restored return avoids seats %d" % table_id)
	# Preserve the fixed left-strip coordinate only for a real unoccupied point.
	var left_source = Floor.create(1536.0)
	var left_target = Model.new(4096.0)
	var safe_left_point := Vector2(136.0, 150.0)
	for candidate_floor in [left_source, left_target.floor]:
		var entry: Array[Vector2] = candidate_floor.route_avoiding_seats(candidate_floor.entrance_point(), safe_left_point)
		var exit: Array[Vector2] = candidate_floor.route_avoiding_seats(safe_left_point, candidate_floor.entrance_point())
		_check(candidate_floor.is_walkable(safe_left_point) and _outside_all_seat_reservations(candidate_floor, safe_left_point) and not entry.is_empty() and candidate_floor.path_avoids_seats(candidate_floor.entrance_point(), entry) and not exit.is_empty() and candidate_floor.path_avoids_seats(safe_left_point, exit), "safe left-strip fixture is unoccupied and has entry/exit routes %d" % candidate_floor.layout_width)
	var left_actor: Dictionary = {"id": 99, "pos": safe_left_point, "path": [], "route_blocked": false}
	_check(left_source.is_walkable(left_actor.pos), "safe left-strip fixture starts walkable")
	_check(left_target._map_actor_position(left_actor, left_source, left_target.floor.entrance_point()), "left edge maps to wide floor")
	_check(is_equal_approx(float((left_actor.pos as Vector2).x), safe_left_point.x) and _outside_all_seat_reservations(left_target.floor, left_actor.pos), "left edge offset is unchanged on wide floor")
	var left_return = Model.new(1536.0)
	_check(left_return._map_actor_position(left_actor, left_target.floor, left_return.floor.entrance_point()), "left edge maps back to narrow floor")
	_check(is_equal_approx(float((left_actor.pos as Vector2).x), safe_left_point.x) and _outside_all_seat_reservations(left_return.floor, left_actor.pos), "left edge offset is unchanged on narrow floor")
	# This former fixture point is walkable but occupied by table 15's new left
	# seat reservation. It must relocate to a legal point, not masquerade as an
	# edge-anchor preservation case.
	var unsafe_left_point := Vector2(100.0, 170.0)
	var unsafe_actor: Dictionary = {"id": 100, "pos": unsafe_left_point, "path": [], "route_blocked": false}
	_check(left_source.is_walkable(unsafe_left_point) and left_source.seat_reservation(15, 1).has_point(unsafe_left_point), "old left-strip point is now table 15 left-seat reserved")
	_check(left_target._map_actor_position(unsafe_actor, left_source, left_target.floor.entrance_point()), "unsafe old left point relocates to wide floor")
	var relocated_exit: Array[Vector2] = left_target.floor.route_avoiding_seats(unsafe_actor.pos, left_target.floor.entrance_point())
	_check(not (unsafe_actor.pos as Vector2).is_equal_approx(unsafe_left_point) and left_target.floor.is_walkable(unsafe_actor.pos) and _outside_all_seat_reservations(left_target.floor, unsafe_actor.pos) and not relocated_exit.is_empty() and left_target.floor.path_avoids_seats(unsafe_actor.pos, relocated_exit), "unsafe old left point relocates legally")


func _right_edge_returning_fixture(table_id: int):
	var model = Model.new(1536.0)
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	model.auto_cook = false
	var guest_id: int = model.spawn_customer("dog")
	_check(guest_id > 0 and model.assign_next(table_id), "right edge fixture assigns table %d" % table_id)
	_check(Support.until(model, func() -> bool: return model.customers[guest_id].state == "seated", 20.0), "right edge fixture reaches table %d" % table_id)
	model.tick(1.0)
	_check(model.act(table_id, "order") and model.act(table_id, "cook"), "right edge fixture starts food task %d" % table_id)
	model.tick(4.1)
	_check(model.tasks.size() == 1 and model.claim_task(0, int(model.tasks[0].id)), "right edge fixture claims food task %d" % table_id)
	_check(Support.until(model, func() -> bool: return model.workers[0].state == "working", 20.0), "right edge fixture reaches service point %d" % table_id)
	_check((model.workers[0].pos as Vector2).is_equal_approx(model.floor.service_point(table_id)), "right edge fixture uses service point %d" % table_id)
	model.tick(0.81)
	_check(model.workers[0].state == "returning", "right edge fixture completes service task %d" % table_id)
	model.tick(0.04)
	return model


func _test_genuine_v4_kitchen_migration(cooking: Variant) -> void:
	var legacy: Dictionary = _freeze_v4_geometry(cooking.to_dict())
	var migrated = Model.new(2560.0)
	_check(migrated.restore(legacy), "frozen V4 active kitchen fixture migrates")
	_check(migrated.paused and not migrated.active_cooking.is_empty() and migrated.validate_invariants().is_empty(), "V4 active cooking survives target validation")
	var reopened = Model.new(4096.0)
	_check(reopened.restore(migrated.to_dict()) and reopened.relayout(1536.0), "V4-to-V5 save reopens and resizes")
	_check(reopened.active_cooking == migrated.active_cooking and reopened.coins == migrated.coins and reopened.validate_invariants().is_empty(), "V4-to-V5 reopen does not lose food or duplicate settlement")


func _test_genuine_v4_claimed_task_migration() -> void:
	var source = Model.new()
	source.open_for_arrivals = false
	source.auto_seat = false
	source.auto_dispatch = false
	source.auto_cook = false
	source.spawn_customer("dog")
	source.assign_next(2)
	for step: int in range(90):
		source.tick(0.1)
		if source.table_action(2) == "order":
			break
	_check(source.act(2, "order") and source.act(2, "cook"), "V4 claimed-task fixture starts food")
	for step: int in range(45): source.tick(0.1)
	_check(source.tasks.size() == 1 and source.claim_task(0, int(source.tasks[0].id)), "V4 claimed-task fixture claims food")
	var task_before: Dictionary = source.tasks[0].duplicate(true)
	var patience_before: float = source.customers[1].patience
	var clock_before: float = source.clock
	var legacy: Dictionary = _freeze_v4_geometry(source.to_dict())
	# An authentic old travelling worker route, rather than V5 coordinates with
	# a version edit, is retained until the old-map validation stage.
	var old_home: Vector2 = Floor.worker_home(0)
	var old_kitchen: Vector2 = Floor.kitchen_point()
	var old_path: Array[Vector2] = Floor.route(old_home, old_kitchen)
	legacy.workers[0].pos = [old_home.x, old_home.y]
	legacy.workers[0].path = []
	for point: Vector2 in old_path:
		legacy.workers[0].path.append([point.x, point.y])
	var migrated = Model.new(4096.0)
	_check(migrated.restore(legacy), "frozen V4 travelling claimed task migrates")
	_check(migrated.tasks.size() == 1 and migrated.tasks[0] == task_before and migrated.workers[0].state == "to_kitchen", "V4 claimed task identity/state survive")
	_check(is_equal_approx(migrated.customers[1].patience, patience_before) and is_equal_approx(migrated.clock, clock_before), "V4 claimed task keeps patience and clock")
	_check(migrated.validate_invariants().is_empty(), "V4 claimed task target geometry validates")


func _freeze_open_floor_v5(snapshot: Dictionary, revision: int) -> Dictionary:
	var legacy := snapshot.duplicate(true)
	var width := float(legacy.layout_width)
	legacy.version = 5
	legacy.layout_revision = revision
	var historic_floor = FloorLayout.new(width, revision)
	for guest: Dictionary in legacy.customers.values():
		for key: String in ["party_id", "party_size", "seat_index", "companions", "arrival", "stand_elapsed", "transition", "transition_elapsed", "departed"]:
			guest.erase(key)
	for index: int in range(legacy.tables.size()):
		var center: Vector2 = historic_floor.table_center(index + 1)
		legacy.tables[index].center = [center.x, center.y]
	for index: int in range(legacy.workers.size()):
		var home: Vector2 = historic_floor.worker_home(index)
		legacy.workers[index].pos = [home.x, home.y]
		legacy.workers[index].path = []
	return legacy


func _historical_table_center(width: float, id: int) -> Vector2:
	var xs: Array[float] = [155.0, lerpf(155.0,width-155.0,0.25), lerpf(155.0,width-155.0,0.5), lerpf(155.0,width-155.0,0.75), width-155.0]
	var ys: Array[float] = [340.0,490.0,645.0,800.0]
	if id >= 15 and id <= 18: return Vector2(xs[0],ys[id-15])
	if id <= 12: return Vector2(xs[1 + (id-1)/4],ys[(id-1)%4])
	var right_row := id - 13 if id <= 14 else id - 17
	return Vector2(xs[4],ys[right_row])


func _outside_all_seat_reservations(layout: Variant, point: Vector2) -> bool:
	for table_id: int in range(1, 21):
		for seat_index: int in range(layout.table_capacity(table_id)):
			if layout.seat_reservation(table_id, seat_index).has_point(point):
				return false
	return true


func _footprint_clears_architecture(layout: Variant, point: Vector2) -> bool:
	var footprint: Rect2 = layout.actor_ground_footprint(point)
	for wall: Rect2 in layout.architecture_obstacles():
		if footprint.intersects(wall): return false
	return true


func _path_footprints_clear(layout: Variant, start: Vector2, path: Array[Vector2]) -> bool:
	var previous := start
	for finish: Vector2 in path:
		var steps := maxi(1, ceili(previous.distance_to(finish) / 8.0))
		for step: int in range(steps + 1):
			if not _footprint_clears_architecture(layout, previous.lerp(finish, float(step) / steps)): return false
		previous = finish
	return true


func _path_crosses_x_in_y(path: Array[Vector2], x: float, y_range: Vector2) -> bool:
	for index: int in range(1, path.size()):
		var a := path[index - 1]
		var b := path[index]
		if (a.x - x) * (b.x - x) > 0.0 or is_equal_approx(a.x, b.x):
			continue
		var y := lerpf(a.y, b.y, inverse_lerp(a.x, b.x, x))
		if y >= y_range.x and y <= y_range.y:
			return true
	return false


func _path_crosses_y_in_x(path: Array[Vector2], y: float, x_range: Vector2) -> bool:
	for index: int in range(1, path.size()):
		var a := path[index - 1]
		var b := path[index]
		if (a.y - y) * (b.y - y) > 0.0 or is_equal_approx(a.y, b.y): continue
		var x := lerpf(a.x, b.x, inverse_lerp(a.y, b.y, y))
		if x >= x_range.x and x <= x_range.y: return true
	return false


func _freeze_v4_geometry(v5: Dictionary) -> Dictionary:
	var legacy: Dictionary = v5.duplicate(true)
	legacy.version = 4
	legacy.erase("layout_width")
	legacy.erase("layout_revision")
	for guest: Dictionary in legacy.customers.values():
		for key: String in ["party_id", "party_size", "seat_index", "companions", "arrival", "stand_elapsed", "transition", "transition_elapsed", "departed"]:
			guest.erase(key)
	# Freeze every spatial record to the old V4 facade; this is deliberately not
	# a V5 snapshot with only its version field changed.
	for index: int in range(legacy.tables.size()):
		var center: Vector2 = Floor.table_center(index + 1)
		legacy.tables[index].center = [center.x, center.y]
	for id: Variant in legacy.customers:
		var guest: Dictionary = legacy.customers[id]
		var table_id: int = int(guest.table_id)
		if guest.state == "seated":
			var seat: Vector2 = Floor.seat_point(table_id)
			guest.pos = [seat.x, seat.y]
			guest.path = []
	for index: int in range(legacy.workers.size()):
		var home: Vector2 = Floor.worker_home(index)
		legacy.workers[index].pos = [home.x, home.y]
		legacy.workers[index].path = []
	return legacy
