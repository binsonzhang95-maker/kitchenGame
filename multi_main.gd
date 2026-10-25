extends Node2D

const Model = preload("res://multi_model.gd")
const Room = preload("res://multi_view.gd")
const Dialogue = preload("res://dialogue_director.gd")
const BubbleLayer = preload("res://bubble_layer.gd")
const MusicController = preload("res://music_controller.gd")
const GameHUD = preload("res://game_hud.gd")
const CookingSession = preload("res://cooking_session.gd")
const CookingView = preload("res://cooking_view.gd")
const KitchenInputAdapter = preload("res://kitchen_input_adapter.gd")
const SFXController = preload("res://sfx_controller.gd")
const ToySimulatorView = preload("res://toy_simulator_view.gd")
const P0Assets = preload("res://p0_assets.gd")
const Localization = preload("res://localization.gd")
const RecipeCatalog = preload("res://recipe_catalog.gd")
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
var sfx_button: Button
var sfx_slider: HSlider
var sfx_level: Label
var save_path: String = SAVE_PATH
var seed_guests: bool = true
## Runtime-only P0 policy. Tests may inject classic before _ready().
@export_enum("p0", "classic") var menu_kind: String = "p0"
# Players confirm an order and cook it; service, payment and cleanup are automatic.
var player_mode: bool = true
var interactive_cooking: bool = true
var cooking_session: Variant = null
var cooking_view: Variant
var input_adapter: Variant
var sfx: Variant
var toy_simulator: Variant
var toy_simulator_enabled := false
var completion_layer: CanvasLayer
var completion_card: Control
var completion_dish: TextureRect
var completion_tween: Tween
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
	Localization.initialize()
	Localization.set_locale("zh_CN")
	RenderingServer.set_default_clear_color(Color("f7f2e7"))
	var restored_save := false
	if FileAccess.file_exists(save_path):
		if model.load_from(save_path):
			restored_save = true
			notice = "已恢复多桌营业进度，任务与付款记录一并恢复。"
		else:
			save_allowed = false
			notice = "存档版本或内容异常，已保护原文件；本次不会覆盖保存。"
	# This is intentionally after restore: stored table recipe ids are historical,
	# while the runtime menu only chooses recipes for guests seated from now on.
	model.set_order_menu(Model.P0_MENU if menu_kind == "p0" else Model.CLASSIC_MENU)
	if not restored_save and seed_guests:
		for i in range(3): model.spawn_customer()
	if player_mode:
		model.enable_player_mode()
		if interactive_cooking: model.enable_interactive_cooking()
	music = MusicController.acquire(get_tree(), save_path + ".audio.json")
	music.set_paused(model.paused)
	input_adapter = KitchenInputAdapter.new()
	input_adapter.use_screen() # Restored games always begin as screen input.
	sfx = SFXController.new()
	add_child(sfx)
	# Accept both editor arguments and `godot -- --toy-simulator`.
	toy_simulator_enabled = OS.get_cmdline_args().has("--toy-simulator") or OS.get_cmdline_user_args().has("--toy-simulator")
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
	toy_simulator = ToySimulatorView.new()
	add_child(toy_simulator)
	toy_simulator.command_requested.connect(_toy_command)
	toy_simulator.event_requested.connect(_toy_event)
	_build_completion_brief()
	if not model.active_cooking.is_empty(): _restore_cooking()
	_refresh()

func set_locale(locale: String) -> bool:
	if not Localization.set_locale(locale): return false
	if is_instance_valid(hud): hud.apply_locale()
	if is_instance_valid(cooking_view): cooking_view.refresh_art()
	_refresh()
	return true

func set_menu_kind(kind: String) -> bool:
	if kind not in ["p0", "classic"]: return false
	menu_kind = kind
	var changed := model.set_order_menu(Model.P0_MENU if kind == "p0" else Model.CLASSIC_MENU)
	if changed: notice = "新品菜单只影响之后入座的客人。" if kind == "p0" else "经典菜单只影响之后入座的客人。"
	_refresh()
	return changed

func _build_ui() -> void:
	hud = GameHUD.new()
	add_child(hud)
	hud.setup(self)

