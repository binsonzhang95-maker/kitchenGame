class_name KitchenInputAdapter
extends RefCounted
## Stateless-with-respect-to-CookingSession input normalizer for the local simulator.
## It only returns a candidate action; the caller remains responsible for session.act().

const FOOD_CARDS: Array[String] = ["potato", "carrot", "egg", "tomato", "bread", "cheese", "coffee", "milk", "ice", "pumpkin", "corn", "mushroom"]
const VESSEL_CARDS: Array[String] = ["pot", "pan"]
const RECOGNIZED_CARDS: Array[String] = ["potato", "carrot", "egg", "tomato", "bread", "cheese", "coffee", "milk", "ice", "pumpkin", "corn", "mushroom", "onion", "cabbage", "green_pepper", "cucumber", "apple", "banana", "pear", "orange", "kiwi", "lemon", "watermelon", "salt", "pepper", "clothes"]
const LEVELS: Array[String] = ["off", "small", "medium", "high"]
const SNAPSHOT_KEYS: Array[String] = ["stove_level", "oven_level", "oven_open", "vessel", "faucet_open"]
const MAX_SEQUENCE: int = 1000000000

var _token: String = ""
var _preparation_epoch: int = 0
var _connection_epoch: int = 0
var _source: String = "screen"
var _connection: String = "disconnected"
var _last_seq: int = 0
var _panel: Dictionary = _empty_panel()
var _faucet_open_offered: bool = false
var _vessel_present_offered: String = ""


func bind(token: String) -> Dictionary:
	# A new binding has no authority from the prior run. Keep both parts of
	# authority monotonic for this adapter instance, even when the token repeats.
	_token = token
	_preparation_epoch += 1
	_connection_epoch += 1
	_source = "screen"
	_connection = "disconnected"
	_last_seq = 0
	_panel = _empty_panel()
	_clear_latches()
	return event_envelope()


func reset_preparation() -> Dictionary:
	# The owner calls this after clear/retry. Current held panel controls are a
	# baseline, not newly performed actions in the new preparation.
	_preparation_epoch += 1
	_initialize_latches_from_panel()
	return event_envelope()


func use_screen() -> Dictionary:
	# Incrementing the connection epoch makes any queued simulator event stale.
	_connection_epoch += 1
	_source = "screen"
	_connection = "disconnected"
	_last_seq = 0
	_panel = _empty_panel()
	_clear_latches()
	return event_envelope()


func connect_simulator() -> Dictionary:
	_connection_epoch += 1
	_source = "simulator"
	_connection = "aligning"
	_last_seq = 0
	_panel = _empty_panel()
	_clear_latches()
	return event_envelope()


func disconnect_simulator() -> Dictionary:
	_connection_epoch += 1
	_source = "simulator"
	_connection = "disconnected"
	_last_seq = 0
	_panel = _empty_panel()
	_clear_latches()
	return event_envelope()


func event_envelope() -> Dictionary:
	return {
		"source": _source,
		"token": _token,
		"preparation_epoch": _preparation_epoch,
		"connection_epoch": _connection_epoch,
		"seq": _last_seq + 1,
	}


func state() -> Dictionary:
	return {
		"token": _token,
		"preparation_epoch": _preparation_epoch,
		"connection_epoch": _connection_epoch,
		"source": _source,
		"connection": _connection,
		"last_seq": _last_seq,
		"panel": _panel.duplicate(true),
	}


func hold_reason(status: Dictionary) -> String:
	if _source == "screen":
		return ""
	if _connection == "disconnected":
		return "simulator_disconnected"
	if _connection == "aligning":
		return "simulator_aligning"
	if str(status.get("phase", "")) != "cooking":
		# Ready is deliberately finishable even if a panel control changes.
		return ""
	if str(status.get("recipe_id", "")) == "bake":
		if bool(_panel.oven_open):
			return "oven_door_open"
		if str(_panel.oven_level) == "off":
			return "oven_off"
		return ""
	var expected_vessel: String = str(status.get("vessel", ""))
	if expected_vessel.is_empty() or str(_panel.vessel) != expected_vessel:
		return "vessel_missing" if str(_panel.vessel).is_empty() else "wrong_vessel"
	var expected_level: String = str(status.get("heat_level", ""))
	var actual_level: String = str(_panel.stove_level)
	if actual_level == "off":
		return "stove_off"
	if actual_level != expected_level:
		return "stove_level_mismatch:" + expected_level
	return ""


