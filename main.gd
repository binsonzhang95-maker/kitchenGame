extends Node2D

const Model = preload("res://game_model.gd")
const Room = preload("res://restaurant_view.gd")
const SAVE_PATH := "user://restaurant_save_v1.json"
const INK := Color("574638")
const GREEN := Color("627c60")
const PHASE_COPY := {
	"entering": ["欢迎光临", "一位猫客人正走进食堂。", "客人进店中…"],
	"queued": ["门口有人等候", "空桌已经备好，带客人入座吧。", "带客人入座"],
	"seating": ["请坐这里", "猫客人找到椅子，慢慢坐下。", "正在入座…"],
	"ordering": ["今天想吃什么？", "招牌咖喱饭 × 1\n冰麦茶 × 1\n\n套餐价格  38 金币", "记录点单"],
	"awaiting_cook": ["订单送到厨房", "兔服务员记好了。\n请让熊厨师开始做饭。", "开始制作"],
	"cooking": ["小火慢慢煮", "熊厨师正在准备热腾腾的咖喱。", "厨房制作中…"],
	"food_ready": ["咖喱饭做好了", "托盘已备好，请兔服务员送餐。", "端盘送餐"],
	"serving_food": ["热饭送到桌边", "兔服务员正在端盘、放菜。", "正在送餐…"],
	"waiting_drink": ["还差一杯麦茶", "饭已上桌，再送一杯清凉麦茶。", "送上饮料"],
	"serving_drink": ["麦茶马上就到", "端杯到桌边，轻轻放下。", "正在送饮料…"],
	"eating": ["好好吃饭的时间", "猫客人正在享用咖喱饭。", "客人用餐中…"],
	"drinking": ["最后一口麦茶", "喝完之后，杯子会留在桌上。", "客人喝茶中…"],
	"checkout": ["谢谢款待", "客人已吃饱喝足。\n本单应收 38 金币。", "结账  +38"],
	"leaving": ["下次再来呀", "客人正在离店。", "客人离店中…"],
	"dirty": ["把桌子收拾好", "先收走杯盘，再用抹布擦桌。", "收杯盘 · 擦桌"],
	"collecting": ["收走杯盘", "兔服务员拿起餐具，收好杯盘。", "正在收餐具…"],
	"wiping": ["擦得干干净净", "抹布来回擦拭，清除桌面污渍。", "正在擦桌…"],
	"ready_next": ["一桌新的期待", "桌椅已归位。\n准备迎接下一位客人吧。", "迎接下一位"]
}
var model = Model.new()
var save_path: String = SAVE_PATH
var room
var headline: Label
var detail: Label
var phase_number: Label
var coins_label: Label
var stats_label: Label
var patience_label: Label
var patience_bar: ProgressBar
var progress_bar: ProgressBar
var primary: Button
var pause_button: Button
var save_label: Label
var log_label: Label
var room_caption: Label
var pause_overlay: Panel
var log_lines: Array[String] = []
var last_phase := ""
var save_clock := 0.0
var action_cooldown := 0.0
var anim_clock := 0.0
var steps: Array[Label] = []

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	RenderingServer.set_default_clear_color(Color("f7f2e7"))
	if FileAccess.file_exists(save_path):
		if model.load_from(save_path):
			log_lines.append("已恢复上次营业进度")
		else:
			log_lines.append("旧存档无法读取，已开启新一桌")
	_build_ui()
	room = Room.new()
	room.model = model
	room.position = Vector2(32, 176)
	room.scale = Vector2(2, 2)
	add_child(room)
	move_child(room, 0)
	last_phase = model.phase
	_refresh()

func _style(color: Color, radius: int = 12, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0 else 0)
	s.content_margin_left = 16
	s.content_margin_right = 16
	return s

func _panel(pos: Vector2, dimensions: Vector2, color: Color, radius: int = 16) -> Panel:
	var panel := Panel.new()
	panel.position = pos
	panel.size = dimensions
	panel.add_theme_stylebox_override("panel", _style(color, radius))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.z_index = -2
	add_child(panel)
	return panel

