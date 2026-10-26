extends SceneTree

const Main = preload("res://multi_main.gd")
const CookingSession = preload("res://cooking_session.gd")
const KitchenInputAdapter = preload("res://kitchen_input_adapter.gd")
const DeviceBridge = preload("res://device_bridge.gd")

class ReplayHost:
	extends RefCounted
	var input_adapter = KitchenInputAdapter.new()
	var cooking_session = CookingSession.new()
	var submitted := 0
	var accepted := 0

	func receive_toy_event(event: Dictionary) -> Dictionary:
		var result: Dictionary = input_adapter.handle(event, cooking_session.status())
		var action := str(result.get("action", ""))
		if action.is_empty():
			return {"committed": false, "action": "", "feedback": str(result.get("feedback", ""))}
		submitted += 1
		var committed := cooking_session.act(action)
		if committed:
			accepted += 1
			if action in ["clear", "retry"]:
				input_adapter.reset_preparation()
		return {"committed": committed, "action": action, "feedback": "committed" if committed else "commit_rejected"}

var checks := 0
var failures := 0
var app: Variant
var save_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_recorded_replay()
	_test_bridge_batch_limit()
	await _test_main_device_lifecycle()
	_finish()


func _test_recorded_replay() -> void:
	var host := ReplayHost.new()
	_expect(host.cooking_session.setup({"table_id": 1, "guest_id": 1, "generation": 1}, "pumpkin_corn_soup"), "real CookingSession setup")
	host.input_adapter.bind("device-replay")
	var bridge := DeviceBridge.new()
	bridge.app = host
	_expect(bridge.set_link("lan"), "bridge accepts LAN link")

	var payloads: Array = []
	for line: String in FileAccess.get_file_as_string("res://tests/fixtures/lab_2c2e_session.jsonl").split("\n", false):
		var row: Variant = JSON.parse_string(line)
		_expect(row is Dictionary and row.get("payload") is Dictionary, "fixture row parses")
		if row is Dictionary and row.get("payload") is Dictionary:
			payloads.append(row.payload)

	var records: Array[Dictionary] = []
	for offset: int in range(0, payloads.size(), DeviceBridge.MAX_PAYLOADS_PER_PUSH):
		records.append_array(bridge.push_payloads(payloads.slice(offset, mini(offset + DeviceBridge.MAX_PAYLOADS_PER_PUSH, payloads.size()))))
	var types: Dictionary = {}
	var saw_snapshot := false
	var saw_pot := false
	for record: Dictionary in records:
		var event: Dictionary = record.event
		var event_type := str(event.get("type", ""))
		types[event_type] = int(types.get(event_type, 0)) + 1
		saw_snapshot = saw_snapshot or event_type == "panel_snapshot"
		saw_pot = saw_pot or (event_type == "vessel" and str(event.get("kind", "")) == "pot" and bool(event.get("present", false)))

	_expect(bridge.last_error.is_empty(), "bounded replay batches complete without bridge errors")
	_expect(saw_snapshot, "replay emits at least one panel snapshot")
	_expect(saw_pot, "replay sees UID 5A:35:8E:05:25:41:89 as stove pot")
	_expect(host.submitted > 0, "replay submits action candidates")
	_expect(host.accepted == host.submitted, "every submitted action is accepted by CookingSession")

	var summary: Array[String] = []
	var sorted_types: Array = types.keys()
	sorted_types.sort()
	for event_type: String in sorted_types:
		summary.append("%s=%d" % [event_type, int(types[event_type])])
	print("DEVICE_REPLAY_SUMMARY " + " ".join(summary))
	bridge.free()


func _test_bridge_batch_limit() -> void:
	var host := ReplayHost.new()
	_expect(host.cooking_session.setup({"table_id": 1, "guest_id": 1, "generation": 1}, "pumpkin_corn_soup"), "batch-limit session setup")
	host.input_adapter.bind("batch-limit")
	var bridge := DeviceBridge.new()
	bridge.app = host
	bridge.set_link("lan")
	var oversized: Array = []
	for index: int in DeviceBridge.MAX_PAYLOADS_PER_PUSH + 1:
		oversized.append({"event_type": "door.state", "doors": index % 2})
	_expect(bridge.push_payloads(oversized).is_empty() and bridge.last_error.contains("at most"), "oversized batch is rejected before synchronous processing")
	_expect(host.input_adapter.state().last_seq == 0, "rejected batch has no partial adapter effects")
	var panel := {"event_type":"io.panel", "linked":true, "knobs":{"stove":0, "oven":0}, "faucet_on":false, "button_states":{"coffee":false, "milk":false, "ice":false}, "doors":0}
	_expect(bridge.push_payloads([panel], false).is_empty(), "discarding caller does not retain result records")
	_expect(bridge.last_error.is_empty() and host.input_adapter.state().connection == "connected", "valid bounded push still aligns adapter")
	bridge.free()


