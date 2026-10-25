extends Node2D

const Model = preload("res://multi_model.gd")
const Room = preload("res://multi_view.gd")
const Dialogue = preload("res://dialogue_director.gd")
const BubbleLayer = preload("res://bubble_layer.gd")
const MusicController = preload("res://music_controller.gd")
const GameHUD = preload("res://game_hud.gd")
const CookingSession = preload("res://cooking_session.gd")
const CookingView = preload("res://cooking_view.gd")
const SAVE_PATH := "user://restaurant_multi_save_v2.json"
const INK := Color("574638")
const GREEN := Color("627c60")
const PHASE_NAMES := {
	"free": "空桌", "reserved": "正在入座", "ordering": "等待点单", "awaiting_cook": "等待制作",
	"cooking": "厨房制作", "food_ready": "等待送餐", "serving_food": "送餐中", "waiting_drink": "等待饮料",
	"serving_drink": "送饮料中", "eating": "用餐中", "drinking": "喝茶中", "checkout": "等待结账",
	"leaving": "正在离店", "dirty": "等待清桌", "collecting": "收杯盘", "wiping": "擦桌中"
}
const SPECIES_NAMES := {"cat":"猫", "dog":"狗", "panda":"熊猫", "raccoon":"浣熊", "red_panda":"小熊猫", "squirrel":"松鼠", "hedgehog":"刺猬", "otter":"水獭", "capybara":"水豚", "koala":"考拉", "deer":"鹿", "sheep":"绵羊", "pig":"小猪", "hamster":"仓鼠", "penguin":"企鹅", "duck":"鸭", "frog":"青蛙", "rabbit":"兔", "fox":"狐"}
var model = Model.new()
var dialogues = Dialogue.new()
var bubble_layer: Variant
var music: Variant
var hud: Variant
var music_button: Button
var music_slider: HSlider
var music_level: Label
var save_path: String = SAVE_PATH
var seed_guests: bool = true
# Players confirm an order and cook it; service, payment and cleanup are automatic.
var player_mode: bool = true
var interactive_cooking: bool = true
var cooking_session: Variant = null
var cooking_view: Variant
var cooking_token: int = 0
var selected_table: int = 1
var room: Variant
var clock: float = 0.0
var cooldown: float = 0.0
var save_clock: float = 0.0
var order_clock: float = 0.0
var save_allowed: bool = true
var stats: Label
var selected_title: Label
var selected_state: Label
var selected_detail: Label
var patience_bar: ProgressBar
var primary: Button
var pause_button: Button
var arrival_button: Button
var seat_button: Button
var dispatch_button: Button
var auto_cook_button: Button
var capacity_button: Button
var dialogue_button: Button
var short_text_button: Button
var next_cook_button: Button
var queue_label: Label
var workers_label: Label
var kitchen_label: Label
var save_label: Label
var orders_box: VBoxContainer
var order_buttons: Array[Button] = []
var pause_overlay: Panel
var notice: String = "点客人确认菜品，再去小厨房亲手做一份。"

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	RenderingServer.set_default_clear_color(Color("f7f2e7"))
	if FileAccess.file_exists(save_path):
		if model.load_from(save_path):
			notice = "已恢复多桌营业进度，任务与付款记录一并恢复。"
		else:
			save_allowed = false
			notice = "存档版本或内容异常，已保护原文件；本次不会覆盖保存。"
	elif seed_guests:
		for i in range(3): model.spawn_customer()
	if player_mode:
		model.enable_player_mode()
		if interactive_cooking: model.enable_interactive_cooking()
	music = MusicController.acquire(get_tree(), save_path + ".audio.json")
	music.set_paused(model.paused)
	room = Room.new()
	room.model = model
	room.position = Vector2(0, 80)
	room.selected_table = selected_table
	room.table_selected.connect(_select_table)
	add_child(room)
	move_child(room, 0)
	bubble_layer = BubbleLayer.new()
	room.add_child(bubble_layer)
	_build_ui()
	cooking_view = CookingView.new()
	add_child(cooking_view)
	cooking_view.action_requested.connect(_cooking_action)
	cooking_view.cancel_requested.connect(_cancel_cooking)
	cooking_view.pause_requested.connect(_pause_cooking)
	cooking_view.visible = false
	if not model.active_cooking.is_empty(): _restore_cooking()
	_refresh()

func _build_ui() -> void:
	hud = GameHUD.new()
	add_child(hud)
	hud.setup(self)

