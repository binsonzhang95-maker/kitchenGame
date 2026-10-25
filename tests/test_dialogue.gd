extends SceneTree
## Pure visual director tests. No normal saves, file IO, or application window.
const Director = preload("res://dialogue_director.gd")
var assertions: int = 0
var failures: int = 0

class FakeModel:
	extends RefCounted
	var paused: bool = false
	var customers: Dictionary = {}
	var tables: Array[Dictionary] = []
	var workers: Array[Dictionary] = [{"id": 0, "state": "idle", "elapsed": 0.0, "task_id": -1}, {"id": 1, "state": "idle", "elapsed": 0.0, "task_id": -1}]
	var tasks: Array[Dictionary] = []
	var coins: int = 76
	var served: int = 2
	var paid_ledger: Dictionary = {"previous_1": true, "previous_2": true}

	func snapshot() -> Dictionary:
		return {"paused": paused, "customers": customers.duplicate(true), "tables": tables.duplicate(true), "workers": workers.duplicate(true), "tasks": tasks.duplicate(true), "coins": coins, "served": served, "paid_ledger": paid_ledger.duplicate(true)}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_pools_and_seed()
	_test_order_sequence_cooldown_and_deduplication()
	_test_pause_and_disable()
	_test_cancellation_and_goodbye()
	_test_automatic_events()
	_test_capacity_identity_and_model_purity()
	print("DIALOGUE_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("DIALOGUE_ASSERT_FAIL " + description)


func _model(count: int = 1):
	var model = FakeModel.new()
	for id: int in range(1, count + 1):
		model.customers[id] = {"id": id, "table_id": id, "state": "seated", "paid": false, "patience": 120.0}
		model.tables.append({"id": id, "guest_id": id, "generation": 1, "phase": "awaiting_cook"})
	return model


func _director(seed_value: int = 441):
	var director = Director.new()
	director.rng.seed = seed_value
	return director


func _test_pools_and_seed() -> void:
	_expect(Director.POOLS.size() == 7, "seven contextual scenes")
	var used_emotions: Dictionary = {}
	for scene: String in Director.POOLS:
		var pool: Array = Director.POOLS[scene]
		_expect(pool.size() >= 3 and pool.size() <= 5, "%s has 3-5 offline expression pairs" % scene)
		for pair: Array in pool:
			_expect(pair.size() == 4 and pair[0] in ["guest", "worker"] and pair[2] in ["guest", "worker"], "pair declares speaker roles")
			_expect(pair[1] in Director.EMOTIONS and pair[3] in Director.EMOTIONS, "pair uses only one of eight atlas emotion IDs")
			used_emotions[pair[1]] = true
			used_emotions[pair[3]] = true
	_expect(used_emotions.size() == 8, "all eight actual atlas emotions are represented")
	var first = _director(991)
	var second = _director(991)
	var model = _model()
	_expect(first.trigger("order", 0, 1, model) and second.trigger("order", 0, 1, model), "seed fixtures trigger")
	_expect(first.to_debug() == second.to_debug(), "fixed RNG seed gives deterministic pairs")
	_expect(str(first.bubbles[0].short_text).is_empty(), "default contains no written dialogue")
	_expect(not first.bubbles[0].has("text"), "long sentence field is absent")
	var short = _director()
	short.show_short_text = true
	short.trigger("order", 0, 1, model)
	_expect(str(short.bubbles[0].short_text).length() in [2, 3, 4], "optional short label is only 2-4 characters")


func _test_order_sequence_cooldown_and_deduplication() -> void:
	var model = _model()
	var director = _director()
	_expect(director.trigger("order", 0, 1, model), "order starts")
	_expect(director.bubbles.size() == 1 and director.bubbles[0].speaker == "guest:1", "order starts with guest expectation/question")
	_expect(director.bubbles[0].emotion in ["hungry", "question"], "order first expression is child-friendly")
	var initial_id: int = int(director.bubbles[0].id)
	director.tick(1.99, model)
	_expect(director.bubbles.size() == 1 and director.bubbles[0].speaker == "guest:1", "reply never appears before two seconds")
	director.tick(0.02, model)
	_expect(director.bubbles.size() == 1 and director.bubbles[0].speaker == "worker:0", "worker replies after guest bubble ends")
	_expect(int(director.bubbles[0].id) > initial_id and is_equal_approx(float(director.bubbles[0].duration), 3.0), "reply has a new stable ID and three-second duration")
	_expect(not director.trigger("order", 0, 1, model), "same scene event cannot be spammed")
	_expect(not director.trigger("food", 0, 1, model), "both actors respect cooldown")
	director.tick(6.0, model)
	_expect(not director.trigger("food", 0, 1, model), "worker cooldown begins when reply actually starts")
	director.tick(2.1, model)
	_expect(not director.trigger("order", 0, 1, model), "same scene stays deduplicated after cooldown")
	_expect(director.trigger("food", 0, 1, model), "different scene can start after both eight-second cooldowns")
	# The next occurrence for another guest picks a different pair in the same pool.
	var alternate_model = _model(2)
	var alternate = _director()
	alternate.trigger("welcome", 0, 1, alternate_model)
	var original_pair: Array = [alternate.bubbles[0].emotion, alternate.to_debug().pending[0].emotion]
	alternate.tick(11.0, alternate_model)
	_expect(alternate.trigger("welcome", 0, 2, alternate_model), "later guest can trigger same context")
	var next_pair: Array = [alternate.bubbles[0].emotion, alternate.to_debug().pending[0].emotion]
	_expect(next_pair != original_pair, "same contextual pair is not selected consecutively")


func _test_pause_and_disable() -> void:
	var model = _model()
	var director = _director()
	director.trigger("food", 0, 1, model)
	model.paused = true
	var frozen: Dictionary = director.to_debug().duplicate(true)
	director.tick(50.0, model)
	_expect(not director.trigger("drink", 1, 1, model), "pause blocks new events")
	_expect(director.to_debug() == frozen, "pause freezes bubbles, elapsed, cooldowns, and pending replies exactly")
	model.paused = false
	director.tick(0.5, model)
	_expect(float(director.bubbles[0].elapsed) > 0.0, "animation elapsed resumes")
	director.enabled = false
	_expect(director.bubbles.is_empty() and director.to_debug().pending.is_empty(), "disable immediately clears visible and pending expressions")
	director.tick(10.0, model)
	_expect(director.active_bubbles(model).is_empty() and not director.trigger("drink", 1, 1, model), "disabled director stays empty")


func _test_cancellation_and_goodbye() -> void:
	var leaving = _model()
	var first = _director()
	first.trigger("food", 0, 1, leaving)
	leaving.customers[1].state = "leaving"
	leaving.tables[0].phase = "leaving"
	_expect(first.active_bubbles(leaving).is_empty(), "active query never exposes stale leaving speakers")
	first.tick(0.1, leaving)
	_expect(first.bubbles.is_empty() and first.to_debug().pending.is_empty(), "leaving cancels ordinary first line and pending reply")
	var generation = _model()
	var second = _director()
	second.trigger("food", 0, 1, generation)
	generation.tables[0].generation = 2
	second.tick(0.1, generation)
	_expect(second.bubbles.is_empty() and second.to_debug().pending.is_empty(), "table generation change invalidates conversation")
	var removed = _model()
	var third = _director()
	third.trigger("food", 0, 1, removed)
	removed.customers.erase(1)
	third.tick(0.1, removed)
	_expect(third.bubbles.is_empty() and third.to_debug().pending.is_empty(), "deleted guest cancels pending reply")
	var goodbye = _model()
	goodbye.customers[1].state = "leaving"
	goodbye.customers[1].paid = true
	goodbye.tables[0].phase = "leaving"
	var fourth = _director()
	_expect(fourth.trigger("goodbye", 0, 1, goodbye), "paid departing guest may receive a farewell")
	_expect(fourth.bubbles.size() == 1 and fourth.bubbles[0].speaker == "worker:0" and fourth.bubbles[0].emotion == "bye", "farewell is worker bye only")
	_expect(fourth.to_debug().pending.is_empty(), "departing guest never has a delayed reply")
	_expect(not fourth.trigger("food", 1, 1, goodbye), "ordinary scene rejects departing guest")
	fourth.tick(2.1, goodbye)
	_expect(fourth.bubbles.is_empty(), "farewell expires without replay")
	_expect(not fourth.trigger("welcome", 2, 1, goodbye), "worker ID outside 0/1 rejected")


func _test_automatic_events() -> void:
	for scene: String in Director.POOLS:
		var model = _model()
		var director = _director()
		match scene:
			"welcome":
				model.customers[1].state = "queued"
				model.customers[1].table_id = 0
				model.tables.clear()
			"order": model.tables[0].phase = "ordering"
			"food", "drink":
				model.tables[0].phase = "serving_food" if scene == "food" else "serving_drink"
				model.workers[1].state = "working"
				model.workers[1].elapsed = 0.65
				model.tasks.append({"id": 1, "kind": scene, "state": "claimed", "worker_id": 1, "guest_id": 1, "table_id": 1, "generation": 1})
			"wait": model.customers[1].patience = 24.0
			"satisfied": model.tables[0].phase = "checkout"
			"goodbye":
				model.customers[1].state = "leaving"
				model.customers[1].paid = true
				model.tables[0].phase = "leaving"
		var before: Dictionary = model.snapshot()
		director.tick(0.1, model)
		_expect(director.bubbles.size() == 1, "automatic %s emits one initial bubble" % scene)
		if not director.bubbles.is_empty():
			_expect(director.bubbles[0].scene == scene, "automatic event chooses %s" % scene)
			if scene in ["food", "drink"]:
				_expect(director.bubbles[0].speaker == "worker:1", "delivery expression belongs to actual assigned worker")
		_expect(model.snapshot() == before, "automatic %s cannot mutate economy, orders, tasks, or actors" % scene)


func _test_capacity_identity_and_model_purity() -> void:
	var model = _model(8)
	var director = _director()
	var before: Dictionary = model.snapshot()
	var observed_ids: Dictionary = {}
	var largest_id: int = 0
	var actor_last_emotion: Dictionary = {}
	var scenes: Array[String] = ["welcome", "order", "food", "drink", "wait", "satisfied"]
	for step: int in range(120):
		for guest_id: int in range(1, 9):
			director.trigger(scenes[(step + guest_id) % scenes.size()], guest_id % 2, guest_id, model)
		director.tick(0.25, model)
		_expect(director.bubbles.size() <= 3, "bubble cap holds under event bursts")
		var actors: Dictionary = {}
		for bubble: Dictionary in director.active_bubbles(model):
			_expect(not actors.has(bubble.speaker), "same actor never has overlapping expressions")
			actors[bubble.speaker] = true
			_expect(bubble.emotion in Director.EMOTIONS and str(bubble.short_text).is_empty(), "default active bubble is nonverbal")
			_expect(float(bubble.duration) >= 2.0 and float(bubble.duration) <= 4.0, "bubble lifespan stays in 2-4 second range")
			_expect(is_equal_approx(float(bubble.elapsed) + float(bubble.remaining), float(bubble.duration)), "animation timing sums to stable duration")
			var id: int = int(bubble.id)
			if not observed_ids.has(id):
				_expect(id > largest_id, "new bubble ID is strictly increasing")
				largest_id = id
				if str(bubble.scene) != "goodbye":
					_expect(str(actor_last_emotion.get(bubble.speaker, "")) != str(bubble.emotion), "neither first nor reply actor repeats its previous expression")
				actor_last_emotion[bubble.speaker] = bubble.emotion
				observed_ids[id] = [bubble.speaker, bubble.emotion]
			else:
				_expect(observed_ids[id] == [bubble.speaker, bubble.emotion], "bubble identity stays stable across frames")
	_expect(largest_id > 4, "stress test exercised multiple complete conversations")
	_expect(model.snapshot() == before, "all director activity leaves model state exactly unchanged")
