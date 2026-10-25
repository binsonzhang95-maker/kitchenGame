extends RefCounted
## Twenty-table simulation. All movement goes through the floor's navigation route.
## Constructing this model creates no guests and performs no file IO.

const Floor = preload("res://floor_plan.gd")
const CookingSession = preload("res://cooking_session.gd")
const SAVE_VERSION: int = 4
const RECIPE_IDS: Array[String] = ["soup", "stir_fry", "bake", "drink"]
## Schema 2 always denotes the original 1120 x 640 layout, never the new floor.
const V2_TABLE_CENTERS: Array[Vector2] = [
	Vector2(350, 210), Vector2(485, 210), Vector2(620, 210), Vector2(755, 210), Vector2(890, 210),
	Vector2(350, 375), Vector2(485, 375), Vector2(620, 375), Vector2(755, 375), Vector2(890, 375),
	Vector2(350, 540), Vector2(485, 540), Vector2(620, 540), Vector2(755, 540),
	Vector2(65, 250), Vector2(200, 250), Vector2(65, 450), Vector2(200, 450),
	Vector2(1045, 250), Vector2(1045, 450),
]
const MEAL_PRICE: int = 38
const SPECIES: Array[String] = ["cat", "dog", "panda", "raccoon", "red_panda", "squirrel", "hedgehog", "otter", "capybara", "koala", "deer", "sheep", "pig", "hamster", "penguin", "duck", "frog"]
const TABLE_PHASES: Array[String] = ["free", "reserved", "ordering", "awaiting_cook", "cooking", "food_ready", "serving_food", "waiting_drink", "serving_drink", "eating", "drinking", "checkout", "leaving", "dirty", "collecting", "wiping"]
const CUSTOMER_STATES: Array[String] = ["queued", "walking", "seated", "leaving"]
const WORKER_STATES: Array[String] = ["idle", "to_kitchen", "to_table", "working", "returning"]
const WALK_SPEED: float = 217.5
const WORK_SPEED: float = 262.5
const ARRIVAL_INTERVAL: float = 8.0
const QUEUE_LIMIT: int = 8

var tables: Array[Dictionary] = []
var customers: Dictionary = {}
var workers: Array[Dictionary] = []
var tasks: Array[Dictionary] = []
var coins: int = 0
var served: int = 0
var lost: int = 0
var rejected: int = 0
var paused: bool = false
var open_for_arrivals: bool = true
var auto_seat: bool = true
var auto_dispatch: bool = true
var auto_cook: bool = false
## Session policy, deliberately absent from save data. Main enables this after
## loading so older manual-operation settings cannot stall player-only ordering.
var player_mode: bool = false
var interactive_cooking: bool = false
var active_cooking: Dictionary = {}
var cooking_return_paused: bool = false
var cooking_session_seq: int = 0
var cooking_session_token: int = 0
var max_customers: int = 6
var clock: float = 0.0
var chef: Dictionary = {"table_id": -1, "elapsed": 0.0}
var paid_ledger: Dictionary = {}
var lost_ledger: Dictionary = {}
var next_customer_id: int = 1
var next_task_id: int = 1
var next_table_cursor: int = 0
var arrival_elapsed: float = 0.0
var legacy_served: int = 0
var legacy_lost: int = 0


func _init() -> void:
	for definition: Dictionary in Floor.table_definitions():
		tables.append({"id": int(definition.id), "zone": str(definition.zone), "label": str(definition.label), "center": definition.center, "phase": "free", "guest_id": 0, "food": false, "drink": false, "elapsed": 0.0, "used": false, "generation": 0, "ordered_at": 0.0, "recipe_id": ""})
	tables.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.id) < int(b.id))
	for id: int in range(2):
		workers.append({"id": id, "species": "rabbit" if id == 0 else "fox", "state": "idle", "pos": worker_home(id), "path": [], "task_id": -1, "elapsed": 0.0, "route_blocked": false})


func worker_home(id: int) -> Vector2:
	return Floor.worker_home(id)


func enable_player_mode() -> void:
	# Changing policy does not tick, pay, or write a save. Paused saves stay paused.
	player_mode = true
	_enforce_player_automation()


func _enforce_player_automation() -> void:
	open_for_arrivals = true
	auto_seat = true
	auto_dispatch = true
	auto_cook = not interactive_cooking


func enable_interactive_cooking() -> void:
	interactive_cooking = true
	auto_cook = false
	# Old automatic cooks have no player action history. Keep their order and
	# identity, but require a fresh interactive preparation before food is made.
	if int(chef.table_id) > 0:
		var table: Dictionary = _table(int(chef.table_id))
		if not table.is_empty() and table.phase == "cooking":
			_set_phase(table, "awaiting_cook")
		chef = {"table_id": -1, "elapsed": 0.0}
	if not active_cooking.is_empty():
		paused = true


func recipe_for_guest(guest_id: int) -> String:
	return RECIPE_IDS[(guest_id - 1) % RECIPE_IDS.size()] if guest_id > 0 else ""


func _cooking_binding_valid(session) -> bool:
	var binding: Dictionary = session.binding
	var table: Dictionary = _table(int(binding.get("table_id", 0)))
	if table.is_empty() or table.phase != "awaiting_cook" or bool(table.food) or bool(table.drink):
		return false
	var guest_id: int = int(binding.get("guest_id", 0))
	return int(table.guest_id) == guest_id and int(table.generation) == int(binding.get("generation", 0)) and str(table.recipe_id) == str(session.recipe_id) and customers.has(guest_id) and customers[guest_id].state == "seated" and not bool(customers[guest_id].paid) and not bool(customers[guest_id].timed_out) and not _has_task(int(table.id), "food")


func begin_cooking(table_id: int) -> bool:
	if not interactive_cooking or not active_cooking.is_empty() or int(chef.table_id) != -1:
		return false
	var table: Dictionary = _table(table_id)
	if table.is_empty() or table.phase != "awaiting_cook":
		return false
	var session = CookingSession.new()
	if not session.setup({"table_id": table_id, "guest_id": int(table.guest_id), "generation": int(table.generation)}, str(table.recipe_id)) or not _cooking_binding_valid(session):
		return false
	cooking_return_paused = paused
	paused = true
	active_cooking = session.to_dict()
	cooking_session_seq += 1
	cooking_session_token = cooking_session_seq
	return true


