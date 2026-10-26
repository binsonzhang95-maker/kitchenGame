extends SceneTree

const DeviceEventMapperScript = preload("res://device_event_mapper.gd")
const DeviceCardMapScript = preload("res://device_card_map.gd")

var failures := 0
var checks := 0


func _init() -> void:
	_test_snapshot_first()
	_test_panel_changes()
	_test_card_on_cutting_board()
	_test_vessel_debounce()
	_test_vessel_replacement()
	_test_flicker_does_not_reemit()
	_test_unknown_uid_once()
	_test_linked_false_resnapshots()
	_test_door_state()
	_test_card_map_matches_fixture()
	if failures == 0:
		print("PASS: DeviceEventMapper tests (%d checks)" % checks)
	else:
		push_error("FAILED: %d of %d DeviceEventMapper checks" % [failures, checks])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("ASSERT: " + label)


func _panel(overrides: Dictionary = {}) -> Dictionary:
	var value := {
		"event_type": "io.panel",
		"linked": true,
		"knobs": {"stove": 0, "oven": 0},
		"faucet_on": false,
		"button_states": {"coffee": false, "milk": false, "ice": false},
		"doors": 0,
	}
	for key: Variant in overrides:
		value[key] = overrides[key]
	return value


func _scan(zone_uids: Dictionary = {}) -> Dictionary:
	var routes: Array[Dictionary] = []
	for antenna: String in ["U16", "U17", "U19", "U20"]:
		var zone: String = DeviceEventMapperScript.ANTENNA_ZONES[antenna]
		var tags: Array[Dictionary] = []
		for uid: String in zone_uids.get(zone, []):
			tags.append({"uid": uid})
		routes.append({"antenna": antenna, "tags": tags})
	return {"event_type": "nfc.scan", "routes": routes}


func _test_snapshot_first() -> void:
	var mapper = DeviceEventMapperScript.new()
	var events: Array = mapper.map(_panel({
		"knobs": {"stove": 2, "oven": 3},
		"faucet_on": true,
		"doors": 1,
	}))
	_expect(events.size() == 1 and events[0] == {
		"type": "panel_snapshot",
		"stove_level": "medium",
		"oven_level": "high",
		"oven_open": true,
		"vessel": "",
		"faucet_open": true,
	}, "first linked panel is a complete snapshot")
	_expect(mapper.map(_panel({"knobs": {"stove": 2, "oven": 3}, "faucet_on": true, "doors": 1})).is_empty(), "unchanged panel emits nothing")


func _test_panel_changes() -> void:
	var mapper = DeviceEventMapperScript.new()
	mapper.map(_panel())
	_expect(mapper.map(_panel({"knobs": {"stove": 1, "oven": 0}})) == [{"type": "stove", "level": "small"}], "stove knob change maps to stove event")
	_expect(mapper.map(_panel({"knobs": {"stove": 1, "oven": 0}, "faucet_on": true})) == [{"type": "faucet", "open": true}], "faucet opening edge")
	_expect(mapper.map(_panel({"knobs": {"stove": 1, "oven": 0}, "faucet_on": true})).is_empty(), "held faucet does not repeat")
	_expect(mapper.map(_panel({"knobs": {"stove": 1, "oven": 0}})) == [{"type": "faucet", "open": false}], "faucet closing edge")

	var coffee_on := _panel({"knobs": {"stove": 1, "oven": 0}, "button_states": {"coffee": true, "milk": false, "ice": false}})
	_expect(mapper.map(coffee_on) == [{"type": "drink_button", "ingredient": "coffee"}], "drink button rising edge")
	_expect(mapper.map(coffee_on).is_empty(), "held drink button does not repeat")
	_expect(mapper.map(_panel({"knobs": {"stove": 1, "oven": 0}})).is_empty(), "drink button release emits nothing")
	_expect(mapper.map(coffee_on) == [{"type": "drink_button", "ingredient": "coffee"}], "drink button can rise again")


func _test_card_on_cutting_board() -> void:
	var mapper = DeviceEventMapperScript.new()
	var events: Array = mapper.map(_scan({"cutting_board": ["5A:65:7F:05:25:41:89"]}))
	_expect(events == [{"type": "card", "category": "pumpkin", "zone": "cutting_board"}], "known card maps to cutting board")
	_expect(mapper.map(_scan({"cutting_board": ["5A:65:7F:05:25:41:89"]})).is_empty(), "present card emits once")


