extends SceneTree
## Isolated acceptance: the player's only successful business action is order.
## Synthetic snapshots and a unique /tmp slot only; never the normal player save.
const Model = preload("res://multi_model.gd")
const Support = preload("res://tests/multi_test_support.gd")
var assertions: int = 0
var failures: int = 0
var started_ms: int = 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	call_deferred("_run")


func _run() -> void:
	_test_policy_and_manual_compatibility()
	_test_no_confirmation_and_timeout()
	_test_checkout_restore()
	_test_order_only_service()
	_test_peak_twenty()
	print("ORDER_ONLY_TEST_RESULT assertions=%d failures=%d wall_ms=%d" % [assertions, failures, Time.get_ticks_msec() - started_ms])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("ORDER_ONLY_ASSERT_FAIL " + description)


func _automatic(model) -> bool:
	return model.open_for_arrivals and model.auto_seat and model.auto_cook and model.auto_dispatch


func _state(model, description: String) -> void:
	var errors: Array[String] = model.validate_invariants()
	_expect(errors.is_empty(), description + ": " + "; ".join(errors))
	_expect(int(model.coins) == int(model.served) * Model.MEAL_PRICE, description + ": exact revenue")


func _wait(model, predicate: Callable, description: String, seconds: float = 60.0) -> bool:
	var reached: bool = Support.until(model, predicate, seconds)
	_expect(reached, description)
	return reached


func _test_policy_and_manual_compatibility() -> void:
	var manual = Support.controlled(false)
	manual.auto_cook = false
	manual.paused = true
	var snapshot: Dictionary = manual.to_dict()
	var cold = Model.new()
	_expect(cold.restore(snapshot), "old manual flags restore before enabling session policy")
	_expect(not cold.player_mode and not _automatic(cold), "cold restore leaves the low-level manual API unchanged")
	cold.enable_player_mode()
	_expect(cold.player_mode and _automatic(cold) and cold.paused, "enable sets all automatic flags and preserves pause")
	_expect(cold.clock == 0.0 and cold.coins == 0 and cold.customers.is_empty(), "enable does not simulate, pay, or spawn")
	_expect(not cold.to_dict().has("player_mode"), "session policy is not a new persistent schema requirement")
	var paused_snapshot: Dictionary = cold.to_dict()
	cold.tick(60.0)
	_expect(Support.same(cold.to_dict(), paused_snapshot), "pause freezes every automatic activity")
	_expect(cold.restore(snapshot) and cold.player_mode and _automatic(cold), "warm restore keeps the active session policy over old manual flags")
	cold.enable_player_mode()
	_expect(Support.same(cold.to_dict(), paused_snapshot), "enabling twice is idempotent")
	cold.paused = false
	cold.open_for_arrivals = false
	cold.auto_seat = false
	cold.auto_cook = false
	cold.auto_dispatch = false
	cold.tick(0.1)
	_expect(_automatic(cold), "a player-mode tick reasserts automatic operations")
	_state(cold, "policy fixture")
	_expect(not manual.player_mode and not manual.auto_dispatch and not manual.auto_cook, "another manual fixture is unaffected")
	print("ORDER_ONLY_CASE policy_manual_compatibility PASS_IF_NO_ASSERTIONS")


func _test_no_confirmation_and_timeout() -> void:
	var model = Model.new()
	model.max_customers = 1
	model.enable_player_mode()
	if not _wait(model, func() -> bool: return model.table_action(1) == "order", "arrival and seating happen without player actions", 30.0):
		return
	var id: int = int(model.tables[0].guest_id)
	model.tick(5.0)
	_expect(model.tables[0].phase == "ordering" and int(model.chef.table_id) == -1 and model.tasks.is_empty(), "waiting five seconds never confirms an order automatically")
	_expect(model.served == 0 and model.coins == 0, "unconfirmed guest produces no income")
	model.customers[id].patience = 0.05
	model.tick(0.1)
	_expect(model.lost == 1 and model.tables[0].phase == "leaving", "unconfirmed guest can time out while keeping its reservation until exit")
	var collecting_at: float = -1.0
	var wiping_at: float = -1.0
	var released: bool = false
	for step: int in range(600):
		model.tick(0.1)
		var phase: String = str(model.tables[0].phase)
		if phase == "collecting" and collecting_at < 0.0:
			collecting_at = float(model.clock)
		if phase == "wiping" and wiping_at < 0.0:
			wiping_at = float(model.clock)
		if phase == "free":
			released = true
			break
	_expect(released and collecting_at >= 0.0 and wiping_at >= 0.0, "timeout automatically collects, wipes, and releases the used table")
	_expect(wiping_at - collecting_at >= 0.999, "timeout cleanup preserves the complete collect clip")
	_expect(float(model.clock) - wiping_at >= 0.999, "timeout cleanup preserves the complete wipe clip")
	_expect(model.lost == 1 and model.served == 0 and model.coins == 0 and model.paid_ledger.is_empty(), "timeout cleanup never bills the guest or counts the loss twice")
	_wait(model, func() -> bool: return int(model.next_customer_id) > id + 1, "automatic admissions continue after a timeout", 20.0)
	_state(model, "timeout recovery")
	print("ORDER_ONLY_CASE no_confirmation_timeout PASS_IF_NO_ASSERTIONS")


