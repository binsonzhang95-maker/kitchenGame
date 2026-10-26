extends CanvasLayer
## Local-only simulator surface. It only emits semantic controls; Main owns
## envelopes and CookingSession commits.
signal command_requested(command: String)
signal event_requested(type: String, payload: Dictionary)

const Localization = preload("res://localization.gd")
const VIEW_SIZE := Vector2(1536, 1152)
const INK := Color("594b39")
const PAPER := Color("fff5dc")
const EDGE := Color("a28b62")
const GREEN := Color("617c58")
const PANEL_KEYS := ["stove_level", "oven_level", "oven_open", "vessel", "faucet_open"]

var root: Control
var screen_blocker: Control
var _layout: Dictionary = {}
var state_icon: TextureRect
var state_label: Label
var need_icon: TextureRect
var need_label: Label
var _previous_connection := ""
var feedback_icon: TextureRect
var feedback_badge: Label
var feedback_label: Label
var connect_button: Button
var snapshot_button: Button
var screen_button: Button
var close_button: Button
var _adapter_state: Dictionary = {}
var _status: Dictionary = {}
var _panel := {"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false}
var _feedback := ""
var _feedback_time := 0.0
var _texture_cache: Dictionary = {}
var _buttons: Dictionary = {}
var _zone := "cutting_board"
var _locale_revision := -1
var _session_token := ""

func _ready() -> void:
	_build()
	hide()

func open() -> void:
	_build()
	show()
	_refresh()

func close() -> void:
	hide()

func is_open() -> bool:
	return visible

## Stable access point for independent GUI tests and future host UI wiring.
func button_for_event(event: String) -> Button:
	return _buttons.get(event) as Button

func sync(adapter_state: Dictionary, status: Dictionary, feedback: String = "") -> void:
	_build()
	_adapter_state = adapter_state.duplicate(true)
	_status = status.duplicate(true)
	var incoming_token := str(_adapter_state.get("token", ""))
	if not incoming_token.is_empty() and incoming_token != _session_token:
		_session_token = incoming_token
		_panel = _empty_panel()
		_feedback = ""
		_feedback_time = 0.0
	var connection := str(_adapter_state.get("connection", "disconnected"))
	var accepted_panel = _adapter_state.get("panel", {})
	# Do not take the adapter's cleared panel after disconnect/alignment as a knob.
	if connection == "connected" and accepted_panel is Dictionary and _valid_panel(accepted_panel):
		_panel = (accepted_panel as Dictionary).duplicate(true)
	if not feedback.is_empty():
		_feedback = feedback
		_feedback_time = 1.25
	_refresh()

func _process(delta: float) -> void:
	if root == null:
		return
	if _locale_revision != Localization.revision():
		_refresh()
	var paused := bool(_status.get("paused", false))
	var connection := str(_adapter_state.get("connection", "disconnected"))
	if connection == "aligning" and not paused:
		state_icon.rotation += delta * 0.9
	if paused or _feedback_time <= 0.0:
		return
	_feedback_time = maxf(0.0, _feedback_time - delta)
	if _feedback_time <= 0.0:
		_feedback = ""
		_refresh()

func _build() -> void:
	if root != null:
		return
	layer = 90
	screen_blocker = Control.new()
	screen_blocker.name = "ToySimulatorInputShield"
	screen_blocker.size = VIEW_SIZE
	screen_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(screen_blocker)
	root = Control.new()
	root.name = "LocalToySimulator"
	root.size = VIEW_SIZE
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(root)
	var panel := Panel.new()
	panel.name = "ToySimulatorPanel"
	panel.position = Vector2(946, 70)
	panel.size = Vector2(570, 1012)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _box(PAPER, EDGE, 3))
	root.add_child(panel)
	var title := _label(panel, "", Vector2(18, 16), Vector2(420, 34), 22, GREEN)
	title.name = "ToySimulatorTitle"
	close_button = _button(panel, "×", Vector2(498, 10), Vector2(52, 48), func(): close(), "ui_toy_close")
	_register("close", close_button)
	state_icon = _image(panel, "res://assets/ui/toy/disconnected_64.png", Vector2(20, 66), Vector2(54, 54))
	state_icon.pivot_offset = state_icon.size * 0.5
	state_label = _label(panel, "", Vector2(84, 72), Vector2(258, 28), 19)
	need_icon = _image(panel, "res://assets/ui/toy/finger_ready_32.png", Vector2(84, 101), Vector2(32, 22))
	need_label = _label(panel, "", Vector2(124, 98), Vector2(220, 28), 15, Color("78694f"))
	connect_button = _button(panel, "", Vector2(364, 70), Vector2(178, 48), _connection_pressed, "ui_toy_connection")
	_register("connection", connect_button)
	snapshot_button = _icon_button(panel, "res://assets/ui/toy/toy_controlled_64.png", Vector2(20, 130), Vector2(250, 52), _snapshot_pressed, "ui_toy_snapshot_tip")
	_register("snapshot", snapshot_button)
	screen_button = _icon_button(panel, "res://assets/ui/mobile/screen_play_64.png", Vector2(286, 130), Vector2(250, 52), func(): command_requested.emit("screen"), "ui_toy_screen_tip")
	_register("screen", screen_button)

	var cards := Panel.new()
	cards.position = Vector2(18, 196)
	cards.size = Vector2(534, 360)
	cards.add_theme_stylebox_override("panel", _box(Color("fff9e9"), Color("d4bd8b"), 2))
	panel.add_child(cards)
	_label(cards, "", Vector2(16, 10), Vector2(200, 25), 17, GREEN).name = "ToyCardsHeading"
	var card_specs: Array[Dictionary] = [
		{"id":"pot", "texture":"res://assets/ui/toy/card_category_pot_64.png"}, {"id":"pan", "texture":"res://assets/ui/toy/card_category_pan_64.png"},
		{"id":"potato", "texture":"res://cooking_art/ingredients/potato.png"}, {"id":"carrot", "texture":"res://cooking_art/ingredients/carrot.png"},
		{"id":"tomato", "texture":"res://cooking_art/ingredients/tomato.png"}, {"id":"egg", "texture":"res://cooking_art/ingredients/egg.png"},
		{"id":"pumpkin", "texture":"res://assets/food/ingredients/pumpkin_whole_64.png"}, {"id":"corn", "texture":"res://assets/food/ingredients/corn_whole_64.png"},
		{"id":"mushroom", "texture":"res://assets/food/ingredients/mushroom_whole_64.png"}, {"id":"unknown", "texture":"res://assets/ui/toy/unknown_card_64.png"},
	]
	for index in range(card_specs.size()):
		var spec: Dictionary = card_specs[index]
		var card_id := str(spec.id)
		_register("card_" + card_id, _card_button(cards, card_id, str(spec.texture), Vector2(14 + (index % 5) * 103, 46 + (index / 5) * 112)))
	var read_failed := _icon_button(cards, "res://assets/ui/toy/unknown_card_64.png", Vector2(428, 270), Vector2(86, 72), func(): event_requested.emit("read_failed", {}), "ui_toy_read_failed_tip")
	read_failed.name = "ToyReadFailed"
	_register("read_failed", read_failed)

	var zones := Panel.new()
	zones.position = Vector2(18, 570)
	zones.size = Vector2(534, 142)
	zones.add_theme_stylebox_override("panel", _box(Color("fff9e9"), Color("d4bd8b"), 2))
	panel.add_child(zones)
	_label(zones, "", Vector2(16, 8), Vector2(200, 25), 17, GREEN).name = "ToyZonesHeading"
	for index in range(["cutting_board", "stove", "oven"].size()):
		var zone_id: String = ["cutting_board", "stove", "oven"][index]
		var texture_name := "board" if zone_id == "cutting_board" else zone_id
		var zone_button := _icon_button(zones, "res://assets/ui/toy/place_card_%s.png" % texture_name, Vector2(16 + index * 171, 42), Vector2(158, 86), func(value = zone_id): _set_zone(value), "ui_toy_zone_tip")
		zone_button.name = "ToyZone" + zone_id.capitalize()
		_register("zone_" + zone_id, zone_button)

	var controls := Panel.new()
	controls.position = Vector2(18, 726)
	controls.size = Vector2(534, 214)
	controls.add_theme_stylebox_override("panel", _box(Color("fff9e9"), Color("d4bd8b"), 2))
	panel.add_child(controls)
	_label(controls, "", Vector2(16, 8), Vector2(220, 25), 17, GREEN).name = "ToyControlsHeading"
	_register("cut", _icon_button(controls, "res://cooking_art/icons/knife.png", Vector2(16, 42), Vector2(58, 58), func(): event_requested.emit("cut", {}), "ui_toy_cut_tip"))
	var faucet := _icon_button(controls, "res://assets/ui/toy/tap_closed.png", Vector2(84, 42), Vector2(68, 58), _faucet_pressed, "ui_toy_faucet_tip")
	faucet.name = "ToyFaucet"
	_register("faucet", faucet)
	for index in range(["pot", "pan"].size()):
		var kind: String = ["pot", "pan"][index]
		var vessel := _icon_button(controls, "res://assets/ui/toy/pot_off_stove.png" if kind == "pot" else "res://assets/ui/toy/reuse_pan.png", Vector2(162 + index * 62, 42), Vector2(58, 58), func(value = kind): _vessel_pressed(value), "ui_toy_vessel_tip")
		var selected := _image(vessel, "res://assets/ui/toy/target_arrow_32.png", Vector2(36, 36), Vector2(18, 18))
		selected.name = "Selected"
		selected.visible = false
		_register("vessel_" + kind, vessel)
	var door := _icon_button(controls, "res://assets/ui/toy/reuse_oven_closed.png", Vector2(286, 42), Vector2(72, 58), _door_pressed, "ui_toy_door_tip")
	door.name = "ToyOvenDoor"
	_register("oven_door", door)
	for index in range(["coffee", "milk", "ice"].size()):
		var ingredient: String = ["coffee", "milk", "ice"][index]
		_register("drink_" + ingredient, _icon_button(controls, "res://assets/ui/toy/drink_%s_normal_64.png" % ingredient, Vector2(370 + index * 50, 42), Vector2(48, 58), func(value = ingredient): _drink_pressed(value), "ui_toy_drink_tip"))
	for index in range(["off", "small", "medium", "high"].size()):
		var level: String = ["off", "small", "medium", "high"][index]
		_register("stove_" + level, _icon_button(controls, "res://assets/ui/toy/knob_%s.png" % _knob_asset_level(level), Vector2(16 + index * 62, 122), Vector2(58, 72), func(value = level): _stove_pressed(value), "ui_toy_stove_tip"))
		_register("oven_" + level, _icon_button(controls, "res://assets/ui/toy/knob_%s.png" % _knob_asset_level(level), Vector2(286 + index * 58, 122), Vector2(54, 72), func(value = level): _oven_level_pressed(value), "ui_toy_oven_tip"))
	feedback_icon = _image(panel, "res://assets/ui/toy/unknown_card_32.png", Vector2(22, 956), Vector2(34, 34))
	feedback_badge = _label(panel, "", Vector2(44, 952), Vector2(18, 18), 15, Color("9f3d31"))
	feedback_label = _label(panel, "", Vector2(66, 956), Vector2(454, 34), 17)
	root.theme = Localization.theme()
	if not _layout.is_empty(): apply_layout(_layout)