func sync_cooking(snapshot: Dictionary, token: int) -> bool:
	if not interactive_cooking or active_cooking.is_empty() or not paused or token != cooking_session_token:
		return false
	var session = CookingSession.new()
	if not session.restore(snapshot) or session.cancelled or not _cooking_binding_valid(session):
		return false
	if session.binding != active_cooking.get("binding") or session.recipe_id != active_cooking.get("recipe_id"):
		return false
	active_cooking = session.to_dict()
	return true


func cancel_cooking(token: int) -> bool:
	if active_cooking.is_empty() or token != cooking_session_token:
		return false
	active_cooking.clear()
	paused = cooking_return_paused
	cooking_return_paused = false
	cooking_session_token = 0
	return true


func complete_cooking(snapshot: Dictionary, token: int) -> bool:
	if not interactive_cooking or not paused or active_cooking.is_empty() or token != cooking_session_token:
		return false
	var session = CookingSession.new()
	if not session.restore(snapshot) or not session.completed or session.cancelled or not _cooking_binding_valid(session):
		return false
	if session.binding != active_cooking.get("binding") or session.recipe_id != active_cooking.get("recipe_id"):
		return false
	var table: Dictionary = _table(int(session.binding.table_id))
	_set_phase(table, "food_ready")
	_enqueue("food", table)
	customers[int(table.guest_id)].patience = 120.0
	active_cooking.clear()
	paused = cooking_return_paused
	cooking_return_paused = false
	cooking_session_token = 0
	return true


func _advance_player_tables() -> void:
	for table: Dictionary in tables:
		match str(table.phase):
			"checkout":
				act(int(table.id), "pay")
			"dirty":
				# act() refuses a second cleanup task and waits for physical exit.
				act(int(table.id), "clean")


func _table(id: int) -> Dictionary:
	if id < 1 or id > tables.size():
		return {}
	return tables[id - 1]


func queue_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: int in customers:
		if customers[id].state == "queued":
			ids.append(id)
	ids.sort()
	return ids


func spawn_customer(species: String = "") -> int:
	if paused or customers.size() >= max_customers or queue_ids().size() >= QUEUE_LIMIT:
		if not paused:
			rejected += 1
		return -1
	if not species.is_empty() and species not in SPECIES:
		return -1
	var id: int = next_customer_id
	next_customer_id += 1
	if species.is_empty():
		species = SPECIES[(id - 1) % SPECIES.size()]
	var guest: Dictionary = {"id": id, "species": species, "table_id": 0, "state": "queued", "pos": Floor.entrance_point(), "path": [], "patience": 45.0, "paid": false, "timed_out": false, "created": clock, "route_blocked": false}
	customers[id] = guest
	_route_to(guest, Floor.queue_point(queue_ids().size() - 1))
	return id


func assign_next(table_id: int) -> bool:
	if paused:
		return false
	var table: Dictionary = _table(table_id)
	var ids: Array[int] = queue_ids()
	if table.is_empty() or table.phase != "free" or ids.is_empty():
		return false
	var guest: Dictionary = customers[ids[0]]
	table.generation = int(table.generation) + 1
	table.guest_id = int(guest.id)
	table.recipe_id = recipe_for_guest(int(guest.id))
	table.used = false
	_set_phase(table, "reserved")
	guest.table_id = table_id
	guest.state = "walking"
	guest.patience = 120.0
	_route_to(guest, Floor.seat_point(table_id))
	next_table_cursor = table_id % tables.size()
	_reflow_queue()
	return true


func table_action(table_id: int) -> String:
	if paused:
		return ""
	var table: Dictionary = _table(table_id)
	if table.is_empty():
		return ""
	match str(table.phase):
		"free": return "assign" if not queue_ids().is_empty() else ""
		"ordering": return "order" if float(table.elapsed) >= 0.92 else ""
		"awaiting_cook": return "cook" if int(chef.table_id) == -1 else ""
		"checkout": return "pay"
		"dirty": return "clean" if not _has_task(table_id, "clean") else ""
	return ""


func act(table_id: int, action: String) -> bool:
	if action.is_empty() or action != table_action(table_id):
		return false
	var table: Dictionary = _table(table_id)
	match action:
		"assign": return assign_next(table_id)
		"order":
			table.ordered_at = clock
			_set_phase(table, "awaiting_cook")
			customers[int(table.guest_id)].patience = 120.0
		"cook": return _start_cook(table_id)
		"pay":
			var id: int = int(table.guest_id)
			if not customers.has(id) or paid_ledger.has(str(id)) or bool(customers[id].paid):
				return false
			paid_ledger[str(id)] = true
			customers[id].paid = true
			coins += MEAL_PRICE
			served += 1
			_begin_leave(customers[id], false)
		"clean":
			if int(table.guest_id) != 0:
				return false
			_enqueue("clean", table)
		_:
			return false
	return true


func cook_next() -> bool:
	if interactive_cooking or paused or int(chef.table_id) != -1:
		return false
	var choice: int = -1
	var oldest: float = INF
	for table: Dictionary in tables:
		if table.phase == "awaiting_cook" and float(table.ordered_at) < oldest:
			choice = int(table.id)
			oldest = float(table.ordered_at)
	return _start_cook(choice) if choice > 0 else false


func _start_cook(table_id: int) -> bool:
	var table: Dictionary = _table(table_id)
	if interactive_cooking or paused or int(chef.table_id) != -1 or table.is_empty() or table.phase != "awaiting_cook":
		return false
	chef = {"table_id": table_id, "elapsed": 0.0}
	_set_phase(table, "cooking")
	return true


func _enqueue(kind: String, table: Dictionary) -> void:
	if _has_task(int(table.id), kind):
		return
	tasks.append({"id": next_task_id, "kind": kind, "table_id": int(table.id), "guest_id": int(table.guest_id), "generation": int(table.generation), "state": "queued", "worker_id": -1, "created": clock})
	next_task_id += 1