func _test_main_device_lifecycle() -> void:
	save_path = "user://device_replay_%d_%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	app = Main.new()
	app.save_path = save_path
	app.seed_guests = false
	app.force_device_mode = true
	root.add_child(app)
	await process_frame
	app.model.open_for_arrivals = false
	app.model.auto_seat = false
	app.model.auto_dispatch = false
	_expect(app.device_mode and is_instance_valid(app.device_bridge), "real Main starts in device mode")
	_expect(app.device_bridge.set_link("lan"), "real Main bridge selects LAN")
	var table_id := await _open_main_order("pumpkin_corn_soup")
	if table_id == 0:
		return
	_expect(app.input_adapter.state().source == "simulator" and app.input_adapter.state().connection == "aligning", "entering device kitchen waits for alignment")
	var aligned: Array[Dictionary] = app.device_bridge.push_payloads([_panel()])
	_expect(aligned.size() == 1 and aligned[0].result.feedback == "aligned", "real Main adapter accepts panel alignment")
	_expect(app.input_adapter.state().connection == "connected", "alignment grants device authority")

	var pot := "5A:35:8E:05:25:41:89"
	var pan := "5A:35:4F:05:25:41:89"
	app.device_bridge.push_payloads([_scan([pot])])
	var replacement: Array[Dictionary] = app.device_bridge.push_payloads([_scan([pan])])
	_expect(replacement.size() == 2 and replacement[0].result.feedback == "panel_updated", "replacement removal is accepted before replacement presence")
	_expect(app.input_adapter.state().panel.vessel == "pan", "real Main adapter ends replacement scan with pan present")
	var old_removal: Array[Dictionary] = app.device_bridge.push_payloads([_scan([pan]), _scan([pan])])
	_expect(old_removal.is_empty() and app.input_adapter.state().panel.vessel == "pan", "debounced pot removal cannot clear the replacement pan")

	_expect(app.device_bridge.set_link("offline"), "real Main bridge selects offline")
	_expect(app._cancel_cooking(), "real Main cancels device kitchen")
	_expect(app._begin_cooking(table_id), "real Main re-enters cancelled order")
	var offline_state: Dictionary = app.input_adapter.state()
	_expect(offline_state.source == "simulator" and offline_state.connection == "disconnected", "offline re-entry keeps disconnected device authority")
	_expect(app._cooking_hold_reason() == "simulator_disconnected", "offline re-entry keeps the cooking hold")
	var elapsed: float = app.cooking_session.elapsed
	await create_timer(0.12, true, false, true).timeout
	_expect(is_equal_approx(app.cooking_session.elapsed, elapsed), "offline real Main lifecycle cannot advance cooking")


func _open_main_order(recipe: String) -> int:
	app.model.set_order_menu([recipe])
	var table_id := 0
	for table: Dictionary in app.model.tables:
		if table.phase == "free":
			table_id = int(table.id)
			break
	_expect(table_id > 0 and app.model.spawn_customer() > 0 and app.model.assign_next(table_id), "seed real Main order")
	if table_id == 0:
		return 0
	var deadline := Time.get_ticks_msec() + 3000
	while app.model.table_action(table_id) != "order" and Time.get_ticks_msec() < deadline:
		app.model.tick(0.1)
		await process_frame
	_expect(app.model.table_action(table_id) == "order" and app.model.act(table_id, "order"), "real Main order reaches kitchen queue")
	_expect(app._begin_cooking(table_id), "real Main opens kitchen")
	return table_id


func _panel() -> Dictionary:
	return {"event_type":"io.panel", "linked":true, "knobs":{"stove":0, "oven":0}, "faucet_on":false, "button_states":{"coffee":false, "milk":false, "ice":false}, "doors":0}


func _scan(stove_uids: Array) -> Dictionary:
	var routes: Array[Dictionary] = []
	for antenna: String in ["U16", "U17", "U19", "U20"]:
		var tags: Array[Dictionary] = []
		if antenna == "U16":
			for uid: String in stove_uids:
				tags.append({"uid": uid})
		routes.append({"antenna": antenna, "tags": tags})
	return {"event_type":"nfc.scan", "routes":routes}


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("DEVICE_REPLAY_FAIL " + label)


func _finish() -> void:
	if is_instance_valid(app):
		app.free()
	for suffix: String in ["", ".tmp", ".audio.json", ".audio.json.tmp"]:
		if FileAccess.file_exists(save_path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path + suffix))
	print("DEVICE_REPLAY_TEST_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