func handle(event: Dictionary, status: Dictionary) -> Dictionary:
	var envelope_feedback: String = _validate_envelope(event)
	if not envelope_feedback.is_empty():
		return _result("", envelope_feedback, false)
	var sequence: int = int(event.seq)
	if sequence <= _last_seq:
		return _result("", "duplicate" if sequence == _last_seq else "stale", false)
	_last_seq = sequence
	if typeof(event.get("type")) != TYPE_STRING:
		return _result("", "invalid_event", false)
	var event_type: String = str(event.type)
	if _source == "screen":
		# Screen controls call CookingSession through Main; semantic device events never do.
		return _result("", "screen_ignored", true)
	if _connection != "connected":
		if event_type == "panel_snapshot" and _connection == "aligning":
			if not _apply_snapshot(event):
				return _result("", "invalid_snapshot", false)
			_connection = "connected"
			return _result("", "aligned", true)
		return _result("", "not_connected" if _connection == "disconnected" else "not_aligned", false)
	match event_type:
		"panel_snapshot":
			if not _apply_snapshot(event):
				return _result("", "invalid_snapshot", false)
			return _result("", "panel_aligned", true)
		"read_failed":
			return _result("", "read_failed", false)
		"card":
			return _handle_card(event, status)
		"cut":
			return _candidate("cut", status, "not_needed")
		"faucet":
			return _handle_faucet(event, status)
		"vessel":
			return _handle_vessel(event, status)
		"stove":
			return _handle_stove(event, status)
		"oven_door":
			return _handle_oven_door(event)
		"oven_level":
			return _handle_oven_level(event)
		"drink_button":
			return _handle_drink_button(event, status)
		_:
			return _result("", "invalid_event", false)


func _handle_card(event: Dictionary, status: Dictionary) -> Dictionary:
	if typeof(event.get("category")) != TYPE_STRING or typeof(event.get("zone")) != TYPE_STRING:
		return _result("", "invalid_event", false)
	var category: String = str(event.category)
	if category in VESSEL_CARDS:
		if str(event.zone) != "stove":
			return _result("", "wrong_zone", false)
		return _offer_vessel(category, true, status)
	if category not in RECOGNIZED_CARDS:
		return _result("", "unknown_card", false)
	if str(event.zone) != "cutting_board":
		return _result("", "wrong_zone", false)
	if category not in FOOD_CARDS:
		return _result("", "not_needed", false)
	return _ingredient_candidate(category, status, false)


func _handle_faucet(event: Dictionary, status: Dictionary) -> Dictionary:
	if typeof(event.get("open")) != TYPE_BOOL:
		return _result("", "invalid_event", false)
	var open: bool = bool(event.open)
	_panel.faucet_open = open
	if not open:
		_faucet_open_offered = false
		return _result("", "panel_updated", true)
	if _faucet_open_offered:
		return _result("", "duplicate", false)
	_faucet_open_offered = true
	if bool(status.get("water_added", false)):
		return _result("", "already_added", false)
	return _candidate("add_water", status, "not_needed")


func _handle_vessel(event: Dictionary, status: Dictionary) -> Dictionary:
	if typeof(event.get("kind")) != TYPE_STRING or typeof(event.get("present")) != TYPE_BOOL:
		return _result("", "invalid_event", false)
	var kind: String = str(event.kind)
	if kind not in VESSEL_CARDS:
		return _result("", "invalid_event", false)
	return _offer_vessel(kind, bool(event.present), status)


func _offer_vessel(kind: String, present: bool, status: Dictionary) -> Dictionary:
	_panel.vessel = kind if present else ""
	if not present:
		_vessel_present_offered = ""
		return _result("", "panel_updated", true)
	if _vessel_present_offered == kind:
		return _result("", "duplicate", false)
	_vessel_present_offered = kind
	if str(status.get("vessel", "")) == kind:
		return _result("", "already_added", false)
	return _candidate(kind, status, "not_needed")


func _handle_stove(event: Dictionary, status: Dictionary) -> Dictionary:
	if typeof(event.get("level")) != TYPE_STRING or str(event.level) not in LEVELS:
		return _result("", "invalid_event", false)
	var level: String = str(event.level)
	var changed: bool = str(_panel.stove_level) != level
	_panel.stove_level = level
	if not changed or level == "off":
		return _result("", "panel_updated", true)
	var expected_vessel: String = str(status.get("vessel", ""))
	if str(_panel.vessel).is_empty():
		return _result("", "vessel_missing", false)
	if expected_vessel.is_empty() or str(_panel.vessel) != expected_vessel:
		return _result("", "wrong_vessel", false)
	return _candidate("heat_" + level, status, "not_needed")


func _handle_oven_door(event: Dictionary) -> Dictionary:
	if typeof(event.get("open")) != TYPE_BOOL:
		return _result("", "invalid_event", false)
	_panel.oven_open = bool(event.open)
	return _result("", "panel_updated", true)