func _process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	_sync_toy_input_capture()
	if cooking_session != null:
		var before_tick: Dictionary = cooking_session.to_dict()
		# Hold covers the whole timer, including ready, not just heat progress.
		var hold_reason: String = _cooking_hold_reason()
		if hold_reason.is_empty():
			cooking_session.tick(delta)
		if cooking_session.completed:
			if not _finish_cooking(): cooking_session.restore(before_tick)
		elif hold_reason.is_empty():
			# Timed progress is business state too; reject it if the binding changed.
			if not model.sync_cooking(cooking_session.to_dict(), cooking_token):
				cooking_session.restore(before_tick)
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
	if cooking_session != null and is_instance_valid(toy_simulator) and toy_simulator.is_open():
		toy_simulator.sync(input_adapter.state(), cooking_session.status())


func _cooking_view_context() -> Dictionary:
	if cooking_session == null:
		return {"cooking_token": -1}
	var hold: String = _cooking_hold_reason()
	return {"recipe_label": Localization.text(RecipeCatalog.name_key(cooking_session.recipe_id)), "table_label": Localization.text("restaurant_table_label", {"table":int(cooking_session.binding.table_id)}), "cooking_token": cooking_token, "visual_paused": cooking_session.paused or not hold.is_empty()}

func _cooking_hold_reason() -> String:
	if cooking_session == null or input_adapter == null: return ""
	var status: Dictionary = cooking_session.status()
	var hold: String = str(input_adapter.hold_reason(status))
	if not hold.is_empty(): return hold
	# A ready dish can still age into retry. Do not let that happen after its
	# selected simulator disconnects or before it has been aligned again.
	var adapter_state: Dictionary = input_adapter.state()
	if str(status.get("phase", "")) == "ready" and str(adapter_state.get("source", "screen")) == "simulator":
		var connection: String = str(adapter_state.get("connection", "disconnected"))
		if connection == "disconnected": return "simulator_disconnected"
		if connection == "aligning": return "simulator_aligning"
	return ""

func _sync_toy_input_capture() -> void:
	if not is_instance_valid(cooking_view) or not is_instance_valid(toy_simulator): return
	# CookingView owns Escape in _input. While the simulator modal is open, let
	# Main close that first instead of cancelling the dish.
	cooking_view.set_process_input(not toy_simulator.is_open())

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
	# Binding happens exactly once after restore and assignment; it invalidates old
	# local toy authority without putting connection information in a save.
	input_adapter.bind(str(cooking_token))
	input_adapter.use_screen()
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
	_hide_completion_brief()
	if not _restore_cooking(): return false
	cooldown = 0.3
	notice = "餐厅先停一停，专心完成这份料理。"
	_save()
	return true

func _cooking_action(action: String, _payload: Dictionary = {}) -> Dictionary:
	var rejected := {"committed":false, "action":action, "feedback":"commit_rejected"}
	if cooking_session == null: return rejected
	if action == "return":
		if cooking_session.completed and _finish_cooking(): return {"committed":true, "action":action, "feedback":"committed"}
		return rejected
	if action == "cancel":
		return {"committed":_cancel_cooking(), "action":action, "feedback":"committed" if cooking_session == null else "commit_rejected"}
	var before: Dictionary = cooking_session.to_dict()
	if not cooking_session.act(action): return rejected
	if cooking_session.completed:
		# Completion is business-synchronous; the visual layer never completes it.
		if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
		if _finish_cooking(): return {"committed":true, "action":action, "feedback":"committed"}
		# Model rejection is a transaction rejection, so restore local state exactly.
		if cooking_session != null: cooking_session.restore(before)
		return rejected
	# Commit the real step before acknowledging it. Save failure does not undo a
	# successful business commit and must not cause an action replay.
	if not model.sync_cooking(cooking_session.to_dict(), cooking_token):
		cooking_session.restore(before)
		return rejected
	if action in ["clear", "retry"]:
		input_adapter.reset_preparation()
		if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
	_save()
	_refresh()
	_play_step_sfx(action)
	if is_instance_valid(cooking_view): cooking_view.play_visual_feedback(action, cooking_token)
	return {"committed":true, "action":action, "feedback":"committed"}