func _has_task(table_id: int, kind: String) -> bool:
	for task: Dictionary in tasks:
		if int(task.table_id) == table_id and task.kind == kind:
			return true
	return false


func _task(id: int) -> Dictionary:
	for task: Dictionary in tasks:
		if int(task.id) == id:
			return task
	return {}


func _task_current(task: Dictionary) -> bool:
	var table: Dictionary = _table(int(task.table_id))
	if table.is_empty() or int(table.generation) != int(task.generation) or int(table.guest_id) != int(task.guest_id):
		return false
	if task.kind == "clean":
		return int(table.guest_id) == 0 and table.phase in ["dirty", "collecting", "wiping"]
	if not customers.has(int(task.guest_id)) or customers[int(task.guest_id)].state != "seated":
		return false
	return table.phase in (["food_ready", "serving_food"] if task.kind == "food" else ["waiting_drink", "serving_drink"])


func claim_task(worker_id: int, task_id: int) -> bool:
	if paused or worker_id < 0 or worker_id >= workers.size():
		return false
	var worker: Dictionary = workers[worker_id]
	var task: Dictionary = _task(task_id)
	if worker.state != "idle" or task.is_empty() or task.state != "queued" or not _task_current(task):
		return false
	# Claim both references synchronously before scheduling any movement.
	task.state = "claimed"
	task.worker_id = worker_id
	worker.task_id = task_id
	worker.elapsed = 0.0
	if task.kind == "clean":
		worker.state = "to_table"
		_route_to(worker, Floor.service_point(int(task.table_id)))
	else:
		worker.state = "to_kitchen"
		_route_to(worker, Floor.kitchen_point())
		_set_phase(_table(int(task.table_id)), "serving_food" if task.kind == "food" else "serving_drink")
	return true


func tick(delta: float) -> void:
	if interactive_cooking:
		auto_cook = false
	if not active_cooking.is_empty():
		paused = true
		return
	if paused or not is_finite(delta) or delta <= 0.0:
		return
	if player_mode:
		_enforce_player_automation()
	var remaining: float = delta
	while remaining > 0.000001 and not paused:
		var step: float = minf(0.1, remaining)
		_tick_step(step)
		remaining -= step


func _tick_step(delta: float) -> void:
	clock += delta
	if player_mode:
		# A restored checkout is settled before its remaining patience is spent.
		_advance_player_tables()
	_tick_customers(delta)
	_tick_tables(delta)
	_tick_workers(delta)
	if player_mode:
		# Newly finished drinks and departed guests can settle/queue cleanup now.
		_advance_player_tables()
	if auto_seat:
		for offset: int in range(tables.size()):
			var index: int = (next_table_cursor + offset) % tables.size()
			var queue: Array[int] = queue_ids()
			if queue.is_empty():
				break
			if clock - float(customers[queue[0]].created) < 0.8:
				break
			if tables[index].phase == "free":
				assign_next(int(tables[index].id))
				break
	if auto_cook and not interactive_cooking:
		cook_next()
	if auto_dispatch:
		# Monotonic task IDs give FIFO service, independently of table ID.
		for worker: Dictionary in workers:
			if worker.state == "idle":
				for task: Dictionary in tasks:
					if task.state == "queued" and claim_task(int(worker.id), int(task.id)):
						break
	if open_for_arrivals:
		arrival_elapsed += delta
		if arrival_elapsed >= ARRIVAL_INTERVAL:
			arrival_elapsed -= ARRIVAL_INTERVAL
			spawn_customer()


func _tick_customers(delta: float) -> void:
	for id: int in customers.keys():
		var guest: Dictionary = customers[id]
		var table: Dictionary = _table(int(guest.table_id))
		if guest.state == "leaving":
			if _move_actor(guest, WALK_SPEED, delta):
				if not table.is_empty() and int(table.guest_id) == id:
					table.guest_id = 0
					if bool(table.used):
						_set_phase(table, "dirty")
					else:
						_release_table(table)
				customers.erase(id)
				_reflow_queue()
			continue
		var needs_patience: bool = guest.state in ["queued", "walking"] or (guest.state == "seated" and table.phase not in ["eating", "drinking"])
		if needs_patience:
			guest.patience = maxf(0.0, float(guest.patience) - delta)
			if float(guest.patience) <= 0.0:
				_begin_leave(guest, true)
				continue
		if guest.state == "queued":
			_move_actor(guest, WALK_SPEED, delta)
		elif guest.state == "walking" and _move_actor(guest, WALK_SPEED, delta):
			guest.state = "seated"
			guest.patience = 120.0
			table.used = true
			_set_phase(table, "ordering")


func _tick_tables(delta: float) -> void:
	for table: Dictionary in tables:
		if table.phase != "free":
			table.elapsed = float(table.elapsed) + delta
		if table.phase == "eating" and float(table.elapsed) >= 5.0:
			_set_phase(table, "drinking")
		elif table.phase == "drinking" and float(table.elapsed) >= 2.0:
			_set_phase(table, "checkout")
			customers[int(table.guest_id)].patience = 120.0
	if int(chef.table_id) > 0 and not interactive_cooking:
		chef.elapsed = float(chef.elapsed) + delta
		if float(chef.elapsed) >= 4.0:
			var table: Dictionary = _table(int(chef.table_id))
			chef = {"table_id": -1, "elapsed": 0.0}
			if table.phase == "cooking":
				_set_phase(table, "food_ready")
				_enqueue("food", table)


