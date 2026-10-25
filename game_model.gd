extends RefCounted
## Deterministic one-table restaurant model. UI sends actions; only this model pays.

const SAVE_VERSION: int = 1
const MEAL_PRICE: int = 38
const MAX_PATIENCE: float = 60.0
const PHASE_SECONDS: Dictionary = {
	"entering": 2.0, "seating": 1.5, "cooking": 4.0,
	"serving_food": 3.0, "serving_drink": 3.0, "eating": 5.0,
	"drinking": 2.4, "leaving": 2.0, "collecting": 1.6, "wiping": 1.6,
}
const ACTIONS: Dictionary = {
	"queued": "seat", "ordering": "order", "awaiting_cook": "cook",
	"food_ready": "serve_food", "waiting_drink": "serve_drink",
	"checkout": "pay", "dirty": "clean", "ready_next": "next",
}
const PATIENCE_PHASES: Array[String] = [
	"queued", "ordering", "awaiting_cook", "cooking", "food_ready",
	"waiting_drink", "checkout",
]
const ALL_PHASES: Array[String] = [
	"entering", "queued", "seating", "ordering", "awaiting_cook", "cooking",
	"food_ready", "serving_food", "waiting_drink", "serving_drink", "eating",
	"drinking", "checkout", "leaving", "dirty", "collecting", "wiping", "ready_next",
]

var phase: String = "entering"
var elapsed: float = 0.0
var patience: float = MAX_PATIENCE
var paused: bool = false
var coins: int = 0
var served: int = 0
var lost: int = 0
var customer_id: int = 1
var paid: bool = false
var food_delivered: bool = false
var drink_delivered: bool = false
var table_used: bool = false
var dishes_collected: bool = false


func available_action() -> String:
	if paused:
		return ""
	return str(ACTIONS.get(phase, ""))


func advance(action: String) -> bool:
	if paused or action.is_empty() or action != available_action():
		return false
	match action:
		"seat":
			table_used = true
			patience = MAX_PATIENCE
			_set_phase("seating")
		"order":
			patience = MAX_PATIENCE
			_set_phase("awaiting_cook")
		"cook":
			_set_phase("cooking")
		"serve_food":
			_set_phase("serving_food")
		"serve_drink":
			_set_phase("serving_drink")
		"pay":
			if paid:
				return false
			paid = true
			coins += MEAL_PRICE
			served += 1
			_set_phase("leaving")
		"clean":
			_set_phase("collecting")
		"next":
			customer_id += 1
			paid = false
			food_delivered = false
			drink_delivered = false
			table_used = false
			dishes_collected = false
			patience = MAX_PATIENCE
			_set_phase("entering")
		_:
			return false
	return true


func tick(delta: float) -> void:
	if paused or not is_finite(delta) or delta <= 0.0:
		return
	# Segment large deltas at every event, so frame rate cannot skip payment or cleanup.
	var remaining: float = delta
	var transitions: int = 0
	while remaining > 0.0 and transitions < 32:
		var duration: float = float(PHASE_SECONDS.get(phase, -1.0))
		var has_patience: bool = phase in PATIENCE_PHASES
		var segment: float = remaining
		if duration >= 0.0:
			segment = minf(segment, maxf(0.0, duration - elapsed))
		if has_patience:
			segment = minf(segment, patience)
		elapsed += segment
		remaining -= segment
		if has_patience:
			patience = maxf(0.0, patience - segment)
		if has_patience and patience <= 0.0:
			lost += 1
			_set_phase("leaving")
			transitions += 1
		elif duration >= 0.0 and elapsed >= duration:
			_complete_phase()
			transitions += 1
		else:
			break


func _set_phase(next_phase: String) -> void:
	phase = next_phase
	elapsed = 0.0


func _complete_phase() -> void:
	match phase:
		"entering":
			_set_phase("queued")
		"seating":
			_set_phase("ordering")
		"cooking":
			_set_phase("food_ready")
		"serving_food":
			food_delivered = true
			patience = MAX_PATIENCE
			_set_phase("waiting_drink")
		"serving_drink":
			drink_delivered = true
			_set_phase("eating")
		"eating":
			_set_phase("drinking")
		"drinking":
			patience = MAX_PATIENCE
			_set_phase("checkout")
		"leaving":
			_set_phase("dirty" if table_used else "ready_next")
		"collecting":
			dishes_collected = true
			_set_phase("wiping")
		"wiping":
			table_used = false
			_set_phase("ready_next")


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION, "phase": phase, "elapsed": elapsed,
		"patience": patience, "paused": paused, "coins": coins, "served": served,
		"lost": lost, "customer_id": customer_id, "paid": paid,
		"food_delivered": food_delivered, "drink_delivered": drink_delivered,
		"table_used": table_used, "dishes_collected": dishes_collected,
	}