func _label(text: String, pos: Vector2, dimensions: Vector2, font_size: int = 20, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.size = dimensions
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _button(text: String, pos: Vector2, dimensions: Vector2, callback: Callable, filled: bool = false) -> Button:
	var button := Button.new()
	button.position = pos
	button.size = dimensions
	button.text = text
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_color_override("font_color", Color("fffaf0") if filled else INK)
	button.add_theme_color_override("font_hover_color", Color("fffaf0") if filled else INK)
	button.add_theme_color_override("font_pressed_color", Color("fffaf0") if filled else INK)
	button.add_theme_color_override("font_disabled_color", Color("98988a"))
	button.add_theme_stylebox_override("normal", _style(GREEN if filled else Color("efe7d8"), 10))
	button.add_theme_stylebox_override("hover", _style(Color("728e6c") if filled else Color("e6ddca"), 10))
	button.add_theme_stylebox_override("pressed", _style(Color("4f674d") if filled else Color("dcd1b9"), 10))
	button.add_theme_stylebox_override("disabled", _style(Color("e4e7d9"), 10))
	button.add_theme_stylebox_override("focus", _style(Color(0, 0, 0, 0), 10, Color("c49b54")))
	button.pressed.connect(callback)
	add_child(button)
	return button

func _bar(pos: Vector2, dimensions: Vector2, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.position = pos
	bar.size = dimensions
	bar.show_percentage = false
	bar.add_theme_font_size_override("font_size", 1)
	bar.add_theme_stylebox_override("background", _style(Color("e9e3d4"), 4))
	bar.add_theme_stylebox_override("fill", _style(color, 4))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	bar.size = dimensions
	return bar

func _build_ui() -> void:
	_label("MORI DINER  /  营业手记", Vector2(34, 21), Vector2(800, 24), 15, GREEN)
	_label("小森食堂", Vector2(30, 49), Vector2(800, 55), 38)
	_label("一张小桌，认真招待每一位客人。", Vector2(33, 113), Vector2(820, 30), 19, Color("8b7b66"))
	_panel(Vector2(1092, 32), Vector2(236, 72), Color("eee4c8"))
	coins_label = _label("", Vector2(1114, 40), Vector2(196, 52), 28)
	stats_label = _label("", Vector2(1015, 117), Vector2(316, 27), 16, Color("8b7b66"))
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_panel(Vector2(24, 168), Vector2(976, 592), Color("dac8a6"), 8)
	# The room is inserted behind these overlay labels.
	room_caption = _label("", Vector2(34, 147), Vector2(940, 20), 14, Color("6d7657"))
	_label("01  /  窗边小桌", Vector2(54, 716), Vector2(440, 28), 16, Color("776249"))
	_panel(Vector2(1024, 176), Vector2(304, 576), Color("fffdf6"))
	phase_number = _label("", Vector2(1048, 197), Vector2(250, 24), 14, GREEN)
	headline = _label("", Vector2(1048, 233), Vector2(258, 40), 24)
	detail = _label("", Vector2(1048, 287), Vector2(256, 144), 17, Color("8a795f"))
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	patience_label = _label("", Vector2(1048, 437), Vector2(256, 25), 15, Color("8a795f"))
	patience_bar = _bar(Vector2(1048, 471), Vector2(256, 8), Color("a4b18b"))
	progress_bar = _bar(Vector2(1048, 500), Vector2(256, 4), Color("bd9b6a"))
	primary = _button("", Vector2(1048, 525), Vector2(256, 58), _primary, true)
	pause_button = _button("暂停", Vector2(1048, 600), Vector2(122, 43), _pause)
	_button("保存", Vector2(1182, 600), Vector2(122, 43), _manual_save)
	save_label = _label("自动保存已开启", Vector2(1048, 662), Vector2(256, 22), 13, Color("9d907b"))
	_label("空格 推进  ·  P 暂停  ·  S 保存", Vector2(1048, 704), Vector2(256, 22), 13, Color("9d907b"))
	for i in range(6):
		var chip := _label(["01  迎客", "02  点单", "03  送餐", "04  吃喝", "05  结账", "06  清桌"][i], Vector2(36 + i * 158, 779), Vector2(150, 30), 16, Color("aaa18e"))
		steps.append(chip)
	log_label = _label("", Vector2(36, 825), Vector2(1290, 25), 14, Color("8b7b66"))
	pause_overlay = _panel(Vector2(32, 176), Vector2(960, 576), Color(0.22, 0.28, 0.21, 0.74), 0)
	pause_overlay.z_index = 20
	var pause_text := Label.new()
	pause_text.text = "营业暂停\n\n点「继续」或按 P 回来"
	pause_text.position = Vector2(240, 225)
	pause_text.size = Vector2(480, 120)
	pause_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_text.add_theme_font_size_override("font_size", 26)
	pause_text.add_theme_color_override("font_color", Color("fff7df"))
	pause_overlay.add_child(pause_text)

func _process(delta: float) -> void:
	action_cooldown = maxf(0, action_cooldown - delta)
	model.tick(delta)
	if not model.paused:
		anim_clock += delta
	room.clock = anim_clock
	room.queue_redraw()
	if model.phase != last_phase:
		if model.phase == "leaving":
			_note("第 %d 位客人 · %s" % [model.customer_id, "已结账 +38 金币" if model.paid else "等候超时，离开食堂"])
		elif model.phase == "ready_next":
			_note("小桌已空出，可以继续迎客")
		last_phase = model.phase
		_save(false)
	save_clock += delta
	if save_clock >= 2.0:
		_save(false)
	_refresh()

func _refresh() -> void:
	var copy: Array = PHASE_COPY[model.phase]
	headline.text = copy[0]
	detail.text = copy[1]
	if model.phase == "leaving" and not model.paid:
		headline.text = "等得有点久了"
		detail.text = "猫客人耐心耗尽，遗憾离开。\n这单没有收入。"
	primary.text = copy[2]
	primary.disabled = model.paused or action_cooldown > 0 or model.available_action().is_empty()
	pause_button.text = "继续" if model.paused else "暂停"
	pause_overlay.visible = model.paused
	coins_label.text = "●  %d  金币" % model.coins
	stats_label.text = "已招待 %d 位   ·   离开 %d 位" % [model.served, model.lost]
	phase_number.text = "第 %02d 位客人  /  猫" % model.customer_id
	patience_bar.value = model.patience / Model.MAX_PATIENCE * 100.0
	patience_label.text = "客人耐心  %d 秒" % ceili(model.patience)
	if model.phase in ["eating", "drinking", "leaving", "dirty", "collecting", "wiping", "ready_next"]:
		patience_label.text = "慢慢享用，好好招待" if model.phase in ["eating", "drinking"] else "一桌一客 · 从容营业"
	patience_label.modulate = Color("ba6e50") if model.patience < 15 and model.phase not in ["dirty", "ready_next"] else Color.WHITE
	progress_bar.visible = Model.PHASE_SECONDS.has(model.phase)
	if progress_bar.visible:
		progress_bar.value = clampf(model.elapsed / float(Model.PHASE_SECONDS[model.phase]), 0, 1) * 100.0
	var step := _step()
	for i in range(steps.size()):
		steps[i].add_theme_color_override("font_color", GREEN if i == step else Color("aaa18e"))
	room_caption.text = "熊的厨房                             窗边小桌 · %s" % ("已坐稳" if model.table_used else "等待客人")
	log_label.text = "  ·  ".join(log_lines)

func _step() -> int:
	match model.phase:
		"entering", "queued", "seating": return 0
		"ordering", "awaiting_cook", "cooking": return 1
		"food_ready", "serving_food", "waiting_drink", "serving_drink": return 2
		"eating", "drinking": return 3
		"checkout", "leaving": return 4
	return 5

func _primary() -> void:
	if action_cooldown > 0:
		return
	if model.advance(model.available_action()):
		action_cooldown = 0.35
		_save(false)
		_refresh()

func _pause() -> void:
	model.paused = not model.paused
	_save(false)
	_refresh()

func _manual_save() -> void:
	_save(true)

func _save(manual: bool) -> void:
	var result: Error = model.save_to(save_path)
	save_clock = 0.0
	if result == OK:
		save_label.text = "已保存 · 包括当前营业进度"
		if manual:
			_note("营业进度已保存")
	else:
		save_label.text = "保存失败（错误 %d），请勿关闭" % result

func _note(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 3:
		log_lines.pop_front()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE: _primary()
		KEY_P, KEY_ESCAPE: _pause()
		KEY_S: _manual_save()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		model.save_to(save_path)
		get_tree().quit()