func _tick_workers(delta: float) -> void:
	for worker: Dictionary in workers:
		if worker.state == "idle":
			continue
		if worker.state == "returning":
			if _move_actor(worker, WORK_SPEED, delta):
				worker.state = "idle"
				worker.elapsed = 0.0
			continue
		var task: Dictionary = _task(int(worker.task_id))
		if task.is_empty() or not _task_current(task):
			_cancel_worker(worker)
			continue
		var table: Dictionary = _table(int(task.table_id))
		if worker.state == "to_kitchen":
			if _move_actor(worker, WORK_SPEED, delta):
				worker.state = "to_table"
				_route_to(worker, Floor.service_point(int(table.id)))
		elif worker.state == "to_table":
			if _move_actor(worker, WORK_SPEED, delta):
				worker.state = "working"
				worker.elapsed = 0.0
				if task.kind == "clean":
					_set_phase(table, "collecting")
		elif worker.state == "working":
			worker.elapsed = float(worker.elapsed) + delta
			if task.kind == "clean":
				if table.phase == "collecting" and float(worker.elapsed) >= 1.0:
					table.food = false
					table.drink = false
					_set_phase(table, "wiping")
					worker.elapsed = 0.0
				elif table.phase == "wiping" and float(worker.elapsed) >= 1.0:
					_release_table(table)
					_finish_task(worker, task)
			elif float(worker.elapsed) >= 0.8:
				if task.kind == "food":
					table.food = true
					_set_phase(table, "waiting_drink")
					customers[int(table.guest_id)].patience = 120.0
					_finish_task(worker, task)
					_enqueue("drink", table)
				else:
					table.drink = true
					_set_phase(table, "eating")
					_finish_task(worker, task)


func _finish_task(worker: Dictionary, task: Dictionary) -> void:
	tasks.erase(task)
	_cancel_worker(worker)


func _cancel_worker(worker: Dictionary) -> void:
	worker.task_id = -1
	worker.elapsed = 0.0
	worker.state = "returning"
	_route_to(worker, worker_home(int(worker.id)))


func _begin_leave(guest: Dictionary, timeout: bool) -> void:
	if guest.state == "leaving":
		return
	var id: int = int(guest.id)
	if timeout and not bool(guest.paid) and not lost_ledger.has(str(id)):
		lost_ledger[str(id)] = true
		lost += 1
		guest.timed_out = true
	var table: Dictionary = _table(int(guest.table_id))
	if not table.is_empty():
		if int(chef.table_id) == int(table.id):
			chef = {"table_id": -1, "elapsed": 0.0}
		for task: Dictionary in tasks.duplicate():
			if int(task.table_id) == int(table.id) and int(task.guest_id) == id:
				if task.state == "claimed":
					_cancel_worker(workers[int(task.worker_id)])
				tasks.erase(task)
		_set_phase(table, "leaving")
	guest.state = "leaving"
	_route_to(guest, Floor.entrance_point())
	_reflow_queue()


func _set_phase(table: Dictionary, phase: String) -> void:
	table.phase = phase
	table.elapsed = 0.0


func _release_table(table: Dictionary) -> void:
	table.guest_id = 0
	table.recipe_id = ""
	table.used = false
	table.food = false
	table.drink = false
	_set_phase(table, "free")


func _route_to(actor: Dictionary, destination: Vector2) -> void:
	var path: Array[Vector2] = Floor.route(actor.pos, destination)
	actor.path = path
	actor.route_blocked = path.is_empty() and not (actor.pos as Vector2).is_equal_approx(destination)


func _move_actor(actor: Dictionary, speed: float, delta: float) -> bool:
	if bool(actor.get("route_blocked", false)):
		return false
	var distance: float = speed * delta
	var path: Array = actor.path
	while not path.is_empty():
		var target: Vector2 = path[0]
		var position: Vector2 = actor.pos
		var length: float = position.distance_to(target)
		if length <= distance + 0.00001:
			actor.pos = target
			distance = maxf(0.0, distance - length)
			path.remove_at(0)
		else:
			actor.pos = position.move_toward(target, distance)
			break
	actor.path = path
	return path.is_empty()


func _reflow_queue() -> void:
	var ids: Array[int] = queue_ids()
	for index: int in range(ids.size()):
		_route_to(customers[ids[index]], Floor.queue_point(index))


func to_dict() -> Dictionary:
	return _encode({"version": SAVE_VERSION, "tables": tables, "customers": customers, "workers": workers, "tasks": tasks, "coins": coins, "served": served, "lost": lost, "rejected": rejected, "paused": paused, "open_for_arrivals": open_for_arrivals, "auto_seat": auto_seat, "auto_dispatch": auto_dispatch, "auto_cook": auto_cook, "interactive_cooking": interactive_cooking, "active_cooking": active_cooking, "cooking_return_paused": cooking_return_paused, "cooking_session_seq": cooking_session_seq, "cooking_session_token": cooking_session_token, "max_customers": max_customers, "clock": clock, "chef": chef, "paid_ledger": paid_ledger, "lost_ledger": lost_ledger, "next_customer_id": next_customer_id, "next_task_id": next_task_id, "next_table_cursor": next_table_cursor, "arrival_elapsed": arrival_elapsed, "legacy_served": legacy_served, "legacy_lost": legacy_lost})


