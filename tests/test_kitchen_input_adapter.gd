extends SceneTree

const CookingSession = preload("res://cooking_session.gd")
const KitchenInputAdapterScript = preload("res://kitchen_input_adapter.gd")

var failures: int = 0
var checks: int = 0


func _init() -> void:
	_test_complete_p0_recipes()
	_test_rejection_and_feedback()
	_test_stove_vessel_refusals()
	_test_vessel_cards()
	_test_epochs_pause_and_reconnect()
	_test_snapshot_and_reselect_edges()
	_test_holds()
	if failures == 0:
		print("PASS: KitchenInputAdapter tests (%d checks)" % checks)
	else:
		push_error("FAILED: %d of %d KitchenInputAdapter checks" % [failures, checks])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("ASSERT: " + label)


func _session(recipe: String) -> RefCounted:
	var session = CookingSession.new()
	_expect(session.setup({"table_id": 1, "guest_id": 1, "generation": 1}, recipe), "setup " + recipe)
	return session


func _connected(token: String = "run") -> RefCounted:
	var adapter = KitchenInputAdapterScript.new()
	adapter.bind(token)
	adapter.connect_simulator()
	var aligned: Dictionary = adapter.handle(_event(adapter, "panel_snapshot", _snapshot()), {})
	_expect(aligned.feedback == "aligned" and aligned.action.is_empty(), "first complete snapshot aligns without action")
	return adapter


func _snapshot(overrides: Dictionary = {}) -> Dictionary:
	var value: Dictionary = {"stove_level": "off", "oven_level": "off", "oven_open": false, "vessel": "", "faucet_open": false}
	for key: Variant in overrides:
		value[key] = overrides[key]
	return value


func _event(adapter: RefCounted, event_type: String, fields: Dictionary = {}) -> Dictionary:
	var value: Dictionary = adapter.event_envelope()
	value["type"] = event_type
	for key: Variant in fields:
		value[key] = fields[key]
	return value


func _submit(session: RefCounted, result: Dictionary, label: String) -> void:
	_expect(not str(result.action).is_empty(), label + " produces a candidate")
	if not str(result.action).is_empty():
		_expect(session.act(str(result.action)), label + " caller submits candidate")


func _tick_under_main_rules(session: RefCounted, adapter: RefCounted, delta: float, label: String) -> void:
	var before: float = float(session.status().elapsed)
	var status: Dictionary = session.status()
	if not bool(status.paused) and adapter.hold_reason(status).is_empty():
		session.tick(delta)
		_expect(session.status().elapsed > before, label + " advances while Main permits ticking")
	else:
		_expect(is_equal_approx(session.status().elapsed, before), label + " does not tick while Main holds or pauses")


func _card(adapter: RefCounted, session: RefCounted, ingredient: String) -> void:
	_submit(session, adapter.handle(_event(adapter, "card", {"category": ingredient, "zone": "cutting_board"}), session.status()), "card " + ingredient)