func _test_checkout_restore() -> void:
	# Build a genuine old manual checkout, without editing business state.
	var manual = Support.controlled()
	manual.max_customers = 1
	manual.spawn_customer("cat")
	manual.assign_next(1)
	if not _wait(manual, func() -> bool: return manual.table_action(1) == "order", "manual fixture reaches ordering"):
		return
	_expect(manual.act(1, "order"), "manual fixture accepts its order")
	if not _wait(manual, func() -> bool: return manual.tables[0].phase == "checkout", "manual API still stops for checkout"):
		return
	manual.tick(1.0)
	_expect(manual.tables[0].phase == "checkout" and manual.coins == 0, "manual mode never enables automatic payment accidentally")
	var id: int = int(manual.tables[0].guest_id)
	manual.customers[id].patience = 0.01
	manual.auto_cook = false
	manual.auto_dispatch = false
	manual.paused = true
	var decoded: Variant = JSON.parse_string(JSON.stringify(manual.to_dict()))
	var resumed = Model.new()
	_expect(decoded is Dictionary and resumed.restore(decoded), "low-patience manual checkout survives JSON restore")
	resumed.enable_player_mode()
	var snapshot: Dictionary = resumed.to_dict()
	resumed.tick(10.0)
	_expect(Support.same(resumed.to_dict(), snapshot), "restored paused checkout remains unpaid and frozen")
	resumed.paused = false
	resumed.tick(0.1)
	_expect(resumed.served == 1 and resumed.coins == 38 and resumed.lost == 0, "resumed checkout pays before remaining patience can expire")
	_expect(resumed.paid_ledger.has(str(id)) and resumed.customers[id].paid, "automatic payment records both durable guards")
	for repeat: int in range(8):
		_expect(not resumed.act(1, "pay"), "automatic checkout rejects duplicate payment attempts")
	var slot: String = "/tmp/mori_order_only_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	if FileAccess.file_exists(slot) or FileAccess.file_exists(slot + ".tmp"):
		_expect(false, "private test slot is unused")
		return
	_expect(resumed.save_to(slot) == OK, "paid progress saves only to the unique temporary test slot")
	var reopened = Model.new()
	var loaded: bool = reopened.load_from(slot)
	_expect(loaded, "paid progress reopens from the private test slot")
	for suffix: String in ["", ".tmp"]:
		if FileAccess.file_exists(slot + suffix):
			_expect(DirAccess.remove_absolute(slot + suffix) == OK, "remove only the private order-only test file")
	if not loaded:
		return
	_expect(not reopened.player_mode, "disk content does not silently enable a session policy")
	reopened.enable_player_mode()
	_expect(not reopened.act(1, "pay"), "reopened paid guest cannot be charged again")
	_wait(reopened, func() -> bool: return reopened.tables[0].phase == "free", "reopened paid guest exits and table cleans without manual work")
	_expect(reopened.coins == 38 and reopened.served == 1 and reopened.lost == 0, "reopened automatic cleanup preserves exactly one payment")
	_state(reopened, "paid reopen")
	print("ORDER_ONLY_CASE checkout_restore PASS_IF_NO_ASSERTIONS")


