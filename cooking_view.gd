extends CanvasLayer
## Read-only kitchen view. Main owns the session, restaurant pause and persistence.
## Missing artwork is an explicit development error, never a replacement appliance.
signal action_requested(action: String, payload: Dictionary)
signal cancel_requested
signal pause_requested

const CookingAnimation = preload("res://cooking_animation.gd")

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
const ACTION_ICONS := {"cut":"knife", "add_water":"water", "stir":"stir", "heat_small":"flame_low", "heat_medium":"flame_medium", "heat_high":"flame_high", "finish":"confirm", "takeout":"confirm", "return":"back"}
const PHASE_LABELS := {"idle":"小小厨房", "ingredients":"选食材", "prep":"切一切", "vessel":"放进去", "heat":"选火候", "cooking":"慢慢做", "ready":"好香呀", "retry":"再试一次", "completed":"做好啦", "cancelled":"回餐厅"}
const ACTION_COOLDOWN_SECONDS := 0.18

var root_control: Control
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
var missing_utensil: Label
var preparation_icon: TextureRect
var art_error_label: Label
var progress_bar: ProgressBar
var action_bar: Control
var pause_overlay: Control
var ingredient_slots: Array[Dictionary] = []
var action_buttons: Dictionary = {}
var _state: Dictionary = {}
var _context: Dictionary = {}
var _actions: Array[String] = []
var _shown_actions: Array[String] = []
var _textures: Dictionary = {}
var _missing_art: Dictionary = {}
var _art_overrides: Dictionary = {}
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

func _ready() -> void:
	_build()
	visibility_changed.connect(_on_visibility_changed)


func _process(delta: float) -> void:
	if _action_cooldown > 0.0:
		_action_cooldown = maxf(0.0, _action_cooldown - delta)
		if _action_cooldown <= 0.0:
			_refresh()
	if not visible or _visual_player == null or not _visual_player.playing:
		return
	_visual_player.set_paused(bool(_state.get("paused", false)))
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
		_stop_visual(false)
		_action_cooldown = 0.0
	_visual_token = incoming_token
	_context = context.duplicate(true)
	if session is Dictionary:
		_state = session.duplicate(true)
		_actions = _strings(_state.get("actions", _state.get("available_actions", [])))
	elif is_instance_valid(session) and session.has_method("status"):
		_state = session.status().duplicate(true)
		_actions = _strings(session.available_actions())
	else:
		_state = {"phase":"idle", "message":"还没有选好要做的菜。"}
		_actions.clear()
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
	if action == "clear":
		_action_cooldown = 0.0
	_stop_visual(false)
	if _uses_action_cooldown(action):
		_action_cooldown = ACTION_COOLDOWN_SECONDS
	_refresh()
	var recipe: String = str(_state.get("recipe_id", ""))
	if recipe == "soup" and action == "add_water":
		_start_visual("pour_water", false, 0.0)
	elif recipe == "soup" and action == "cut":
		_start_visual("chop", false, 0.0)
	else:
		_reconcile_loop_visual()


func clear_visual_feedback() -> void:
	_action_cooldown = 0.0
	_stop_visual(true)


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

## Optional import/path adapter. Keys are ingredient IDs, utensil names or icon names.
func set_art_paths(paths: Dictionary) -> void:
	_art_overrides = paths.duplicate(true)
	refresh_art()

func refresh_art() -> void:
	_stop_visual(false)
	_textures.clear()
	_missing_art.clear()
	_visual_cache.clear()
	if _built:
		_refresh()
		_reconcile_loop_visual()

func art_status() -> Dictionary:
	return {"complete":_missing_art.is_empty(), "missing_paths":_missing_art.keys(), "errors":_missing_art.duplicate()}

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
	panel.add_theme_stylebox_override("panel", _style(fill))
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
	button.add_theme_stylebox_override("normal", _style(PAPER))
	button.add_theme_stylebox_override("hover", _style(Color("fffbea"), GREEN))
	button.add_theme_stylebox_override("pressed", _style(Color("dce7ca"), GREEN))
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