func _test_complete_p0_recipes() -> void:
	# Soup: physical candidates, then the final screen action owned by the caller.
	var soup = _session("soup")
	var soup_adapter = _connected("soup-token")
	_card(soup_adapter, soup, "potato")
	_card(soup_adapter, soup, "carrot")
	_submit(soup, soup_adapter.handle(_event(soup_adapter, "faucet", {"open": true}), soup.status()), "soup water")
	_submit(soup, soup_adapter.handle(_event(soup_adapter, "cut"), soup.status()), "soup cut")
	_submit(soup, soup_adapter.handle(_event(soup_adapter, "vessel", {"kind": "pot", "present": true}), soup.status()), "soup pot")
	_submit(soup, soup_adapter.handle(_event(soup_adapter, "stove", {"level": "medium"}), soup.status()), "soup heat")
	_tick_under_main_rules(soup, soup_adapter, soup.cook_duration(), "legacy soup")
	_expect(soup.status().phase == "ready", "soup reaches ready")
	_expect(soup.act("finish"), "soup final screen action")
	_expect(soup.status().completed, "soup completed")

	var stir = _session("stir_fry")
	var stir_adapter = _connected("stir-token")
	_card(stir_adapter, stir, "egg")
	_card(stir_adapter, stir, "tomato")
	_submit(stir, stir_adapter.handle(_event(stir_adapter, "cut"), stir.status()), "stir cut")
	_submit(stir, stir_adapter.handle(_event(stir_adapter, "vessel", {"kind": "pan", "present": true}), stir.status()), "stir pan")
	_submit(stir, stir_adapter.handle(_event(stir_adapter, "stove", {"level": "high"}), stir.status()), "stir heat")
	_tick_under_main_rules(stir, stir_adapter, stir.cook_duration(), "legacy stir fry")
	_expect(stir.act("stir"), "stir final screen action")
	_expect(stir.status().completed, "stir completed")

	var bake = _session("bake")
	var bake_adapter = _connected("bake-token")
	_card(bake_adapter, bake, "bread")
	_card(bake_adapter, bake, "cheese")
	_expect(bake.act("oven"), "bake oven remains a screen action")
	_tick_under_main_rules(bake, bake_adapter, bake.cook_duration(), "bake with oven off")
	bake_adapter.handle(_event(bake_adapter, "oven_level", {"level": "medium"}), bake.status())
	_expect(bake_adapter.hold_reason(bake.status()).is_empty(), "bake aligns a closed, active oven before ticking")
	_tick_under_main_rules(bake, bake_adapter, bake.cook_duration(), "bake with active oven")
	_expect(bake.act("takeout"), "bake final screen action")
	_expect(bake.status().completed, "bake completed")
	_expect(bake_adapter.state().connection == "connected", "bake adapter did not need an oven action")

	var drink = _session("drink")
	var drink_adapter = _connected("drink-token")
	_submit(drink, drink_adapter.handle(_event(drink_adapter, "drink_button", {"ingredient": "coffee"}), drink.status()), "coffee")
	_submit(drink, drink_adapter.handle(_event(drink_adapter, "drink_button", {"ingredient": "milk"}), drink.status()), "milk")
	_submit(drink, drink_adapter.handle(_event(drink_adapter, "drink_button", {"ingredient": "ice"}), drink.status()), "ice")
	_expect(drink.act("stir"), "drink final screen action")
	_expect(drink.status().completed, "drink completed")

	# The current P0 menu keeps the legacy recipes above compatible, while its
	# two new dishes must traverse their own complete device-to-screen paths.
	var pumpkin_soup = _session("pumpkin_corn_soup")
	var pumpkin_adapter = _connected("pumpkin-token")
	_card(pumpkin_adapter, pumpkin_soup, "pumpkin")
	_card(pumpkin_adapter, pumpkin_soup, "corn")
	_submit(pumpkin_soup, pumpkin_adapter.handle(_event(pumpkin_adapter, "faucet", {"open": true}), pumpkin_soup.status()), "pumpkin soup water")
	_submit(pumpkin_soup, pumpkin_adapter.handle(_event(pumpkin_adapter, "cut"), pumpkin_soup.status()), "pumpkin soup cut")
	_submit(pumpkin_soup, pumpkin_adapter.handle(_event(pumpkin_adapter, "vessel", {"kind": "pot", "present": true}), pumpkin_soup.status()), "pumpkin soup pot")
	_submit(pumpkin_soup, pumpkin_adapter.handle(_event(pumpkin_adapter, "stove", {"level": "medium"}), pumpkin_soup.status()), "pumpkin soup heat")
	_tick_under_main_rules(pumpkin_soup, pumpkin_adapter, pumpkin_soup.cook_duration(), "pumpkin soup")
	_expect(pumpkin_soup.status().phase == "ready", "pumpkin soup reaches ready")
	_expect(pumpkin_soup.act("finish") and pumpkin_soup.status().completed, "pumpkin soup final screen finish")

	var mushrooms = _session("pan_fried_mushrooms")
	var mushroom_adapter = _connected("mushroom-token")
	_card(mushroom_adapter, mushrooms, "mushroom")
	_submit(mushrooms, mushroom_adapter.handle(_event(mushroom_adapter, "vessel", {"kind": "pan", "present": true}), mushrooms.status()), "mushrooms pan")
	_submit(mushrooms, mushroom_adapter.handle(_event(mushroom_adapter, "stove", {"level": "high"}), mushrooms.status()), "mushrooms heat")
	_tick_under_main_rules(mushrooms, mushroom_adapter, mushrooms.cook_duration(), "mushrooms")
	_expect(mushrooms.status().phase == "ready", "mushrooms reach ready")
	_expect(mushrooms.act("flip") and mushrooms.status().completed, "mushrooms final screen flip")


