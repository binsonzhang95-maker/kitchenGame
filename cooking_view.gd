extends CanvasLayer
## Read-only kitchen view. Main owns the session, restaurant pause and persistence.
## Missing artwork is an explicit development error, never a replacement appliance.
signal action_requested(action: String, payload: Dictionary)
signal cancel_requested
signal pause_requested

const CookingAnimation = preload("res://cooking_animation.gd")
const Localization = preload("res://localization.gd")
const RecipeCatalog = preload("res://recipe_catalog.gd")
const P0Assets = preload("res://p0_assets.gd")

const VIEW_SIZE := Vector2(1536, 1152)
const ART_ROOT := "res://cooking_art/"
const BACKGROUND_PATH := "res://restaurant_art/restaurant_open_background.png"
const INK := Color("594b39")
const PAPER := Color("fff5dc")
const GREEN := Color("708d60")
const EDGE := Color("ac9166")
const INGREDIENT_LABELS := {"potato":"土豆", "carrot":"胡萝卜", "egg":"鸡蛋", "tomato":"番茄", "bread":"面包", "cheese":"芝士", "coffee":"咖啡", "milk":"牛奶", "ice":"冰块", "water":"清水"}
const RECIPE_LABELS := {"soup":"蔬菜汤", "stir_fry":"番茄炒蛋", "bake":"芝士面包", "drink":"冰咖啡"}
const ACTION_LABELS := {"cut":"切一切", "pot":"入锅", "pan":"入锅", "oven":"放进去", "add_water":"加水", "heat_small":"小火", "heat_medium":"中火", "heat_high":"大火", "finish":"盛出来", "stir":"翻一翻", "takeout":"取出来", "retry":"再试试", "clear":"重选", "return":"回餐厅"}
const ACTION_ICONS := {"cut":"knife", "add_water":"water", "stir":"stir", "flip":"flip", "heat_small":"flame_low", "heat_medium":"flame_medium", "heat_high":"flame_high", "finish":"confirm", "takeout":"confirm", "return":"confirm"}
const PHASE_LABELS := {"idle":"小小厨房", "ingredients":"选食材", "prep":"切一切", "vessel":"放进去", "heat":"选火候", "cooking":"慢慢做", "ready":"好香呀", "retry":"再试一次", "completed":"做好啦", "cancelled":"回餐厅"}
const ACTION_COOLDOWN_SECONDS := 0.18
const SIDE_TEXTURE_SIZE := Vector2(384, 1024)
const SIDE_EDGE_SOURCE_WIDTH := 2.0

var root_control: Control
var screen_root: Control
var screen_fill: ColorRect
var side_left_clip: Control
var side_right_clip: Control
var side_left: TextureRect
var side_right: TextureRect
var side_left_outer_edge: TextureRect
var side_right_outer_edge: TextureRect
var header_fill: ColorRect
var footer_fill: ColorRect
var pause_full_shade: ColorRect
var _layout: Dictionary = {}
var cancel_button: Button
var pause_button: Button
var clear_button: Button
var water_button: Button
var water_label: Label
var water_icon: TextureRect
var water_hint: Label
var recipe_label: Label
var binding_label: Label
var prompt_label: Label
var step_label: Label
var message_label: Label
var utensil_image: TextureRect
var background_image: TextureRect
var art_stack: Control
var missing_utensil: Label
var preparation_icon: TextureRect
var preparation_aux_icon: TextureRect
var heat_icon: TextureRect
var guide_icon: TextureRect
var art_error_label: Label
var progress_bar: ProgressBar
var action_bar: Control
var pause_overlay: Control
var pause_title_label: Label
var pause_resume_button: Button
var ingredient_slots: Array[Dictionary] = []
var step_icons: Array[TextureRect] = []
var completion_badge: TextureRect
var water_flow: TextureRect
var feedback_icon: TextureRect
var action_buttons: Dictionary = {}
var _state: Dictionary = {}
var _context: Dictionary = {}
var _actions: Array[String] = []
var _shown_actions: Array[String] = []
var _textures: Dictionary = {}
var _missing_art: Dictionary = {}
var _art_overrides: Dictionary = {}
var _p0_assets := P0Assets.new()
var _art_layers: Array[TextureRect] = []
var _locale_revision := -1
## Per-view visual cache: each of the four clips is resolved once until an
## explicit artwork refresh.  Failed resolutions are cached too, so Main's
## frame-by-frame sync cannot repeatedly read a broken resource.
var _visual_cache: Dictionary = {}
var _built: bool = false
var _visual_player: Variant = null
var _visual_token: int = -1
var _visual_clip: String = ""
var _visual_loop: bool = false
var _action_cooldown: float = 0.0
var _water_flow_remaining := 0.0
var _water_flow_frame := 0
var _spoon_angle := 0.0
var _spoon_elapsed := 0.0
var _visual_elapsed := 0.0
var _idle_elapsed := 0.0
var _feedback_epoch := 0
var _feedback_tween: Tween
var _feedback_paused := false
var _visual_state_key := ""

func _ready() -> void:
	_build()
	visibility_changed.connect(_on_visibility_changed)


func _process(delta: float) -> void:
	var visuals_paused := _visuals_paused()
	_set_feedback_paused(visuals_paused)
	if visuals_paused:
		return
	_visual_elapsed += delta
	if _water_flow_remaining > 0.0:
		_water_flow_remaining = maxf(0.0, _water_flow_remaining - delta)
		_water_flow_frame = int(floor((0.50 - _water_flow_remaining) * 8.0)) % 4
		if water_flow != null:
			water_flow.texture = _t("water_flow_%d" % _water_flow_frame)
			water_flow.visible = _water_flow_remaining > 0.0
			if _water_flow_remaining <= 0.0:
				_refresh()
	if preparation_icon != null and preparation_icon.visible and str(_state.get("recipe_id", "")) == "drink" and str(_state.get("phase", "")) == "ready":
		_spoon_angle = sin(_visual_elapsed * 3.2) * 10.0
		preparation_icon.rotation_degrees = _spoon_angle
	_update_cooking_breathing(delta)
	_update_idle_guide(delta)
	if _action_cooldown > 0.0:
		_action_cooldown = maxf(0.0, _action_cooldown - delta)
		if _action_cooldown <= 0.0:
			_refresh()
	if not visible or _visual_player == null or not _visual_player.playing:
		return
	_visual_player.set_paused(false)
	var completed: bool = _visual_player.advance(delta)
	if completed:
		_stop_visual(true)
	else:
		_apply_visual_texture()