func _process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	if cooking_session != null:
		cooking_session.tick(delta)
		if cooking_session.completed:
			_finish_cooking()
		else:
			model.sync_cooking(cooking_session.to_dict(), cooking_token)
	else:
		model.tick(delta)
	dialogues.tick(delta, model)
	bubble_layer.sync(dialogues, model)
	if not model.paused: clock += delta
	room.clock = clock
	room.selected_table = selected_table if hud._selection_open else 0
	room.queue_redraw()
	save_clock += delta
	if save_clock >= 3.0: _save()
	_refresh()

func _refresh() -> void:
	if is_instance_valid(hud): hud.refresh()
	if cooking_session != null and is_instance_valid(cooking_view):
		cooking_view.sync(cooking_session, _cooking_view_context())


func _cooking_view_context() -> Dictionary:
	if cooking_session == null:
		return {"cooking_token": -1}
	return {"recipe_label": CookingSession.recipe_label(cooking_session.recipe_id), "table_label": model.tables[int(cooking_session.binding.table_id)-1].label, "cooking_token": cooking_token}

func _select_table(id: int) -> void:
	if cooking_session != null: return
	selected_table = clampi(id, 1, 20)
	if is_instance_valid(hud): hud.select_table()
	_refresh()

func _focus_next_order() -> void:
	if model.paused or hud.settings_root.visible or hud.debug_root.visible: return
	for table: Dictionary in model.tables:
		if model.table_action(table.id) in (["order", "cook"] if model.interactive_cooking else ["order"]):
			_select_table(int(table.id))
			return
	notice = "客人会自己进来，坐好后再帮他们点单。"
	_refresh()

func _primary() -> void:
	if cooldown > 0 or model.paused or cooking_session != null: return
	var action: String = model.table_action(selected_table)
	var manual_actions: Array = ["order", "cook"] if model.interactive_cooking else ["order"]
	if player_mode and (action not in manual_actions or not hud._selection_open or hud.settings_root.visible or hud.debug_root.visible): return
	if action == "cook" and model.interactive_cooking:
		_begin_cooking(selected_table)
	elif model.act(selected_table, action):
		cooldown = 0.3
		if action == "order":
			if model.interactive_cooking:
				_begin_cooking(selected_table)
			else:
				notice = "点好啦，厨房会做好送来。"
		_save()
	_refresh()

func _restore_cooking() -> bool:
	var restored = CookingSession.new()
	if not restored.restore(model.active_cooking):
		notice = "厨房进度异常，已保护原存档。"
		save_allowed = false
		return false
	cooking_session = restored
	cooking_token = model.cooking_session_token
	selected_table = int(restored.binding.table_id)
	hud._selection_open = false
	hud.settings_root.visible = false
	hud.debug_root.visible = false
	cooking_view.visible = true
	music.set_paused(cooking_session.paused)
	_refresh()
	return true

func _begin_cooking(table_id: int) -> bool:
	if cooking_session != null or not model.begin_cooking(table_id): return false
	if not _restore_cooking(): return false
	cooldown = 0.3
	notice = "餐厅先停一停，专心完成这份料理。"
	_save()
	return true

func _cooking_action(action: String, _payload: Dictionary = {}) -> void:
	if cooking_session == null: return
	if action == "return":
		if cooking_session.completed: _finish_cooking()
		return
	if action == "cancel":
		_cancel_cooking()
		return
	if not cooking_session.act(action):
		return
	if cooking_session.completed:
		# Completion stays synchronous: it must return to the dining room now and
		# never wait for a purely visual kitchen effect.
		cooking_view.clear_visual_feedback()
		_finish_cooking()
		return
	# Commit the real kitchen step before permitting its visual acknowledgement.
	# The transient view player never calls act(), completes an order, or saves.
	if not model.sync_cooking(cooking_session.to_dict(), cooking_token):
		return
	_save()
	_refresh()
	if is_instance_valid(cooking_view):
		cooking_view.play_visual_feedback(action, cooking_token)

func _finish_cooking() -> bool:
	if cooking_session == null or not cooking_session.completed: return false
	if not model.complete_cooking(cooking_session.to_dict(), cooking_token):
		notice = "料理与当前订单不匹配，未送餐或计费。"
		return false
	if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
	cooking_session = null
	cooking_token = 0
	cooking_view.visible = false
	music.set_paused(model.paused)
	notice = "做好啦！服务员会送餐、收款，再把桌子收拾好。"
	cooldown = 0.3
	_save()
	_refresh()
	return true

func _cancel_cooking() -> void:
	if cooking_session == null: return
	if not model.cancel_cooking(cooking_token): return
	if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
	cooking_session = null
	cooking_token = 0
	cooking_view.visible = false
	music.set_paused(model.paused)
	notice = "已返回餐厅，订单还在；点这位客人继续做饭。"
	cooldown = 0.3
	_save()
	_refresh()

