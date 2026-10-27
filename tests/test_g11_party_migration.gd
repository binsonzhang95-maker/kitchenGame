extends SceneTree
const Model = preload("res://multi_model.gd")
const FloorLayout = preload("res://floor_layout.gd")
const Support = preload("res://tests/multi_test_support.gd")
var failures := 0

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("G11_MIGRATION_FAIL " + message)

func _reject_atomic(model, snapshot: Dictionary, message: String) -> void:
	var before: Dictionary = model.to_dict()
	_check(not model.restore(snapshot), message)
	_check(Support.same(model.to_dict(), before), message + " is atomic")

func _initialize() -> void:
	var source = Model.new()
	source.open_for_arrivals = false
	var leader := source.spawn_party(2, ["cat", "dog"])
	var snapshot: Dictionary = source.to_dict()
	var restored = Model.new(2496.0)
	_check(restored.restore(snapshot), "V6 party snapshot restores across width")
	_check(restored.party_members(leader).size() == 2, "companions survive restore")
	var bad: Dictionary = snapshot.duplicate(true)
	bad.customers["1"].companions[0].species = "otter"
	_reject_atomic(restored, bad, "unshipped companion species is rejected")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].seat_index = 2
	_reject_atomic(restored, bad, "duplicate/invalid seat index is rejected")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].party_id = 2
	_reject_atomic(restored, bad, "foreign companion party is rejected")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].table_id = 1
	_reject_atomic(restored, bad, "companion table binding mismatch is rejected")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].id = 7
	_reject_atomic(restored, bad, "companion cannot inject leader id")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].paid = true
	_reject_atomic(restored, bad, "companion cannot inject paid business field")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].state = "walking"
	_reject_atomic(restored, bad, "companion cannot inject state field")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].departed = true
	_reject_atomic(restored, bad, "queued companion cannot forge departure")
	bad = snapshot.duplicate(true)
	bad.customers["1"].companions[0].path = [[-500.0, -500.0]]
	_reject_atomic(restored, bad, "illegal companion path is rejected")
	bad = snapshot.duplicate(true)
	bad.layout_revision = int(round(float(bad.layout_width) * 100.0))
	_reject_atomic(restored, bad, "V6 cannot downgrade to legacy geometry revision")
	var legacy_header: Dictionary = _as_v5(snapshot)
	legacy_header.layout_revision = FloorLayout.revision_for_width(float(legacy_header.layout_width))
	_reject_atomic(restored, legacy_header, "V5 cannot claim the current revision")

	var departing = Model.new()
	departing.open_for_arrivals = false
	departing.auto_dispatch = false
	departing.auto_cook = false
	var departing_party := departing.spawn_party(2, ["cat", "dog"])
	_check(departing.assign_next(1) and Support.until(departing, func() -> bool: return departing.customers[departing_party].state == "seated", 20.0), "departure fixture seats a party")
	departing._begin_leave(departing.customers[departing_party], true)
	bad = departing.to_dict()
	bad.customers["1"].transition_elapsed = -1.0
	_reject_atomic(restored, bad, "negative leader stand transition is rejected")
	print("G11_PARTY_MIGRATION_RESULT failures=%d" % failures)
	quit(0 if failures == 0 else 1)


func _as_v5(snapshot: Dictionary) -> Dictionary:
	var legacy: Dictionary = snapshot.duplicate(true)
	legacy.version = 5
	for guest: Dictionary in legacy.customers.values():
		for key: String in ["party_id", "party_size", "seat_index", "companions", "arrival", "stand_elapsed", "transition", "transition_elapsed", "departed"]:
			guest.erase(key)
	return legacy