func _test_order_only_service() -> void:
	var failures_before: int = failures
	var model = Model.new()
	model.enable_player_mode()
	var confirmed: Dictionary = {}
	var used_tables: Dictionary = {}
	var released_tables: Dictionary = {}
	var species: Dictionary = {}
	var phases: Dictionary = {}
	var seen_claims: Dictionary = {}
	var seen_workers: Dictionary = {}
	var seen_payments: Dictionary = {}
	var last_claim: int = 0
	var collected: int = 0
	var wiped: int = 0
	var restored_claim: bool = false
	var completed: bool = false
	# Continuous arrivals remain enabled. Completion measures the 40 confirmed
	# meals and their cleanup; later unconfirmed guests may already be waiting.
	for step: int in range(9000):
		for table: Dictionary in model.tables:
			var table_id: int = int(table.id)
			if confirmed.size() < 40 and model.table_action(table_id) == "order":
				var guest_id: int = int(table.guest_id)
				_expect(not confirmed.has(guest_id), "each guest needs exactly one player confirmation")
				_expect(model.act(table_id, "order"), "only order advances the player's business action")
				_expect(not model.act(table_id, "order"), "a repeated order confirmation is rejected")
				confirmed[guest_id] = table_id
				used_tables[table_id] = true
				species[str(model.customers[guest_id].species)] = true
		model.tick(0.1)
		var new_claims: Array[int] = []
		for task: Dictionary in model.tasks:
			if task.state != "claimed" or seen_claims.has(int(task.id)):
				continue
			new_claims.append(int(task.id))
			seen_claims[int(task.id)] = true
			seen_workers[int(task.worker_id)] = true
			for waiting: Dictionary in model.tasks:
				_expect(waiting.state != "queued" or int(waiting.id) > int(task.id), "automatic workers never pass over an older queued task")
		new_claims.sort()
		for task_id: int in new_claims:
			_expect(task_id > last_claim, "new automatic claims follow monotonically increasing FIFO task IDs")
			last_claim = task_id
		for key: Variant in model.paid_ledger:
			if seen_payments.has(key):
				continue
			seen_payments[key] = true
			var before: int = int(model.coins)
			_expect(confirmed.has(int(key)), "only a player-confirmed guest can generate payment")
			if confirmed.has(int(key)):
				_expect(not model.act(int(confirmed[int(key)]), "pay"), "automatic payment has already closed the checkout action")
			_expect(int(model.coins) == before, "repeated payment does not add coins")
		for table: Dictionary in model.tables:
			var table_id: int = int(table.id)
			var previous: Dictionary = phases.get(table_id, {"phase": "free", "since": 0.0, "generation": 0})
			if str(previous.phase) != str(table.phase):
				if previous.phase == "collecting":
					_expect(table.phase == "wiping" and float(model.clock) - float(previous.since) >= 0.999, "collecting completes its full clip before wiping")
					collected += 1
				if previous.phase == "wiping":
					# Auto seating may reserve the released table in this same tick.
					var released: bool = table.phase == "free" or (table.phase == "reserved" and int(table.generation) == int(previous.generation) + 1 and not table.used and not table.food and not table.drink)
					_expect(released and float(model.clock) - float(previous.since) >= 0.999, "wiping completes its full clip before releasing or reassigning the table")
					wiped += 1
					released_tables[table_id] = true
				phases[table_id] = {"phase": str(table.phase), "since": float(model.clock), "generation": int(table.generation)}
		if not restored_claim and not seen_claims.is_empty():
			model.paused = true
			var paused_snapshot: Dictionary = model.to_dict()
			var decoded: Variant = JSON.parse_string(JSON.stringify(paused_snapshot))
			var loaded = Model.new()
			var valid: bool = decoded is Dictionary and loaded.restore(decoded)
			_expect(valid, "claimed automatic service survives JSON save/reopen")
			if not valid:
				break
			loaded.enable_player_mode()
			_expect(Support.same(loaded.to_dict(), paused_snapshot), "reopen preserves all claimed ownership, routes, timers, and accounting")
			loaded.tick(200.0)
			_expect(Support.same(loaded.to_dict(), paused_snapshot), "paused restored automatic service remains frozen")
			loaded.paused = false
			model = loaded
			restored_claim = true
		if step % 10 == 0:
			_state(model, "order-only run step %d" % step)
		if failures > failures_before:
			break
		if int(model.served) == 40 and wiped == 40:
			completed = true
			break
		if Time.get_ticks_msec() - started_ms > 180000:
			_expect(false, "180-second wall-clock watchdog")
			break
	_expect(completed and confirmed.size() == 40, "forty confirmed guests complete and clean with only order clicks")
	_expect(model.max_customers == 6 and int(model.lost) == 0, "default six-guest operation completes without starvation")
	_expect(int(model.served) == 40 and int(model.coins) == 1520 and model.paid_ledger.size() == 40, "forty guests pay exactly once for 1520 coins")
	_expect(used_tables.size() == 20 and released_tables.size() == 20, "all twenty tables are served and released for reuse")
	_expect(species.size() == 17, "automatic arrivals include all seventeen species")
	_expect(seen_workers.size() == 2 and seen_claims.size() == 120, "both workers complete the forty food, drink, and cleanup task sets")
	_expect(collected == 40 and wiped == 40, "every guest receives complete collect and wipe phases")
	_expect(restored_claim, "the run includes a pause/reopen with a live task claim")
	_state(model, "order-only completion")
	print("ORDER_ONLY_40 served=%d lost=%d coins=%d confirmed=%d tables=%d released=%d species=%d claims=%d workers=%d collect=%d wipe=%d simulation_seconds=%.2f" % [int(model.served), int(model.lost), int(model.coins), confirmed.size(), used_tables.size(), released_tables.size(), species.size(), seen_claims.size(), seen_workers.size(), collected, wiped, float(model.clock)])