func _build() -> void:
	if _built: return
	_built = true
	layer = 70
	root_control = Control.new()
	root_control.size = VIEW_SIZE
	root_control.mouse_filter = Control.MOUSE_FILTER_STOP
	root_control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(root_control)
	var background := _image(root_control, Vector2(0, 80), Vector2(1536, 1024))
	background.texture = _texture(BACKGROUND_PATH)
	background.modulate = Color(0.58, 0.60, 0.52, 1)
	var veil := ColorRect.new()
	veil.size = VIEW_SIZE
	veil.color = Color(0.18, 0.15, 0.10, 0.26)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.add_child(veil)
	_panel(root_control, Vector2.ZERO, Vector2(1536, 84), Color("eee0bd"))
	cancel_button = _button(root_control, "返回", Vector2(24, 16), Vector2(112, 52), _request_cancel, "订单还在，下次可重新制作")
	recipe_label = _label(root_control, "小小厨房", Vector2(176, 14), Vector2(1000, 56), 30)
	clear_button = _button(root_control, "重选", Vector2(1256, 16), Vector2(112, 52), _emit_action.bind("clear"), "清空这一份，重新选食材")
	pause_button = _button(root_control, "暂停", Vector2(1392, 16), Vector2(120, 52), _request_pause, "暂停 / 继续做菜（P）")
	binding_label = _label(root_control, "", Vector2(32, 100), Vector2(288, 40), 20)
	binding_label.add_theme_color_override("font_color", PAPER)
	prompt_label = _label(root_control, "选食材", Vector2(336, 100), Vector2(864, 40), 28)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.add_theme_color_override("font_color", PAPER)
	step_label = _label(root_control, "", Vector2(1268, 100), Vector2(236, 40), 22)
	step_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	step_label.add_theme_color_override("font_color", PAPER)
	for index in range(3):
		var button := _button(root_control, "", Vector2(492 + index * 184, 154), Vector2(168, 176), _request_slot.bind(index))
		var icon := _image(button, Vector2(20, 6), Vector2(128, 128))
		var label := _label(button, "", Vector2(8, 136), Vector2(152, 32), 22)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var mark := _label(button, "", Vector2(124, 4), Vector2(40, 30), 18)
		mark.add_theme_color_override("font_color", GREEN)
		ingredient_slots.append({"button":button, "image":icon, "label":label, "mark":mark, "action":""})
	# The panel is a work surface. The appliance itself is always supplied artwork.
	_panel(root_control, Vector2(160, 350), Vector2(1216, 558), Color("e9cc99"))
	utensil_image = _image(root_control, Vector2(512, 356), Vector2(512, 512))
	preparation_icon = _image(root_control, Vector2(832, 464), Vector2(160, 160))
	preparation_icon.visible = false
	# Water is independent of the three ingredient slots, beside the cookware.
	water_button = _button(root_control, "", Vector2(1104, 532), Vector2(144, 148), _emit_action.bind("add_water"), "加清水，不占食材位")
	water_icon = _image(water_button, Vector2(24, 4), Vector2(96, 96))
	water_label = _label(water_button, "加水", Vector2(8, 106), Vector2(128, 34), 24)
	water_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	water_hint = _label(root_control, "不占食材位", Vector2(1080, 686), Vector2(192, 30), 18)
	water_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	missing_utensil = _label(root_control, "", Vector2(440, 508), Vector2(656, 192), 26)
	missing_utensil.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	missing_utensil.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	missing_utensil.add_theme_color_override("font_color", Color("92523b"))
	art_error_label = _label(root_control, "", Vector2(184, 858), Vector2(1168, 36), 18)
	art_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	art_error_label.add_theme_color_override("font_color", Color("92523b"))
	progress_bar = ProgressBar.new()
	progress_bar.position = Vector2(544, 924)
	progress_bar.show_percentage = false
	progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress_bar.add_theme_stylebox_override("background", _style(Color("c2ad82"), Color.TRANSPARENT, 0))
	progress_bar.add_theme_stylebox_override("fill", _style(GREEN, Color.TRANSPARENT, 0))
	root_control.add_child(progress_bar)
	progress_bar.size = Vector2(448, 8)
	message_label = _label(root_control, "", Vector2(168, 940), Vector2(1200, 46), 24)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.add_theme_color_override("font_color", PAPER)
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
	var pause_title := _label(note, "休息一下", Vector2(32, 24), Vector2(384, 58), 32)
	pause_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button(note, "继续", Vector2(136, 112), Vector2(176, 60), _request_pause)

func _art_path(kind: String, key: String) -> String:
	return str(_art_overrides.get(key, ART_ROOT + kind + "/" + key + ".png"))

func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		var texture: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
		_textures[path] = texture
		if texture == null: _missing_art[path] = true
	return _textures[path] as Texture2D