func _test_rejection_and_feedback() -> void:
	var session = _session("soup")
	var adapter = _connected("reject-token")
	var before: Dictionary = session.to_dict()
	_expect(adapter.handle(_event(adapter, "card", {"category": "potato", "zone": "stove"}), session.status()).feedback == "wrong_zone", "wrong card zone")
	_expect(adapter.handle(_event(adapter, "card", {"category": "alien", "zone": "cutting_board"}), session.status()).feedback == "unknown_card", "unknown card")
	_expect(adapter.handle(_event(adapter, "read_failed"), session.status()).feedback == "read_failed", "reader failure")
	_expect(adapter.handle(_event(adapter, "card", {"category": "onion", "zone": "cutting_board"}), session.status()).feedback == "not_needed", "recognized planned card is not needed")
	_expect(adapter.handle(_event(adapter, "card", {"category": "egg", "zone": "cutting_board"}), session.status()).feedback == "not_needed", "known but unused food is not needed")
	var malformed: Dictionary = adapter.event_envelope()
	malformed["type"] = "card"
	_expect(adapter.handle(malformed, session.status()).feedback == "invalid_event", "bad event schema")
	var float_seq: Dictionary = _event(adapter, "cut")
	float_seq["seq"] = 1.0
	_expect(adapter.handle(float_seq, session.status()).feedback == "invalid_event", "float sequence rejected")
	_expect(session.to_dict() == before, "feedback and malformed input never mutate session")

	_card(adapter, session, "potato")
	_expect(adapter.handle(_event(adapter, "card", {"category": "potato", "zone": "cutting_board"}), session.status()).feedback == "already_added", "duplicate ingredient")
	var duplicate: Dictionary = _event(adapter, "card", {"category": "carrot", "zone": "cutting_board"})
	var first: Dictionary = adapter.handle(duplicate, session.status())
	_expect(first.action == "add_carrot", "first sequence accepted")
	_expect(adapter.handle(duplicate, session.status()).feedback == "duplicate", "same sequence rejected")
	var old_token: Dictionary = _event(adapter, "cut")
	old_token["token"] = "other"
	_expect(adapter.handle(old_token, session.status()).feedback == "stale", "old token rejected")
	var old_epoch: Dictionary = _event(adapter, "cut")
	old_epoch["preparation_epoch"] = 99
	_expect(adapter.handle(old_epoch, session.status()).feedback == "stale", "wrong preparation epoch rejected")
	var old_connection: Dictionary = _event(adapter, "cut")
	old_connection["connection_epoch"] = 99
	_expect(adapter.handle(old_connection, session.status()).feedback == "stale", "wrong connection epoch rejected")


func _test_stove_vessel_refusals() -> void:
	# These are real Session instances: a rejected physical stove event must not
	# submit heat or start cooking, even though timer holds only apply after cooking.
	var missing = _session("pan_fried_mushrooms")
	var missing_adapter = _connected("missing-vessel")
	_card(missing_adapter, missing, "mushroom")
	_expect(missing.act("pan"), "session reaches heat phase with its expected pan")
	var missing_result: Dictionary = missing_adapter.handle(_event(missing_adapter, "stove", {"level": "high"}), missing.status())
	_expect(missing_result.feedback == "vessel_missing" and missing_result.action.is_empty(), "missing vessel refuses heat before timer hold")
	_expect(missing.status().phase == "heat" and missing.status().attempts == 0, "missing vessel does not begin cooking or increase attempts")
	_expect(missing_adapter.hold_reason(missing.status()).is_empty(), "pre-cooking hold does not replace missing-vessel refusal")

	var wrong = _session("pan_fried_mushrooms")
	var wrong_adapter = _connected("wrong-vessel")
	_card(wrong_adapter, wrong, "mushroom")
	_expect(wrong.act("pan"), "wrong-vessel session reaches heat phase")
	_expect(wrong_adapter.handle(_event(wrong_adapter, "vessel", {"kind": "pot", "present": true}), wrong.status()).feedback == "not_needed", "wrong vessel only updates panel")
	var wrong_result: Dictionary = wrong_adapter.handle(_event(wrong_adapter, "stove", {"level": "high"}), wrong.status())
	_expect(wrong_result.feedback == "wrong_vessel" and wrong_result.action.is_empty(), "wrong vessel refuses heat before timer hold")
	_expect(wrong.status().phase == "heat" and wrong.status().attempts == 0, "wrong vessel does not begin cooking or increase attempts")