func _test_peak_twenty() -> void:
	var model = Model.new()
	model.max_customers = 20
	model.enable_player_mode()
	for step: int in range(40):
		if model.customers.size() == 20:
			break
		if model.queue_ids().size() < Model.QUEUE_LIMIT:
			model.spawn_customer()
		model.tick(0.9)
	_expect(model.customers.size() == 20, "pressure fixture has twenty simultaneous guests with automatic arrivals enabled")
	var cohort: Array = model.customers.keys()
	var confirmed: Dictionary = {}
	var generations: Dictionary = {}
	var complete: bool = false
	for step: int in range(6000):
		for table: Dictionary in model.tables:
			if int(table.guest_id) not in cohort:
				continue
			generations[int(table.id)] = int(table.generation)
			if model.table_action(int(table.id)) == "order":
				confirmed[int(table.guest_id)] = true
				_expect(model.act(int(table.id), "order"), "pressure cohort order confirmed once")
		model.tick(0.1)
		if step % 10 == 0:
			_state(model, "twenty-concurrent pressure step %d" % step)
		if _cohort_clear(model, cohort, generations):
			complete = true
			break
	var paid: int = 0
	var timed_out: int = 0
	for id: int in cohort:
		if model.paid_ledger.has(str(id)):
			paid += 1
			_expect(confirmed.has(id) and not model.lost_ledger.has(str(id)), "pressure guest pays only after confirmation and never both pays and times out")
		if model.lost_ledger.has(str(id)):
			timed_out += 1
	_expect(complete and generations.size() == 20, "all twenty original reservations finish and release or change generation")
	_expect(paid + timed_out == 20, "every original guest has exactly one terminal outcome")
	_expect(model.served == paid and model.coins == paid * Model.MEAL_PRICE and model.paid_ledger.size() == paid, "only the confirmed pressure cohort produces unique income")
	_expect(int(model.chef.table_id) == -1 and _cohort_clear(model, cohort, generations), "no original customer, kitchen order, service task, or cleanup task remains stranded")
	_expect(_automatic(model) and model.player_mode, "pressure test never closes automatic arrivals or dispatch")
	_state(model, "twenty-concurrent completion")
	print("ORDER_ONLY_PEAK20 confirmed=%d served=%d cohort_lost=%d total_lost=%d coins=%d tables=%d later_guests=%d remaining_tasks=%d simulation_seconds=%.2f" % [confirmed.size(), paid, timed_out, int(model.lost), int(model.coins), generations.size(), model.customers.size(), model.tasks.size(), float(model.clock)])


func _cohort_clear(model, cohort: Array, generations: Dictionary) -> bool:
	for id: int in cohort:
		if model.customers.has(id):
			return false
	for task: Dictionary in model.tasks:
		if int(task.guest_id) in cohort or (generations.has(int(task.table_id)) and int(task.generation) == int(generations[int(task.table_id)])):
			return false
	for table_id: int in generations:
		var table: Dictionary = model.tables[table_id - 1]
		if int(table.generation) == int(generations[table_id]) and (table.phase != "free" or int(table.guest_id) != 0):
			return false
	return true