func _handle_oven_level(event: Dictionary) -> Dictionary:
	if typeof(event.get("level")) != TYPE_STRING or str(event.level) not in LEVELS:
		return _result("", "invalid_event", false)
	_panel.oven_level = str(event.level)
	return _result("", "panel_updated", true)


func _handle_drink_button(event: Dictionary, status: Dictionary) -> Dictionary:
	if typeof(event.get("ingredient")) != TYPE_STRING:
		return _result("", "invalid_event", false)
	var ingredient: String = str(event.ingredient)
	if ingredient not in ["coffee", "milk", "ice"]:
		return _result("", "not_needed", false)
	return _ingredient_candidate(ingredient, status, true)


func _ingredient_candidate(ingredient: String, status: Dictionary, ordered: bool) -> Dictionary:
	var ingredients: Array = status.get("ingredients", [])
	if ingredients is Array and ingredient in ingredients:
		return _result("", "already_added", false)
	var action: String = "add_" + ingredient
	if _has_action(status, action):
		return _candidate(action, status, "not_needed")
	if ordered and str(status.get("phase", "")) == "ingredients":
		return _result("", "out_of_order", false)
	return _result("", "not_needed", false)


func _candidate(action: String, status: Dictionary, otherwise: String) -> Dictionary:
	if bool(status.get("paused", false)):
		return _result("", "paused", false)
	if not _status_actions_valid(status):
		return _result("", "invalid_status", false)
	if _has_action(status, action):
		return _result(action, "action_candidate", true)
	return _result("", otherwise, false)


func _has_action(status: Dictionary, action: String) -> bool:
	if not _status_actions_valid(status):
		return false
	return action in status.actions


func _status_actions_valid(status: Dictionary) -> bool:
	if not status.has("actions") or not status.actions is Array:
		return false
	for action: Variant in status.actions:
		if typeof(action) != TYPE_STRING:
			return false
	return true


func _apply_snapshot(event: Dictionary) -> bool:
	for key: String in SNAPSHOT_KEYS:
		if not event.has(key):
			return false
	if typeof(event.stove_level) != TYPE_STRING or str(event.stove_level) not in LEVELS:
		return false
	if typeof(event.oven_level) != TYPE_STRING or str(event.oven_level) not in LEVELS:
		return false
	if typeof(event.oven_open) != TYPE_BOOL or typeof(event.faucet_open) != TYPE_BOOL:
		return false
	if typeof(event.vessel) != TYPE_STRING or str(event.vessel) not in ["", "pot", "pan"]:
		return false
	# Do not mutate before all validation has succeeded.
	_panel = {
		"stove_level": str(event.stove_level),
		"oven_level": str(event.oven_level),
		"oven_open": bool(event.oven_open),
		"vessel": str(event.vessel),
		"faucet_open": bool(event.faucet_open),
	}
	# A snapshot reports the state already held at alignment time. It must not
	# turn that state into a fresh faucet/vessel edge after resume or reselect.
	_initialize_latches_from_panel()
	return true


func _validate_envelope(event: Dictionary) -> String:
	for key: String in ["source", "token", "preparation_epoch", "connection_epoch", "seq"]:
		if not event.has(key):
			return "invalid_event"
	if typeof(event.source) != TYPE_STRING or str(event.source) not in ["screen", "simulator"]:
		return "invalid_event"
	if typeof(event.token) != TYPE_STRING or typeof(event.preparation_epoch) != TYPE_INT or typeof(event.connection_epoch) != TYPE_INT or typeof(event.seq) != TYPE_INT:
		return "invalid_event"
	if int(event.preparation_epoch) < 1 or int(event.connection_epoch) < 1 or int(event.seq) < 1 or int(event.seq) > MAX_SEQUENCE:
		return "invalid_event"
	if str(event.token) != _token or int(event.preparation_epoch) != _preparation_epoch or int(event.connection_epoch) != _connection_epoch or str(event.source) != _source:
		return "stale"
	return ""


func _result(action: String, feedback: String, accepted: bool) -> Dictionary:
	return {
		"action": action,
		"feedback": feedback,
		"accepted": accepted,
		"token": _token,
		"preparation_epoch": _preparation_epoch,
		"connection_epoch": _connection_epoch,
	}


func _clear_latches() -> void:
	_faucet_open_offered = false
	_vessel_present_offered = ""


func _initialize_latches_from_panel() -> void:
	_faucet_open_offered = bool(_panel.faucet_open)
	_vessel_present_offered = str(_panel.vessel)


static func _empty_panel() -> Dictionary:
	return {"stove_level": "off", "oven_level": "off", "oven_open": false, "vessel": "", "faucet_open": false}