func _test_vessel_cards() -> void:
	var soup = _session("soup")
	var adapter = _connected("vessel-cards")
	_expect(adapter.handle(_event(adapter, "card", {"category": "pot", "zone": "cutting_board"}), soup.status()).feedback == "wrong_zone", "pot card wrong zone is recognized")
	_expect(adapter.handle(_event(adapter, "card", {"category": "pan", "zone": "counter"}), soup.status()).feedback == "wrong_zone", "pan card wrong zone is never unknown")
	_expect(adapter.handle(_event(adapter, "card", {"category": "potato", "zone": "stove"}), soup.status()).feedback == "wrong_zone", "ordinary food remains cutting-board only")
	_card(adapter, soup, "potato")
	_card(adapter, soup, "carrot")
	_submit(soup, adapter.handle(_event(adapter, "faucet", {"open": true}), soup.status()), "vessel-card water")
	_submit(soup, adapter.handle(_event(adapter, "cut"), soup.status()), "vessel-card cut")
	var pot_card: Dictionary = adapter.handle(_event(adapter, "card", {"category": "pot", "zone": "stove"}), soup.status())
	_expect(pot_card.action == "pot" and pot_card.feedback == "action_candidate", "stove pot card follows vessel candidate path")
	_submit(soup, pot_card, "stove pot card")
	_expect(adapter.handle(_event(adapter, "card", {"category": "pot", "zone": "stove"}), soup.status()).feedback == "duplicate", "duplicate pot card is deduplicated")
	_expect(adapter.handle(_event(adapter, "card", {"category": "pan", "zone": "stove"}), soup.status()).feedback == "not_needed", "other vessel card follows normal present path")

	var already_added = _session("pan_fried_mushrooms")
	var already_adapter = _connected("vessel-card-already-added")
	_card(already_adapter, already_added, "mushroom")
	_expect(already_added.act("pan"), "session can already contain pan before its card is seen")
	_expect(already_adapter.handle(_event(already_adapter, "card", {"category": "pan", "zone": "stove"}), already_added.status()).feedback == "already_added", "first pan card preserves vessel already-added semantics")
	_expect(already_adapter.handle(_event(already_adapter, "card", {"category": "pan", "zone": "stove"}), already_added.status()).feedback == "duplicate", "already-added pan card sets the same duplicate latch")


