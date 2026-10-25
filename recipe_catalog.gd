extends RefCounted
## Stable cooking metadata. IDs, never translated labels, are persisted.
const RECIPES: Dictionary = {
	"soup": {"label": "土豆胡萝卜汤", "name_key": "recipe_potato_carrot_soup_name", "ingredients": ["potato", "carrot"], "vessel": "pot", "need_water": true, "need_cut": true, "final_action": "finish", "heat_durations": {"small": 8.0, "medium": 6.0, "high": 4.0}, "steps": ["选料加水", "切块入锅", "调火慢煮", "完成料理"]},
	"stir_fry": {"label": "番茄炒蛋", "name_key": "recipe_tomato_egg_name", "ingredients": ["egg", "tomato"], "vessel": "pan", "need_water": false, "need_cut": true, "final_action": "stir", "heat_durations": {"small": 6.0, "medium": 4.0, "high": 3.0}, "steps": ["准备食材", "切番茄入锅", "调火加热", "翻炒完成"]},
	"bake": {"label": "芝士烤吐司", "name_key": "recipe_cheese_toast_name", "ingredients": ["bread", "cheese"], "vessel": "oven", "need_water": false, "need_cut": false, "final_action": "takeout", "heat_durations": {}, "bake_duration": 8.0, "steps": ["准备食材", "放入烤箱", "等待烤制", "取出料理"]},
	"drink": {"label": "冰拿铁", "name_key": "recipe_iced_latte_name", "ingredients": ["coffee", "milk", "ice"], "vessel": "", "need_water": false, "need_cut": false, "final_action": "stir", "heat_durations": {}, "steps": ["倒入咖啡", "加入牛奶", "加入冰块", "搅拌完成"]},
	"pumpkin_corn_soup": {"label": "南瓜玉米汤", "name_key": "recipe_pumpkin_corn_soup_name", "ingredients": ["pumpkin", "corn"], "vessel": "pot", "need_water": true, "need_cut": true, "final_action": "finish", "heat_durations": {"small": 8.0, "medium": 6.0, "high": 4.0}, "steps": ["选料加水", "切块入锅", "调火慢煮", "完成料理"]},
	"pan_fried_mushrooms": {"label": "香煎蘑菇", "name_key": "recipe_pan_fried_mushrooms_name", "ingredients": ["mushroom"], "vessel": "pan", "need_water": false, "need_cut": false, "final_action": "flip", "heat_durations": {"small": 6.0, "medium": 4.0, "high": 3.0}, "steps": ["准备蘑菇", "放入炒锅", "调火加热", "翻面完成"]},
}


static func has(recipe_id: String) -> bool:
	return RECIPES.has(recipe_id)


static func get_recipe(recipe_id: String) -> Dictionary:
	return RECIPES.get(recipe_id, {})

static func name_key(recipe_id: String) -> String:
	return str(get_recipe(recipe_id).get("name_key", ""))