## Safe before or after add_child. Does not tick or modify the supplied session.
func sync(session: Variant, context: Dictionary = {}) -> void:
	_build()
	var incoming_token: int = int(context.get("cooking_token", -1))
	if _visual_token != -1 and incoming_token != _visual_token:
		_clear_transient_visuals(false)
	_visual_token = incoming_token
	_context = context.duplicate(true)
	var next_state: Dictionary = {}
	var next_actions: Array[String] = []
	if session is Dictionary:
		next_state = session.duplicate(true)
		next_actions = _strings(next_state.get("actions", next_state.get("available_actions", [])))
	elif is_instance_valid(session) and session.has_method("status"):
		next_state = session.status().duplicate(true)
		next_actions = _strings(session.available_actions())
	else:
		next_state = {"phase":"idle", "message":"还没有选好要做的菜。"}
	var next_visual_key := _visual_key(next_state)
	if next_visual_key != _visual_state_key:
		_reset_static_visual_baseline()
		_visual_state_key = next_visual_key
	_state = next_state
	_actions = next_actions
	if str(_state.get("phase", "")) in ["idle", "retry", "cancelled"]:
		_clear_transient_visuals(false)
	_set_feedback_paused(_visuals_paused())
	_refresh()
	_reconcile_loop_visual()

func open(session: Variant, context: Dictionary = {}) -> void:
	sync(session, context)
	show()


## Called only after Main accepted, synchronized, and saved a business action.
## This state is intentionally transient and is never written to a session snapshot.
func play_visual_feedback(action: String, token: int) -> void:
	if token != _visual_token:
		return
	_idle_elapsed = 0.0
	if action == "clear":
		_clear_transient_visuals(false)
	_stop_visual(false)
	if _uses_action_cooldown(action):
		_action_cooldown = ACTION_COOLDOWN_SECONDS
	_refresh()
	var recipe: String = str(_state.get("recipe_id", ""))
	if recipe == "soup" and action == "add_water":
		# Classic soup keeps its authored four-frame pour.  The P0 pumpkin soup
		# deliberately has its own faucet/flow treatment below.
		_start_visual("pour_water", false, 0.0)
	elif recipe == "pumpkin_corn_soup" and action == "add_water":
		_water_flow_remaining = 0.50
		_water_flow_frame = 0
		water_icon.texture = _t("tap_open")
	elif recipe == "soup" and action == "cut":
		_start_visual("chop", false, 0.0)
	else:
		_reconcile_loop_visual()
	if action.begins_with("add_") and action != "add_water":
		_play_ingredient_arrival(action.trim_prefix("add_"))
	elif action == "cut" and recipe == "pumpkin_corn_soup":
		_play_knife_tap()
	elif action == "flip" and recipe == "pan_fried_mushrooms":
		_play_pan_flip()


func clear_visual_feedback() -> void:
	_clear_transient_visuals(true)


func _visuals_paused() -> bool:
	return bool(_state.get("paused", false)) or bool(_context.get("visual_paused", false))


func _set_feedback_paused(paused: bool) -> void:
	if _feedback_tween != null and not _feedback_tween.is_valid():
		_feedback_tween = null
	if paused != _feedback_paused and _feedback_tween != null:
		if paused:
			_feedback_tween.pause()
		else:
			_feedback_tween.play()
	_feedback_paused = paused
	if _visual_player != null:
		_visual_player.set_paused(paused)


func _clear_transient_visuals(refresh_static: bool) -> void:
	_feedback_epoch += 1
	_action_cooldown = 0.0
	_water_flow_remaining = 0.0
	_water_flow_frame = 0
	_idle_elapsed = 0.0
	_spoon_elapsed = 0.0
	_visual_elapsed = 0.0
	_spoon_angle = 0.0
	if water_flow != null: water_flow.visible = false
	if feedback_icon != null:
		feedback_icon.visible = false
		feedback_icon.modulate = Color.WHITE
	if guide_icon != null: guide_icon.visible = false
	if preparation_icon != null: preparation_icon.rotation_degrees = 0.0
	if art_stack != null:
		art_stack.position = utensil_image.position if utensil_image != null else Vector2(512, 356)
		art_stack.modulate = Color.WHITE
		art_stack.scale = Vector2.ONE
	_kill_feedback_tween()
	_feedback_paused = false
	_stop_visual(refresh_static)


func _visual_key(state: Dictionary) -> String:
	# Deliberately exclude elapsed/progress and paused.  Main syncs those every
	# frame, and a pause is a freeze rather than a new visual baseline.
	return str([
		state.get("recipe_id", ""), state.get("phase", ""), state.get("ingredients", []),
		state.get("water_added", false), state.get("cut_done", false), state.get("vessel", ""),
		state.get("heat_level", ""), state.get("completed", false),
	])


func _reset_static_visual_baseline() -> void:
	_visual_elapsed = 0.0
	_spoon_elapsed = 0.0
	_spoon_angle = 0.0
	if preparation_icon != null:
		preparation_icon.rotation_degrees = 0.0
	if art_stack != null:
		art_stack.position = utensil_image.position if utensil_image != null else Vector2(512, 356)
		art_stack.modulate = Color.WHITE
		art_stack.scale = Vector2.ONE
	if heat_icon != null:
		heat_icon.scale = Vector2.ONE
		heat_icon.modulate = Color.WHITE
	for image: TextureRect in _art_layers:
		image.modulate = Color.WHITE


func _kill_feedback_tween() -> void:
	if _feedback_tween == null:
		return
	if _feedback_tween.is_valid():
		_feedback_tween.kill()
	_feedback_tween = null


## Narrow inspection surface for the isolated GUI regression; no gameplay reads it.
func animation_debug_state() -> Dictionary:
	var texture: AtlasTexture = _visual_player.current_atlas_texture() if _visual_player != null and _visual_player.playing else null
	return {"clip": _visual_clip, "playing": _visual_player != null and _visual_player.playing, "loop": _visual_loop, "region": texture.region if texture != null else Rect2()}


func _on_visibility_changed() -> void:
	if not visible:
		clear_visual_feedback()
	else:
		# sync() can run while hidden; only restore the latest loop once the
		# kitchen is actually visible again.
		_reconcile_loop_visual()


func _uses_action_cooldown(action: String) -> bool:
	return action not in ["", "clear", "cancel", "pause", "return"]


func _action_is_cooled(action: String) -> bool:
	return _action_cooldown > 0.0 and _uses_action_cooldown(action)