func _test_epochs_pause_and_reconnect() -> void:
	var rebind_adapter = KitchenInputAdapterScript.new()
	rebind_adapter.bind("same-token")
	rebind_adapter.connect_simulator()
	_expect(rebind_adapter.handle(_event(rebind_adapter, "panel_snapshot", _snapshot()), {}).feedback == "aligned", "first same-token bind aligns")
	var queued_old: Dictionary = _event(rebind_adapter, "card", {"category": "potato", "zone": "cutting_board"})
	queued_old["seq"] = 900
	var first_authority: Dictionary = rebind_adapter.state()
	rebind_adapter.bind("same-token")
	var rebound_authority: Dictionary = rebind_adapter.state()
	_expect(int(rebound_authority.preparation_epoch) > int(first_authority.preparation_epoch) and int(rebound_authority.connection_epoch) > int(first_authority.connection_epoch), "same-token rebind strictly advances authority epochs")
	rebind_adapter.connect_simulator()
	_expect(rebind_adapter.handle(_event(rebind_adapter, "panel_snapshot", _snapshot()), {}).feedback == "aligned", "same-token rebind reconnects and aligns")
	_expect(rebind_adapter.handle(queued_old, {}).feedback == "stale", "same-token rebind rejects old higher-sequence event")

	var session = _session("soup")
	var adapter = _connected("epoch-token")
	var queued: Dictionary = _event(adapter, "card", {"category": "potato", "zone": "cutting_board"})
	_expect(session.act("clear"), "caller can clear")
	adapter.reset_preparation()
	_expect(adapter.handle(queued, session.status()).feedback == "stale", "clear invalidates same-token queued event")

	_card(adapter, session, "potato")
	_card(adapter, session, "carrot")
	_submit(session, adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()), "water before pause")
	_submit(session, adapter.handle(_event(adapter, "cut"), session.status()), "cut before pause")
	_submit(session, adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()), "pot before pause")
	session.set_paused(true)
	var paused_heat: Dictionary = adapter.handle(_event(adapter, "stove", {"level": "medium"}), session.status())
	_expect(paused_heat.feedback == "paused" and paused_heat.action.is_empty(), "manual pause updates panel but emits no heat")
	session.set_paused(false)
	_expect(adapter.handle(_event(adapter, "stove", {"level": "medium"}), session.status()).action.is_empty(), "unpause does not replay stove event")
	_expect(adapter.handle(_event(adapter, "stove", {"level": "off"}), session.status()).action.is_empty(), "off only updates panel")
	_submit(session, adapter.handle(_event(adapter, "stove", {"level": "medium"}), session.status()), "new heat after pause")

	var progress: float = session.status().elapsed
	adapter.disconnect_simulator()
	_expect(adapter.hold_reason(session.status()) == "simulator_disconnected", "disconnect holds timer")
	_tick_under_main_rules(session, adapter, session.cook_duration(), "disconnect")
	_expect(is_equal_approx(session.status().elapsed, progress), "adapter disconnect preserves session progress")
	session.set_paused(true)
	adapter.use_screen()
	_expect(adapter.hold_reason(session.status()).is_empty(), "screen mode clears external hold")
	_expect(session.status().paused, "screen switch does not clear manual pause")
	_tick_under_main_rules(session, adapter, session.cook_duration(), "manual pause after screen switch")

	session.set_paused(false)
	adapter.connect_simulator()
	var before: Dictionary = session.to_dict()
	var reconnect: Dictionary = adapter.handle(_event(adapter, "panel_snapshot", _snapshot({"stove_level": "medium", "vessel": "pot"})), session.status())
	_expect(reconnect.feedback == "aligned" and reconnect.action.is_empty(), "reconnect snapshot only aligns")
	_expect(session.to_dict() == before, "reconnect snapshot cannot add, heat, or complete")
	_tick_under_main_rules(session, adapter, session.cook_duration(), "reconnected matching panel")
	adapter.disconnect_simulator()
	adapter.connect_simulator()
	var panel_before: Dictionary = adapter.state().panel
	var incomplete: Dictionary = _event(adapter, "panel_snapshot", {"stove_level": "high", "oven_level": "off", "oven_open": false, "vessel": ""})
	_expect(adapter.handle(incomplete, session.status()).feedback == "invalid_snapshot", "incomplete snapshot rejected")
	_expect(adapter.state().panel == panel_before and adapter.state().connection == "aligning", "bad snapshot is atomic")


