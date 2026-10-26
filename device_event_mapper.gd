class_name DeviceEventMapper
extends RefCounted

const CardMap = preload("res://device_card_map.gd")
const ANTENNA_ZONES: Dictionary = {
	"U16": "stove",
	"U17": "cutting_board",
	"U19": "washing_machine",
	"U20": "oven",
}
const LEVELS: Array[String] = ["off", "small", "medium", "high"]
const REMOVAL_SCANS := 3

var _present: Dictionary = {}
var _stove_vessel_uid := ""
var _panel_linked := false
var _panel: Dictionary = {}


func _init() -> void:
	reset()


func reset() -> void:
	_present = {}
	for zone: String in ANTENNA_ZONES.values():
		_present[zone] = {}
	_stove_vessel_uid = ""
	_panel_linked = false
	_panel = {}


func map(payload: Dictionary) -> Array[Dictionary]:
	match str(payload.get("event_type", "")):
		"nfc.scan":
			return _map_nfc(payload)
		"io.panel":
			return _map_panel(payload)
		"door.state":
			return _map_door(payload)
	return []


func _map_nfc(payload: Dictionary) -> Array[Dictionary]:
	var seen: Dictionary = {}
	for zone: String in ANTENNA_ZONES.values():
		seen[zone] = {}
	var routes: Variant = payload.get("routes", [])
	if routes is Array:
		for route: Variant in routes:
			if not route is Dictionary:
				continue
			var zone: String = str(ANTENNA_ZONES.get(str(route.get("antenna", "")), ""))
			if zone.is_empty():
				continue
			var tags: Variant = route.get("tags", [])
			if not tags is Array:
				continue
			for tag: Variant in tags:
				if not tag is Dictionary:
					continue
				var uid := str(tag.get("uid", "")).to_upper()
				if not uid.is_empty():
					seen[zone][uid] = true

	var events: Array[Dictionary] = []
	var previous_vessel := _stove_vessel()
	for zone: String in ANTENNA_ZONES.values():
		var zone_present: Dictionary = _present[zone]
		for uid: String in zone_present.keys():
			if seen[zone].has(uid):
				zone_present[uid].misses = 0
				continue
			zone_present[uid].misses = int(zone_present[uid].misses) + 1
			if int(zone_present[uid].misses) < REMOVAL_SCANS:
				continue
			zone_present.erase(uid)
		for uid: String in seen[zone]:
			if zone_present.has(uid):
				continue
			var name := str(CardMap.UID_TO_NAME.get(uid, ""))
			var card := str(CardMap.NAME_TO_CARD_ID.get(name, ""))
			zone_present[uid] = {"card": card, "misses": 0}
			if card.is_empty():
				events.append({"type": "read_failed"})
			elif zone != "stove" or card not in ["pot", "pan"]:
				events.append({"type": "card", "category": card, "zone": zone})

	var next_vessel_uid := _stove_vessel_uid
	if next_vessel_uid.is_empty() or not _present.stove.has(next_vessel_uid) or not seen.stove.has(next_vessel_uid):
		for uid: String in seen.stove:
			if str(_present.stove[uid].card) in ["pot", "pan"]:
				next_vessel_uid = uid
				break
	if not next_vessel_uid.is_empty() and not _present.stove.has(next_vessel_uid):
		next_vessel_uid = ""
	_stove_vessel_uid = next_vessel_uid
	var next_vessel := _stove_vessel()
	if next_vessel != previous_vessel:
		if not previous_vessel.is_empty():
			events.append({"type": "vessel", "kind": previous_vessel, "present": false})
		if not next_vessel.is_empty():
			events.append({"type": "vessel", "kind": next_vessel, "present": true})
	return events


func _map_panel(payload: Dictionary) -> Array[Dictionary]:
	if typeof(payload.get("linked")) != TYPE_BOOL:
		return []
	if not bool(payload.linked):
		_panel_linked = false
		return []
	var next := _panel_state(payload)
	if next.is_empty():
		return []
	if not _panel_linked:
		_panel_linked = true
		_panel = next
		return [{
			"type": "panel_snapshot",
			"stove_level": next.stove_level,
			"oven_level": next.oven_level,
			"oven_open": next.oven_open,
			"vessel": _stove_vessel(),
			"faucet_open": next.faucet_open,
		}]

	var events: Array[Dictionary] = []
	if next.stove_level != _panel.stove_level:
		events.append({"type": "stove", "level": next.stove_level})
	if next.oven_level != _panel.oven_level:
		events.append({"type": "oven_level", "level": next.oven_level})
	if next.oven_open != _panel.oven_open:
		events.append({"type": "oven_door", "open": next.oven_open})
	if next.faucet_open != _panel.faucet_open:
		events.append({"type": "faucet", "open": next.faucet_open})
	for ingredient: String in ["coffee", "milk", "ice"]:
		if bool(next.buttons[ingredient]) and not bool(_panel.buttons[ingredient]):
			events.append({"type": "drink_button", "ingredient": ingredient})
	_panel = next
	return events


func _map_door(payload: Dictionary) -> Array[Dictionary]:
	var open := _door_value(payload.get("doors"))
	if open < 0:
		return []
	if _panel_linked:
		_panel.oven_open = open == 1
	return [{"type": "oven_door", "open": open == 1}]


func _panel_state(payload: Dictionary) -> Dictionary:
	var knobs: Variant = payload.get("knobs")
	var buttons: Variant = payload.get("button_states")
	if not knobs is Dictionary or not buttons is Dictionary:
		return {}
	var stove := _level(knobs.get("stove"))
	var oven := _level(knobs.get("oven"))
	var door := _door_value(payload.get("doors"))
	if stove.is_empty() or oven.is_empty() or door < 0 or typeof(payload.get("faucet_on")) != TYPE_BOOL:
		return {}
	var button_values := {}
	for ingredient: String in ["coffee", "milk", "ice"]:
		if typeof(buttons.get(ingredient)) != TYPE_BOOL:
			return {}
		button_values[ingredient] = bool(buttons[ingredient])
	return {
		"stove_level": stove,
		"oven_level": oven,
		"oven_open": door == 1,
		"faucet_open": bool(payload.faucet_on),
		"buttons": button_values,
	}


func _level(value: Variant) -> String:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return ""
	var index := int(value)
	if float(value) != float(index) or index < 0 or index >= LEVELS.size():
		return ""
	return LEVELS[index]


func _door_value(value: Variant) -> int:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return -1
	return 0 if float(value) == 0.0 else 1


func _stove_vessel() -> String:
	if _stove_vessel_uid.is_empty() or not _present.stove.has(_stove_vessel_uid):
		return ""
	return str(_present.stove[_stove_vessel_uid].card)