func restore(data: Dictionary) -> bool:
	# Validate the whole snapshot before assigning even one field.
	for key: String in ["version", "coins", "served", "lost", "customer_id"]:
		if not _is_integer(data.get(key)):
			return false
	if int(data["version"]) != SAVE_VERSION or int(data["customer_id"]) < 1:
		return false
	for key: String in ["elapsed", "patience"]:
		if not _is_number(data.get(key)):
			return false
	for key: String in ["paused", "paid", "food_delivered", "drink_delivered", "table_used", "dishes_collected"]:
		if typeof(data.get(key)) != TYPE_BOOL:
			return false
	if typeof(data.get("phase")) != TYPE_STRING or data["phase"] not in ALL_PHASES:
		return false
	var next_phase: String = data["phase"]
	var next_elapsed: float = float(data["elapsed"])
	var next_patience: float = float(data["patience"])
	if next_elapsed < 0.0 or next_elapsed > 31536000.0 or next_patience < 0.0 or next_patience > MAX_PATIENCE:
		return false
	if next_phase in PATIENCE_PHASES and next_patience == 0.0:
		return false
	if PHASE_SECONDS.has(next_phase) and next_elapsed > float(PHASE_SECONDS[next_phase]):
		return false
	if int(data["coins"]) != int(data["served"]) * MEAL_PRICE:
		return false
	var completed: int = int(data["served"]) + int(data["lost"])
	var guest_finished: bool = next_phase in ["leaving", "dirty", "collecting", "wiping", "ready_next"]
	if completed != int(data["customer_id"]) - (0 if guest_finished else 1):
		return false
	if bool(data["paid"]) and (int(data["served"]) == 0 or next_phase not in ["leaving", "dirty", "collecting", "wiping", "ready_next"]):
		return false
	if bool(data["drink_delivered"]) and not bool(data["food_delivered"]):
		return false
	if bool(data["paid"]) and not bool(data["drink_delivered"]):
		return false
	if bool(data["dishes_collected"]) and next_phase not in ["wiping", "ready_next"]:
		return false
	if next_phase == "wiping" and not bool(data["dishes_collected"]):
		return false
	if next_phase in ["entering", "queued"] and (bool(data["table_used"]) or bool(data["paid"]) or bool(data["food_delivered"]) or bool(data["drink_delivered"]) or bool(data["dishes_collected"])):
		return false
	if next_phase in ["seating", "ordering", "awaiting_cook", "cooking", "food_ready", "serving_food"] and (not bool(data["table_used"]) or bool(data["food_delivered"])):
		return false
	if next_phase in ["waiting_drink", "serving_drink"] and (not bool(data["table_used"]) or not bool(data["food_delivered"]) or bool(data["drink_delivered"])):
		return false
	if next_phase in ["eating", "drinking", "checkout"] and (not bool(data["table_used"]) or not bool(data["drink_delivered"])):
		return false
	if next_phase in ["dirty", "collecting", "wiping"] and not bool(data["table_used"]):
		return false
	if next_phase == "ready_next" and bool(data["table_used"]):
		return false
	phase = next_phase
	elapsed = next_elapsed
	patience = next_patience
	paused = bool(data["paused"])
	coins = int(data["coins"])
	served = int(data["served"])
	lost = int(data["lost"])
	customer_id = int(data["customer_id"])
	paid = bool(data["paid"])
	food_delivered = bool(data["food_delivered"])
	drink_delivered = bool(data["drink_delivered"])
	table_used = bool(data["table_used"])
	dishes_collected = bool(data["dishes_collected"])
	return true


func _is_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))


func _is_integer(value: Variant) -> bool:
	return _is_number(value) and float(value) >= 0.0 and float(value) <= 1000000000.0 and floorf(float(value)) == float(value)


func save_to(path: String) -> Error:
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
	if not FileAccess.file_exists(path):
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parser := JSON.new()
	var result: Error = parser.parse(file.get_as_text())
	file.close()
	if result != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return false
	return restore(parser.data)
