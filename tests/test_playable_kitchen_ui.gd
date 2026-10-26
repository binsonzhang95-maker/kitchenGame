extends SceneTree
## Full-width kitchen contract test.  It deliberately constructs the new
## responsive-layout dictionary locally so it remains valid while the layout
## implementation is being changed in another batch.

const CookingView = preload("res://cooking_view.gd")
const DESIGNED_HEIGHT := 1152.0
const ROOM_HEIGHT := 1024.0
var view: CookingView
var checks := 0
var failures := 0
var requested: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("PLAYABLE_KITCHEN_UI_FAIL " + label)


func _layout(viewport: Vector2, insets: Dictionary = {}) -> Dictionary:
	var left := float(insets.get("left", 0.0))
	var right := float(insets.get("right", 0.0))
	var top := float(insets.get("top", 0.0))
	var bottom := float(insets.get("bottom", 0.0))
	var safe := Rect2(Vector2(left, top), viewport - Vector2(left + right, top + bottom))
	var scale := minf(safe.size.y / DESIGNED_HEIGHT, safe.size.x / 1536.0)
	var design_width := safe.size.x / scale
	return {
		"viewport": viewport,
		"safe_rect": safe,
		"scale": scale,
		"content_rect": safe,
		"room_rect": Rect2(safe.position + Vector2(0, 80) * scale, Vector2(design_width, ROOM_HEIGHT) * scale),
		"world_size": Vector2(design_width, ROOM_HEIGHT),
	}


func _state(recipe: String, phase: String, actions: Array) -> Dictionary:
	var ingredients: Array = []
	var required: Array = []
	match recipe:
		"soup": required = ["potato", "carrot", "water"]
		"stir_fry": required = ["egg", "tomato"]
		"bake": required = ["bread", "cheese"]
		"drink": required = ["coffee", "milk", "ice"]
		"pumpkin_corn_soup": required = ["pumpkin", "corn", "water"]
		"pan_fried_mushrooms": required = ["mushroom"]
	return {
		"recipe_id": recipe, "phase": phase, "actions": actions,
		"required_ingredients": required, "ingredients": ingredients,
		"step_index": 0, "paused": false, "completed": false,
		"progress": 0.5, "vessel": "", "water_added": false, "cut_done": false,
	}


