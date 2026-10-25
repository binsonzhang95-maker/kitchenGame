extends RefCounted
## Offline, visual-only dialogue. No model writes, IO, task claims, or saved state.
const MAX_BUBBLES: int = 3
const COOLDOWN: float = 8.0
const FIRST_SECONDS: float = 2.0
const REPLY_SECONDS: float = 3.0
const EMOTIONS: Array[String] = ["hungry", "question", "ok", "wait", "upset", "sorry", "love", "bye"]
const SHORT_TEXT: Dictionary = {"hungry": "想吃", "question": "想问问", "ok": "好的", "wait": "等等", "upset": "鼓鼓脸", "sorry": "抱歉", "love": "喜欢", "bye": "再见"}
## Entries are [first role, first emotion, reply role, reply emotion].
## They contain no dialogue text; IDs match the supplied eight-row icon atlas.
const POOLS: Dictionary = {
	"welcome": [["worker", "ok", "guest", "hungry"], ["worker", "love", "guest", "ok"], ["worker", "ok", "guest", "love"]],
	"order": [["guest", "hungry", "worker", "ok"], ["guest", "question", "worker", "ok"], ["guest", "hungry", "worker", "love"], ["guest", "question", "worker", "love"]],
	"food": [["worker", "ok", "guest", "love"], ["worker", "love", "guest", "hungry"], ["worker", "ok", "guest", "ok"], ["worker", "love", "guest", "ok"]],
	"drink": [["worker", "ok", "guest", "love"], ["worker", "love", "guest", "ok"], ["worker", "ok", "guest", "ok"]],
	"wait": [["guest", "wait", "worker", "sorry"], ["guest", "upset", "worker", "sorry"], ["guest", "question", "worker", "wait"]],
	"satisfied": [["guest", "love", "worker", "ok"], ["guest", "ok", "worker", "love"], ["guest", "love", "worker", "love"]],
	"goodbye": [["worker", "bye", "guest", "bye"], ["worker", "bye", "guest", "ok"], ["worker", "bye", "guest", "love"]],
}

var enabled: bool = true:
	set(value):
		enabled = value
		if not enabled:
			bubbles.clear()
			_pending.clear()
var bubbles: Array[Dictionary] = []
var show_short_text: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _clock: float = 0.0
var _next_bubble_id: int = 1
var _pending: Array[Dictionary] = []
var _next_allowed: Dictionary = {}
var _events_seen: Dictionary = {}
var _last_pair: Dictionary = {}
var _last_emotion: Dictionary = {}
var _guest_states: Dictionary = {}
var _table_states: Dictionary = {}


func _init() -> void:
	rng.randomize()


func trigger(scene: String, worker_id: int, guest_id: int, model) -> bool:
	if not enabled or model == null or bool(model.paused) or not POOLS.has(scene):
		return false
	if not _worker_exists(worker_id, model) or not model.customers.has(guest_id):
		return false
	var guest: Dictionary = model.customers[guest_id]
	var goodbye: bool = scene == "goodbye"
	if str(guest.state) == "leaving" and (not goodbye or not bool(guest.get("paid", false))):
		return false
	if goodbye and (str(guest.state) != "leaving" or not bool(guest.get("paid", false))):
		return false
	var context: Dictionary = _context(scene, worker_id, guest_id, model)
	var event_key: String = "%s:%d:%d:%d" % [scene, guest_id, int(context.table_id), int(context.generation)]
	var worker_speaker: String = "worker:%d" % worker_id
	var guest_speaker: String = "guest:%d" % guest_id
	if _events_seen.has(event_key) or bubbles.size() >= MAX_BUBBLES or not _available(worker_speaker):
		return false
	if not goodbye and not _available(guest_speaker):
		return false
	if not _context_valid(context, model, goodbye):
		return false
	var choices: Array = POOLS[scene]
	var eligible: Array[int] = []
	for index: int in range(choices.size()):
		var candidate: Array = choices[index]
		if choices.size() > 1 and index == int(_last_pair.get(scene, -1)):
			continue
		var candidate_first: String = worker_speaker if candidate[0] == "worker" else guest_speaker
		var candidate_reply: String = worker_speaker if candidate[2] == "worker" else guest_speaker
		# Check both actors before reserving the pair. Farewell is necessarily bye;
		# the event key still prevents replay for the same departing guest.
		if not goodbye and (str(candidate[1]) == str(_last_emotion.get(candidate_first, "")) or str(candidate[3]) == str(_last_emotion.get(candidate_reply, ""))):
			continue
		eligible.append(index)
	if eligible.is_empty():
		return false
	var selected: int = eligible[rng.randi_range(0, eligible.size() - 1)]
	var pair: Array = choices[selected]
	var first_speaker: String = worker_speaker if pair[0] == "worker" else guest_speaker
	var reply_speaker: String = worker_speaker if pair[2] == "worker" else guest_speaker
	_last_pair[scene] = selected
	_events_seen[event_key] = guest_id
	_show(first_speaker, str(pair[1]), FIRST_SECONDS, context, _clock)
	if not goodbye:
		var reply: Dictionary = context.duplicate(true)
		reply.speaker = reply_speaker
		reply.emotion = str(pair[3])
		reply.due = _clock + FIRST_SECONDS
		reply.expires = _clock + FIRST_SECONDS + REPLY_SECONDS
		_pending.append(reply)
	return true