func _test_snapshot_and_reselect_edges() -> void:
	# An input observed while paused is still a held physical state. A following
	# snapshot must preserve that baseline until a real release and reassertion.
	var session = _session("soup")
	var adapter = _connected("edge-token")
	_card(adapter, session, "potato")
	_card(adapter, session, "carrot")
	session.set_paused(true)
	_expect(adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()).feedback == "paused", "paused faucet stores panel state without candidate")
	_expect(adapter.handle(_event(adapter, "panel_snapshot", _snapshot({"faucet_open": true})), session.status()).feedback == "panel_aligned", "same-state faucet snapshot aligns")
	session.set_paused(false)
	_expect(adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()).feedback == "duplicate", "resumed held faucet is not a new water action")
	_expect(adapter.handle(_event(adapter, "faucet", {"open": false}), session.status()).feedback == "panel_updated", "faucet close resets edge")
	_submit(session, adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()), "faucet re-open after snapshot")
	_submit(session, adapter.handle(_event(adapter, "cut"), session.status()), "edge regression cut")

	session.set_paused(true)
	_expect(adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()).feedback == "paused", "paused vessel stores panel state without candidate")
	_expect(adapter.handle(_event(adapter, "panel_snapshot", _snapshot({"faucet_open": true, "vessel": "pot"})), session.status()).feedback == "panel_aligned", "same-state vessel snapshot aligns")
	session.set_paused(false)
	_expect(adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()).feedback == "duplicate", "resumed held vessel is not a new pot action")
	_expect(adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": false}), session.status()).feedback == "panel_updated", "vessel removal resets edge")
	_submit(session, adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()), "vessel replace after snapshot")

	_expect(session.act("clear"), "edge regression can reselect recipe")
	adapter.reset_preparation()
	_expect(adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()).feedback == "duplicate", "reselect keeps held faucet as baseline")
	_expect(adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()).feedback == "duplicate", "reselect keeps held vessel as baseline")
	_expect(adapter.handle(_event(adapter, "faucet", {"open": false}), session.status()).feedback == "panel_updated", "reselect faucet can release")
	_submit(session, adapter.handle(_event(adapter, "faucet", {"open": true}), session.status()), "first actual faucet edge after reselect")
	_card(adapter, session, "potato")
	_card(adapter, session, "carrot")
	_submit(session, adapter.handle(_event(adapter, "cut"), session.status()), "reselect cut")
	_expect(adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": false}), session.status()).feedback == "panel_updated", "reselect vessel can remove")
	_submit(session, adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), session.status()), "first actual vessel edge after reselect")


func _test_holds() -> void:
	var soup = _session("soup")
	var adapter = _connected("hold-soup")
	_card(adapter, soup, "potato")
	_card(adapter, soup, "carrot")
	_submit(soup, adapter.handle(_event(adapter, "faucet", {"open": true}), soup.status()), "hold water")
	_submit(soup, adapter.handle(_event(adapter, "cut"), soup.status()), "hold cut")
	_submit(soup, adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), soup.status()), "hold pot")
	_submit(soup, adapter.handle(_event(adapter, "stove", {"level": "medium"}), soup.status()), "hold heat")
	_expect(adapter.hold_reason(soup.status()).is_empty(), "matching stove panel runs")
	adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": false}), soup.status())
	_expect(adapter.hold_reason(soup.status()) == "vessel_missing", "removed pot holds")
	adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": true}), soup.status())
	_expect(adapter.hold_reason(soup.status()).is_empty(), "putting matching pot back resumes")
	adapter.handle(_event(adapter, "stove", {"level": "off"}), soup.status())
	_expect(adapter.hold_reason(soup.status()) == "stove_off", "stove off holds")
	adapter.handle(_event(adapter, "stove", {"level": "high"}), soup.status())
	_expect(adapter.hold_reason(soup.status()) == "stove_level_mismatch:medium", "wrong stove level holds with target")
	adapter.handle(_event(adapter, "stove", {"level": "medium"}), soup.status())
	_expect(adapter.hold_reason(soup.status()).is_empty(), "target stove level resumes")
	_tick_under_main_rules(soup, adapter, soup.cook_duration(), "held-panel soup after restoration")
	adapter.handle(_event(adapter, "stove", {"level": "off"}), soup.status())
	adapter.handle(_event(adapter, "vessel", {"kind": "pot", "present": false}), soup.status())
	_expect(adapter.hold_reason(soup.status()).is_empty() and soup.act("finish"), "ready does not lock final screen action")

	var bake = _session("bake")
	var bake_adapter = _connected("hold-bake")
	_card(bake_adapter, bake, "bread")
	_card(bake_adapter, bake, "cheese")
	_expect(bake.act("oven"), "begin bake by screen action")
	_expect(bake_adapter.hold_reason(bake.status()) == "oven_off", "oven off holds bake")
	bake_adapter.handle(_event(bake_adapter, "oven_level", {"level": "small"}), bake.status())
	_expect(bake_adapter.hold_reason(bake.status()).is_empty(), "any non-off oven level runs bake")
	bake_adapter.handle(_event(bake_adapter, "oven_door", {"open": true}), bake.status())
	_expect(bake_adapter.hold_reason(bake.status()) == "oven_door_open", "open oven door holds bake")
	bake_adapter.handle(_event(bake_adapter, "oven_door", {"open": false}), bake.status())
	_expect(bake_adapter.hold_reason(bake.status()).is_empty(), "closing oven door resumes bake")