func _run() -> void:
	view = CookingView.new()
	root.add_child(view)
	view.action_requested.connect(func(action: String, _payload: Dictionary): requested.append(action))
	view.sync(_state("soup", "ingredients", ["add_potato", "add_carrot", "add_water", "clear"]), {"cooking_token":1})
	await process_frame
	for spec: Dictionary in [
		{"name":"1536", "viewport":Vector2(1536, 1152), "insets":{}},
		{"name":"2048", "viewport":Vector2(2048, 1152), "insets":{}},
		{"name":"2496-safe", "viewport":Vector2(2496, 1152), "insets":{"left":150.0, "right":150.0, "bottom":60.0}},
	]:
		var layout := _layout(spec.viewport, spec.insets)
		view.apply_layout(layout)
		await process_frame
		_check_full_width(layout, str(spec.name))
	# A real pointer event must travel through the Control tree and retain the
	# action payload, not call the view's signal or session API directly.
	view.apply_layout(_layout(Vector2(1536, 1152)))
	await process_frame
	_click(view.button_for_action("add_potato").get_global_rect().get_center())
	await process_frame
	_check(requested == ["add_potato"], "actual ingredient tap requests add_potato exactly once")
	# Dynamic action rebuilds have the same right-hand station geometry. Cover
	# classic and P0 recipe phases, including the three simultaneous heat choices.
	for spec: Dictionary in [
		{"recipe":"soup", "phase":"heat", "actions":["heat_small", "heat_medium", "heat_high"]},
		{"recipe":"stir_fry", "phase":"ready", "actions":["stir"]},
		{"recipe":"bake", "phase":"ready", "actions":["takeout"]},
		{"recipe":"drink", "phase":"ready", "actions":["stir"]},
		{"recipe":"pumpkin_corn_soup", "phase":"prep", "actions":["cut"]},
		{"recipe":"pan_fried_mushrooms", "phase":"heat", "actions":["heat_small", "heat_medium", "heat_high"]},
	]:
		view.sync(_state(spec.recipe, spec.phase, spec.actions), {"cooking_token":2})
		view.apply_layout(_layout(Vector2(2048, 1152)))
		await process_frame
		_check_action_station(str(spec.recipe) + " " + str(spec.phase))
	# The overlay is a true root-sized shield after a full-width relayout.
	view.sync(_state("soup", "heat", ["heat_medium"]), {"cooking_token":3, "visual_paused":true})
	view.apply_layout(_layout(Vector2(2496, 1152), {"left":150.0, "right":150.0, "bottom":60.0}))
	_check(view.pause_overlay.size.x == view.root_control.size.x and view.pause_overlay.size.y == 1068.0, "pause shield follows full design width")
	view.queue_free()
	await process_frame
	print("PLAYABLE_KITCHEN_UI_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _check_full_width(layout: Dictionary, label: String) -> void:
	var safe: Rect2 = layout.safe_rect
	var viewport_rect := Rect2(Vector2.ZERO, layout.viewport)
	var scale: float = float(layout.scale)
	var design_width: float = (layout.world_size as Vector2).x
	_check(is_equal_approx(view.root_control.size.x, design_width), label + " root consumes world width")
	_check(view.background_image.texture != null and view.background_image.texture.resource_path.ends_with("kitchen_background_panorama_2304x1024.png"), label + " uses single panorama")
	_check(view.background_image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED, label + " panorama cover-crops without stretching")
	_check(viewport_rect.grow(0.1).encloses(view.background_image.get_global_rect()) and view.background_image.get_global_rect().grow(0.1).encloses(viewport_rect), label + " panorama global rect covers the complete viewport")
	var ingredient_rects: Array[Rect2] = []
	for slot: Dictionary in view.ingredient_slots:
		var rect := (slot.button as Button).get_global_rect()
		ingredient_rects.append(rect)
		_check(safe.grow(0.1).encloses(rect), label + " ingredient target remains in safe bounds")
		_check(rect.size.x >= 128.0 * scale and rect.size.y >= 128.0 * scale, label + " ingredient target remains touch sized")
	for first in range(ingredient_rects.size()):
		for second in range(first + 1, ingredient_rects.size()):
			_check(not ingredient_rects[first].intersects(ingredient_rects[second]), label + " ingredient targets do not overlap")
	_check(view.action_buttons.is_empty() and not view.action_bar.visible, label + " ingredient phase has no empty action station")
	_check(view.utensil_image.position.x >= design_width * 0.25 and view.utensil_image.get_rect().end.x <= design_width * 0.70, label + " appliance stays in centre workspace")
	_check(view.water_button.get_global_rect().position.x < safe.position.x + safe.size.x * 0.25, label + " water control is reachable in ingredient zone")


func _check_action_station(label: String) -> void:
	var station := view.action_bar.get_global_rect()
	var safe: Rect2 = view._layout.content_rect
	for action: Variant in view.action_buttons:
		var button: Button = view.action_buttons[action]
		_check(station.grow(0.1).encloses(button.get_global_rect()), label + " action " + str(action) + " is inside right station")
		_check(safe.grow(0.1).encloses(button.get_global_rect()), label + " action " + str(action) + " remains in safe content")
		_check(button.size.x >= 104.0 and button.size.y >= 112.0, label + " action " + str(action) + " stays touch sized")
	var buttons: Array = view.action_buttons.values()
	for first in range(buttons.size()):
		for second in range(first + 1, buttons.size()):
			_check(not (buttons[first] as Button).get_global_rect().intersects((buttons[second] as Button).get_global_rect()), label + " rebuilt action targets do not overlap")


func _click(point: Vector2) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)
