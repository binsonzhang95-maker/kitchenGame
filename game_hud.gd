extends CanvasLayer
## Small game controls. The restaurant is the main surface; diagnostics start hidden.
const SIZE := Vector2(1536, 1152)
const INK := Color("594b39")
const GREEN := Color("617c58")
const CREAM := Color("fff5dc")
const EDGE := Color("a28b62")
const RECIPE_TEXTURES := {
	"soup": preload("res://cooking_art/utensils/pot_full.png"),
	"stir_fry": preload("res://cooking_art/utensils/pan_full.png"),
	"bake": preload("res://cooking_art/utensils/oven_ready.png"),
	"drink": preload("res://cooking_art/utensils/cup_full.png"),
}
const CookingSession = preload("res://cooking_session.gd")

class PixelIcon:
	extends Control
	var kind: String = "coin"
	var ink := Color("594b39")
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var unit: float = minf(size.x, size.y) / 16.0
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * unit)
		match kind:
			"coin", "pay":
				draw_rect(Rect2(4, 1, 8, 14), Color("94643d"))
				draw_rect(Rect2(2, 3, 12, 10), Color("94643d"))
				draw_rect(Rect2(4, 2, 8, 12), Color("e9b74d"))
				draw_rect(Rect2(3, 4, 10, 8), Color("f6cf6c"))
				draw_rect(Rect2(5, 3, 2, 9), Color("ffe6a0"))
				draw_rect(Rect2(8, 5, 2, 6), Color("b97c38"))
			"guest", "assign", "invite":
				draw_rect(Rect2(3, 2, 3, 4), Color("bd936d"))
				draw_rect(Rect2(10, 2, 3, 4), Color("bd936d"))
				draw_rect(Rect2(3, 5, 10, 7), Color("ddb58a"))
				draw_rect(Rect2(5, 7, 2, 2), ink)
				draw_rect(Rect2(10, 7, 2, 2), ink)
				draw_rect(Rect2(7, 10, 2, 1), ink)
				draw_rect(Rect2(5, 12, 7, 3), Color("8fa574"))
			"pause":
				draw_rect(Rect2(3, 2, 4, 12), ink)
				draw_rect(Rect2(10, 2, 4, 12), ink)
			"play":
				for x in range(4, 12):
					draw_rect(Rect2(x, 2 + floori(float(x - 4) * 0.5), 1, 12 - (x - 4)), ink)
			"settings":
				draw_rect(Rect2(6, 1, 4, 14), ink)
				draw_rect(Rect2(1, 6, 14, 4), ink)
				draw_rect(Rect2(3, 3, 10, 10), ink)
				draw_rect(Rect2(6, 6, 4, 4), Color("fff5dc"))
			"order":
				draw_rect(Rect2(3, 1, 10, 14), ink)
				draw_rect(Rect2(4, 2, 8, 12), Color("fff5dc"))
				for y in [5, 8, 11]: draw_rect(Rect2(6, y, 5, 1), Color("aa9a75"))
				draw_rect(Rect2(6, 0, 4, 3), Color("9cb385"))
			"cook":
				draw_rect(Rect2(2, 8, 12, 5), Color("9cab87"))
				draw_rect(Rect2(4, 13, 8, 2), ink)
				draw_rect(Rect2(1, 7, 14, 2), ink)
				for x in [4, 8, 12]:
					draw_rect(Rect2(x, 2, 1, 3), Color("b1a58a"))
					draw_rect(Rect2(x - 1, 4, 1, 2), Color("b1a58a"))
			"clean":
				draw_rect(Rect2(2, 6, 11, 7), Color("70968c"))
				draw_rect(Rect2(3, 7, 9, 4), Color("a7c7ad"))
				draw_rect(Rect2(11, 1, 1, 5), Color("d3ac4f"))
				draw_rect(Rect2(9, 3, 5, 1), Color("d3ac4f"))
			"wait":
				draw_rect(Rect2(4, 1, 9, 2), ink)
				draw_rect(Rect2(4, 13, 9, 2), ink)
				for i in range(4):
					draw_rect(Rect2(5 + i, 3 + i, 7 - i * 2, 1), Color("c5a66c"))
					draw_rect(Rect2(5 + i, 12 - i, 7 - i * 2, 1), Color("c5a66c"))
			"close":
				for i in range(3, 13):
					draw_rect(Rect2(i, i, 2, 2), ink)
					draw_rect(Rect2(15 - i, i, 2, 2), ink)

