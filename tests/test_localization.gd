extends SceneTree

const Localization = preload("res://localization.gd")
const RecipeCatalog = preload("res://recipe_catalog.gd")
const UI_CSV := "res://i18n/ui.csv"

var _failures: Array[String] = []


func _init() -> void:
	_test_csv_contract()
	_test_runtime_service()
	_test_fonts()
	if _failures.is_empty():
		print("localization tests passed")
		quit(0)
	else:
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _test_csv_contract() -> void:
	var file := FileAccess.open(UI_CSV, FileAccess.READ)
	_expect(file != null, "ui.csv must be readable")
	if file == null:
		return
	var header := file.get_csv_line()
	_expect(header == PackedStringArray(["keys", "zh_CN", "en", "de", "fr", "ko", "ja"]), "ui.csv must retain its seven-column header")
	var keys := {}
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.is_empty() or (row.size() == 1 and row[0].is_empty()):
			continue
		_expect(row.size() == 7, "every ui.csv row must have seven columns: %s" % row)
		if row.size() != 7:
			continue
		var key := row[0]
		_expect(not key.is_empty() and not keys.has(key), "keys must be unique and non-empty: %s" % key)
		keys[key] = true
		_expect(not row[1].is_empty() and not row[2].is_empty(), "zh_CN and en must be complete: %s" % key)
		for column: int in [3, 4, 5, 6]:
			_expect(row[column].is_empty(), "future locale columns must remain empty: %s" % key)
		_expect(_placeholders(row[1]) == _placeholders(row[2]), "named placeholders must match: %s" % key)
	_expect(keys.size() >= 86, "the supplied 86 keys must be retained")
	for recipe_id: String in RecipeCatalog.RECIPES:
		_expect(keys.has(RecipeCatalog.name_key(recipe_id)), "every catalogue recipe must use a CSV name key: %s" % recipe_id)


func _test_runtime_service() -> void:
	Localization.initialize()
	var configured: PackedStringArray = ProjectSettings.get_setting("internationalization/locale/translations", PackedStringArray())
	_expect(configured.has(str(Localization.TRANSLATION_PATHS["zh_CN"])) and configured.has(str(Localization.TRANSLATION_PATHS["en"])), "ProjectSettings registers both imported translations")
	_expect(Localization.SUPPORTED_LOCALES == ["zh_CN", "en"], "only zh_CN and en are switchable")
	_expect(Localization.FUTURE_LOCALES == ["de", "fr", "ko", "ja"], "future locale list must be explicit")
	_expect(Localization.has_key("ui_confirm"), "imported translation must expose CSV keys")
	Localization.set_locale("zh_CN")
	var before := Localization.revision()
	_expect(Localization.text("ui_confirm") == "确认", "Chinese lookup must use TranslationServer")
	_expect(Localization.text("ui_now_need", {"ingredient": "玉米"}) == "现在需要：玉米", "Chinese named formatting must work")
	_expect(Localization.set_locale("en"), "en must be accepted")
	_expect(Localization.current_locale() == "en", "accepted locale must become current")
	_expect(Localization.revision() == before + 1, "a language change must increment revision")
	_expect(Localization.text("ui_confirm") == "Confirm", "English lookup must use TranslationServer")
	_expect(Localization.text("ui_now_need", {"ingredient": "corn"}) == "Needed now: corn", "English named formatting must work")
	var stable_revision := Localization.revision()
	_expect(not Localization.set_locale("ja"), "unsupported locale must be rejected")
	_expect(Localization.current_locale() == "en" and Localization.revision() == stable_revision, "rejected locale must leave state unchanged")
	var old_message := "做得好，这份料理完成了！"
	_expect(Localization.legacy_text(old_message) == "Great job, this dish is ready!", "known legacy session message must translate")
	_expect(old_message == "做得好，这份料理完成了！", "legacy_text must not mutate saved input")
	_expect(Localization.legacy_text("自定义旧消息") == "自定义旧消息", "unknown non-empty legacy text must be preserved")
	_expect(Localization.recipe_name_key("pumpkin_corn_soup") == "recipe_pumpkin_corn_soup_name", "new pumpkin recipe id must use its existing CSV key")
	_expect(Localization.recipe_name_key("pan_fried_mushrooms") == "recipe_pan_fried_mushrooms_name", "new mushroom recipe id must use its existing CSV key")
	_expect(RecipeCatalog.RECIPES.size() == 6, "the catalogue is the only source of all six recipe ids")
	var runtime_source := (load("res://localization.gd") as Script).get_source_code()
	_expect(not "func _csv_keys" in runtime_source and not "FileAccess.open(CSV_PATH" in runtime_source, "runtime key lookup must not read raw CSV")


func _test_fonts() -> void:
	var chinese_theme := Localization.theme("zh_CN")
	var english_theme := Localization.theme("en")
	var chinese_font := chinese_theme.get_default_font()
	var english_font := english_theme.get_default_font()
	_expect(chinese_font != null and english_font != null, "both locale themes require an embedded FontFile")
	if chinese_font != null:
		_expect(str(chinese_font.get_meta("localization_source_path", "")) == Localization.CHINESE_FONT_PATH, "Chinese theme must use the bundled SC FontFile as its primary font")
		_expect(chinese_font.has_char("中".unicode_at(0)) and chinese_font.has_char("A".unicode_at(0)), "Chinese UI font must cover Chinese and Latin UI glyphs")
	if english_font != null:
		_expect(str(english_font.get_meta("localization_source_path", "")) == Localization.LATIN_FONT_PATH, "English theme must use the bundled Latin FontFile as its primary font")
		_expect(english_font.has_char("A".unicode_at(0)), "English primary font must cover Latin UI glyphs")
		_expect(english_font.fallbacks.size() == 1 and str(english_font.fallbacks[0].get_meta("localization_source_path", "")) == Localization.CHINESE_FONT_PATH, "English theme must have a one-way SC fallback for untranslated legacy Chinese")
		if english_font.fallbacks.size() == 1:
			_expect(english_font.fallbacks[0].has_char("中".unicode_at(0)), "English theme's SC fallback must cover untranslated Chinese glyphs")
	if chinese_font != null:
		_expect(chinese_font.fallbacks.size() == 1 and str(chinese_font.fallbacks[0].get_meta("localization_source_path", "")) == Localization.LATIN_FONT_PATH and chinese_font.fallbacks[0].has_char("A".unicode_at(0)) and chinese_font.fallbacks[0].fallbacks.is_empty(), "Chinese theme must have a one-way Latin fallback without a FontFile cycle")


func _placeholders(value: String) -> Array[String]:
	var result: Array[String] = []
	var expression := RegEx.new()
	expression.compile("\\{([A-Za-z_][A-Za-z0-9_]*)\\}")
	for match: RegExMatch in expression.search_all(value):
		result.append(match.get_string(1))
	result.sort()
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
