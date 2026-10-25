class_name P0Assets
extends RefCounted
## Runtime-only gateway for optional P0 art. Both hits and misses are cached.
const PATHS := {
	"background":"res://assets/kitchen/background/kitchen_background_main_1536x1024.png", "skin_panel":"res://assets/ui/skin/panel.png", "skin_button":"res://assets/ui/skin/button_normal.png", "skin_button_pressed":"res://assets/ui/skin/button_pressed.png", "skin_progress_track":"res://assets/ui/skin/progress_track.png", "skin_progress_fill":"res://assets/ui/skin/progress_fill.png",
	"back":"res://assets/ui/mobile/back_64.png", "pause":"res://assets/ui/mobile/pause_64.png", "play":"res://assets/ui/mobile/play_128.png", "confirm":"res://assets/ui/mobile/confirm_64.png", "flip":"res://cooking_art/icons/flip.png", "reselect":"res://assets/ui/toy/rotation_arrow.png", "completion":"res://assets/ui/toy/completion.png", "recognition_success":"res://assets/ui/toy/recognition_success_64.png", "selected_ring":"res://assets/ui/mobile/selected_ring.png", "finger_touch_0":"res://assets/ui/mobile/finger_touch_0.png", "finger_touch_1":"res://assets/ui/mobile/finger_touch_1.png", "tap_closed":"res://assets/ui/toy/tap_closed.png", "tap_open":"res://assets/ui/toy/tap_open.png", "water_flow_0":"res://assets/ui/toy/water_flow_0.png", "water_flow_1":"res://assets/ui/toy/water_flow_1.png", "water_flow_2":"res://assets/ui/toy/water_flow_2.png", "water_flow_3":"res://assets/ui/toy/water_flow_3.png",
	"pot_empty":"res://assets/kitchen/utensils/pot_empty.png", "pan_empty":"res://assets/kitchen/utensils/pan_empty.png", "oven_open_empty":"res://assets/kitchen/utensils/oven_open_empty.png", "oven_closed":"res://assets/kitchen/utensils/oven_closed.png", "cup_empty":"res://assets/kitchen/utensils/cup_empty.png", "drink_spoon":"res://assets/kitchen/utensils/drink_stir_spoon_128.png", "pot_water":"res://assets/kitchen/overlays/pot_water_surface.png", "pot_pumpkin_raw":"res://assets/kitchen/overlays/pot_pumpkin_corn_raw.png", "pot_pumpkin_cooked":"res://assets/kitchen/overlays/pot_pumpkin_corn_cooked.png", "pan_mushroom_raw":"res://assets/kitchen/overlays/pan_mushroom_raw.png", "pan_mushroom_cooked":"res://assets/kitchen/overlays/pan_mushroom_cooked.png", "oven_interior":"res://assets/kitchen/overlays/oven_interior_empty.png", "oven_raw":"res://assets/kitchen/overlays/oven_food_raw.png", "oven_cooked":"res://assets/kitchen/overlays/oven_food_cooked.png", "oven_shell":"res://assets/kitchen/overlays/oven_shell_open.png", "oven_glow":"res://assets/kitchen/overlays/oven_glow.png", "cup_coffee":"res://assets/kitchen/overlays/cup_coffee.png", "cup_coffee_milk":"res://assets/kitchen/overlays/cup_coffee_milk.png", "cup_ice":"res://assets/kitchen/overlays/cup_ice.png",
	"pumpkin":"res://assets/food/ingredients/pumpkin_whole_128.png", "corn":"res://assets/food/ingredients/corn_whole_128.png", "mushroom":"res://assets/food/ingredients/mushroom_whole_128.png", "pumpkin_chopped":"res://assets/food/prepared/pumpkin_chopped_128.png", "corn_prepared":"res://assets/food/prepared/corn_prepared_128.png", "mushroom_sliced":"res://assets/food/prepared/mushroom_sliced_128.png", "dish_pumpkin_corn_soup":"res://assets/food/dishes/pumpkin_corn_soup_64.png", "dish_pan_fried_mushrooms":"res://assets/food/dishes/pan_seared_mushrooms_64.png", "dish_bake":"res://assets/food/dishes/cheese_toast_64.png", "dish_drink":"res://assets/food/dishes/iced_latte_64.png"
}
var _cache: Dictionary = {}
var _optional_missing: Dictionary = {}
var _required_missing: Dictionary = {}
var _overrides: Dictionary = {}
func set_overrides(paths: Dictionary) -> void: _overrides = paths.duplicate(true); refresh()
func refresh() -> void: _cache.clear(); _optional_missing.clear(); _required_missing.clear()
func texture(key: String, optional: bool = true) -> Texture2D:
	var path := str(_overrides.get(key, PATHS.get(key, "")))
	if path.is_empty():
		if optional: _optional_missing[key] = "no mapped path"
		else: _required_missing[key] = "no mapped path"
		return null
	if _cache.has(path): return _cache[path] as Texture2D
	var result: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_cache[path] = result
	if result == null:
		if optional: _optional_missing[key] = path
		else: _required_missing[key] = path
	return result
func optional_missing() -> Dictionary: return _optional_missing.duplicate(true)
func required_missing() -> Dictionary: return _required_missing.duplicate(true)
func stylebox(key: String, margins: int = 20, content_margin: int = 8) -> StyleBoxTexture:
	var source := texture(key)
	if source == null: return null
	var box := StyleBoxTexture.new()
	box.texture = source
	box.texture_margin_left = margins; box.texture_margin_top = margins; box.texture_margin_right = margins; box.texture_margin_bottom = margins
	box.content_margin_left = content_margin; box.content_margin_top = content_margin; box.content_margin_right = content_margin; box.content_margin_bottom = content_margin
	return box