var app: Variant
var settings_root: Control
var debug_root: Control
var settings_button: Button
var popup: Panel
var popup_icon: PixelIcon
var demand_row: Control
var recipe_icon: TextureRect
var popup_status: Label
var status_icon: PixelIcon
var debug_order_button: Button
var debug_dispatch_button: Button
var pause_icon: PixelIcon
var money_label: Label
var count_label: Label
var help_label: Label
var debug_title: Label
var settings_save_label: Label
var invite_button: Button
var order_button: Button
var pay_button: Button
var _selection_open: bool = false

func setup(owner_app) -> void:
	app = owner_app
	layer = 30
	_build_top()
	_build_bottom()
	_build_popup()
	_build_settings()
	_build_debug()
	_build_pause()
	refresh()

func _style(fill: Color, border: Color = EDGE, thickness: int = 2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(thickness)
	style.set_corner_radius_all(2)
	return style

func _panel(parent: Node, at: Vector2, dimensions: Vector2, fill: Color, block: bool = false) -> Panel:
	var panel := Panel.new()
	panel.position = at
	panel.size = dimensions
	panel.add_theme_stylebox_override("panel", _style(fill))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP if block else Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)
	return panel

func _label(parent: Node, content: String, at: Vector2, dimensions: Vector2, font_size: int = 20, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = content
	label.position = at
	label.size = dimensions
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _icon(parent: Node, kind: String, at: Vector2, extent: float = 28.0) -> PixelIcon:
	var icon := PixelIcon.new()
	icon.kind = kind
	icon.position = at
	icon.size = Vector2.ONE * extent
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(icon)
	return icon

func _button(parent: Node, content: String, at: Vector2, dimensions: Vector2, callback: Callable, tip: String, kind: String = "") -> Button:
	var button := Button.new()
	button.position = at
	button.size = dimensions
	button.text = content
	button.tooltip_text = tip
	button.add_theme_font_size_override("font_size", 20)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_color_override("font_disabled_color", Color("8d8b76"))
	button.add_theme_stylebox_override("normal", _style(CREAM))
	button.add_theme_stylebox_override("hover", _style(Color("fffbe8"), Color("b18b43")))
	button.add_theme_stylebox_override("pressed", _style(Color("e5d4ac")))
	button.add_theme_stylebox_override("disabled", _style(Color("e2dfcd"), Color("aaa58a")))
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, Color("4e776b"), 3))
	if not kind.is_empty():
		_icon(button, kind, Vector2(12, (dimensions.y - 28) * 0.5))
		button.text = "      " + content if not content.is_empty() else ""
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _build_top() -> void:
	_panel(self, Vector2.ZERO, Vector2(1536, 80), Color("eee0bd"))
	_icon(self, "coin", Vector2(32, 23), 32)
	money_label = _label(self, "0", Vector2(76, 18), Vector2(190, 44), 28)
	money_label.tooltip_text = "金币：每份套餐收入 38 金币"
	money_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_icon(self, "guest", Vector2(280, 25), 28)
	count_label = _label(self, "", Vector2(322, 22), Vector2(160, 36), 22)
	count_label.tooltip_text = "正在招待 / 接待上限"
	count_label.mouse_filter = Control.MOUSE_FILTER_PASS
	app.pause_button = _button(self, "", Vector2(1384, 14), Vector2(58, 52), app._pause, "暂停 / 继续（P）")
	pause_icon = _icon(app.pause_button, "pause", Vector2(14, 11), 30)
	settings_button = _button(self, "", Vector2(1454, 14), Vector2(58, 52), toggle_settings, "设置：声音、表情与营业选项")
	_icon(settings_button, "settings", Vector2(14, 11), 30)

