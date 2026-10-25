class_name Localization
extends RefCounted
## Small, explicit localisation boundary for the UI.
##
## UI code should call `Localization.text("ui_confirm")` and explicitly refresh
## when `Localization.revision()` changes.  This class owns no player setting and
## intentionally never writes to a save file.

const SUPPORTED_LOCALES: Array[String] = ["zh_CN", "en"]
const FUTURE_LOCALES: Array[String] = ["de", "fr", "ko", "ja"]

const TRANSLATION_PATHS := {
	"zh_CN": "res://i18n/ui.zh_CN.translation",
	"en": "res://i18n/ui.en.translation",
}
const CHINESE_FONT_PATH := "res://fonts/zh_CN/NotoSansCJKsc-Regular.otf"
const LATIN_FONT_PATH := "res://fonts/latin/NotoSans-Regular.ttf"
const RecipeCatalog = preload("res://recipe_catalog.gd")

## `session.message` is saved legacy text.  This strict allow-list is indexed
## from the imported zh_CN Translation at startup.  Runtime text intentionally
## never depends on the source CSV being present in an exported build.
const LEGACY_MESSAGE_KEYS: PackedStringArray = [
	"kitchen_recipe_unselected", "session_recipe_already_bound", "session_order_unavailable",
	"session_take_it_slow", "session_follow_current_step", "session_returned_unfinished",
	"session_cleared_recipe", "session_retry_keeps_progress", "session_ingredient_slots_full",
	"session_recipe_complete", "session_overcooked_retry", "session_ready_finish",
	"session_prompt_add_latte_ingredients", "session_prompt_add_soup_ingredients",
	"session_prompt_choose_ingredients", "session_prompt_chop_tomato",
	"session_prompt_chop_soup_vegetables", "session_prompt_put_in_oven",
	"session_prompt_put_in_pot", "session_prompt_put_in_pan", "session_prompt_choose_heat",
	"session_prompt_baking", "session_prompt_heating", "session_prompt_stir_drink",
	"session_prompt_takeout_bake", "session_prompt_finish_stir_fry",
	"session_prompt_finish_soup", "session_prompt_retry", "session_prompt_completed",
	"session_prompt_cancelled", "session_prompt_start",
	"notice_choose_guest", "notice_restored", "notice_save_invalid", "notice_guests_arrive",
	"notice_ordered_kitchen", "notice_kitchen_restore_invalid", "notice_focus_cooking",
	"notice_order_mismatch", "notice_finished_service", "notice_returned_order_waiting",
]

static var _initialized := false
static var _locale := "zh_CN"
static var _revision := 0
static var _translations: Dictionary = {}
static var _keys: Dictionary = {}
static var _legacy_text_keys: Dictionary = {}
static var _themes: Dictionary = {}
static var _diagnostics: PackedStringArray = []


static func initialize() -> void:
	if _initialized:
		return
	_initialized = true
	for locale: String in SUPPORTED_LOCALES:
		_register_translation(locale)
	_build_legacy_index()
	# Do not adopt an unsupported OS locale; this module only ships two choices.
	TranslationServer.set_locale(_locale)


static func set_locale(locale: String) -> bool:
	initialize()
	if locale not in SUPPORTED_LOCALES:
		return false
	if locale == _locale:
		return true
	_locale = locale
	TranslationServer.set_locale(_locale)
	_revision += 1
	return true


static func current_locale() -> String:
	initialize()
	return _locale


static func revision() -> int:
	initialize()
	return _revision


static func has_key(key: String) -> bool:
	initialize()
	if key.is_empty():
		return false
	if _keys.has(key):
		return bool(_keys[key])
	# OptimizedTranslation deliberately exposes no key list.  Ask the imported
	# resources directly on first use and cache both hits and misses.
	for translation: Translation in _translations.values():
		if not translation.get_message(key).is_empty():
			_keys[key] = true
			return true
	_keys[key] = false
	return false


static func text(key: String, args: Dictionary = {}) -> String:
	initialize()
	if key.is_empty() or not has_key(key):
		return key
	var translated := TranslationServer.translate(key)
	# A missing imported resource must remain legible during development.  The
	# selected translation's source message is the CSV key, not player-facing text.
	if translated == key:
		var chinese: Translation = _translations.get("zh_CN") as Translation
		if chinese != null:
			translated = chinese.get_message(key)
	if not args.is_empty():
		translated = translated.format(args)
	return translated


static func legacy_text(value: String) -> String:
	initialize()
	if value.is_empty():
		return value
	var key := str(_legacy_text_keys.get(value, ""))
	return text(key) if not key.is_empty() else value


static func recipe_name_key(recipe_id: String) -> String:
	return RecipeCatalog.name_key(recipe_id)


static func theme(locale: String = "") -> Theme:
	initialize()
	var requested := _locale if locale.is_empty() else locale
	if requested not in SUPPORTED_LOCALES:
		requested = _locale
	if _themes.has(requested):
		return _themes[requested] as Theme
	var result := Theme.new()
	var primary := _font_for_theme(requested)
	if primary != null:
		result.set_default_font(primary)
	else:
		_diagnose("No usable font for locale %s; Godot's editor fallback may be used." % requested)
	_themes[requested] = result
	return result


static func diagnostics() -> PackedStringArray:
	initialize()
	return _diagnostics.duplicate()


static func _register_translation(locale: String) -> void:
	var path := str(TRANSLATION_PATHS[locale])
	if not ResourceLoader.exists(path):
		_diagnose("Translation resource is unavailable: %s" % path)
		return
	var translation := load(path) as Translation
	if translation == null:
		_diagnose("Translation resource could not be loaded: %s" % path)
		return
	_translations[locale] = translation
	TranslationServer.add_translation(translation)


static func _font_for_theme(locale: String) -> FontFile:
	# Each theme receives independent FontFile instances.  A fallback therefore
	# points one way only; never make Chinese and Latin FontFiles fall back to each
	# other on the same resources.
	var primary_path := CHINESE_FONT_PATH if locale == "zh_CN" else LATIN_FONT_PATH
	var fallback_path := LATIN_FONT_PATH if locale == "zh_CN" else CHINESE_FONT_PATH
	var primary := _load_font(primary_path)
	var fallback := _load_font(fallback_path)
	if primary == null:
		return fallback
	if fallback != null:
		primary.fallbacks = [fallback]
	return primary


static func _load_font(path: String) -> FontFile:
	if not ResourceLoader.exists(path):
		_diagnose("Font file is unavailable: %s" % path)
		return null
	var source := load(path) as FontFile
	if source == null:
		_diagnose("Font file could not be loaded: %s" % path)
		return null
	var copy := source.duplicate(true) as FontFile
	copy.set_meta("localization_source_path", path)
	return copy


static func _build_legacy_index() -> void:
	var chinese: Translation = _translations.get("zh_CN") as Translation
	if chinese == null:
		return
	for key: String in LEGACY_MESSAGE_KEYS:
		var old_text := chinese.get_message(key)
		if old_text.is_empty() or old_text == key:
			_diagnose("Legacy message key is unavailable: %s" % key)
			continue
		_legacy_text_keys[old_text] = key


static func _diagnose(message: String) -> void:
	if message not in _diagnostics:
		_diagnostics.append(message)