func _reconcile_loop_visual() -> void:
	if not visible:
		return
	var desired: String = ""
	if str(_state.get("phase", "")) == "cooking":
		if str(_state.get("recipe_id", "")) == "soup": desired = "stir"
		elif str(_state.get("recipe_id", "")) == "stir_fry": desired = "stir_fry"
	if desired.is_empty():
		if _visual_loop:
			_stop_visual(true)
		return
	if _visual_player != null and _visual_player.playing and _visual_loop and _visual_clip == desired:
		return
	_start_visual(desired, true, float(_state.get("elapsed", 0.0)))


func _start_visual(clip: String, loops: bool, phase_elapsed: float) -> void:
	if not visible:
		return
	var resolved: Dictionary = _visual_cache.get(clip, {})
	if resolved.is_empty():
		resolved = _load_visual_player(clip)
		_visual_cache[clip] = resolved
	if not bool(resolved.get("ok", false)):
		_missing_art["动画 " + clip] = str(resolved.get("error", "无法读取动画资源"))
		if _built:
			_refresh()
		return
	var player: CookingAnimation = resolved.get("player") as CookingAnimation
	if player == null:
		_missing_art["动画 " + clip] = "动画缓存没有可播放资源"
		if _built:
			_refresh()
		return
	if not (player.play_loop() if loops else player.play_once()):
		_missing_art["动画 " + clip] = "动画资源无法开始播放"
		if _built:
			_refresh()
		return
	if loops and phase_elapsed > 0.0:
		player.advance(phase_elapsed)
	player.set_paused(bool(_state.get("paused", false)))
	_visual_player = player
	_visual_clip = clip
	_visual_loop = loops
	_apply_visual_texture()


## Kept narrow and overridable solely for the isolated visual regression.
func _load_visual_player(clip: String) -> Dictionary:
	var player := CookingAnimation.new()
	if not player.load_clip(clip):
		return {"ok":false, "error":player.last_error}
	return {"ok":true, "player":player}


func _apply_visual_texture() -> void:
	if _visual_player != null and _visual_player.playing:
		# AtlasTexture regions remain exactly 256x256; the existing 512px work area
		# scales the whole canvas with nearest-neighbour sampling.
		utensil_image.texture = _visual_player.current_atlas_texture()


func _stop_visual(refresh_static: bool) -> void:
	if _visual_player != null:
		_visual_player.stop()
	_visual_player = null
	_visual_clip = ""
	_visual_loop = false
	if refresh_static and _built:
		_refresh()


func _update_cooking_breathing(delta: float) -> void:
	var recipe := str(_state.get("recipe_id", ""))
	var phase := str(_state.get("phase", ""))
	if recipe == "pan_fried_mushrooms" and phase == "cooking":
		art_stack.position = utensil_image.position + Vector2(sin(_visual_elapsed * 5.0) * 3.0, absf(sin(_visual_elapsed * 5.0)) * -2.0)
	else:
		art_stack.position = utensil_image.position
	if heat_icon != null:
		var heating := recipe in ["soup", "pumpkin_corn_soup", "stir_fry", "pan_fried_mushrooms"] and phase == "cooking"
		heat_icon.visible = heating and heat_icon.texture != null
		if heating:
			var heat_breath := sin(_visual_elapsed * 4.0)
			heat_icon.scale = Vector2.ONE * (0.92 + heat_breath * 0.08)
			heat_icon.modulate = Color(1.0, 1.0, 1.0, 0.84 + heat_breath * 0.12)
		else:
			heat_icon.scale = Vector2.ONE
			heat_icon.modulate = Color.WHITE
	if _art_layers.size() > 1:
		_art_layers[1].modulate.a = (0.70 + sin(_visual_elapsed * 3.0) * 0.20) if recipe == "bake" and phase == "cooking" else 1.0
	if recipe == "bake" and phase == "cooking":
		art_stack.modulate = Color(1.0, 0.96 + sin(_visual_elapsed * 3.0) * 0.04, 0.82 + sin(_visual_elapsed * 3.0) * 0.10, 1.0)


func _update_idle_guide(delta: float) -> void:
	if guide_icon == null:
		return
	_idle_elapsed += delta
	if _idle_elapsed < 1.5:
		guide_icon.visible = false
		return
	var target: Button = null
	for action: String in _actions:
		if not _is_progress_action(action):
			continue
		target = button_for_action(action)
		if target != null and target.is_visible_in_tree() and not target.disabled:
			break
		target = null
	if target == null:
		guide_icon.visible = false
		return
	guide_icon.texture = _t("finger_touch_%d" % (int(floor(_idle_elapsed * 1.2)) % 2))
	guide_icon.position = root_control.get_global_transform_with_canvas().affine_inverse() * target.global_position + Vector2(target.size.x - 38.0, -22.0)
	guide_icon.visible = guide_icon.texture != null


func _is_progress_action(action: String) -> bool:
	# Clear/cancel/pause/return and retry are recovery/navigation controls, never
	# the ordinary next-step hint.  In cooking, the remaining actions are only
	# those helpers, so the finger must stay hidden while heat is running.
	if action in ["", "clear", "retry", "cancel", "pause", "return"]:
		return false
	return action.begins_with("add_") or action in ["cut", "pot", "pan", "oven", "heat_small", "heat_medium", "heat_high", "finish", "stir", "flip", "takeout"]

## Optional import/path adapter. Keys are ingredient IDs, utensil names or icon names.
func set_art_paths(paths: Dictionary) -> void:
	_art_overrides = paths.duplicate(true)
	_p0_assets.set_overrides(paths)
	refresh_art()

func refresh_art() -> void:
	_stop_visual(false)
	_textures.clear()
	_missing_art.clear()
	_visual_cache.clear()
	_p0_assets.refresh()
	if _built:
		background_image.texture = _p0_assets.texture("background")
		if background_image.texture == null: background_image.texture = _texture(BACKGROUND_PATH)
		background_image.modulate = Color.WHITE
		_refresh()
		_reconcile_loop_visual()

func art_status() -> Dictionary:
	return {"complete":_missing_art.is_empty() and _p0_assets.required_missing().is_empty(), "missing_paths":_missing_art.keys(), "errors":_missing_art.duplicate(), "optional_missing":_p0_assets.optional_missing(), "required_missing":_p0_assets.required_missing()}

