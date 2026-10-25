extends SceneTree
## Headless checks for the isolated kitchen animation player. No gameplay scene is started.

const CookingAnimation = preload("res://cooking_animation.gd")
const CookingView = preload("res://cooking_view.gd")
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