func _finish_cooking() -> bool:
	if cooking_session == null or not cooking_session.completed: return false
	var completed_recipe: String = str(cooking_session.recipe_id)
	if not model.complete_cooking(cooking_session.to_dict(), cooking_token):
		notice = "料理与当前订单不匹配，未送餐或计费。"
		return false
	if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
	# Revoke the old device before the next order can be selected.
	input_adapter.bind("")
	input_adapter.use_screen()
	cooking_session = null
	cooking_token = 0
	cooking_view.visible = false
	if is_instance_valid(toy_simulator): toy_simulator.close()
	_sync_toy_input_capture()
	music.set_paused(model.paused)
	notice = "做好啦！服务员会送餐、收款，再把桌子收拾好。"
	cooldown = 0.3
	_save()
	_refresh()
	sfx.play("dish_complete")
	_show_completion_brief(completed_recipe)
	return true

func _cancel_cooking() -> bool:
	if cooking_session == null: return false
	if not model.cancel_cooking(cooking_token): return false
	if is_instance_valid(cooking_view): cooking_view.clear_visual_feedback()
	input_adapter.bind("")
	input_adapter.use_screen()
	cooking_session = null
	cooking_token = 0
	cooking_view.visible = false
	if is_instance_valid(toy_simulator): toy_simulator.close()
	_sync_toy_input_capture()
	music.set_paused(model.paused)
	notice = "已返回餐厅，订单还在；点这位客人继续做饭。"
	cooldown = 0.3
	_save()
	_refresh()
	sfx.play("ui_back")
	return true

func _pause_cooking() -> void:
	if cooking_session == null: return
	cooking_session.set_paused(not cooking_session.paused)
	if not model.sync_cooking(cooking_session.to_dict(), cooking_token):
		cooking_session.set_paused(not cooking_session.paused)
		return
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
		save_label.text = Localization.text("ui_save_protected")
		return
	var error: Error = model.save_to(save_path)
	save_label.text = Localization.text("ui_save_success") if error == OK else Localization.text("ui_save_failed", {"error":error})

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if toy_simulator != null and toy_simulator.is_open() and event.keycode == KEY_ESCAPE:
		toy_simulator.close()
		_sync_toy_input_capture()
		get_viewport().set_input_as_handled()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if cooking_session != null:
		if event.keycode == KEY_F3 and toy_simulator_enabled:
			_open_toy_simulator()
			return
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

func _toggle_sfx() -> void:
	if sfx == null: return
	sfx.set_enabled(not bool(sfx.get_debug_state().get("enabled", true)))
	_refresh()

func _sfx_volume_changed(value: float) -> void:
	if sfx != null: sfx.set_volume(value / 100.0)
	_refresh()

func _open_toy_simulator() -> void:
	if cooking_session == null or not toy_simulator_enabled: return
	if is_instance_valid(hud): hud.debug_root.visible = false
	toy_simulator.open()
	_sync_toy_input_capture()
	_refresh()

func _toy_command(command: String) -> void:
	if cooking_session == null: return
	match command:
		"connect":
			input_adapter.connect_simulator()
			sfx.play("toy_connected")
		"disconnect":
			input_adapter.disconnect_simulator()
			sfx.play("toy_disconnected")
		"screen":
			input_adapter.use_screen()
			sfx.play("ui_back")
	_refresh()

func _toy_event(type: String, payload: Dictionary) -> void:
	if cooking_session == null or not toy_simulator_enabled: return
	var event: Dictionary = input_adapter.event_envelope()
	event.type = type
	for key: String in payload:
		event[key] = payload[key]
	receive_toy_event(event)