func _encode(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[str(key)] = _encode(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_encode(item))
		return result
	return value


func restore(data: Dictionary) -> bool:
	if not _integer(data.get("version")):
		return false
	if int(data.version) < SAVE_VERSION:
		for key: String in ["interactive_cooking", "active_cooking", "cooking_return_paused", "cooking_session_seq", "cooking_session_token"]:
			if data.has(key):
				return false
	if int(data.version) == 1:
		return _restore_v1(data)
	if int(data.version) == 2:
		return _restore_v2(data)
	if int(data.version) not in [3, SAVE_VERSION]:
		return false
	var candidate = get_script().new()
	if not candidate._read_snapshot(data) or not candidate.validate_invariants().is_empty():
		return false
	_copy_from(candidate)
	return true


func _restore_v2(data: Dictionary) -> bool:
	# Decode into a private candidate. Spatial data is intentionally rebuilt;
	# economic state, phases, clocks, patience, and task identities are untouched.
	var candidate = get_script().new()
	if not candidate._read_snapshot(data) or not candidate._is_v2_layout():
		return false
	if not candidate._relocate_v2_actors() or not candidate.validate_invariants().is_empty():
		return false
	_copy_from(candidate)
	return true


func _is_v2_layout() -> bool:
	if tables.size() != V2_TABLE_CENTERS.size():
		return false
	for index: int in range(tables.size()):
		var table: Dictionary = tables[index]
		if int(table.id) != index + 1 or not (table.center as Vector2).is_equal_approx(V2_TABLE_CENTERS[index]):
			return false
	return true


func _relocate_v2_actors() -> bool:
	for table: Dictionary in tables:
		table.center = Floor.table_center(int(table.id))
	var queue: Array[int] = queue_ids()
	for id: int in customers:
		var guest: Dictionary = customers[id]
		var table_id: int = int(guest.table_id)
		if guest.state not in CUSTOMER_STATES or table_id < 0 or table_id > tables.size() or bool(guest.route_blocked):
			return false
		var table: Dictionary = _table(table_id)
		if guest.state == "seated":
			if table.is_empty() or not guest.path.is_empty() or not (guest.pos as Vector2).is_equal_approx(V2_TABLE_CENTERS[table_id - 1] + Vector2(0, -60)):
				return false
		guest.path = []
		guest.route_blocked = false
		match str(guest.state):
			"queued":
				if table_id != 0:
					return false
				guest.pos = Floor.queue_point(queue.find(id))
			"walking":
				if table.is_empty():
					return false
				guest.pos = Floor.entrance_point()
				_route_to(guest, Floor.seat_point(table_id))
			"seated":
				if table.is_empty():
					return false
				guest.pos = Floor.seat_point(table_id)
			"leaving":
				# A guest may have reserved a table but timed out before sitting.
				guest.pos = Floor.seat_point(table_id) if not table.is_empty() and bool(table.used) else Floor.queue_point(0)
				_route_to(guest, Floor.entrance_point())
	for index: int in range(workers.size()):
		var worker: Dictionary = workers[index]
		if int(worker.id) != index or worker.state not in WORKER_STATES or bool(worker.route_blocked):
			return false
		if worker.state == "working":
			var active_task: Dictionary = _task(int(worker.task_id))
			if active_task.is_empty() or _table(int(active_task.table_id)).is_empty() or not worker.path.is_empty():
				return false
			if not (worker.pos as Vector2).is_equal_approx(V2_TABLE_CENTERS[int(active_task.table_id) - 1] + Vector2(56, 16)):
				return false
		worker.path = []
		worker.route_blocked = false
		if worker.state == "idle":
			worker.pos = worker_home(index)
		elif worker.state == "returning":
			worker.pos = Floor.kitchen_point()
			_route_to(worker, worker_home(index))
		else:
			var task: Dictionary = _task(int(worker.task_id))
			if task.is_empty() or _table(int(task.table_id)).is_empty():
				return false
			var destination: Vector2 = Floor.service_point(int(task.table_id))
			match str(worker.state):
				"to_kitchen":
					worker.pos = worker_home(index)
					_route_to(worker, Floor.kitchen_point())
				"to_table":
					worker.pos = worker_home(index) if task.kind == "clean" else Floor.kitchen_point()
					_route_to(worker, destination)
				"working":
					worker.pos = destination
	return true


func _read_snapshot(data: Dictionary) -> bool:
	var schema: int = int(data.get("version", 0))
	if schema == SAVE_VERSION:
		if typeof(data.get("interactive_cooking")) != TYPE_BOOL or typeof(data.get("cooking_return_paused")) != TYPE_BOOL or not data.get("active_cooking") is Dictionary or not _integer(data.get("cooking_session_seq")) or not _integer(data.get("cooking_session_token")):
			return false
	else:
		# Never accept a downgraded header that would silently discard a session.
		for key: String in ["interactive_cooking", "active_cooking", "cooking_return_paused", "cooking_session_seq", "cooking_session_token"]:
			if data.has(key):
				return false
	for key: String in ["coins", "served", "lost", "rejected", "max_customers", "next_customer_id", "next_task_id", "next_table_cursor", "legacy_served", "legacy_lost"]:
		if not _integer(data.get(key)):
			return false
	for key: String in ["clock", "arrival_elapsed"]:
		if not _number(data.get(key)) or float(data[key]) < 0.0:
			return false
	for key: String in ["paused", "open_for_arrivals", "auto_seat", "auto_dispatch", "auto_cook"]:
		if typeof(data.get(key)) != TYPE_BOOL:
			return false
	for key: String in ["tables", "workers", "tasks"]:
		if typeof(data.get(key)) != TYPE_ARRAY:
			return false
	for key: String in ["customers", "chef", "paid_ledger", "lost_ledger"]:
		if typeof(data.get(key)) != TYPE_DICTIONARY:
			return false
	if data.tables.size() != 20 or data.workers.size() != 2 or data.customers.size() > 20 or data.tasks.size() > 60:
		return false
	var decoded_tables: Array[Dictionary] = []
	for raw: Variant in data.tables:
		if not raw is Dictionary or not _fields(raw, ["id", "guest_id", "generation"], ["elapsed", "ordered_at"], ["zone", "label", "phase"], ["food", "drink", "used"]) or not _vector(raw.get("center")):
			return false
		var item: Dictionary = raw.duplicate(true)
		if schema == SAVE_VERSION:
			if typeof(raw.get("recipe_id")) != TYPE_STRING:
				return false
		else:
			item.recipe_id = "" if raw.phase == "free" else recipe_for_guest(int(raw.guest_id) if int(raw.guest_id) > 0 else int(raw.id))
		item.center = _vector_value(raw.center)
		_cast_integer_fields(item, ["id", "guest_id", "generation"])
		decoded_tables.append(item)
	var decoded_customers: Dictionary = {}
	for key: Variant in data.customers:
		if not str(key).is_valid_int() or int(key) < 1 or str(key) != str(int(key)):
			return false
		var raw: Variant = data.customers[key]
		if not raw is Dictionary or not _fields(raw, ["id", "table_id"], ["patience", "created"], ["species", "state"], ["paid", "timed_out", "route_blocked"]) or not _actor_fields(raw):
			return false
		var item: Dictionary = _decode_actor(raw)
		_cast_integer_fields(item, ["id", "table_id"])
		if int(item.id) != int(key) or decoded_customers.has(int(key)):
			return false
		decoded_customers[int(key)] = item
	var decoded_workers: Array[Dictionary] = []
	for raw: Variant in data.workers:
		if not raw is Dictionary or not _fields(raw, ["id"], ["elapsed"], ["species", "state"], ["route_blocked"]) or not _signed_integer(raw.get("task_id"), -1) or not _actor_fields(raw):
			return false
		var item: Dictionary = _decode_actor(raw)
		_cast_integer_fields(item, ["id", "task_id"])
		decoded_workers.append(item)
	var decoded_tasks: Array[Dictionary] = []
	for raw: Variant in data.tasks:
		if not raw is Dictionary or not _fields(raw, ["id", "table_id", "guest_id", "generation"], ["created"], ["kind", "state"], []) or not _signed_integer(raw.get("worker_id"), -1):
			return false
		var item: Dictionary = raw.duplicate(true)
		_cast_integer_fields(item, ["id", "table_id", "guest_id", "generation", "worker_id"])
		decoded_tasks.append(item)
	if not _signed_integer(data.chef.get("table_id"), -1) or not _number(data.chef.get("elapsed")) or float(data.chef.elapsed) < 0.0:
		return false
	for ledger: Dictionary in [data.paid_ledger, data.lost_ledger]:
		for key: Variant in ledger:
			if typeof(key) != TYPE_STRING or not str(key).is_valid_int() or int(key) < 1 or str(key) != str(int(key)) or typeof(ledger[key]) != TYPE_BOOL or not ledger[key]:
				return false
	tables = decoded_tables
	customers = decoded_customers
	workers = decoded_workers
	tasks = decoded_tasks
	coins = int(data.coins)
	served = int(data.served)
	lost = int(data.lost)
	rejected = int(data.rejected)
	paused = data.paused
	open_for_arrivals = data.open_for_arrivals
	auto_seat = data.auto_seat
	auto_dispatch = data.auto_dispatch
	auto_cook = data.auto_cook
	interactive_cooking = bool(data.get("interactive_cooking", false))
	active_cooking = data.get("active_cooking", {}).duplicate(true)
	if not active_cooking.is_empty():
		# JSON numbers arrive as floats. Rebuild through the session decoder so
		# order IDs and counters have the same canonical types as a live session.
		var restored_session = CookingSession.new()
		if not restored_session.restore(active_cooking):
			return false
		active_cooking = restored_session.to_dict()
	cooking_return_paused = bool(data.get("cooking_return_paused", false))
	cooking_session_seq = int(data.get("cooking_session_seq", 0))
	cooking_session_token = int(data.get("cooking_session_token", 0))
	max_customers = int(data.max_customers)
	clock = float(data.clock)
	chef = {"table_id": int(data.chef.table_id), "elapsed": float(data.chef.elapsed)}
	paid_ledger = data.paid_ledger.duplicate(true)
	lost_ledger = data.lost_ledger.duplicate(true)
	next_customer_id = int(data.next_customer_id)
	next_task_id = int(data.next_task_id)
	next_table_cursor = int(data.next_table_cursor)
	arrival_elapsed = float(data.arrival_elapsed)
	legacy_served = int(data.legacy_served)
	legacy_lost = int(data.legacy_lost)
	return true


func _restore_v1(data: Dictionary) -> bool:
	# Only a completed/clean one-table snapshot is migratable. Mid-service saves
	# are explicitly rejected, with this model and the source file left unchanged.
	if data.get("phase") != "ready_next" or typeof(data.get("paused")) != TYPE_BOOL:
		return false
	for key: String in ["coins", "served", "lost", "customer_id"]:
		if not _integer(data.get(key)):
			return false
	if int(data.coins) != int(data.served) * MEAL_PRICE or int(data.customer_id) != int(data.served) + int(data.lost):
		return false
	var candidate = get_script().new()
	candidate.coins = int(data.coins)
	candidate.served = int(data.served)
	candidate.lost = int(data.lost)
	candidate.legacy_served = int(data.served)
	candidate.legacy_lost = int(data.lost)
	candidate.next_customer_id = int(data.customer_id) + 1
	candidate.paused = data.paused
	_copy_from(candidate)
	return true


func _copy_from(other) -> void:
	var keep_interactive: bool = interactive_cooking
	tables = other.tables
	customers = other.customers
	workers = other.workers
	tasks = other.tasks
	coins = other.coins
	served = other.served
	lost = other.lost
	rejected = other.rejected
	paused = other.paused
	open_for_arrivals = other.open_for_arrivals
	auto_seat = other.auto_seat
	auto_dispatch = other.auto_dispatch
	auto_cook = other.auto_cook
	interactive_cooking = other.interactive_cooking or keep_interactive
	active_cooking = other.active_cooking.duplicate(true)
	cooking_return_paused = other.cooking_return_paused
	cooking_session_seq = other.cooking_session_seq
	cooking_session_token = other.cooking_session_token
	max_customers = other.max_customers
	clock = other.clock
	chef = other.chef
	paid_ledger = other.paid_ledger
	lost_ledger = other.lost_ledger
	next_customer_id = other.next_customer_id
	next_task_id = other.next_task_id
	next_table_cursor = other.next_table_cursor
	arrival_elapsed = other.arrival_elapsed
	legacy_served = other.legacy_served
	legacy_lost = other.legacy_lost
	if interactive_cooking:
		enable_interactive_cooking()
	if player_mode:
		_enforce_player_automation()


func _number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value))