func _test_vessel_debounce() -> void:
	var mapper = DeviceEventMapperScript.new()
	var pot := "5A:35:8E:05:25:41:89"
	mapper.map(_scan({"stove": [pot]}))
	var snapshot: Array = mapper.map(_panel())
	_expect(snapshot.size() == 1 and snapshot[0].vessel == "pot", "snapshot takes vessel from stove NFC presence")
	_expect(mapper.map(_scan()).is_empty(), "pot remains after first missed scan")
	_expect(mapper.map(_scan()).is_empty(), "pot remains after second missed scan")
	_expect(mapper.map(_scan()) == [{"type": "vessel", "kind": "pot", "present": false}], "pot is removed after third missed scan")


func _test_vessel_replacement() -> void:
	var mapper = DeviceEventMapperScript.new()
	var pot := "5A:35:8E:05:25:41:89"
	var pan := "5A:35:4F:05:25:41:89"
	mapper.map(_scan({"stove": [pot]}))
	_expect(mapper.map(_scan({"stove": [pan]})) == [
		{"type": "vessel", "kind": "pot", "present": false},
		{"type": "vessel", "kind": "pan", "present": true},
	], "replacing cookware emits one effective vessel transition")
	_expect(mapper.map(_scan({"stove": [pan]})).is_empty(), "replacement remains stable on second old-vessel miss")
	_expect(mapper.map(_scan({"stove": [pan]})).is_empty(), "debounced old-vessel removal cannot clear replacement")
	_expect(mapper.map(_panel())[0].vessel == "pan", "snapshot reports the effective replacement")


func _test_flicker_does_not_reemit() -> void:
	var mapper = DeviceEventMapperScript.new()
	var pan := "5A:35:4F:05:25:41:89"
	_expect(mapper.map(_scan({"stove": [pan]})) == [{"type": "vessel", "kind": "pan", "present": true}], "pan first presence")
	mapper.map(_scan())
	_expect(mapper.map(_scan({"stove": [pan]})).is_empty(), "one missed scan does not re-emit")
	mapper.map(_scan())
	mapper.map(_scan())
	_expect(mapper.map(_scan({"stove": [pan]})).is_empty(), "two missed scans do not re-emit")


func _test_unknown_uid_once() -> void:
	var mapper = DeviceEventMapperScript.new()
	var unknown := "AA:BB:CC:DD:EE:FF:00"
	_expect(mapper.map(_scan({"cutting_board": [unknown]})) == [{"type": "read_failed"}], "unknown UID becomes read_failed")
	_expect(mapper.map(_scan({"cutting_board": [unknown]})).is_empty(), "unknown UID reports once per presence")


func _test_linked_false_resnapshots() -> void:
	var mapper = DeviceEventMapperScript.new()
	mapper.map(_panel())
	_expect(mapper.map(_panel({"linked": false})).is_empty(), "unlinked panel emits nothing")
	var events: Array = mapper.map(_panel({"knobs": {"stove": 3, "oven": 1}}))
	_expect(events.size() == 1 and events[0].type == "panel_snapshot" and events[0].stove_level == "high" and events[0].oven_level == "small", "first linked frame after offline re-snapshots")


func _test_door_state() -> void:
	var mapper = DeviceEventMapperScript.new()
	_expect(mapper.map({"event_type": "door.state", "doors": 1}) == [{"type": "oven_door", "open": true}], "door.state open maps to oven door")
	_expect(mapper.map({"event_type": "door.state", "doors": 0}) == [{"type": "oven_door", "open": false}], "door.state closed maps to oven door")


func _test_card_map_matches_fixture() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/nfc_tag_map.json"))
	_expect(parsed is Dictionary and parsed.get("tags") is Dictionary, "card-map fixture parses")
	if not parsed is Dictionary or not parsed.get("tags") is Dictionary:
		return
	var fixture: Dictionary = {}
	for uid: String in parsed.tags:
		fixture[uid] = str(parsed.tags[uid].name)
	_expect(DeviceCardMapScript.UID_TO_NAME == fixture, "generated UID table exactly matches fixture")
	for name: String in fixture.values():
		_expect(DeviceCardMapScript.NAME_TO_CARD_ID.has(name), "Chinese card name has game id: " + name)
