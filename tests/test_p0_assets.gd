extends SceneTree
const Assets = preload("res://p0_assets.gd")
const Catalog = preload("res://recipe_catalog.gd")
var failures := 0
func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("P0_ASSETS_FAIL: " + message)
func _init() -> void:
	var assets = Assets.new()
	_check(assets.texture("background") != null, "new kitchen background is available")
	_check(assets.texture("dish_pumpkin_corn_soup") != null and assets.texture("dish_pan_fried_mushrooms") != null, "new dish icons are available")
	_check(assets.texture("flip") != null and assets.texture("tap_closed") != null and assets.texture("tap_open") != null, "icon-only flip and both faucet states are available")
	assets.set_overrides({"pot_pumpkin_raw":"res://missing_optional_p0.png"})
	_check(assets.texture("pot_pumpkin_raw") == null and assets.optional_missing().has("pot_pumpkin_raw"), "missing optional overlay is reported separately")
	_check(assets.texture("pot_pumpkin_raw") == null and assets.optional_missing().size() == 1, "failed optional load is cached")
	assets.set_overrides({"pot_pumpkin_raw":"res://assets/kitchen/overlays/pot_pumpkin_corn_raw.png"})
	_check(assets.texture("pot_pumpkin_raw") != null and assets.optional_missing().is_empty(), "explicit refresh clears negative cache")
	assets.set_overrides({"pan_empty":"res://missing_required_p0.png"})
	_check(assets.texture("pan_empty", false) == null and assets.required_missing().has("pan_empty") and assets.optional_missing().is_empty(), "required composition damage is distinct from optional art")
	_check(Catalog.name_key("pumpkin_corn_soup") == "recipe_pumpkin_corn_soup_name" and Catalog.name_key("soup") == "recipe_potato_carrot_soup_name", "catalogue owns stable recipe name keys")
	print("P0_ASSETS_TEST_RESULT failures=%d" % failures)
	quit(0 if failures == 0 else 1)