func _integer(value: Variant) -> bool:
	return _signed_integer(value, 0)


func _signed_integer(value: Variant, minimum: int) -> bool:
	return _number(value) and float(value) >= minimum and float(value) <= 1000000000.0 and floorf(float(value)) == float(value)


func _vector(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1]) and absf(float(value[0])) < 1000000.0 and absf(float(value[1])) < 1000000.0


func _vector_value(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func _actor_fields(data: Dictionary) -> bool:
	if not _vector(data.get("pos")) or not data.get("path") is Array or data.path.size() > 1000:
		return false
	for point: Variant in data.path:
		if not _vector(point):
			return false
	return true


func _decode_actor(data: Dictionary) -> Dictionary:
	var result: Dictionary = data.duplicate(true)
	result.pos = _vector_value(data.pos)
	var path: Array[Vector2] = []
	for point: Array in data.path:
		path.append(_vector_value(point))
	result.path = path
	return result


func _fields(data: Dictionary, integers: Array, numbers: Array, strings: Array, booleans: Array) -> bool:
	for key: String in integers:
		if not _integer(data.get(key)):
			return false
	for key: String in numbers:
		if not _number(data.get(key)) or float(data[key]) < 0.0:
			return false
	for key: String in strings:
		if typeof(data.get(key)) != TYPE_STRING:
			return false
	for key: String in booleans:
		if typeof(data.get(key)) != TYPE_BOOL:
			return false
	return true


func _cast_integer_fields(data: Dictionary, keys: Array) -> void:
	for key: String in keys:
		data[key] = int(data[key])


func validate_invariants() -> Array[String]:
	var errors: Array[String] = []
	if tables.size() != 20 or workers.size() != 2:
		errors.append("Expected 20 tables and 2 workers")
		return errors
	if interactive_cooking and (auto_cook or int(chef.table_id) != -1):
		errors.append("Interactive kitchen cannot retain an automatic cook")
	if active_cooking.is_empty():
		if cooking_return_paused or cooking_session_token != 0:
			errors.append("Inactive kitchen retains return-pause or token state")
	else:
		var session = CookingSession.new()
		if cooking_session_token < 1 or cooking_session_token != cooking_session_seq or not interactive_cooking or not paused or not session.restore(active_cooking) or session.cancelled or not _cooking_binding_valid(session):
			errors.append("Invalid active cooking session or order binding")
	if max_customers < 1 or max_customers > 20 or customers.size() > 20 or queue_ids().size() > QUEUE_LIMIT:
		errors.append("Customer or queue capacity exceeded")
	if coins != served * MEAL_PRICE or served != paid_ledger.size() + legacy_served or lost != lost_ledger.size() + legacy_lost:
		errors.append("Revenue or completion ledger mismatch")
	if next_customer_id < 1 or next_task_id < 1 or next_table_cursor < 0 or next_table_cursor >= 20 or arrival_elapsed < 0.0 or arrival_elapsed >= ARRIVAL_INTERVAL + 0.00001:
		errors.append("Invalid sequence/arrival counters")
	var seen_guests: Dictionary = {}
	var unresolved_guests: int = 0
	for index: int in range(tables.size()):
		var table: Dictionary = tables[index]
		if int(table.id) != index + 1 or table.phase not in TABLE_PHASES or not (table.center as Vector2).is_equal_approx(Floor.table_center(int(table.id))):
			errors.append("Invalid table identity/phase/geometry at %d" % (index + 1))
		var guest_id: int = int(table.guest_id)
		if (table.phase == "free" and str(table.get("recipe_id", "")) != "") or (table.phase != "free" and str(table.get("recipe_id", "")) not in RECIPE_IDS):
			errors.append("Missing or invalid order recipe %d" % int(table.id))
		if guest_id > 0:
			if seen_guests.has(guest_id) or not customers.has(guest_id) or int(customers[guest_id].table_id) != int(table.id):
				errors.append("Duplicate or missing table reservation %d" % int(table.id))
			seen_guests[guest_id] = true
		if table.phase in ["free", "dirty", "collecting", "wiping"] and guest_id != 0:
			errors.append("Vacant/cleaning table retains guest %d" % int(table.id))
		if table.phase not in ["free", "dirty", "collecting", "wiping"] and guest_id == 0:
			errors.append("Occupied table has no guest %d" % int(table.id))
		if table.phase == "free" and (bool(table.used) or bool(table.food) or bool(table.drink)):
			errors.append("Free table has leftover state")
		if table.phase == "reserved" and bool(table.used):
			errors.append("Reserved table already used")
		if table.phase not in ["free", "reserved", "leaving"] and not bool(table.used):
			errors.append("Used table lost its occupancy history")
		if table.phase in ["waiting_drink", "serving_drink", "eating", "drinking", "checkout"] and not bool(table.food):
			errors.append("Missing food after food service")
		if table.phase in ["eating", "drinking", "checkout"] and not bool(table.drink):
			errors.append("Missing drink after drink service")
		if table.phase == "cooking" and int(chef.table_id) != int(table.id):
			errors.append("Cooking table is not owned by chef")
		if table.phase in ["food_ready", "serving_food"] and not _has_task(int(table.id), "food"):
			errors.append("Food service lacks task")
		if table.phase in ["waiting_drink", "serving_drink"] and not _has_task(int(table.id), "drink"):
			errors.append("Drink service lacks task")
		if table.phase in ["collecting", "wiping"] and not _has_task(int(table.id), "clean"):
			errors.append("Cleanup lacks task")
	for id: int in customers:
		var guest: Dictionary = customers[id]
		if not bool(guest.paid) and not bool(guest.timed_out):
			unresolved_guests += 1
		if int(guest.id) != id or id >= next_customer_id or guest.species not in SPECIES or guest.state not in CUSTOMER_STATES or float(guest.patience) > 120.0:
			errors.append("Invalid customer identity/state %d" % id)
		if bool(guest.paid) != paid_ledger.has(str(id)) or bool(guest.timed_out) != lost_ledger.has(str(id)) or (bool(guest.paid) and bool(guest.timed_out)):
			errors.append("Customer payment/loss ledger mismatch %d" % id)
		if guest.state == "leaving" and not bool(guest.paid) and not bool(guest.timed_out):
			errors.append("Departing customer has no completion reason")
		if guest.state != "leaving" and (bool(guest.paid) or bool(guest.timed_out) or float(guest.patience) <= 0.0):
			errors.append("Completed/expired customer is still active")
		var table: Dictionary = _table(int(guest.table_id))
		if guest.state == "queued" and int(guest.table_id) != 0:
			errors.append("Queued customer owns a table")
		if guest.state in ["walking", "seated"] and table.is_empty():
			errors.append("Assigned customer has no table")
		if not table.is_empty():
			if int(table.guest_id) != id:
				errors.append("Customer/table reservation mismatch")
			if guest.state == "walking" and table.phase != "reserved":
				errors.append("Walking guest has no reserved table")
			if guest.state == "leaving" and table.phase != "leaving":
				errors.append("Leaving guest table released too early")
			if guest.state == "seated" and table.phase in ["free", "reserved", "leaving", "dirty", "collecting", "wiping"]:
				errors.append("Seated guest has incompatible table phase")
		var destination: Vector2 = Floor.entrance_point()
		if guest.state == "queued":
			destination = Floor.queue_point(queue_ids().find(id))
		elif guest.state in ["walking", "seated"]:
			destination = Floor.seat_point(int(guest.table_id))
		if not _valid_actor_route(guest, destination):
			errors.append("Customer route crosses furniture or has wrong destination %d" % id)
	if next_customer_id - 1 != served + lost + unresolved_guests:
		errors.append("Spawned customer accounting mismatch")
	for ledger: Dictionary in [paid_ledger, lost_ledger]:
		for id: Variant in ledger:
			if int(id) >= next_customer_id:
				errors.append("Completion ledger contains a future guest")
	for id: Variant in paid_ledger:
		if lost_ledger.has(str(id)):
			errors.append("Guest counted as both served and lost")
	var task_ids: Dictionary = {}
	var table_tasks: Dictionary = {}
	var worker_claims: Dictionary = {}
	var previous_task_id: int = 0
	for task: Dictionary in tasks:
		var id: int = int(task.id)
		var pair: String = "%d:%s" % [int(task.table_id), str(task.kind)]
		if id < 1 or id >= next_task_id or task_ids.has(id) or id <= previous_task_id or table_tasks.has(pair) or task.kind not in ["food", "drink", "clean"] or task.state not in ["queued", "claimed"]:
			errors.append("Invalid/duplicate/out-of-order task %d" % id)
		previous_task_id = id
		task_ids[id] = true
		table_tasks[pair] = true
		if not _task_current(task):
			errors.append("Stale task generation or guest %d" % id)
		var table: Dictionary = _table(int(task.table_id))
		if not table.is_empty():
			var required_phase: String = "dirty"
			if task.kind == "food":
				required_phase = "food_ready" if task.state == "queued" else "serving_food"
			elif task.kind == "drink":
				required_phase = "waiting_drink" if task.state == "queued" else "serving_drink"
			if (task.kind != "clean" or task.state == "queued") and table.phase != required_phase:
				errors.append("Task claim phase mismatch")
		var worker_id: int = int(task.worker_id)
		if task.state == "queued" and worker_id != -1:
			errors.append("Queued task already has a worker")
		if task.state == "claimed":
			if worker_id < 0 or worker_id >= workers.size():
				errors.append("Claimed task has invalid worker")
			elif worker_claims.has(worker_id) or int(workers[worker_id].task_id) != id or workers[worker_id].state not in ["to_kitchen", "to_table", "working"]:
				errors.append("Worker task claim mismatch")
			if worker_id >= 0 and worker_id < workers.size() and task.kind == "clean":
				var owner: Dictionary = workers[worker_id]
				if owner.state == "working":
					if table.is_empty() or table.phase not in ["collecting", "wiping"]:
						errors.append("Working cleanup requires collecting or wiping table")
				elif owner.state != "to_table" or table.is_empty() or table.phase != "dirty":
					errors.append("Traveling cleanup requires to_table worker and dirty table")
			worker_claims[worker_id] = id
	for index: int in range(workers.size()):
		var worker: Dictionary = workers[index]
		if int(worker.id) != index or worker.species != ("rabbit" if index == 0 else "fox") or worker.state not in WORKER_STATES:
			errors.append("Invalid worker identity/state")
		if worker.state in ["idle", "returning"]:
			if int(worker.task_id) != -1:
				errors.append("Free worker retains task")
		elif not worker_claims.has(index) or int(worker.task_id) != int(worker_claims[index]):
			errors.append("Busy worker has no matching claim")
		var destination: Vector2 = Floor.kitchen_point()
		if worker.state in ["idle", "returning"]:
			destination = worker_home(index)
		elif worker.state in ["to_table", "working"]:
			var task: Dictionary = _task(int(worker.task_id))
			if not task.is_empty():
				destination = Floor.service_point(int(task.table_id))
		if not _valid_actor_route(worker, destination):
			errors.append("Worker route crosses furniture or has wrong destination %d" % index)
		if worker.state == "working" and (not worker.path.is_empty() or not (worker.pos as Vector2).is_equal_approx(destination)):
			errors.append("Working worker must have arrived at service point")
	if int(chef.table_id) != -1:
		var table: Dictionary = _table(int(chef.table_id))
		if table.is_empty() or table.phase != "cooking" or float(chef.elapsed) >= 4.00001:
			errors.append("Chef ownership/timer mismatch")
	elif float(chef.elapsed) != 0.0:
		errors.append("Idle chef retains timer")
	return errors


func _valid_actor_route(actor: Dictionary, destination: Vector2) -> bool:
	var previous: Vector2 = actor.pos
	if bool(actor.get("route_blocked", false)) or not Floor.is_walkable(previous):
		return false
	for point: Vector2 in actor.path:
		if not Floor.segment_is_walkable(previous, point):
			return false
		previous = point
	return previous.is_equal_approx(destination)


func save_to(path: String) -> Error:
	if not validate_invariants().is_empty():
		return ERR_INVALID_DATA
	var temporary: String = path + ".tmp"
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		return error
	return DirAccess.rename_absolute(temporary, path)


func load_from(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parser := JSON.new()
	var error: Error = parser.parse(file.get_as_text())
	file.close()
	return error == OK and parser.data is Dictionary and restore(parser.data)