func _strings(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item: Variant in value: result.append(str(item))
	return result

func _style(fill: Color, border: Color = EDGE, width: int = 2) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(width)
	box.set_corner_radius_all(6)
	return box

func _panel(parent: Node, at: Vector2, dimensions: Vector2, fill: Color) -> Panel:
	var panel := Panel.new()
	panel.position = at
	panel.size = dimensions
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var skinned := _p0_assets.stylebox("skin_panel", 20)
	panel.add_theme_stylebox_override("panel", skinned if skinned != null else _style(fill))
	parent.add_child(panel)
	return panel

func _label(parent: Node, text: String, at: Vector2, dimensions: Vector2, font_size: int = 24) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.size = dimensions
	label.add_theme_color_override("font_color", INK)
	label.add_theme_font_size_override("font_size", font_size)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, at: Vector2, dimensions: Vector2, callback: Callable, tip: String = "") -> Button:
	var button := Button.new()
	button.position = at
	button.size = dimensions
	button.text = text
	button.tooltip_text = tip
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_color_override("font_disabled_color", Color("9a927b"))
	var normal := _p0_assets.stylebox("skin_button", 20)
	var pressed := _p0_assets.stylebox("skin_button_pressed", 20)
	button.add_theme_stylebox_override("normal", normal if normal != null else _style(PAPER))
	button.add_theme_stylebox_override("hover", _style(Color("fffbea"), GREEN))
	button.add_theme_stylebox_override("pressed", pressed if pressed != null else _style(Color("dce7ca"), GREEN))
	button.add_theme_stylebox_override("disabled", _style(Color("e0d8c0"), Color("baad90")))
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, GREEN, 3))
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _image(parent: Node, at: Vector2, dimensions: Vector2) -> TextureRect:
	var image := TextureRect.new()
	image.position = at
	image.size = dimensions
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(image)
	return image

func _button_icon(button: Button, key: String, size: Vector2 = Vector2(64, 64)) -> TextureRect:
	button.text = ""
	var icon := _image(button, (button.size - size) * 0.5, size)
	icon.texture = _t(key)
	return icon

