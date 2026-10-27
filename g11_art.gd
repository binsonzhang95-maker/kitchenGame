class_name G11Art
extends RefCounted

## Normalises the delivered side-animation manifests without changing their
## source metadata.  Renderers use this helper for timing and pivots only.
const SIDE_SPECIES := ["cat", "dog", "panda", "capybara", "hamster"]
const SIDE_ROOT := "res://assets/side/"
static var _side_cache: Dictionary = {}
static var _front_cache: Dictionary = {}


static func has_side_species(species: String) -> bool:
	return species in SIDE_SPECIES


static func side_manifest(species: String) -> Dictionary:
	if not has_side_species(species):
		return {}
	if _side_cache.has(species):
		return _side_cache[species]
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIDE_ROOT + species + "/g11_animation.json"))
	var manifest: Dictionary = raw if raw is Dictionary else {}
	_side_cache[species] = manifest
	return manifest


static func side_action(species: String, action_name: String) -> Dictionary:
	var manifest := side_manifest(species)
	var actions: Dictionary = manifest.get("actions", {})
	return actions.get(action_name, {})


static func front_action(species: String, action_name: String) -> Dictionary:
	if not has_side_species(species):
		return {}
	if not _front_cache.has(species):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/actions/%s/animation.json" % species))
		_front_cache[species] = raw if raw is Dictionary else {}
	var manifest: Dictionary = _front_cache[species]
	var actions: Dictionary = manifest.get("actions", {})
	return actions.get(action_name, {})


static func frame_index(elapsed: float, action: Dictionary) -> int:
	var durations: Array = action.get("duration_ms", [])
	if durations.is_empty():
		return 0
	var total := 0.0
	for duration: Variant in durations:
		total += float(duration) / 1000.0
	if total <= 0.0:
		return 0
	var moment := maxf(0.0, elapsed)
	if bool(action.get("loop", false)):
		moment = fmod(moment, total)
	else:
		moment = minf(moment, maxf(0.0, total - 0.0001))
	for index: int in range(durations.size()):
		moment -= float(durations[index]) / 1000.0
		if moment < 0.0:
			return index
	return durations.size() - 1


static func frame_pivot(manifest: Dictionary, action: Dictionary, index: int) -> Vector2:
	# `frames` is the frame count, never a frame array.  The source-of-truth
	# pivot lives on each `frame_rects` entry; the old per-frame list is only a
	# compatibility fallback for a later delivery which omits that field.
	var frames: Array = action.get("frame_rects", [])
	if index >= 0 and index < frames.size() and frames[index] is Dictionary:
		var pivot: Array = frames[index].get("pivot", [])
		if pivot.size() == 2:
			return Vector2(float(pivot[0]), float(pivot[1]))
	var pivots: Array = action.get("per_frame_pivot", manifest.get("per_frame_pivot", []))
	if index >= 0 and index < pivots.size() and pivots[index] is Array and pivots[index].size() == 2:
		return Vector2(float(pivots[index][0]), float(pivots[index][1]))
	var value: Array = action.get("pivot", manifest.get("pivot", [64, 110]))
	return Vector2(float(value[0]), float(value[1])) if value.size() == 2 else Vector2(64, 110)


static func action_for_table(phase: String, elapsed: float, chatting: bool) -> String:
	# One-shot arrival has priority over conversation and begins at elapsed zero.
	# It is deliberately not member-staggered: a party reaches physical seats as
	# a group and must not show its final seated pose before its first frame.
	if phase == "ordering" and elapsed < 0.92:
		return "sit_down"
	if phase == "eating":
		return "chat" if chatting else "eat"
	if phase == "drinking" and elapsed < 1.16:
		return "drink"
	if phase == "checkout" and elapsed < 0.88:
		return "happy"
	if chatting and phase in ["ordering", "awaiting_cook", "cooking", "food_ready", "serving_food", "waiting_drink", "eating"]:
		return "chat"
	return "seated_idle"