func apply_layout(layout: Dictionary) -> void:
	_layout = layout.duplicate(true)
	if root == null: return
	var viewport: Vector2 = layout.get("viewport", VIEW_SIZE)
	var content: Rect2 = layout.get("content_rect", Rect2(Vector2.ZERO, VIEW_SIZE))
	var scale: float = float(layout.get("scale", 1.0))
	if screen_blocker != null: screen_blocker.size = viewport
	# The simulator is a modal, so it may retain its compact 1536 design width;
	# centre it in a wider safe content area while its input shield covers the
	# entire viewport.
	root.position = content.position + Vector2(maxf(0.0, content.size.x - VIEW_SIZE.x * scale) * 0.5, 0.0)
	root.scale = Vector2.ONE * scale

func _box(fill: Color, border: Color, thickness: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(thickness)
	box.set_corner_radius_all(3)
	return box

func _label(parent: Node, text: String, at: Vector2, extent: Vector2, font_size: int = 18, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.size = extent
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, at: Vector2, extent: Vector2, callback: Callable, tip_key: String) -> Button:
	var button := Button.new()
	button.text = text
	button.position = at
	button.size = extent
	button.tooltip_text = _tx(tip_key)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_stylebox_override("normal", _box(Color("fff2d2"), EDGE, 2))
	button.add_theme_stylebox_override("hover", _box(Color("fffbe8"), Color("b18b43"), 2))
	button.add_theme_stylebox_override("pressed", _box(Color("e5d4ac"), EDGE, 2))
	button.add_theme_stylebox_override("focus", _box(Color.TRANSPARENT, GREEN, 3))
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _icon_button(parent: Node, texture_path: String, at: Vector2, extent: Vector2, callback: Callable, tip_key: String) -> Button:
	var button := _button(parent, "", at, extent, callback, tip_key)
	button.clip_contents = true
	var side := minf(extent.x, extent.y)
	var icon := _image(button, texture_path, Vector2((extent.x - side) * 0.5, (extent.y - side) * 0.5), Vector2(side, side))
	icon.name = "Icon"
	return button

func _card_button(parent: Node, card_id: String, texture_path: String, at: Vector2) -> Button:
	var card := _button(parent, "", at, Vector2(90, 96), func(): _card_pressed(card_id), "ui_toy_card_tip")
	card.clip_contents = true
	card.name = "ToyCard" + card_id.capitalize()
	_image(card, "res://assets/ui/toy/card_frame_64.png", Vector2.ZERO, card.size)
	var art := _image(card, texture_path, Vector2(11, 7), Vector2(68, 68))
	art.name = "Art"
	var added := _image(card, "res://assets/ui/toy/card_already_added_32.png", Vector2(58, 61), Vector2(28, 28))
	added.name = "Added"
	added.visible = false
	return card

func _image(parent: Node, texture_path: String, at: Vector2, extent: Vector2) -> TextureRect:
	var image := TextureRect.new()
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# These supplied sprite sheets have deliberately large transparent bounds.
	# Scale their complete canvas into each fixed hit target so neighboring cards
	# cannot be obscured by their source-sized pixels.
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.texture = _texture(texture_path)
	image.position = at
	image.size = extent
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(image)
	return image

func _texture(path: String) -> Texture2D:
	if _texture_cache.has(path):
		return _texture_cache[path] as Texture2D
	var texture: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_texture_cache[path] = texture # Cache misses too; refresh never repeatedly loads.
	return texture

func _register(id: String, button: Button) -> void:
	_buttons[id] = button

func _tx(key: String, args: Dictionary = {}) -> String:
	return Localization.text(key, args)

func _connection_pressed() -> void:
	var connection := str(_adapter_state.get("connection", "disconnected"))
	command_requested.emit("disconnect" if connection in ["connected", "aligning"] else "connect")

func _snapshot_pressed() -> void:
	event_requested.emit("panel_snapshot", _panel.duplicate(true))

func _set_zone(value: String) -> void:
	_zone = value
	_refresh()

func _card_pressed(kind: String) -> void:
	if kind in ["pot", "pan"] and _zone == "stove":
		_panel.vessel = kind
	event_requested.emit("card", {"category":kind, "zone":_zone})
	_refresh()

func _faucet_pressed() -> void:
	_panel.faucet_open = not bool(_panel.faucet_open)
	event_requested.emit("faucet", {"open":bool(_panel.faucet_open)})
	_refresh()

func _vessel_pressed(kind: String = "") -> void:
	if kind.is_empty():
		var expected := str(_status.get("vessel", ""))
		kind = expected if expected in ["pot", "pan"] else "pot"
	var present := str(_panel.vessel) != kind
	_panel.vessel = kind if present else ""
	event_requested.emit("vessel", {"kind":kind, "present":present})
	_refresh()

func _door_pressed() -> void:
	_panel.oven_open = not bool(_panel.oven_open)
	event_requested.emit("oven_door", {"open":bool(_panel.oven_open)})
	_refresh()

func _stove_pressed(level: String) -> void:
	_panel.stove_level = level
	event_requested.emit("stove", {"level":level})
	_refresh()

func _oven_level_pressed(level: String) -> void:
	_panel.oven_level = level
	event_requested.emit("oven_level", {"level":level})
	_refresh()

func _drink_pressed(ingredient: String = "") -> void:
	if ingredient.is_empty():
		var ingredients: Array = _status.get("ingredients", [])
		ingredient = ["coffee", "milk", "ice"][mini(ingredients.size(), 2)]
	event_requested.emit("drink_button", {"ingredient":ingredient})

func _knob_asset_level(level: String) -> String:
	return "low" if level == "small" else level

func _refresh() -> void:
	if root == null:
		return
	_locale_revision = Localization.revision()
	root.theme = Localization.theme()
	var connection := str(_adapter_state.get("connection", "disconnected"))
	if connection != _previous_connection and connection == "disconnected":
		state_icon.rotation = 0.0
	_previous_connection = connection
	state_icon.texture = _texture("res://assets/ui/toy/%s.png" % {"connected":"connected_64", "aligning":"connecting_64", "disconnected":"disconnected_64"}.get(connection, "disconnected_64"))
	state_icon.tooltip_text = _tx({"connected":"ui_local_toy_connected", "aligning":"ui_local_toy_aligning", "disconnected":"ui_local_toy_disconnected"}.get(connection, "ui_local_toy_disconnected"))
	(root.find_child("ToySimulatorTitle", true, false) as Label).text = _tx("ui_local_toy_title")
	(root.find_child("ToyCardsHeading", true, false) as Label).text = _tx("ui_toy_cards")
	(root.find_child("ToyZonesHeading", true, false) as Label).text = _tx("ui_toy_zones")
	(root.find_child("ToyControlsHeading", true, false) as Label).text = _tx("ui_toy_controls")
	state_label.text = _tx({"connected":"ui_local_toy_connected", "aligning":"ui_local_toy_aligning", "disconnected":"ui_local_toy_disconnected"}.get(connection, "ui_local_toy_disconnected"))
	connect_button.text = _tx("ui_local_toy_disconnect") if connection in ["connected", "aligning"] else _tx("ui_local_toy_connect")
	connect_button.tooltip_text = _tx("ui_toy_connection")
	close_button.tooltip_text = _tx("ui_toy_close")
	snapshot_button.disabled = connection != "aligning"
	snapshot_button.tooltip_text = _tx("ui_toy_snapshot_tip")
	screen_button.tooltip_text = _tx("ui_toy_screen_tip")
	var read_failed := button_for_event("read_failed")
	if read_failed != null: read_failed.tooltip_text = _tx("ui_toy_read_failed_tip")
	_update_zone_buttons()
	_update_cards()
	_update_controls()
	need_label.text = _next_hint()
	need_icon.texture = _texture(_need_texture())
	need_icon.visible = not need_label.text.is_empty()
	feedback_label.text = _feedback_text(_feedback)
	feedback_icon.texture = _texture(_feedback_texture(_feedback))
	feedback_icon.visible = not _feedback.is_empty()
	feedback_badge.text = "!" if _feedback == "read_failed" else ""
	feedback_badge.visible = not feedback_badge.text.is_empty()
	feedback_label.visible = not _feedback.is_empty()

func _update_zone_buttons() -> void:
	for zone_id in ["cutting_board", "stove", "oven"]:
		var button := button_for_event("zone_" + zone_id)
		if button == null: continue
		button.tooltip_text = _tx("ui_toy_zone_selected" if zone_id == _zone else "ui_toy_zone_tip", {"zone":_tx("zone_%s_name" % zone_id)})
		button.modulate = Color.WHITE if zone_id == _zone else Color("d8cfbb")

func _update_cards() -> void:
	var ingredients: Array = _status.get("ingredients", [])
	for card_id in ["pot", "pan", "potato", "carrot", "tomato", "egg", "pumpkin", "corn", "mushroom", "unknown"]:
		var button := button_for_event("card_" + card_id)
		if button == null: continue
		button.tooltip_text = _tx("ui_toy_unknown_card_tip") if card_id == "unknown" else _tx("ui_toy_card_tip", {"card":_card_name(card_id)})
		var added := button.find_child("Added", true, false) as TextureRect
		if added != null: added.visible = card_id in ingredients

func _update_controls() -> void:
	var faucet := button_for_event("faucet")
	_set_icon(faucet, "res://assets/ui/toy/tap_%s.png" % ("open" if bool(_panel.faucet_open) else "closed"))
	if faucet != null: faucet.tooltip_text = _tx("ui_water_on" if bool(_panel.faucet_open) else "ui_water_off")
	for kind in ["pot", "pan"]:
		var vessel := button_for_event("vessel_" + kind)
		_set_icon(vessel, "res://assets/ui/toy/pot_%s_stove.png" % ("on" if str(_panel.vessel) == kind else "off") if kind == "pot" else "res://assets/ui/toy/reuse_pan.png")
		var selected := vessel.find_child("Selected", true, false) as TextureRect if vessel != null else null
		if selected != null: selected.visible = str(_panel.vessel) == kind
		if vessel != null: vessel.tooltip_text = _tx("ui_toy_vessel_tip", {"vessel":_card_name(kind)})
	var door := button_for_event("oven_door")
	_set_icon(door, "res://assets/ui/toy/reuse_oven_%s.png" % ("open" if bool(_panel.oven_open) else "closed"))
	if door != null: door.tooltip_text = _tx("ui_oven_open" if bool(_panel.oven_open) else "ui_oven_closed")
	for level in ["off", "small", "medium", "high"]:
		var knob_path := "res://assets/ui/toy/knob_%s.png" % _knob_asset_level(level)
		var stove := button_for_event("stove_" + level)
		var oven := button_for_event("oven_" + level)
		_set_icon(stove, knob_path)
		_set_icon(oven, knob_path)
		if stove != null:
			stove.tooltip_text = _tx("ui_toy_stove_tip", {"level":_level_name(level)})
			stove.modulate = Color.WHITE if str(_panel.stove_level) == level else Color("d8cfbb")
		if oven != null:
			oven.tooltip_text = _tx("ui_toy_oven_tip", {"level":_level_name(level)})
			oven.modulate = Color.WHITE if str(_panel.oven_level) == level else Color("d8cfbb")
	var ingredients: Array = _status.get("ingredients", [])
	for ingredient in ["coffee", "milk", "ice"]:
		var drink := button_for_event("drink_" + ingredient)
		_set_icon(drink, "res://assets/ui/toy/drink_%s_%s_64.png" % [ingredient, "done" if ingredient in ingredients else "normal"])
		if drink != null: drink.tooltip_text = _tx("ui_toy_drink_tip", {"ingredient":_card_name(ingredient)})
	var cut := button_for_event("cut")
	if cut != null: cut.tooltip_text = _tx("ui_toy_cut_tip")

func _set_icon(button: Button, texture_path: String) -> void:
	if button == null: return
	var icon := button.find_child("Icon", true, false) as TextureRect
	if icon != null: icon.texture = _texture(texture_path)

func _next_hint() -> String:
	var actions: Array = _status.get("actions", [])
	for candidate in actions:
		var action := str(candidate)
		if action in ["clear", "cancel", "pause", "resume", "retry", "return"]: continue
		var hint := _action_hint(action)
		if not hint.is_empty(): return hint
	if str(_status.get("phase", "")) == "cooking":
		var remaining := maxf(0.0, float(_status.get("duration", 0.0)) - float(_status.get("elapsed", 0.0)))
		return _tx("ui_toy_waiting", {"seconds":ceili(remaining)})
	return ""

func _need_texture() -> String:
	if str(_status.get("phase", "")) == "cooking": return "res://assets/ui/toy/timer_track.png"
	var actions: Array = _status.get("actions", [])
	for candidate in actions:
		var action := str(candidate)
		if action in ["clear", "cancel", "pause", "resume", "retry", "return"]: continue
		if action == "finish": return "res://assets/ui/toy/completion.png"
		return "res://assets/ui/toy/finger_ready_32.png"
	return "res://assets/ui/toy/finger_ready_32.png"

func _action_hint(action: String) -> String:
	if action.begins_with("add_"): return _tx("ui_now_need", {"ingredient":_card_name(action.trim_prefix("add_"))})
	if action.begins_with("heat_"): return _tx("ui_toy_heat", {"level":_level_name(action.trim_prefix("heat_"))})
	return {"cut":_tx("ui_cut"), "pot":_card_name("pot"), "pan":_card_name("pan"), "oven":_tx("zone_oven_name"), "flip":_tx("ui_flip"), "stir":_tx("ui_stir"), "finish":_tx("ui_toy_finish"), "takeout":_tx("ui_takeout")}.get(action, "")

func _card_name(kind: String) -> String:
	var key := "category_%s_name" % kind
	return _tx("ui_unknown_card") if kind == "unknown" else (_tx(key) if Localization.has_key(key) else _tx("category_card_name"))

func _level_name(level: String) -> String:
	return _tx({"off":"ui_heat_off", "small":"ui_heat_1", "medium":"ui_heat_2", "high":"ui_heat_3"}.get(level, "ui_heat_off"))

func _feedback_text(value: String) -> String:
	return _tx({"committed":"ui_toy_committed", "commit_rejected":"ui_toy_commit_rejected", "action_candidate":"ui_toy_ready", "aligned":"ui_toy_aligned", "panel_aligned":"ui_toy_aligned", "panel_updated":"ui_toy_panel_updated", "already_added":"ui_already_added", "not_needed":"ui_not_needed", "unknown_card":"ui_unknown_card", "read_failed":"ui_read_failed", "wrong_zone":"ui_toy_wrong_zone", "vessel_missing":"ui_toy_vessel_missing", "wrong_vessel":"ui_toy_wrong_vessel", "stale":"ui_toy_stale", "duplicate":"ui_toy_duplicate", "paused":"ui_toy_paused", "aligning":"ui_local_toy_aligning", "not_aligned":"ui_local_toy_aligning", "invalid_snapshot":"ui_toy_invalid_snapshot", "not_connected":"ui_local_toy_disconnected", "invalid_event":"ui_toy_unavailable", "invalid_status":"ui_toy_unavailable", "screen_ignored":"ui_toy_unavailable", "out_of_order":"ui_toy_not_now"}.get(value, "ui_toy_unavailable")) if not value.is_empty() else ""

func _feedback_texture(value: String) -> String:
	if value == "committed": return "res://assets/ui/toy/recognition_success_32.png"
	if value == "action_candidate": return "res://assets/ui/toy/finger_ready_32.png"
	if value in ["aligned", "panel_aligned", "panel_updated", "stale", "duplicate"]: return "res://assets/ui/toy/target_arrow_32.png"
	if value == "already_added": return "res://assets/ui/toy/card_already_added_32.png"
	if value in ["not_needed", "wrong_zone", "commit_rejected", "wrong_vessel", "vessel_missing", "out_of_order"]: return "res://assets/ui/toy/card_not_needed_32.png"
	return "res://assets/ui/toy/unknown_card_32.png"

func _valid_panel(value: Dictionary) -> bool:
	for key in PANEL_KEYS:
		if not value.has(key): return false
	return str(value.stove_level) in ["off", "small", "medium", "high"] and str(value.oven_level) in ["off", "small", "medium", "high"] and typeof(value.oven_open) == TYPE_BOOL and typeof(value.faucet_open) == TYPE_BOOL and str(value.vessel) in ["", "pot", "pan"]

func _empty_panel() -> Dictionary:
	return {"stove_level":"off", "oven_level":"off", "oven_open":false, "vessel":"", "faucet_open":false}