func _play_ingredient_arrival(ingredient: String) -> void:
	if feedback_icon == null: return
	_kill_feedback_tween()
	var source := Vector2(704, 242)
	for slot: Dictionary in ingredient_slots:
		if str(slot.action) == "add_" + ingredient:
			source = (slot.button as Button).position + Vector2(44, 28)
			break
	feedback_icon.texture = _t(ingredient) if ingredient in ["pumpkin", "corn", "mushroom"] else _texture(_art_path("ingredients", ingredient))
	feedback_icon.position = source
	feedback_icon.modulate = Color.WHITE
	feedback_icon.visible = feedback_icon.texture != null
	_feedback_epoch += 1
	var epoch := _feedback_epoch
	_feedback_tween = create_tween()
	_feedback_tween.finished.connect(_finish_feedback_tween.bind(epoch))
	_feedback_paused = _visuals_paused()
	_feedback_tween.set_parallel(true)
	_feedback_tween.tween_property(feedback_icon, "position", Vector2(704, 520), 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_feedback_tween.tween_property(feedback_icon, "modulate:a", 0.15, 0.25)
	_feedback_tween.chain().tween_callback(_hide_feedback.bind(epoch))
	if _feedback_paused:
		_feedback_tween.pause()

func _play_knife_tap() -> void:
	if feedback_icon == null: return
	_kill_feedback_tween()
	feedback_icon.texture = _texture(_art_path("icons", "knife"))
	feedback_icon.position = Vector2(728, 470)
	feedback_icon.modulate = Color.WHITE
	feedback_icon.visible = feedback_icon.texture != null
	_feedback_epoch += 1
	var epoch := _feedback_epoch
	_feedback_tween = create_tween()
	_feedback_tween.finished.connect(_finish_feedback_tween.bind(epoch))
	_feedback_paused = _visuals_paused()
	_feedback_tween.tween_property(feedback_icon, "position:y", 505.0, 0.12)
	_feedback_tween.tween_property(feedback_icon, "position:y", 470.0, 0.12)
	_feedback_tween.tween_callback(_hide_feedback.bind(epoch))
	if _feedback_paused:
		_feedback_tween.pause()

func _hide_feedback(epoch: int = -1) -> void:
	if epoch == -1 or epoch == _feedback_epoch:
		feedback_icon.visible = false

func _finish_feedback_tween(epoch: int) -> void:
	if epoch == _feedback_epoch:
		_feedback_tween = null
		_feedback_paused = false

func _play_pan_flip() -> void:
	_kill_feedback_tween()
	art_stack.position = utensil_image.position
	_feedback_epoch += 1
	var epoch := _feedback_epoch
	_feedback_tween = create_tween()
	_feedback_tween.finished.connect(_finish_feedback_tween.bind(epoch))
	_feedback_paused = _visuals_paused()
	_feedback_tween.tween_property(art_stack, "position:x", utensil_image.position.x + 18.0, 0.10)
	_feedback_tween.tween_property(art_stack, "position:x", utensil_image.position.x, 0.14)
	if _feedback_paused:
		_feedback_tween.pause()

func _build() -> void:
	if _built: return
	_built = true
	layer = 70
	screen_root = Control.new()
	screen_root.name = "KitchenScreenBackdrop"
	screen_root.size = VIEW_SIZE
	screen_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(screen_root)
	screen_fill = ColorRect.new()
	screen_fill.color = Color("e9cc99")
	screen_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(screen_fill)
	# These are the outer slices of one 384 + 1536 + 384 panorama.  The slice
	# itself stays authored-sized and receives the shared layout scale; its parent
	# clips only the outer part when a side gap is narrower than the slice.
	for spec: Dictionary in [
		{"name":"KitchenExtendLeft", "path":"res://assets/kitchen/background/kitchen_background_extend_left_384x1024.png", "left":true},
		{"name":"KitchenExtendRight", "path":"res://assets/kitchen/background/kitchen_background_extend_right_384x1024.png", "left":false},
	]:
		var clip := Control.new()
		clip.name = str(spec.name) + "Clip"
		clip.clip_contents = true
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		screen_root.add_child(clip)
		var outer_edge := TextureRect.new()
		outer_edge.name = str(spec.name) + "OuterEdge"
		var edge_texture := AtlasTexture.new()
		edge_texture.atlas = load(str(spec.path)) as Texture2D
		edge_texture.region = Rect2(0, 0, SIDE_EDGE_SOURCE_WIDTH, SIDE_TEXTURE_SIZE.y) if bool(spec.left) else Rect2(SIDE_TEXTURE_SIZE.x - SIDE_EDGE_SOURCE_WIDTH, 0, SIDE_EDGE_SOURCE_WIDTH, SIDE_TEXTURE_SIZE.y)
		outer_edge.texture = edge_texture
		outer_edge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		outer_edge.stretch_mode = TextureRect.STRETCH_SCALE
		outer_edge.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		outer_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(outer_edge)
		var image := TextureRect.new()
		image.name = str(spec.name)
		image.texture = load(str(spec.path)) as Texture2D
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP
		image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(image)
		if bool(spec.left):
			side_left_clip = clip
			side_left_outer_edge = outer_edge
			side_left = image
		else:
			side_right_clip = clip
			side_right_outer_edge = outer_edge
			side_right = image
	header_fill = ColorRect.new()
	header_fill.color = Color("eee0bd")
	header_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(header_fill)
	footer_fill = ColorRect.new()
	footer_fill.color = Color("eee0bd")
	footer_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen_root.add_child(footer_fill)
	pause_full_shade = ColorRect.new()
	pause_full_shade.color = Color(0.16, 0.19, 0.13, 0.55)
	pause_full_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pause_full_shade.visible = false
	screen_root.add_child(pause_full_shade)
	root_control = Control.new()
	root_control.size = VIEW_SIZE
	root_control.mouse_filter = Control.MOUSE_FILTER_STOP
	root_control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(root_control)
	background_image = _image(root_control, Vector2(0, 80), Vector2(1536, 1024))
	background_image.texture = _p0_assets.texture("background")
	if background_image.texture == null: background_image.texture = _texture(BACKGROUND_PATH)
	background_image.modulate = Color.WHITE
	_panel(root_control, Vector2.ZERO, Vector2(1536, 84), Color("eee0bd"))
	cancel_button = _button(root_control, "", Vector2(24, 10), Vector2(64, 64), _request_cancel)
	_button_icon(cancel_button, "back", Vector2(48, 48))
	recipe_label = _label(root_control, "小小厨房", Vector2(176, 14), Vector2(1000, 56), 30)
	clear_button = _button(root_control, "", Vector2(1300, 10), Vector2(64, 64), _emit_action.bind("clear"))
	_button_icon(clear_button, "reselect", Vector2(48, 48))
	pause_button = _button(root_control, "", Vector2(1428, 10), Vector2(64, 64), _request_pause)
	_button_icon(pause_button, "pause", Vector2(48, 48))
	binding_label = _label(root_control, "", Vector2(96, 18), Vector2(180, 48), 20)
	binding_label.add_theme_color_override("font_color", INK)
	prompt_label = _label(root_control, "", Vector2(336, 98), Vector2(864, 40), 20)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.add_theme_color_override("font_color", INK)
	prompt_label.visible = false
	step_label = _label(root_control, "", Vector2(1268, 100), Vector2(236, 40), 22)
	step_label.visible = false
	for index in range(4):
		var step_icon := _image(root_control, Vector2(640 + index * 72, 94), Vector2(56, 56))
		step_icons.append(step_icon)
	for index in range(3):
		var button := _button(root_control, "", Vector2(492 + index * 184, 154), Vector2(168, 176), _request_slot.bind(index))
		var icon := _image(button, Vector2(20, 20), Vector2(128, 128))
		var ring := _image(button, Vector2(12, 12), Vector2(144, 144))
		ring.texture = _t("selected_ring")
		ring.visible = false
		var mark := _image(button, Vector2(112, 8), Vector2(44, 44))
		mark.texture = _t("recognition_success")
		mark.visible = false
		ingredient_slots.append({"button":button, "image":icon, "ring":ring, "mark":mark, "action":""})
	# The panel is a work surface. The appliance itself is always supplied artwork.
	_panel(root_control, Vector2(160, 350), Vector2(1216, 558), Color("e9cc99"))
	utensil_image = _image(root_control, Vector2(512, 356), Vector2(512, 512))
	art_stack = Control.new()
	art_stack.position = utensil_image.position
	art_stack.size = utensil_image.size
	art_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.add_child(art_stack)
	for layer_index in range(6):
		var art := _image(art_stack, Vector2.ZERO, art_stack.size)
		art.visible = false
		_art_layers.append(art)
	preparation_icon = _image(root_control, Vector2(832, 464), Vector2(160, 160))
	preparation_icon.visible = false
	preparation_aux_icon = _image(root_control, Vector2(1010, 482), Vector2(128, 128))
	preparation_aux_icon.visible = false
	heat_icon = _image(root_control, Vector2(710, 788), Vector2(64, 64))
	heat_icon.visible = false
	# Water is independent of the three ingredient slots, beside the cookware.
	water_button = _button(root_control, "", Vector2(1104, 532), Vector2(144, 148), _emit_action.bind("add_water"), "加清水，不占食材位")
	water_icon = _image(water_button, Vector2(24, 4), Vector2(96, 96))
	water_label = _label(water_button, "", Vector2.ZERO, Vector2.ZERO, 1)
	water_label.visible = false
	water_hint = _label(root_control, "", Vector2.ZERO, Vector2.ZERO, 1)
	water_hint.visible = false
	# The flow's top midpoint is aligned to the tap artwork's source (113, 52).
	water_flow = _image(root_control, Vector2(1185, 584), Vector2(64, 128))
	water_flow.visible = false
	feedback_icon = _image(root_control, Vector2.ZERO, Vector2(96, 96))
	feedback_icon.visible = false
	guide_icon = _image(root_control, Vector2.ZERO, Vector2(48, 48))
	guide_icon.visible = false
	missing_utensil = _label(root_control, "", Vector2(440, 508), Vector2(656, 192), 26)
	missing_utensil.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	missing_utensil.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	missing_utensil.add_theme_color_override("font_color", Color("92523b"))
	art_error_label = _label(root_control, "", Vector2(184, 858), Vector2(1168, 36), 18)
	art_error_label.visible = false
	progress_bar = ProgressBar.new()
	progress_bar.position = Vector2(544, 924)
	progress_bar.show_percentage = false
	progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var progress_track := _p0_assets.stylebox("skin_progress_track", 16, 4)
	var progress_fill := _p0_assets.stylebox("skin_progress_fill", 8, 2)
	progress_bar.add_theme_stylebox_override("background", progress_track if progress_track != null else _style(Color("c2ad82"), Color.TRANSPARENT, 0))
	progress_bar.add_theme_stylebox_override("fill", progress_fill if progress_fill != null else _style(GREEN, Color.TRANSPARENT, 0))
	root_control.add_child(progress_bar)
	progress_bar.size = Vector2(448, 32)
	message_label = _label(root_control, "", Vector2(168, 940), Vector2(1200, 46), 20)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.add_theme_color_override("font_color", INK)
	_panel(root_control, Vector2(0, 996), Vector2(1536, 156), Color("eee0bd"))
	action_bar = Control.new()
	action_bar.position = Vector2(0, 1008)
	action_bar.size = Vector2(1536, 128)
	action_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.add_child(action_bar)
	pause_overlay = Control.new()
	pause_overlay.position = Vector2(0, 84)
	pause_overlay.size = Vector2(1536, 1068)
	pause_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_overlay.visible = false
	root_control.add_child(pause_overlay)
	var shade := ColorRect.new()
	shade.size = pause_overlay.size
	shade.color = Color(0.16, 0.19, 0.13, 0.55)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pause_overlay.add_child(shade)
	var note := _panel(pause_overlay, Vector2(544, 380), Vector2(448, 204), PAPER)
	pause_title_label = _label(note, "", Vector2.ZERO, Vector2.ZERO, 1)
	pause_title_label.visible = false
	pause_resume_button = _button(note, "", Vector2(160, 48), Vector2(128, 128), _request_pause)
	_button_icon(pause_resume_button, "play", Vector2(96, 96))
	completion_badge = _image(root_control, Vector2(712, 842), Vector2(112, 112))
	completion_badge.texture = _t("completion")
	completion_badge.visible = false
	if not _layout.is_empty(): apply_layout(_layout)

func apply_layout(layout: Dictionary) -> void:
	_layout = layout.duplicate(true)
	if screen_root == null or root_control == null: return
	var viewport: Vector2 = layout.get("viewport", VIEW_SIZE)
	var content: Rect2 = layout.get("content_rect", Rect2(Vector2.ZERO, VIEW_SIZE))
	var scale: float = float(layout.get("scale", 1.0))
	screen_root.size = viewport
	root_control.position = content.position
	root_control.scale = Vector2.ONE * scale
	var room_top := content.position.y + 80.0 * scale
	var room_height := SIDE_TEXTURE_SIZE.y * scale
	_layout_side_extensions(viewport, content, room_top, room_height, scale)
	header_fill.position = Vector2.ZERO
	header_fill.size = Vector2(viewport.x, content.position.y + 84.0 * scale)
	footer_fill.position = Vector2(0, content.end.y - 156.0 * scale)
	footer_fill.size = Vector2(viewport.x, viewport.y - footer_fill.position.y)
	pause_full_shade.position = Vector2.ZERO
	pause_full_shade.size = viewport


func _layout_side_extensions(viewport: Vector2, content: Rect2, room_top: float, room_height: float, scale: float) -> void:
	var strip_width := SIDE_TEXTURE_SIZE.x * scale
	var left_gap := maxf(0.0, content.position.x)
	var right_gap := maxf(0.0, viewport.x - content.end.x)
	if side_left_clip != null:
		side_left_clip.position = Vector2(0, room_top)
		side_left_clip.size = Vector2(left_gap, room_height)
	if side_left != null:
		side_left.size = SIDE_TEXTURE_SIZE
		side_left.scale = Vector2.ONE * scale
		# Anchor the panorama's source right edge to the central background.
		side_left.position = Vector2(left_gap - strip_width, 0)
	if side_left_outer_edge != null:
		var left_extra := maxf(0.0, left_gap - strip_width)
		side_left_outer_edge.position = Vector2.ZERO
		side_left_outer_edge.size = Vector2(left_extra, room_height)
	if side_right_clip != null:
		side_right_clip.position = Vector2(content.end.x, room_top)
		side_right_clip.size = Vector2(right_gap, room_height)
	if side_right != null:
		side_right.size = SIDE_TEXTURE_SIZE
		side_right.scale = Vector2.ONE * scale
		# Anchor the panorama's source left edge to the central background.
		side_right.position = Vector2.ZERO
	if side_right_outer_edge != null:
		var right_extra := maxf(0.0, right_gap - strip_width)
		side_right_outer_edge.position = Vector2(strip_width, 0)
		side_right_outer_edge.size = Vector2(right_extra, room_height)

func _art_path(kind: String, key: String) -> String:
	return str(_art_overrides.get(key, ART_ROOT + kind + "/" + key + ".png"))

func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		var texture: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
		_textures[path] = texture
		if texture == null: _missing_art[path] = true
	return _textures[path] as Texture2D

func _t(key: String) -> Texture2D:
	return _p0_assets.texture(key, true)

func _clear_p0_layers() -> void:
	for image: TextureRect in _art_layers:
		image.texture = null
		image.visible = false

func _set_p0_layers(keys: Array[String]) -> bool:
	_clear_p0_layers()
	# A partial stack is never valid: showing food without its vessel is more
	# misleading than a neutral empty utensil. Resolve the complete composition
	# before changing any visible layer.
	if keys.is_empty() or keys.size() > _art_layers.size():
		return false
	var textures: Array[Texture2D] = []
	for key: String in keys:
		var texture := _p0_assets.texture(key, false)
		if texture == null:
			return false
		textures.append(texture)
	for index in range(mini(keys.size(), _art_layers.size())):
		_art_layers[index].texture = textures[index]
		_art_layers[index].visible = true
	return true

func _p0_recipe_layers(recipe: String, phase: String, selected: Array[String], cut_done: bool, water_added: bool) -> bool:
	# All supplied overlays share their 256 transparent canvas and pivot. Keep
	# each TextureRect aligned; order here is back-to-front, never baked into PNGs.
	match recipe:
		"pumpkin_corn_soup":
			var filling := "pot_pumpkin_cooked" if phase in ["ready", "completed"] else "pot_pumpkin_raw"
			var pot_keys: Array[String] = ["pot_empty"]
			if water_added: pot_keys.append("pot_water")
			# Water is visible as soon as it has been added, but food never appears
			# in the pot until the session has actually accepted the pot action.
			if str(_state.get("vessel", "")) == "pot": pot_keys.append(filling)
			return _set_p0_layers(pot_keys)
		"pan_fried_mushrooms":
			var mushrooms := "pan_mushroom_cooked" if phase in ["ready", "completed"] else "pan_mushroom_raw"
			var pan_keys: Array[String] = ["pan_empty"]
			if str(_state.get("vessel", "")) == "pan": pan_keys.append(mushrooms)
			return _set_p0_layers(pan_keys)
		"bake":
			var in_oven := str(_state.get("vessel", "")) == "oven"
			var toast_ready := selected.has("bread") and selected.has("cheese") and in_oven
			if phase == "cooking" and in_oven: return _set_p0_layers(["oven_closed"])
			if not toast_ready: return _set_p0_layers(["oven_interior", "oven_shell"])
			var food := "oven_cooked" if phase in ["ready", "completed"] else "oven_raw"
			# Open oven composition is strictly interior → glow → food → shell.
			return _set_p0_layers(["oven_interior", "oven_glow", food, "oven_shell"])
		"drink":
			var keys: Array[String] = []
			if selected.has("milk"): keys.append("cup_coffee_milk")
			elif selected.has("coffee"): keys.append("cup_coffee")
			if selected.has("ice"): keys.append("cup_ice")
			keys.append("cup_empty") # cup rim is the foreground layer.
			return _set_p0_layers(keys)
	_clear_p0_layers()
	return false


func _neutral_vessel_texture(vessel: String) -> Texture2D:
	var key: String = str({"pot":"pot_empty", "pan":"pan_empty", "oven":"oven_open_empty", "cup":"cup_empty"}.get(vessel, "pot_empty"))
	var supplied := _t(key)
	if supplied != null:
		return supplied
	# The existing cooking-art appliance is the deliberately neutral final
	# fallback when every P0 layer (including its empty vessel) is unavailable.
	return _texture(ART_ROOT + "utensils/" + vessel + ".png")


func _preview_texture(recipe: String, ingredient: String, cut_done: bool) -> Texture2D:
	if recipe == "pumpkin_corn_soup":
		if cut_done and ingredient == "pumpkin": return _t("pumpkin_chopped")
		if cut_done and ingredient == "corn": return _t("corn_prepared")
		return _t(ingredient)
	if recipe == "pan_fried_mushrooms":
		return _t(ingredient)
	return _texture(_art_path("ingredients", ingredient))


func _refresh_preparation_previews(recipe: String, phase: String, selected: Array[String]) -> void:
	preparation_icon.visible = false
	preparation_aux_icon.visible = false
	if recipe == "stir_fry" and phase == "prep":
		preparation_icon.texture = _texture(_art_path("icons", "knife"))
		preparation_icon.visible = preparation_icon.texture != null
		return
	if recipe == "drink" and phase == "ready":
		preparation_icon.texture = _t("drink_spoon")
		preparation_icon.visible = preparation_icon.texture != null
		return
	var actual_vessel := str(_state.get("vessel", ""))
	var preview: Array[String] = []
	if recipe == "pumpkin_corn_soup" and actual_vessel != "pot": preview = selected
	elif recipe == "pan_fried_mushrooms" and actual_vessel != "pan": preview = selected
	elif recipe == "bake" and actual_vessel != "oven": preview = selected
	if preview.is_empty():
		return
	preparation_icon.texture = _preview_texture(recipe, preview[0], bool(_state.get("cut_done", false)))
	preparation_icon.visible = preparation_icon.texture != null
	if preview.size() > 1:
		preparation_aux_icon.texture = _preview_texture(recipe, preview[1], bool(_state.get("cut_done", false)))
		preparation_aux_icon.visible = preparation_aux_icon.texture != null

func _lt(key: String, args: Dictionary = {}) -> String:
	return Localization.text(key, args)

func _refresh() -> void:
	Localization.initialize()
	if _locale_revision != Localization.revision():
		_locale_revision = Localization.revision()
		root_control.theme = Localization.theme()
		_shown_actions.clear() # Rebuild translated tooltips even when actions match.
	var recipe: String = str(_state.get("recipe_id", ""))
	var phase: String = str(_state.get("phase", "idle"))
	var paused: bool = bool(_state.get("paused", false))
	var completed: bool = bool(_state.get("completed", false))
	cancel_button.tooltip_text = _lt("ui_back")
	clear_button.tooltip_text = _lt("kitchen_action_reselect")
	pause_button.tooltip_text = _lt("ui_resume") if paused else _lt("ui_pause")
	if pause_resume_button != null: pause_resume_button.tooltip_text = _lt("ui_resume")
	var recipe_name := _lt(RecipeCatalog.name_key(recipe)) if RecipeCatalog.has(recipe) else _lt("kitchen_make_something_tasty")
	recipe_label.text = recipe_name
	binding_label.text = str(_context.get("table_label", ""))
	prompt_label.tooltip_text = _lt("kitchen_phase_" + phase) if Localization.has_key("kitchen_phase_" + phase) else ""
	step_label.text = ""
	var phase_step := clampi(int(_state.get("step_index", 0)), 0, 3)
	var stage_icons := ["knife", "pot", "flame_medium", "confirm"]
	if recipe == "bake": stage_icons = ["bread", "cheese", "oven", "confirm"]
	elif recipe == "drink": stage_icons = ["coffee", "milk", "ice", "drink_spoon"]
	elif recipe == "pan_fried_mushrooms": stage_icons = ["confirm", "pan", "flame_medium", "flip"]
	for index in range(step_icons.size()):
		var stage_key: String = stage_icons[index]
		var stage_kind := "utensils" if stage_key in ["pot", "pan", "oven"] else ("ingredients" if stage_key in ["bread", "cheese", "coffee", "milk", "ice"] else "icons")
		step_icons[index].texture = _t(stage_key) if stage_key in P0Assets.PATHS else _texture(_art_path(stage_kind, stage_key))
		step_icons[index].modulate = Color.WHITE if index == phase_step else Color(1, 1, 1, 0.35)
		step_icons[index].visible = not recipe.is_empty()
	pause_overlay.visible = paused
	if pause_full_shade != null: pause_full_shade.visible = paused
	clear_button.visible = _actions.has("clear") and not completed
	clear_button.disabled = paused
	var required: Array[String] = _strings(_state.get("required_ingredients", []))
	required.erase("water") # Water never occupies an ingredient slot.
	var selected: Array[String] = _strings(_state.get("ingredients", []))
	for index in range(3):
		var slot: Dictionary = ingredient_slots[index]
		var ingredient: String = required[index] if index < required.size() else ""
		var action: String = "add_" + ingredient
		var used: bool = selected.has(ingredient)
		slot.action = action if not ingredient.is_empty() else ""
		slot.button.disabled = paused or _action_is_cooled(action) or ingredient.is_empty() or not _actions.has(action)
		var ingredient_name := _lt("category_" + ingredient + "_name") if not ingredient.is_empty() else ""
		slot.button.tooltip_text = _lt("kitchen_slot_add_ingredient", {"ingredient":ingredient_name}) if not ingredient.is_empty() else ""
		slot.button.visible = not ingredient.is_empty()
		slot.mark.visible = used
		slot.ring.visible = not used and not slot.button.disabled
		slot.image.texture = (_t(ingredient) if ingredient in ["pumpkin", "corn", "mushroom"] else _texture(_art_path("ingredients", ingredient))) if not ingredient.is_empty() else null
		slot.image.modulate = Color.WHITE if used else Color(1, 1, 1, 0.42)
	water_button.visible = recipe in ["soup", "pumpkin_corn_soup"]
	water_hint.visible = false
	water_button.disabled = paused or _action_is_cooled("add_water") or not _actions.has("add_water")
	water_label.text = ""
	water_button.tooltip_text = _lt("kitchen_water_added_hint") if bool(_state.get("water_added", false)) else _lt("kitchen_water_add_hint")
	if water_button.visible: water_icon.texture = _t("tap_open") if _water_flow_remaining > 0.0 else _t("tap_closed")
	var heating := recipe in ["soup", "pumpkin_corn_soup", "stir_fry", "pan_fried_mushrooms"] and phase == "cooking"
	if heat_icon != null:
		var heat_level := str(_state.get("heat_level", ""))
		var flame_key := str({"small":"flame_low", "medium":"flame_medium", "high":"flame_high"}.get(heat_level, ""))
		heat_icon.texture = _texture(_art_path("icons", flame_key)) if heating and not flame_key.is_empty() else null
		heat_icon.visible = heating and heat_icon.texture != null
	var vessel: String = {"soup":"pot", "pumpkin_corn_soup":"pot", "stir_fry":"pan", "pan_fried_mushrooms":"pan", "bake":"oven", "drink":"cup"}.get(recipe, "pot")
	var is_p0_recipe := recipe in ["pumpkin_corn_soup", "pan_fried_mushrooms", "bake", "drink"]
	var p0_layers_active := _p0_recipe_layers(recipe, phase, selected, bool(_state.get("cut_done", false)), bool(_state.get("water_added", false)))
	utensil_image.visible = not p0_layers_active
	var active: bool = phase in ["heat", "cooking", "ready", "retry", "completed"]
	if recipe in ["bake", "drink"]: active = phase in ["ready", "completed"]
	var variant: String = vessel + ("_ready" if vessel == "oven" else "_full") if active else vessel
	var utensil_path: String = _art_path("utensils", variant)
	if is_p0_recipe and not p0_layers_active:
		# Optional P0 layers can be absent. Use only the matching neutral vessel,
		# never a legacy full-pot/full-pan image from another dish.
		utensil_image.texture = _neutral_vessel_texture(vessel)
		utensil_image.visible = true
	# The supplied board contains only potato and carrot; it is soup-only artwork.
	if recipe == "soup" and phase in ["prep", "vessel"]:
		variant = "board_chopped" if bool(_state.get("cut_done", false)) else "board_whole"
		utensil_path = _art_path("tools", variant)
	_refresh_preparation_previews(recipe, phase, selected)
	if not is_p0_recipe or p0_layers_active:
		utensil_image.texture = _texture(utensil_path) if not p0_layers_active else null
	_apply_visual_texture()
	missing_utensil.visible = utensil_image.texture == null
	missing_utensil.text = "" # Diagnostics stay in art_status/F3, not player UI.
	progress_bar.visible = phase in ["cooking", "ready"]
	progress_bar.value = clampf(float(_state.get("progress", 0.0)), 0.0, 1.0) * 100.0
	message_label.tooltip_text = ""
	message_label.visible = phase in ["retry", "cancelled"]
	message_label.text = _lt("kitchen_phase_" + phase) if message_label.visible else ""
	completion_badge.visible = completed
	var visible_actions: Array[String] = []
	for action: String in _actions:
		if not action.begins_with("add_") and action not in ["clear", "cancel", "pause"]: visible_actions.append(action)
	if completed: visible_actions = ["return"]
	_sync_actions(visible_actions, paused, recipe)
	art_error_label.visible = false
	art_error_label.text = ""
	var diagnostics: PackedStringArray = []
	for item: Variant in _missing_art:
		diagnostics.append(str(item) + "：" + str(_missing_art[item]))
	art_error_label.tooltip_text = "\n".join(diagnostics)

func _sync_actions(actions: Array[String], paused: bool, recipe: String) -> void:
	if actions != _shown_actions:
		_shown_actions = actions.duplicate()
		for child: Node in action_bar.get_children():
			if child is Control: child.hide()
			child.queue_free()
		action_buttons.clear()
		var width: float = 168.0
		var start: float = (1536.0 - (actions.size() * width + maxi(0, actions.size() - 1) * 20.0)) * 0.5
		for index in range(actions.size()):
			var action: String = actions[index]
			var title: String = _lt("kitchen_action_" + action) if Localization.has_key("kitchen_action_" + action) else str(ACTION_LABELS.get(action, _lt("ui_confirm")))
			if action == "stir" and recipe == "drink": title = _lt("kitchen_action_stir_drink")
			var button := _button(action_bar, "", Vector2(start + index * (width + 20), 0), Vector2(width, 112), _emit_action.bind(action), title)
			var icon_key: String = str(ACTION_ICONS.get(action, ""))
			if action == "stir" and recipe == "stir_fry": icon_key = "flip"
			if action == "stir" and recipe == "drink": icon_key = "drink_spoon"
			if action in ["pot", "pan", "oven"]: icon_key = action
			if action in ["retry", "clear"]: icon_key = "reselect"
			if not icon_key.is_empty():
				var icon_size := Vector2(80, 80)
				var icon := _image(button, (button.size - icon_size) * 0.5, icon_size)
				icon.texture = _t(icon_key) if icon_key in P0Assets.PATHS else _texture(_art_path("utensils" if action in ["pot", "pan", "oven"] else "icons", icon_key))
			action_buttons[action] = button
	for action: Variant in action_buttons:
		action_buttons[action].disabled = paused or _action_is_cooled(str(action))

## Test/integration lookup for actual pointer targets, including independent water.
func button_for_action(action: String) -> Button:
	if action == "add_water": return water_button
	if action == "clear": return clear_button
	for slot: Dictionary in ingredient_slots:
		if str(slot.action) == action: return slot.button as Button
	return action_buttons.get(action) as Button

func _request_slot(index: int) -> void:
	if index < 0 or index >= ingredient_slots.size(): return
	_emit_action(str(ingredient_slots[index].action))

func _emit_action(action: String) -> void:
	if bool(_state.get("paused", false)) or _action_is_cooled(action): return
	if action == "return":
		if bool(_state.get("completed", false)): action_requested.emit(action, {})
	elif _actions.has(action):
		action_requested.emit(action, {})

func _request_cancel() -> void:
	cancel_requested.emit()

func _request_pause() -> void:
	pause_requested.emit()

func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_P:
		_request_pause()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE:
		_request_cancel()
		get_viewport().set_input_as_handled()