func _refresh() -> void:
	var recipe: String = str(_state.get("recipe_id", ""))
	var phase: String = str(_state.get("phase", "idle"))
	var paused: bool = bool(_state.get("paused", false))
	var completed: bool = bool(_state.get("completed", false))
	recipe_label.text = "小小厨房 · " + str(_context.get("recipe_label", _state.get("recipe_label", RECIPE_LABELS.get(recipe, "做点好吃的"))))
	binding_label.text = str(_context.get("table_label", ""))
	prompt_label.text = str(PHASE_LABELS.get(phase, "慢慢来"))
	prompt_label.tooltip_text = str(_state.get("prompt", ""))
	step_label.text = "%d / %d" % [clampi(int(_state.get("step_index", 0)) + 1, 1, 4), int(_state.get("step_count", 4))] if not recipe.is_empty() else ""
	pause_button.text = "继续" if paused else "暂停"
	pause_overlay.visible = paused
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
		slot.button.tooltip_text = "放入" + str(INGREDIENT_LABELS.get(ingredient, ingredient)) if not ingredient.is_empty() else "这道菜不用放第三种食材"
		slot.label.text = str(INGREDIENT_LABELS.get(ingredient, "空位"))
		slot.mark.text = "好了" if used else ""
		slot.image.texture = _texture(_art_path("ingredients", ingredient)) if not ingredient.is_empty() else null
		slot.image.modulate = Color(1, 1, 1, 0.62) if used else Color.WHITE
	water_button.visible = recipe == "soup"
	water_hint.visible = water_button.visible
	water_button.disabled = paused or _action_is_cooled("add_water") or not _actions.has("add_water")
	water_label.text = "已加" if bool(_state.get("water_added", false)) else "加水"
	water_button.tooltip_text = "清水已加，不占食材位" if bool(_state.get("water_added", false)) else "加清水，不占食材位"
	if water_button.visible: water_icon.texture = _texture(_art_path("icons", "water"))
	var vessel: String = {"soup":"pot", "stir_fry":"pan", "bake":"oven", "drink":"cup"}.get(recipe, "pot")
	var active: bool = phase in ["heat", "cooking", "ready", "retry", "completed"]
	if recipe in ["bake", "drink"]: active = phase in ["ready", "completed"]
	var variant: String = vessel + ("_ready" if vessel == "oven" else "_full") if active else vessel
	var utensil_path: String = _art_path("utensils", variant)
	# The supplied board contains only potato and carrot; it is soup-only artwork.
	if recipe == "soup" and phase in ["prep", "vessel"]:
		variant = "board_chopped" if bool(_state.get("cut_done", false)) else "board_whole"
		utensil_path = _art_path("tools", variant)
	preparation_icon.visible = recipe == "stir_fry" and phase == "prep"
	if preparation_icon.visible:
		utensil_path = _art_path("ingredients", "tomato")
		preparation_icon.texture = _texture(_art_path("icons", "knife"))
	utensil_image.texture = _texture(utensil_path)
	_apply_visual_texture()
	missing_utensil.visible = utensil_image.texture == null
	missing_utensil.text = "开发检查：缺少厨具图片\n" + variant + ".png\n这不是最终游戏画面" if missing_utensil.visible else ""
	progress_bar.visible = phase in ["cooking", "ready"]
	progress_bar.value = clampf(float(_state.get("progress", 0.0)), 0.0, 1.0) * 100.0
	message_label.tooltip_text = str(_state.get("message", ""))
	message_label.text = {"idle":"先选一道喜欢的菜", "ingredients":"点亮着的食材，按顺序放好", "prep":"切一切，再放进去", "vessel":"食材准备好啦", "heat":"小火慢慢煮，大火要留心", "cooking":"等一等，香味来了", "ready":"好啦，点下面的小按钮", "retry":"没关系，我们再试一次", "completed":"做得好！", "cancelled":"回餐厅啦"}.get(phase, "慢慢来，不着急")
	var visible_actions: Array[String] = []
	for action: String in _actions:
		if not action.begins_with("add_") and action not in ["clear", "cancel", "pause"]: visible_actions.append(action)
	if completed: visible_actions = ["return"]
	_sync_actions(visible_actions, paused, recipe)
	art_error_label.visible = not _missing_art.is_empty()
	art_error_label.text = "开发检查：缺少 %d 张厨房图片，画面尚未验收" % _missing_art.size() if art_error_label.visible else ""
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
			var title: String = str(ACTION_LABELS.get(action, "继续"))
			if action == "stir" and recipe == "drink": title = "搅一搅"
			var button := _button(action_bar, title, Vector2(start + index * (width + 20), 0), Vector2(width, 112), _emit_action.bind(action), title)
			var icon_key: String = str(ACTION_ICONS.get(action, ""))
			if action == "stir" and recipe == "stir_fry": icon_key = "flip"
			if action in ["pot", "pan", "oven"]: icon_key = action
			if not icon_key.is_empty():
				button.text = ""
				var icon := _image(button, Vector2(56, 8), Vector2(56, 56))
				icon.texture = _texture(_art_path("utensils" if action in ["pot", "pan", "oven"] else "icons", icon_key))
				var label := _label(button, title, Vector2(4, 72), Vector2(width - 8, 32), 24)
				label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