## Full bridge events are validation input, never a convenience API. Missing
## envelope fields must reach the adapter unchanged and be rejected there.
func receive_toy_event(event: Dictionary) -> Dictionary:
	var rejected := {"committed":false, "action":"", "feedback":"commit_rejected"}
	if cooking_session == null or input_adapter == null: return rejected
	var result: Dictionary = input_adapter.handle(event, cooking_session.status())
	var feedback := str(result.get("feedback", ""))
	if feedback == "unknown_card": sfx.play("card_unknown")
	elif feedback in ["not_needed", "wrong_zone"]: sfx.play("card_not_needed")
	if str(result.get("action", "")).is_empty():
		if is_instance_valid(toy_simulator) and toy_simulator.is_open(): toy_simulator.sync(input_adapter.state(), cooking_session.status(), feedback)
		_refresh()
		return {"committed":false, "action":"", "feedback":feedback}
	# A candidate is never success. Only the committed Main path can acknowledge it.
	var action := str(result.action)
	var committed: Dictionary = _cooking_action(action)
	var final_feedback: String = "committed" if bool(committed.get("committed", false)) else "commit_rejected"
	if is_instance_valid(toy_simulator) and toy_simulator.is_open() and cooking_session != null:
		toy_simulator.sync(input_adapter.state(), cooking_session.status(), final_feedback)
	_refresh()
	return {"committed":bool(committed.get("committed", false)), "action":action, "feedback":final_feedback}

func _play_step_sfx(action: String) -> void:
	if sfx == null or action in ["clear", "retry", "cancel"]: return
	sfx.play("step_complete")

func _build_completion_brief() -> void:
	completion_layer = CanvasLayer.new()
	completion_layer.layer = 40
	add_child(completion_layer)
	completion_card = Panel.new()
	completion_card.theme = Localization.theme()
	completion_card.position = Vector2(634, 116)
	completion_card.size = Vector2(268, 116)
	completion_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var skin := StyleBoxFlat.new()
	skin.bg_color = Color("fff5dc")
	skin.bg_color.a = 0.96
	skin.border_color = Color("a28b62")
	skin.set_border_width_all(3)
	skin.set_corner_radius_all(4)
	completion_card.add_theme_stylebox_override("panel", skin)
	completion_layer.add_child(completion_card)
	completion_dish = TextureRect.new()
	completion_dish.position = Vector2(18, 16)
	completion_dish.size = Vector2(84, 84)
	completion_dish.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	completion_dish.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	completion_dish.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	completion_dish.mouse_filter = Control.MOUSE_FILTER_IGNORE
	completion_card.add_child(completion_dish)
	var badge := TextureRect.new()
	badge.texture = load("res://assets/ui/toy/completion.png") as Texture2D
	badge.position = Vector2(104, 18)
	badge.size = Vector2(38, 38)
	badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	completion_card.add_child(badge)
	var label := Label.new()
	label.name = "CompletionRecipe"
	label.position = Vector2(148, 26)
	label.size = Vector2(108, 62)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	completion_card.add_child(label)
	completion_card.hide()

func _hide_completion_brief() -> void:
	if completion_tween != null:
		if completion_tween.is_valid(): completion_tween.kill()
		completion_tween = null
	if completion_card != null: completion_card.hide()

func _show_completion_brief(recipe: String) -> void:
	if completion_card == null: return
	_hide_completion_brief()
	# Legacy recipes retain their completion badge but deliberately have no P0 dish
	# art: substituting another recipe's dish would be misleading.
	var asset_key := str({"pumpkin_corn_soup":"dish_pumpkin_corn_soup", "pan_fried_mushrooms":"dish_pan_fried_mushrooms", "bake":"dish_bake", "drink":"dish_drink"}.get(recipe, ""))
	completion_dish.texture = P0Assets.new().texture(asset_key) if not asset_key.is_empty() else null
	var label := completion_card.get_node_or_null("CompletionRecipe") as Label
	if label != null: label.text = Localization.text(RecipeCatalog.name_key(recipe))
	completion_card.theme = Localization.theme()
	completion_card.modulate = Color.WHITE
	completion_card.scale = Vector2.ONE * 0.82
	completion_card.show()
	var tween := create_tween()
	completion_tween = tween
	tween.tween_property(completion_card, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(completion_card, "modulate:a", 1.0, 0.06)
	tween.tween_property(completion_card, "modulate:a", 0.0, 0.06).set_delay(0.22)
	tween.finished.connect(func() -> void:
		if completion_tween != tween: return
		completion_card.hide()
		completion_tween = null
	)

func _music_volume_changed(value: float) -> void:
	music.set_volume(value / 100.0)
	_persist_music()
	_refresh()

func _persist_music() -> void:
	var error: Error = music.save_settings()
	if error != OK:
		notice = "音乐设置本次有效；原设置文件受保护或暂时无法保存。"