func tick(delta: float, model) -> void:
	if not enabled:
		bubbles.clear()
		_pending.clear()
		return
	if model == null or bool(model.paused) or not is_finite(delta) or delta <= 0.0:
		return
	_clock += delta
	for bubble: Dictionary in bubbles.duplicate():
		bubble.remaining = maxf(0.0, float(bubble.remaining) - delta)
		bubble.elapsed = float(bubble.duration) - float(bubble.remaining)
		if float(bubble.remaining) <= 0.0 or not _context_valid(bubble, model, str(bubble.scene) == "goodbye"):
			bubbles.erase(bubble)
	for reply: Dictionary in _pending.duplicate():
		if not _context_valid(reply, model, false) or _clock >= float(reply.expires):
			_pending.erase(reply)
		elif _clock >= float(reply.due) and bubbles.size() < MAX_BUBBLES:
			# Use the original due time even after a long frame; no late full-length bubble.
			_show(str(reply.speaker), str(reply.emotion), REPLY_SECONDS, reply, float(reply.due))
			_pending.erase(reply)
	_detect_events(model)
	_prune_history(model)


func active_bubbles(model) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not enabled or model == null:
		return result
	for bubble: Dictionary in bubbles:
		if float(bubble.remaining) > 0.0 and _context_valid(bubble, model, str(bubble.scene) == "goodbye"):
			result.append(bubble.duplicate(true))
	return result


func to_debug() -> Dictionary:
	return {"clock": _clock, "bubbles": bubbles.duplicate(true), "pending": _pending.duplicate(true), "next_allowed": _next_allowed.duplicate(true), "events_seen": _events_seen.duplicate(true)}


func _show(speaker: String, emotion: String, seconds: float, context: Dictionary, started: float) -> void:
	var bubble: Dictionary = context.duplicate(true)
	bubble.id = _next_bubble_id
	_next_bubble_id += 1
	bubble.speaker = speaker
	bubble.emotion = emotion
	bubble.short_text = str(SHORT_TEXT.get(emotion, "")) if show_short_text else ""
	bubble.duration = seconds
	bubble.elapsed = maxf(0.0, _clock - started)
	bubble.remaining = maxf(0.0, seconds - float(bubble.elapsed))
	bubbles.append(bubble)
	_next_allowed[speaker] = started + COOLDOWN
	_last_emotion[speaker] = emotion


func _available(speaker: String) -> bool:
	if _clock < float(_next_allowed.get(speaker, 0.0)):
		return false
	for bubble: Dictionary in bubbles:
		if bubble.speaker == speaker:
			return false
	for reply: Dictionary in _pending:
		if reply.speaker == speaker:
			return false
	return true


