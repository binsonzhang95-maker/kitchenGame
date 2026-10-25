extends SceneTree
## Headless checks for the isolated kitchen animation player. No gameplay scene is started.

const CookingAnimation = preload("res://cooking_animation.gd")
const CookingView = preload("res://cooking_view.gd")
const Assets = preload("res://p0_assets.gd")
var assertions: int = 0
var failures: int = 0

class FailingCookingView extends CookingView:
	var load_attempts: int = 0
	var permit_load: bool = false
	func _load_visual_player(clip: String) -> Dictionary:
		load_attempts += 1
		if not permit_load:
			return {"ok":false, "error":"injected unreadable clip: " + clip}
		return super._load_visual_player(clip)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_variable_frame_boundaries()
	_test_large_delta_and_one_shot_completion()
	_test_pause()
	_test_loop_has_no_completion_events()
	_test_replay_and_stop()
	_test_all_resources_are_readable()
	_test_invalid_or_unplayable_clips_are_safe()
	_test_view_caches_failed_visual_loads()
	_test_p0_compositions_are_atomic_and_refreshable()
	_test_p0_layers_follow_actual_vessel_and_neutral_fallbacks()
	await _test_view_transient_feedback_pauses_and_cleans()
	await _test_sync_freezes_live_visuals_and_guides_only_progress()
	print("COOKING_ANIMATION_TEST_RESULT assertions=%d failures=%d" % [assertions, failures])
	quit(0 if failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("COOKING_ANIMATION_ASSERT_FAIL " + label)


func _player(clip: String):
	var player = CookingAnimation.new()
	_expect(player.load_clip(clip), "loads " + clip + ": " + player.last_error)
	return player


func _test_variable_frame_boundaries() -> void:
	var player = _player("chop")
	_expect(player.play_once(), "chop starts once")
	player.advance(0.179)
	_expect(player.current_frame() == 0, "first variable frame holds before 180ms")
	player.advance(0.001)
	_expect(player.current_frame() == 1, "first variable frame changes at 180ms")
	player.advance(0.139)
	_expect(player.current_frame() == 1, "second variable frame holds before 140ms")
	player.advance(0.001)
	_expect(player.current_frame() == 2, "second variable frame changes at 320ms")
	_expect(player.anchor() == Vector2i(128, 242), "whole canvas anchor remains fixed")


func _test_large_delta_and_one_shot_completion() -> void:
	var player = _player("pour_water")
	player.play_once()
	var completed_events: int = 0
	if player.advance(10.0):
		completed_events += 1
	_expect(player.is_complete() and not player.playing, "large delta finishes a one-shot")
	_expect(player.current_frame() == 3, "completed one-shot holds its final frame")
	if player.advance(10.0):
		completed_events += 1
	_expect(completed_events == 1, "one-shot completion reports exactly once")


func _test_pause() -> void:
	var player = _player("chop")
	player.play_once()
	player.advance(0.100)
	player.set_paused(true)
	var frame_before_pause := player.current_frame()
	_expect(not player.advance(5.0), "paused player reports no completion")
	_expect(player.current_frame() == frame_before_pause and not player.is_complete(), "paused player does not advance")
	player.set_paused(false)
	player.advance(0.080)
	_expect(player.current_frame() == 1, "unpaused player resumes the preserved time")


func _test_loop_has_no_completion_events() -> void:
	var player = _player("stir_fry")
	player.play_loop()
	var completion_events: int = 0
	for _round in range(8):
		if player.advance(0.640):
			completion_events += 1
	_expect(player.playing and not player.is_complete(), "loop remains visual after many full cycles")
	_expect(completion_events == 0, "looping visual produces no completion or business event")
	_expect(player.current_frame() == 0, "loop returns to its first frame after whole cycles")


func _test_replay_and_stop() -> void:
	var player = _player("chop")
	player.play_once()
	player.advance(2.0)
	_expect(player.is_complete(), "chop can complete before replay")
	_expect(player.replay() and player.playing and not player.is_complete() and player.current_frame() == 0, "replay resets then restarts")
	player.advance(0.200)
	player.stop()
	_expect(not player.playing and not player.is_complete() and player.current_frame() == 0, "stop resets to first frame without completion")


func _test_all_resources_are_readable() -> void:
	for clip: String in CookingAnimation.CLIP_NAMES:
		var player = _player(clip)
		# Keep this test's failure path diagnostic: a failed load has no metadata
		# or texture and must not turn the test runner itself into an error.
		if player.clip_id.is_empty():
			continue
		var data: Dictionary = player.metadata()
		_expect(int(data.get("frame_count", 0)) == 4 and (data.get("frames", []) as Array).size() == 4 and (data.get("durations_ms", []) as Array).size() == 4, clip + " retains four source frames")
		var texture := player.current_texture()
		_expect(texture is AtlasTexture and texture.get_width() == 256 and texture.get_height() == 256, clip + " exposes a 256px AtlasTexture")


func _test_invalid_or_unplayable_clips_are_safe() -> void:
	var unknown = CookingAnimation.new()
	_expect(not unknown.load_clip("unknown_clip") and not unknown.last_error.is_empty(), "unknown clip fails with an error")
	_expect(unknown.current_texture() == null, "unknown clip has no texture")
	_expect(not unknown.play_once() and not unknown.play_loop() and not unknown.replay(), "unknown clip cannot play")
	var unloaded = CookingAnimation.new()
	_expect(unloaded.current_texture() == null, "unloaded player has null texture")
	_expect(not unloaded.play_once() and not unloaded.advance(1.0), "unloaded player cannot advance")


func _test_view_caches_failed_visual_loads() -> void:
	var view := FailingCookingView.new()
	view.hide()
	root.add_child(view)
	var cooking_state := {"recipe_id":"soup", "phase":"cooking", "elapsed":0.0, "paused":false, "actions":[]}
	view.show()
	view.sync(cooking_state, {"cooking_token":71})
	_expect(view.load_attempts == 1, "failed loop clip is loaded once")
	var failed_status: Dictionary = view.art_status()
	_expect(not bool(failed_status.complete) and str(failed_status.errors.get("动画 stir", "")).contains("injected unreadable"), "failed loop reports its readable diagnostic")
	view.sync(cooking_state, {"cooking_token":71})
	_expect(view.load_attempts == 1, "continuous sync does not reread cached failed loop")
	view.permit_load = true
	view.refresh_art()
	_expect(view.load_attempts == 2 and view.art_status().complete and bool(view.animation_debug_state().playing), "explicit artwork refresh clears failure cache and recovers loop")
	view.hide()
	view.sync(cooking_state, {"cooking_token":71})
	_expect(view.load_attempts == 2 and not bool(view.animation_debug_state().playing), "hidden sync neither reloads nor replays loop")
	view.show()
	_expect(view.load_attempts == 2 and bool(view.animation_debug_state().playing), "show restores the current cached loop")
	view.free()


func _test_p0_compositions_are_atomic_and_refreshable() -> void:
	var view := CookingView.new()
	root.add_child(view)
	view._build()
	view.set_art_paths({"pan_empty":"res://missing_required_pan.png"})
	_expect(not view._p0_recipe_layers("pan_fried_mushrooms", "vessel", ["mushroom"], false, false), "a partial pan composition is rejected")
	var has_visible_layer := false
	for layer: TextureRect in view._art_layers:
		has_visible_layer = has_visible_layer or layer.visible
	_expect(not has_visible_layer and view.art_status().required_missing.has("pan_empty"), "partial P0 failure leaves no floating food and reports required art")
	view.set_art_paths({"background":"res://missing_background.png"})
	_expect(view.background_image.texture != null, "missing optional P0 background falls back safely")
	view.set_art_paths({"background":"res://assets/kitchen/background/kitchen_background_main_1536x1024.png"})
	_expect(view.background_image.texture != null and view.background_image.texture.resource_path.contains("assets/kitchen/background"), "refresh_art replaces the background after a cache clear")
	view.free()


func _visible_paths(view: CookingView) -> Array[String]:
	var paths: Array[String] = []
	for layer: TextureRect in view._art_layers:
		if layer.visible and layer.texture != null:
			paths.append(layer.texture.resource_path)
	return paths


func _test_p0_layers_follow_actual_vessel_and_neutral_fallbacks() -> void:
	var view := CookingView.new()
	root.add_child(view)
	view.show()
	view.sync({"recipe_id":"pumpkin_corn_soup", "phase":"prep", "ingredients":["pumpkin", "corn"], "water_added":true, "cut_done":true, "vessel":"", "actions":[]}, {"cooking_token":91})
	var paths := _visible_paths(view)
	_expect(paths.any(func(path: String) -> bool: return path.contains("pot_water")) and not paths.any(func(path: String) -> bool: return path.contains("pot_pumpkin")), "water is visible in prep but soup filling waits for a real pot")
	_expect(view.preparation_icon.visible and view.preparation_aux_icon.visible and view.preparation_icon.texture.resource_path.contains("pumpkin_chopped") and view.preparation_aux_icon.texture.resource_path.contains("corn_prepared"), "cut P0 soup uses its own small prepared ingredients before pot")
	view.sync({"recipe_id":"pumpkin_corn_soup", "phase":"heat", "ingredients":["pumpkin", "corn"], "water_added":true, "cut_done":true, "vessel":"pot", "actions":[]}, {"cooking_token":91})
	_expect(_visible_paths(view).any(func(path: String) -> bool: return path.contains("pot_pumpkin_corn_raw")), "soup filling appears only after the pot action")
	view.sync({"recipe_id":"pan_fried_mushrooms", "phase":"vessel", "ingredients":["mushroom"], "vessel":"", "actions":[]}, {"cooking_token":91})
	_expect(not _visible_paths(view).any(func(path: String) -> bool: return path.contains("pan_mushroom")) and view.preparation_icon.visible, "mushrooms stay out of pan before real pan action")
	view.sync({"recipe_id":"bake", "phase":"vessel", "ingredients":["bread"], "vessel":"", "actions":[]}, {"cooking_token":91})
	_expect(not _visible_paths(view).any(func(path: String) -> bool: return path.contains("oven_food")), "one bread selection never draws a complete toast")
	view.sync({"recipe_id":"bake", "phase":"vessel", "ingredients":["bread", "cheese"], "vessel":"oven", "actions":[]}, {"cooking_token":91})
	_expect(_visible_paths(view).any(func(path: String) -> bool: return path.contains("oven_food_raw")), "toast enters oven only after both ingredients and oven action")
	var all_missing: Dictionary = {}
	for key: String in Assets.PATHS:
		all_missing[key] = "res://missing_all_p0_%s.png" % key
	view.set_art_paths(all_missing)
	for recipe: String in ["pumpkin_corn_soup", "pan_fried_mushrooms", "bake", "drink"]:
		var vessel: String = {"pumpkin_corn_soup":"pot", "pan_fried_mushrooms":"pan", "bake":"oven", "drink":"cup"}[recipe]
		view.sync({"recipe_id":recipe, "phase":"vessel", "ingredients":[], "vessel":"", "actions":[]}, {"cooking_token":92})
		_expect(_visible_paths(view).is_empty() and view.utensil_image.texture != null and view.utensil_image.texture.resource_path.contains("cooking_art/utensils/" + vessel + ".png"), recipe + " all-P0-missing fallback stays neutral and dish-correct")
	view.free()


func _test_view_transient_feedback_pauses_and_cleans() -> void:
	var view := CookingView.new()
	root.add_child(view)
	view.show()
	var state := {"recipe_id":"pumpkin_corn_soup", "phase":"ingredients", "ingredients":[], "water_added":false, "vessel":"", "paused":false, "actions":["add_water"]}
	view.sync(state, {"cooking_token":101})
	view.play_visual_feedback("add_water", 101)
	await create_timer(0.12, true, false, true).timeout
	await process_frame
	var flow_before_pause := view._water_flow_remaining
	var frame_before_pause := view._water_flow_frame
	for _round in range(3):
		view.sync(state, {"cooking_token":101, "visual_paused":true})
		await process_frame
	_expect(is_equal_approx(view._water_flow_remaining, flow_before_pause) and view._water_flow_frame == frame_before_pause and view.water_flow.visible, "visual hold freezes independent water flow")
	view.sync(state, {"cooking_token":101, "visual_paused":false})
	await create_timer(0.12, true, false, true).timeout
	await process_frame
	_expect(view._water_flow_remaining < flow_before_pause, "water flow resumes continuously after visual hold")
	view.play_visual_feedback("add_water", 101)
	view.sync(state, {"cooking_token":102})
	_expect(is_zero_approx(view._water_flow_remaining) and not view.water_flow.visible and not view.feedback_icon.visible and view.art_stack.position == view.utensil_image.position, "token change clears old short feedback and restores art baseline")
	view.play_visual_feedback("add_water", 102)
	view.clear_visual_feedback()
	_expect(is_zero_approx(view._water_flow_remaining) and not view.water_flow.visible and view.art_stack.position == view.utensil_image.position, "clear cancels flow and every transient transform")
	view.free()


func _sync_hold(view: CookingView, state: Dictionary, token: int, key: String = "visual_paused") -> void:
	for _round in range(4):
		view.sync(state, {"cooking_token":token, key:true})
		await process_frame


func _test_sync_freezes_live_visuals_and_guides_only_progress() -> void:
	var view := CookingView.new()
	root.add_child(view)
	view.show()

	# The feedback tween must reach its natural finished signal, release its
	# RefCounted handle, and tolerate a later regular sync without play()ing a
	# finished Tween.
	var arrival := {"recipe_id":"pumpkin_corn_soup", "phase":"ingredients", "ingredients":[], "water_added":false, "vessel":"", "paused":false, "actions":["add_pumpkin"]}
	view.sync(arrival, {"cooking_token":111})
	view.play_visual_feedback("add_pumpkin", 111)
	await process_frame
	var arrival_position := view.feedback_icon.position
	await _sync_hold(view, arrival, 111)
	_expect(view._feedback_tween != null and view.feedback_icon.position == arrival_position, "repeated paused sync freezes ingredient flight without resetting it")
	view.sync(arrival, {"cooking_token":111})
	await create_timer(0.40, true, false, true).timeout
	await process_frame
	_expect(view._feedback_tween == null and not view.feedback_icon.visible, "naturally finished feedback tween clears its reference")
	view.sync(arrival, {"cooking_token":111})

	# A real drink preview keeps its live spoon angle through continuous Main
	# syncs; only an actual state transition resets that baseline.
	var drink := {"recipe_id":"drink", "phase":"ready", "ingredients":["coffee", "milk", "ice"], "vessel":"cup", "paused":false, "actions":["stir"]}
	view.sync(drink, {"cooking_token":112})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	var spoon_angle := view.preparation_icon.rotation_degrees
	await _sync_hold(view, drink, 112)
	_expect(view.preparation_icon.visible and is_equal_approx(view.preparation_icon.rotation_degrees, spoon_angle), "repeated visual-paused sync preserves spoon angle")
	view.sync(drink, {"cooking_token":112})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	_expect(not is_equal_approx(view.preparation_icon.rotation_degrees, spoon_angle), "spoon resumes from the frozen animation clock")

	# Oven breathing must not white-flash while an external visual hold repeatedly
	# synchronizes the same state.
	var bake := {"recipe_id":"bake", "phase":"cooking", "ingredients":["bread", "cheese"], "vessel":"oven", "paused":false, "actions":["clear", "cancel"]}
	view.sync(bake, {"cooking_token":113})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	var oven_brightness := view.art_stack.modulate
	await _sync_hold(view, bake, 113)
	_expect(view._art_layers[0].visible and view.art_stack.modulate == oven_brightness, "repeated visual-paused sync preserves oven brightness")
	view.sync(bake, {"cooking_token":113})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	_expect(view.art_stack.modulate != oven_brightness, "oven brightness resumes after visual hold")

	# All supplied flame variants are real and distinct.  Paused session syncs
	# retain both their texture and current breathing brightness.
	var previous_flame: Texture2D = null
	for level: String in ["small", "medium", "high"]:
		var heat := {"recipe_id":"soup", "phase":"cooking", "ingredients":["potato", "carrot"], "vessel":"pot", "heat_level":level, "paused":false, "actions":["clear", "cancel"]}
		view.sync(heat, {"cooking_token":114})
		await create_timer(0.08, true, false, true).timeout
		await process_frame
		var flame_name := str({"small":"flame_low", "medium":"flame_medium", "high":"flame_high"}[level])
		_expect(view.heat_icon.visible and view.heat_icon.texture != null and view.heat_icon.texture.resource_path.contains(flame_name) and view.heat_icon.texture != previous_flame, "heat " + level + " uses its own supplied flame texture")
		previous_flame = view.heat_icon.texture
	var live_heat := {"recipe_id":"soup", "phase":"cooking", "ingredients":["potato", "carrot"], "vessel":"pot", "heat_level":"medium", "paused":false, "actions":["clear", "cancel"]}
	view.sync(live_heat, {"cooking_token":114})
	await create_timer(0.11, true, false, true).timeout
	await process_frame
	var paused_heat := live_heat.duplicate(true)
	paused_heat.paused = true
	view.sync(paused_heat, {"cooking_token":114})
	var flame_alpha := view.heat_icon.modulate.a
	await _sync_hold(view, paused_heat, 114)
	_expect(view.heat_icon.visible and is_equal_approx(view.heat_icon.modulate.a, flame_alpha), "paused session sync preserves flame brightness without white flash")
	var heat_off := paused_heat.duplicate(true)
	heat_off.phase = "heat"
	view.sync(heat_off, {"cooking_token":114})
	_expect(not view.heat_icon.visible and view.heat_icon.texture == null, "flame is absent while heat is off")

	var pan := {"recipe_id":"pan_fried_mushrooms", "phase":"cooking", "ingredients":["mushroom"], "vessel":"pan", "heat_level":"medium", "paused":false, "actions":["clear", "cancel"]}
	view.sync(pan, {"cooking_token":115})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	var pan_position := view.art_stack.position
	await _sync_hold(view, pan, 115)
	_expect(view.art_stack.position == pan_position, "repeated visual-paused sync preserves pan bounce position")
	view.sync(pan, {"cooking_token":115})
	await create_timer(0.13, true, false, true).timeout
	await process_frame
	_expect(view.art_stack.position != pan_position, "pan bounce resumes continuously after visual hold")

	# Cooking has only helper actions, so it never points at clear/cancel.  A
	# ready action remains a legitimate advancing target.
	await create_timer(1.55, true, false, true).timeout
	await process_frame
	_expect(not view.guide_icon.visible, "cooking wait never guides clear or cancel")
	var ready := {"recipe_id":"soup", "phase":"ready", "ingredients":["potato", "carrot"], "vessel":"pot", "heat_level":"medium", "paused":false, "actions":["finish", "clear", "cancel"]}
	view.sync(ready, {"cooking_token":115})
	await create_timer(1.55, true, false, true).timeout
	await process_frame
	_expect(view.guide_icon.visible, "ready state guides the advancing finish action")
	view.free()