func _pause_cooking() -> void:
	if cooking_session == null: return
	cooking_session.set_paused(not cooking_session.paused)
	model.sync_cooking(cooking_session.to_dict(), cooking_token)
	music.set_paused(cooking_session.paused)
	_save()
	_refresh()

func _order_all() -> void:
	if player_mode: return
	if model.paused or cooldown > 0: return
	var count: int = 0
	for t in model.tables:
		if model.act(t.id, "order"): count += 1
	notice = "已记录 %d 桌点单。" % count
	cooldown = 0.3
	_save()

func _pay_all() -> void:
	if player_mode: return
	if model.paused or cooldown > 0: return
	var count: int = 0
	for t in model.tables:
		if model.act(t.id, "pay"): count += 1
	notice = "已结清 %d 桌，共收入 %d 金币。" % [count,count*38]
	cooldown = 0.3
	_save()

func _cook_next() -> void:
	if player_mode: return
	if model.paused or cooldown > 0: return
	if model.cook_next():
		notice = "熊主理人开始制作最早登记的订单。"
		cooldown = 0.3
	else: notice = "厨房正在制作，或还没有已登记的订单。"
	_save()

func _dispatch() -> void:
	if player_mode: return
	if model.paused or cooldown > 0: return
	for w in model.workers:
		for task in model.tasks:
			if model.claim_task(w.id, task.id): break
	cooldown = 0.3
	_save()

func _invite() -> void:
	if player_mode: return
	if model.paused or cooldown > 0: return
	var id: int = model.spawn_customer()
	notice = "新客人已到门口。" if id > 0 else "队列或在店人数已满，请先招待现有客人。"
	cooldown = 0.3
	_save()

func _pause() -> void:
	if cooking_session != null:
		_pause_cooking()
		return
	model.paused = not model.paused
	music.set_paused(model.paused)
	_save()
	_refresh()

func _toggle_arrivals() -> void:
	if player_mode: return
	if model.paused: return
	model.open_for_arrivals = not model.open_for_arrivals
	_save()

func _toggle_seating() -> void:
	if player_mode: return
	if model.paused: return
	model.auto_seat = not model.auto_seat
	notice = "自动分桌已%s；可点击空桌安排队首客人。" % ("开启" if model.auto_seat else "关闭")
	_save()

func _toggle_dispatch() -> void:
	if player_mode: return
	if model.paused: return
	model.auto_dispatch = not model.auto_dispatch
	_save()

func _toggle_cooking() -> void:
	if player_mode: return
	if model.paused: return
	model.auto_cook = not model.auto_cook
	_save()

func _cycle_capacity() -> void:
	if model.paused: return
	var choices: Array[int] = [6,10,14,20]
	model.max_customers = choices[(choices.find(model.max_customers)+1)%choices.size()]
	notice = "新的在店上限只影响后续进店，不会赶走已有客人。"
	_save()

func _manual_save() -> void:
	_save()

func _save() -> void:
	save_clock = 0.0
	if not save_allowed:
		save_label.text = "已保护异常存档，本次不覆盖"
		return
	if cooking_session != null and not model.sync_cooking(cooking_session.to_dict(), cooking_token):
		save_label.text = "保存失败：厨房订单绑定异常"
		return
	var error: Error = model.save_to(save_path)
	save_label.text = "营业进度已保存 · 独立多桌存档" if error == OK else "保存失败：%d" % error

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if cooking_session != null:
		if event.keycode == KEY_S: _manual_save()
		return
	match event.keycode:
		KEY_SPACE:
			if not hud.settings_root.visible and not hud.debug_root.visible:
				_primary()
		KEY_P: _pause()
		KEY_ESCAPE:
			if not hud.close_overlay(): _pause()
		KEY_F3: hud.toggle_debug()
		KEY_S: _manual_save()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if save_allowed: _save()
		get_tree().quit()

func _toggle_dialogues() -> void:
	dialogues.enabled = not dialogues.enabled
	bubble_layer.sync(dialogues, model)
	_refresh()

func _toggle_short_text() -> void:
	bubble_layer.show_short_text = not bubble_layer.show_short_text
	dialogues.show_short_text = bubble_layer.show_short_text
	for bubble in dialogues.bubbles:
		bubble.short_text = str(Dialogue.SHORT_TEXT.get(bubble.emotion, "")) if dialogues.show_short_text else ""
	bubble_layer.sync(dialogues, model)
	_refresh()

func _toggle_music() -> void:
	music.set_enabled(not music.enabled)
	_persist_music()
	_refresh()

func _music_volume_changed(value: float) -> void:
	music.set_volume(value / 100.0)
	_persist_music()
	_refresh()

func _persist_music() -> void:
	var error: Error = music.save_settings()
	if error != OK:
		notice = "音乐设置本次有效；原设置文件受保护或暂时无法保存。"