func _build_bottom() -> void:
	_panel(self, Vector2(0, 1104), Vector2(1536, 48), Color("eee0bd"))
	help_label = _label(self, "点客人，点好单再去做饭", Vector2(26, 1114), Vector2(620, 28), 18, Color("7c6d51"))
	order_button = _button(self, "点单", Vector2(696, 1108), Vector2(144, 40), app._focus_next_order, "找到等待点单或等待下厨的客人", "order")

func _demand_icon(texture: Texture2D, at: Vector2, tip: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.position = at
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size = Vector2(56, 46)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_PASS
	icon.tooltip_text = tip
	demand_row.add_child(icon)
	return icon

func _build_popup() -> void:
	popup = _panel(self, Vector2.ZERO, Vector2(144, 104), Color("fff9e6"), true)
	popup.visible = false
	demand_row = Control.new()
	demand_row.position = Vector2.ZERO
	demand_row.size = Vector2(144, 50)
	demand_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(demand_row)
	recipe_icon = _demand_icon(RECIPE_TEXTURES.soup, Vector2(44, 2), "土豆胡萝卜汤")
	app.primary = _button(popup, "点单", Vector2(4, 50), Vector2(136, 42), app._primary, "确认这一位客人的点单（空格）")
	popup_icon = _icon(app.primary, "order", Vector2(12, 7), 28)
	status_icon = _icon(popup, "wait", Vector2(12, 12), 28)
	popup_status = _label(popup, "等一等", Vector2(48, 11), Vector2(88, 32), 18)
	app.patience_bar = ProgressBar.new()
	app.patience_bar.position = Vector2(6, 96)
	app.patience_bar.show_percentage = false
	app.patience_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	app.patience_bar.add_theme_stylebox_override("background", _style(Color("e7dcc0"), Color.TRANSPARENT, 0))
	app.patience_bar.add_theme_stylebox_override("fill", _style(Color("94ad77"), Color.TRANSPARENT, 0))
	popup.add_child(app.patience_bar)
	app.patience_bar.size = Vector2(132, 4)

func _modal_root() -> Control:
	var root := Control.new()
	root.size = SIZE
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.visible = false
	add_child(root)
	var veil := ColorRect.new()
	veil.size = SIZE
	veil.color = Color(0.12, 0.16, 0.10, 0.48)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(veil)
	return root

func _build_settings() -> void:
	settings_root = _modal_root()
	settings_root.gui_input.connect(_settings_backdrop_input)
	var paper := _panel(settings_root, Vector2(492, 298), Vector2(552, 500), CREAM, true)
	_label(paper, "小小设置", Vector2(26, 20), Vector2(380, 40), 25)
	_button(paper, "", Vector2(480, 14), Vector2(50, 46), toggle_settings, "关闭设置", "close")
	app.music_button = _button(paper, "", Vector2(24, 82), Vector2(180, 44), app._toggle_music, "音乐开关：关闭时暂停，开启继续原进度")
	app.music_slider = HSlider.new()
	app.music_slider.position = Vector2(224, 92)
	app.music_slider.size = Vector2(220, 24)
	app.music_slider.min_value = 0
	app.music_slider.max_value = 100
	app.music_slider.step = 1
	app.music_slider.value = app.music.volume * 100.0
	app.music_slider.tooltip_text = "音乐音量"
	app.music_slider.value_changed.connect(app._music_volume_changed)
	paper.add_child(app.music_slider)
	app.music_level = _label(paper, "", Vector2(460, 86), Vector2(70, 32), 18)
	app.dialogue_button = _button(paper, "", Vector2(24, 146), Vector2(240, 44), app._toggle_dialogues, "显示角色动态表情气泡")
	app.short_text_button = _button(paper, "", Vector2(288, 146), Vector2(240, 44), app._toggle_short_text, "可选 2–4 字短词；默认无字")
	app.capacity_button = _button(paper, "", Vector2(24, 222), Vector2(504, 44), app._cycle_capacity, "轮换同时接待人数：6、10、14、20；已有客人继续招待")
	_label(paper, "你来下厨，大家来帮忙", Vector2(24, 284), Vector2(504, 32), 20, GREEN)
	_button(paper, "保存进度", Vector2(24, 340), Vector2(504, 48), app._manual_save, "营业会自动保存，也可以手动保存（S）")
	settings_save_label = _label(paper, "", Vector2(24, 410), Vector2(504, 68), 17, Color("7c6d51"))
	settings_save_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _build_debug() -> void:
	debug_root = _modal_root()
	debug_root.gui_input.connect(_debug_backdrop_input)
	var controls := _panel(debug_root, Vector2(24, 96), Vector2(524, 590), CREAM, true)
	_label(controls, "开发控制 · 玩家模式下只读", Vector2(20, 16), Vector2(484, 34), 21, GREEN)
	invite_button = _button(controls, "迎客", Vector2(20, 76), Vector2(232, 44), app._invite, "开发测试：招呼一位新客人", "invite")
	debug_order_button = _button(controls, "批量点单", Vector2(272, 76), Vector2(232, 44), app._order_all, "开发测试：记录所有点单", "order")
	app.next_cook_button = _button(controls, "做饭", Vector2(20, 138), Vector2(232, 44), app._cook_next, "开发测试：制作下一单", "cook")
	pay_button = _button(controls, "收钱", Vector2(272, 138), Vector2(232, 44), app._pay_all, "开发测试：结账", "pay")
	app.arrival_button = _button(controls, "", Vector2(20, 220), Vector2(232, 44), app._toggle_arrivals, "开发测试：自动迎客")
	app.seat_button = _button(controls, "", Vector2(272, 220), Vector2(232, 44), app._toggle_seating, "开发测试：自动分桌")
	app.dispatch_button = _button(controls, "", Vector2(20, 282), Vector2(232, 44), app._toggle_dispatch, "开发测试：自动派工")
	app.auto_cook_button = _button(controls, "", Vector2(272, 282), Vector2(232, 44), app._toggle_cooking, "开发测试：自动做饭")
	debug_dispatch_button = _button(controls, "派出服务员", Vector2(20, 364), Vector2(484, 44), app._dispatch, "开发测试：手动认领服务任务")
	_label(controls, "正常游戏由你点单、亲手做饭。\n送餐、收款与清桌会自动完成。", Vector2(20, 438), Vector2(484, 100), 18)
	var paper := _panel(debug_root, Vector2(980, 96), Vector2(532, 984), CREAM, true)
	_label(paper, "开发面板 · F3 关闭", Vector2(20, 16), Vector2(490, 34), 21, GREEN)
	app.stats = _label(paper, "", Vector2(20, 56), Vector2(490, 56), 19)
	app.selected_title = _label(paper, "", Vector2(20, 112), Vector2(490, 28), 17)
	app.selected_state = _label(paper, "", Vector2(20, 146), Vector2(490, 28), 20)
	app.selected_detail = _label(paper, "", Vector2(20, 184), Vector2(490, 56), 17)
	app.selected_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(20, 258)
	scroll.size = Vector2(492, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	paper.add_child(scroll)
	app.orders_box = VBoxContainer.new()
	app.orders_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	app.orders_box.add_theme_constant_override("separation", 4)
	scroll.add_child(app.orders_box)
	app.order_buttons.clear()
	for i in range(20):
		var item := Button.new()
		item.custom_minimum_size = Vector2(470, 32)
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.add_theme_font_size_override("font_size", 16)
		item.add_theme_color_override("font_color", INK)
		item.add_theme_stylebox_override("normal", _style(Color("eee5cb"), EDGE, 1))
		item.pressed.connect(app._select_table.bind(i + 1))
		app.orders_box.add_child(item)
		app.order_buttons.append(item)
	app.queue_label = _label(paper, "", Vector2(20, 680), Vector2(490, 66), 17)
	app.queue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	app.workers_label = _label(paper, "", Vector2(20, 752), Vector2(490, 62), 16)
	app.workers_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	app.kitchen_label = _label(paper, "", Vector2(20, 826), Vector2(490, 52), 16)
	app.kitchen_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	app.save_label = _label(paper, "", Vector2(20, 900), Vector2(490, 60), 16)
	app.save_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _build_pause() -> void:
	app.pause_overlay = _panel(self, Vector2(0, 80), Vector2(1536, 1024), Color(0.12, 0.16, 0.10, 0.34))
	app.pause_overlay.visible = false
	var paper := _panel(app.pause_overlay, Vector2(648, 424), Vector2(240, 128), CREAM)
	_icon(paper, "pause", Vector2(28, 26), 32)
	_label(paper, "休息一下", Vector2(78, 20), Vector2(150, 40), 24)
	_label(paper, "点右上角继续", Vector2(28, 76), Vector2(190, 30), 18)
	# Settings and diagnostics must remain usable while the restaurant is paused.
	move_child(settings_root, get_child_count() - 1)
	move_child(debug_root, get_child_count() - 1)

func select_table() -> void:
	_selection_open = true
	refresh()

func toggle_settings() -> void:
	settings_root.visible = not settings_root.visible
	debug_root.visible = false
	refresh()

func toggle_debug() -> void:
	debug_root.visible = not debug_root.visible
	settings_root.visible = false
	refresh()

func close_overlay() -> bool:
	if settings_root.visible or debug_root.visible:
		settings_root.visible = false
		debug_root.visible = false
		refresh()
		return true
	return false

func _settings_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		settings_root.visible = false
		refresh()

func _debug_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		debug_root.visible = false
		refresh()

func _popup_position(table: Dictionary) -> Vector2:
	var center: Vector2 = app.room.get_global_transform_with_canvas() * Vector2(table.center)
	# A 144 px control fits the 148 px gap between the hall's table bounds.
	var candidates: Array[Vector2] = [center + Vector2(60, -18), center + Vector2(-204, -18), center + Vector2(94, -18), center + Vector2(-238, -18), center + Vector2(-72, 70)]
	var actor_bounds: Array[Rect2] = []
	for actor: Dictionary in app.model.customers.values() + app.model.workers:
		var feet: Vector2 = app.room.get_global_transform_with_canvas() * Vector2(actor.pos)
		actor_bounds.append(Rect2(feet - Vector2(34, 80), Vector2(68, 84)))
	var bubble_bounds: Array[Rect2] = []
	for visual: Dictionary in app.bubble_layer._visuals.values():
		var bubble_center: Vector2 = visual.sprite.get_global_transform_with_canvas().origin
		bubble_bounds.append(Rect2(bubble_center - Vector2(36, 36), Vector2(72, 72)))
		if visual.label.visible: bubble_bounds.append(visual.label.get_global_rect().grow(4))
	var best := candidates[0]
	var best_score: float = INF
	for point: Vector2 in candidates:
		point.x = clampf(point.x, 8, 1536 - popup.size.x - 8)
		point.y = clampf(point.y, 88, 1104 - popup.size.y - 8)
		var bounds := Rect2(point, popup.size)
		var score: float = center.distance_squared_to(point + popup.size * 0.5) * 0.001
		for other: Dictionary in app.model.tables:
			var other_center: Vector2 = app.room.get_global_transform_with_canvas() * Vector2(other.center)
			if bounds.intersects(Rect2(other_center - Vector2(56, 76), Vector2(112, 132))): score += 10000
		for actor_rect: Rect2 in actor_bounds:
			if bounds.intersects(actor_rect): score += 12000
		for bubble_rect: Rect2 in bubble_bounds:
			if bounds.intersects(bubble_rect): score += 16000
		if score < best_score:
			best_score = score
			best = point
	return best.round()

func refresh() -> void:
	if app == null or app.model.tables.is_empty(): return
	var model = app.model
	var table: Dictionary = model.tables[app.selected_table - 1]
	var guest: Dictionary = model.customers.get(table.guest_id, {})
	var phase: String = table.phase
	var action: String = model.table_action(app.selected_table)
	money_label.text = str(model.coins)
	count_label.text = "%d / %d" % [model.customers.size(), model.max_customers]
	pause_icon.kind = "play" if model.paused else "pause"
	pause_icon.queue_redraw()
	app.pause_button.tooltip_text = "继续营业（P）" if model.paused else "暂停营业（P）"
	app.pause_overlay.visible = model.paused and app.cooking_session == null
	popup.visible = _selection_open and not model.paused and not settings_root.visible and not debug_root.visible
	var can_order: bool = action == "order"
	var can_cook: bool = action == "cook" and model.interactive_cooking
	var can_manual: bool = can_order or can_cook
	var recipe: String = str(table.get("recipe_id", ""))
	var recipe_label: String = CookingSession.recipe_label(recipe)
	recipe_icon.texture = RECIPE_TEXTURES.get(recipe, RECIPE_TEXTURES.soup)
	recipe_icon.tooltip_text = recipe_label
	var player: bool = bool(app.player_mode)
	# Players confirm a recipe and reopen unfinished cooking; service stays automatic.
	app.primary.visible = can_manual or not player
	demand_row.visible = can_manual
	popup_status.visible = player and not can_manual
	status_icon.visible = popup_status.visible
	popup.size = Vector2(144, 104 if can_manual else 64)
	app.primary.position = Vector2(4, 50 if can_manual else 4)
	app.primary.size = Vector2(136, 42 if can_manual else 48)
	app.patience_bar.position = Vector2(6, 96 if can_manual else 56)
	popup.position = _popup_position(table)
	var short_action: String = {"assign":"入座", "order":"点单", "cook":"做饭", "pay":"收钱", "clean":"收拾", "":"等候"}.get(action, "等候")
	app.primary.text = "      " + short_action
	app.primary.tooltip_text = ("确认点单并开始制作：" if can_order else "重新制作：") + recipe_label + "（空格）" if can_manual else "%s：%s" % [table.label, app.PHASE_NAMES.get(phase, phase)]
	app.primary.disabled = model.paused or action.is_empty() or app.cooldown > 0 or (player and not can_manual)
	popup_icon.kind = action if not action.is_empty() else "wait"
	popup_icon.queue_redraw()
	popup_status.text = {"free":"空桌", "reserved":"入座中", "awaiting_cook":"等饭中", "cooking":"做饭中", "food_ready":"送饭中", "serving_food":"送饭中", "waiting_drink":"等饮品", "serving_drink":"送饮品", "eating":"用餐中", "drinking":"喝饮品", "checkout":"谢谢啦", "leaving":"再见啦", "dirty":"打扫中", "collecting":"收拾中", "wiping":"擦桌中"}.get(phase, "等一等")
	status_icon.kind = "cook" if phase in ["awaiting_cook", "cooking"] else "clean" if phase in ["dirty", "collecting", "wiping"] else "wait"
	status_icon.queue_redraw()
	app.patience_bar.visible = not guest.is_empty() and phase not in ["leaving", "dirty", "collecting", "wiping"]
	if not guest.is_empty(): app.patience_bar.value = clampf(float(guest.patience) / 120.0, 0.0, 1.0) * 100.0
	app.arrival_button.text = "自动迎客：%s" % ("开" if model.open_for_arrivals else "关")
	app.seat_button.text = "自动分桌：%s" % ("开" if model.auto_seat else "关")
	app.dispatch_button.text = "自动派工：%s" % ("开" if model.auto_dispatch else "关")
	app.auto_cook_button.text = "自动做饭：%s" % ("开" if model.auto_cook else "关")
	app.capacity_button.text = "同时接待：%d" % model.max_customers
	app.dialogue_button.text = "表情：%s" % ("开" if app.dialogues.enabled else "关")
	app.short_text_button.text = "短词：%s" % ("开" if app.bubble_layer.show_short_text else "关")
	app.music_button.text = "音乐：%s" % ("开" if app.music.enabled else "关")
	app.music_level.text = "%d%%" % roundi(app.music.volume * 100.0)
	var cooking: bool = int(model.chef.table_id) > 0
	app.next_cook_button.disabled = player or model.paused or cooking or app.cooldown > 0 or not _has_action("cook")
	invite_button.disabled = player or model.paused or app.cooldown > 0 or model.customers.size() >= model.max_customers or model.queue_ids().size() >= 8
	order_button.disabled = model.paused or not (_has_action("order") or (model.interactive_cooking and _has_action("cook")))
	debug_order_button.disabled = player or model.paused or app.cooldown > 0 or not _has_action("order")
	pay_button.disabled = player or model.paused or app.cooldown > 0 or not _has_action("pay")
	debug_dispatch_button.disabled = player or model.paused or app.cooldown > 0
	for control: Button in [app.arrival_button, app.seat_button, app.dispatch_button, app.auto_cook_button]:
		control.disabled = player or model.paused
	app.stats.text = "%d 金币 · 招待 %d 位 · 流失 %d 位" % [model.coins, model.served, model.lost]
	app.selected_title.text = "%s / %s" % [table.label, {"hall":"大厅", "private":"包厢", "bar":"吧台"}.get(table.zone, "")]
	app.selected_state.text = app.PHASE_NAMES.get(phase, phase)
	app.selected_detail.text = "空桌" if guest.is_empty() else "%s #%d · 耐心 %d 秒 · %s" % [app.SPECIES_NAMES.get(guest.species, guest.species), guest.id, ceili(guest.patience), recipe_label]
	app.queue_label.text = "等候 %d / 8\n%s" % [model.queue_ids().size(), app.notice]
	var worker_lines: Array[String] = []
	for worker: Dictionary in model.workers:
		var text: String = "空闲" if worker.state == "idle" else "返回"
		for task: Dictionary in model.tasks:
			if int(task.id) == int(worker.task_id): text = "%s %s" % [model.tables[int(task.table_id) - 1].label, {"food":"送料理", "drink":"送饮品", "clean":"收拾"}.get(task.kind, task.kind)]
		worker_lines.append("%s：%s" % [app.SPECIES_NAMES.get(worker.species, worker.species), text])
	app.workers_label.text = "\n".join(worker_lines)
	app.kitchen_label.text = "厨房：%s · 任务 %d" % [(str(model.tables[int(model.chef.table_id) - 1].label) + " 制作中") if cooking else "等待点单", model.tasks.size()]
	for i in range(model.tables.size()):
		var item: Dictionary = model.tables[i]
		app.order_buttons[i].text = "%s · %s" % [item.label, app.PHASE_NAMES.get(item.phase, item.phase)]
	var setting_status: String = app.notice if str(app.notice).begins_with("音乐设置") else app.save_label.text
	settings_save_label.text = setting_status + "\n暂停 P · 保存 S · 确认点单 空格"
	if not app.save_allowed:
		help_label.text = "进度文件已保护 · 请查看设置"
	elif str(app.save_label.text).contains("保存失败"):
		help_label.text = "保存未成功 · 请查看设置"
	elif model.paused:
		help_label.text = "休息一下"
	else:
		help_label.text = "有订单等你下厨，点客人继续做饭" if model.interactive_cooking and _has_action("cook") else ("点客人，确认菜品后去做饭" if _has_action("order") else "客人会自己进来，坐好再点单")

func _has_action(action: String) -> bool:
	for table: Dictionary in app.model.tables:
		if app.model.table_action(table.id) == action: return true
	return false