func _worker_exists(worker_id: int, model) -> bool:
	return worker_id in [0, 1] and worker_id < model.workers.size() and int(model.workers[worker_id].id) == worker_id


func _context(scene: String, worker_id: int, guest_id: int, model) -> Dictionary:
	var guest: Dictionary = model.customers[guest_id]
	var table_id: int = int(guest.get("table_id", 0))
	var generation: int = -1
	if table_id > 0 and table_id <= model.tables.size():
		generation = int(model.tables[table_id - 1].generation)
	return {"scene": scene, "worker_id": worker_id, "guest_id": guest_id, "table_id": table_id, "generation": generation}


func _context_valid(context: Dictionary, model, allow_goodbye: bool) -> bool:
	var guest_id: int = int(context.guest_id)
	if not _worker_exists(int(context.worker_id), model) or not model.customers.has(guest_id):
		return false
	var guest: Dictionary = model.customers[guest_id]
	if str(guest.state) == "leaving":
		if not allow_goodbye or str(context.scene) != "goodbye" or not bool(guest.get("paid", false)) or str(context.get("speaker", "worker:")).begins_with("guest:"):
			return false
	var table_id: int = int(context.table_id)
	if table_id > 0:
		if table_id > model.tables.size() or int(guest.get("table_id", 0)) != table_id:
			return false
		var table: Dictionary = model.tables[table_id - 1]
		if int(table.guest_id) != guest_id or int(table.generation) != int(context.generation):
			return false
		if table.phase in ["free", "dirty", "collecting", "wiping"]:
			return false
	return true


func _auto(scene: String, guest_id: int, model, preferred: int = -1) -> void:
	if preferred in [0, 1]:
		# Food/drink lines belong to the worker actually handling that task.
		trigger(scene, preferred, guest_id, model)
		return
	for worker_id: int in [0, 1]:
		if trigger(scene, worker_id, guest_id, model):
			return


func _detect_events(model) -> void:
	for guest_id: int in model.customers:
		var guest: Dictionary = model.customers[guest_id]
		var state: String = str(guest.state)
		var previous: String = str(_guest_states.get(guest_id, ""))
		if previous.is_empty() and state in ["queued", "walking"]:
			_auto("welcome", guest_id, model)
		if state != "leaving" and float(guest.get("patience", 120.0)) < 25.0:
			_auto("wait", guest_id, model)
		if state == "leaving" and previous != "leaving" and bool(guest.get("paid", false)):
			_auto("goodbye", guest_id, model)
		_guest_states[guest_id] = state
	for table: Dictionary in model.tables:
		var table_id: int = int(table.id)
		var phase: String = str(table.phase)
		var marker: String = "%s:%d:%d" % [phase, int(table.guest_id), int(table.generation)]
		if str(_table_states.get(table_id, "")) != marker and int(table.guest_id) > 0:
			match phase:
				"ordering": _auto("order", int(table.guest_id), model)
				"waiting_drink": _auto("food", int(table.guest_id), model)
				"eating": _auto("drink", int(table.guest_id), model)
				"checkout": _auto("satisfied", int(table.guest_id), model)
		_table_states[table_id] = marker
	for task: Dictionary in model.tasks:
		if str(task.get("kind", "")) not in ["food", "drink"] or str(task.get("state", "")) != "claimed":
			continue
		var worker_id: int = int(task.get("worker_id", -1))
		if not _worker_exists(worker_id, model):
			continue
		var worker: Dictionary = model.workers[worker_id]
		if worker.state == "working" and float(worker.get("elapsed", 0.0)) >= 0.6:
			_auto(str(task.kind), int(task.guest_id), model, worker_id)


func _prune_history(model) -> void:
	for key: Variant in _events_seen.keys():
		if not model.customers.has(int(_events_seen[key])):
			_events_seen.erase(key)
	for guest_id: Variant in _guest_states.keys():
		if not model.customers.has(int(guest_id)):
			_guest_states.erase(guest_id)
			_next_allowed.erase("guest:%d" % int(guest_id))
			_last_emotion.erase("guest:%d" % int(guest_id))
