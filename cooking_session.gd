extends RefCounted
## A bound, isolated cooking activity. No restaurant, economy, or file access.
const SAVE_VERSION: int = 1
const MAX_INGREDIENTS: int = 3
const READY_WINDOW: float = 12.0
const RECIPES: Dictionary = {
	"soup": {"label": "土豆胡萝卜汤", "ingredients": ["potato", "carrot"], "vessel": "pot", "steps": ["选料加水", "切块入锅", "调火慢煮", "完成料理"]},
	"stir_fry": {"label": "番茄炒蛋", "ingredients": ["egg", "tomato"], "vessel": "pan", "steps": ["准备食材", "切番茄入锅", "调火加热", "翻炒完成"]},
	"bake": {"label": "芝士烤吐司", "ingredients": ["bread", "cheese"], "vessel": "oven", "steps": ["准备食材", "放入烤箱", "等待烤制", "取出料理"]},
	"drink": {"label": "冰拿铁", "ingredients": ["coffee", "milk", "ice"], "vessel": "", "steps": ["倒入咖啡", "加入牛奶", "加入冰块", "搅拌完成"]},
}
const PHASES: Array[String] = ["idle", "ingredients", "prep", "vessel", "heat", "cooking", "ready", "retry", "completed", "cancelled"]
const HEAT_LEVELS: Array[String] = ["small", "medium", "high"]
const ACTION_LABELS: Dictionary = {
	"add_potato": "加土豆", "add_carrot": "加胡萝卜", "add_egg": "加鸡蛋", "add_tomato": "加番茄", "add_bread": "放面包", "add_cheese": "放芝士",
	"add_coffee": "倒咖啡", "add_milk": "加牛奶", "add_ice": "加冰块", "add_water": "加清水", "cut": "切一切", "pot": "放入汤锅", "pan": "放入炒锅",
	"oven": "放入烤箱", "heat_small": "小火", "heat_medium": "中火", "heat_high": "大火", "finish": "完成料理", "stir": "翻炒完成", "takeout": "取出烤盘",
	"clear": "清空重做", "retry": "再试一次", "cancel": "返回餐厅",
}

var binding: Dictionary = {}
var recipe_id: String = ""
var phase: String = "idle"
var ingredients: Array[String] = []
var water_added: bool = false
var cut_done: bool = false
var vessel: String = ""
var heat_level: String = ""
var elapsed: float = 0.0
var paused: bool = false
var completed: bool = false
var cancelled: bool = false
var cancelled_from: String = ""
var message: String = ""
var attempts: int = 0


static func recipe_label(id: String) -> String:
	return str(RECIPES[id].label) if RECIPES.has(id) else "未选择料理"


static func action_label(action: String) -> String:
	return str(ACTION_LABELS.get(action, action))


func setup(order_binding: Dictionary, recipe: String) -> bool:
	if phase != "idle":
		return _fail("这份料理已经绑定订单，请先完成或返回餐厅。")
	if not RECIPES.has(recipe) or not _binding_valid(order_binding):
		return _fail("这份订单或配方暂时不可用，请返回餐厅再试。")
	binding = {"table_id": int(order_binding.table_id), "guest_id": int(order_binding.guest_id), "generation": int(order_binding.generation)}
	recipe_id = recipe
	_reset_preparation()
	message = "按步骤慢慢来，操作失误也可以重试。"
	return true


func is_bound_to(table_id: int, guest_id: int, generation: int) -> bool:
	return not binding.is_empty() and int(binding.table_id) == table_id and int(binding.guest_id) == guest_id and int(binding.generation) == generation


func required_ingredients() -> Array[String]:
	var result: Array[String] = []
	if RECIPES.has(recipe_id):
		result.assign(RECIPES[recipe_id].ingredients)
	return result


func ingredient_options() -> Array[String]:
	var result: Array[String] = []
	if phase != "ingredients" or paused:
		return result
	var required: Array[String] = required_ingredients()
	if recipe_id == "drink":
		if ingredients.size() < required.size():
			result.append(required[ingredients.size()])
	else:
		for ingredient: String in required:
			if ingredient not in ingredients:
				result.append(ingredient)
	return result


func available_actions() -> Array[String]:
	var actions: Array[String] = []
	if phase in ["idle", "completed", "cancelled"]:
		return actions
	if paused:
		return ["cancel"]
	match phase:
		"ingredients":
			for ingredient: String in ingredient_options():
				actions.append("add_" + ingredient)
			if recipe_id == "soup" and not water_added:
				actions.append("add_water")
		"prep": actions.append("cut")
		"vessel": actions.append(str(RECIPES[recipe_id].vessel))
		"heat": actions.assign(["heat_small", "heat_medium", "heat_high"])
		"ready": actions.append("finish" if recipe_id == "soup" else ("takeout" if recipe_id == "bake" else "stir"))
		"retry": actions.append("retry")
	actions.append("clear")
	actions.append("cancel")
	return actions


func act(action: String) -> bool:
	if action not in available_actions():
		return _fail("先按当前步骤来吧，食材仍然保留着。")
	message = ""
	if action == "cancel":
		cancelled_from = phase
		phase = "cancelled"
		cancelled = true
		message = "已返回餐厅，这份料理尚未完成。"
		return true
	if action == "clear":
		_reset_preparation()
		message = "已清空操作，可以重新选择这份配方的食材。"
		return true
	if action == "retry":
		elapsed = 0.0
		heat_level = ""
		phase = "vessel" if recipe_id == "bake" else "heat"
		if recipe_id == "bake":
			vessel = ""
		message = "食材和准备步骤都保留了，再来一次就好。"
		return true
	if action.begins_with("add_"):
		var ingredient: String = action.trim_prefix("add_")
		if ingredient == "water":
			water_added = true
		else:
			# available_actions supplies only recipe ingredients, unique and ordered.
			if ingredients.size() >= MAX_INGREDIENTS:
				return _fail("三个食材位已经满了，可以清空后重新选择。")
			ingredients.append(ingredient)
		if _ingredients_ready():
			phase = "ready" if recipe_id == "drink" else ("vessel" if recipe_id == "bake" else "prep")
	elif action == "cut":
		cut_done = true
		phase = "vessel"
	elif action in ["pot", "pan", "oven"]:
		vessel = action
		if recipe_id == "bake":
			_begin_cooking()
		else:
			phase = "heat"
	elif action.begins_with("heat_"):
		heat_level = action.trim_prefix("heat_")
		_begin_cooking()
	elif action in ["finish", "stir", "takeout"]:
		completed = true
		phase = "completed"
		message = "做得好，这份料理完成了！"
	return true


func _fail(text: String) -> bool:
	message = text
	return false


func _reset_preparation() -> void:
	ingredients.clear()
	water_added = false
	cut_done = false
	vessel = ""
	heat_level = ""
	elapsed = 0.0
	completed = false
	cancelled = false
	cancelled_from = ""
	phase = "ingredients"


func _ingredients_ready() -> bool:
	var required: Array[String] = required_ingredients()
	if ingredients.size() != required.size():
		return false
	for ingredient: String in required:
		if ingredient not in ingredients:
			return false
	return recipe_id != "soup" or water_added


func _begin_cooking() -> void:
	elapsed = 0.0
	attempts += 1
	phase = "cooking"


func cook_duration() -> float:
	if recipe_id == "bake":
		return 8.0
	if heat_level not in HEAT_LEVELS:
		return 0.0
	var durations: Dictionary = {"small": 8.0, "medium": 6.0, "high": 4.0} if recipe_id == "soup" else {"small": 6.0, "medium": 4.0, "high": 3.0}
	return float(durations[heat_level])


func set_paused(value: bool) -> void:
	paused = value


func tick(delta: float) -> void:
	if paused or phase not in ["cooking", "ready"] or recipe_id == "drink" or not is_finite(delta) or delta <= 0.0:
		return
	var duration: float = cook_duration()
	elapsed = minf(elapsed + delta, duration + READY_WINDOW)
	if elapsed >= duration + READY_WINDOW:
		phase = "retry"
		message = "火候有点过头了，食材还在，可以轻松重试。"
	elif elapsed >= duration and phase == "cooking":
		phase = "ready"
		message = "现在刚刚好，慢慢完成最后一步吧。"


func _step_index() -> int:
	var current: String = cancelled_from if cancelled else phase
	if recipe_id == "drink":
		return mini(3, ingredients.size())
	if current in ["prep", "vessel"]:
		return 1
	if current in ["heat", "cooking", "retry"]:
		return 2
	return 3 if current in ["ready", "completed"] else 0


func _prompt() -> String:
	match phase:
		"ingredients": return "依次加入咖啡、牛奶和冰块。" if recipe_id == "drink" else ("加入土豆、胡萝卜和清水；清水不占食材位。" if recipe_id == "soup" else "选择这份配方需要的食材。")
		"prep": return "把番茄切一切，鸡蛋不用切。" if recipe_id == "stir_fry" else "把土豆和胡萝卜切成小块。"
		"vessel": return "将准备好的食材放入" + ("烤箱。" if recipe_id == "bake" else ("汤锅。" if recipe_id == "soup" else "炒锅。"))
		"heat": return "选择小火、中火或大火，慢慢等它做好。"
		"cooking": return "正在烤制，稍等一会儿。" if recipe_id == "bake" else "正在加热，稍等一会儿。"
		"ready": return "搅拌均匀就完成啦。" if recipe_id == "drink" else ("已经做好了，取出烤盘吧。" if recipe_id == "bake" else ("翻炒一下就完成啦。" if recipe_id == "stir_fry" else "汤已经煮好了，点击完成吧。"))
		"retry": return "不用担心，保留食材重试，或清空重新准备。"
		"completed": return "料理完成，返回餐厅继续送餐。"
		"cancelled": return "已取消，这次不会完成订单。"
	return "选择一份订单开始料理。"


func status() -> Dictionary:
	var duration: float = cook_duration()
	var progress: float = clampf(elapsed / duration, 0.0, 1.0) if duration > 0.0 else (1.0 if completed else 0.0)
	return {"recipe_id": recipe_id, "recipe_label": recipe_label(recipe_id), "binding": binding.duplicate(true), "phase": phase, "ingredients": ingredients.duplicate(), "water_added": water_added, "cut_done": cut_done, "vessel": vessel, "heat_level": heat_level, "elapsed": elapsed, "paused": paused, "completed": completed, "cancelled": cancelled, "message": message, "prompt": _prompt(), "ingredient_options": ingredient_options(), "required_ingredients": required_ingredients(), "actions": available_actions(), "step_index": _step_index(), "step_count": 4, "steps": RECIPES[recipe_id].steps.duplicate() if RECIPES.has(recipe_id) else [], "progress": progress, "duration": duration, "ready_remaining": maxf(0.0, duration + READY_WINDOW - elapsed) if phase == "ready" and recipe_id != "drink" else -1.0, "slots_used": ingredients.size(), "max_slots": MAX_INGREDIENTS, "attempts": attempts}


func to_dict() -> Dictionary:
	return {"version": SAVE_VERSION, "binding": binding.duplicate(true), "recipe_id": recipe_id, "phase": phase, "ingredients": ingredients.duplicate(), "water_added": water_added, "cut_done": cut_done, "vessel": vessel, "heat_level": heat_level, "elapsed": elapsed, "paused": paused, "completed": completed, "cancelled": cancelled, "cancelled_from": cancelled_from, "message": message, "attempts": attempts}


func restore(data: Dictionary) -> bool:
	if not _integer(data.get("version"), 1) or int(data.version) != SAVE_VERSION:
		return false
	for key: String in ["recipe_id", "phase", "vessel", "heat_level", "cancelled_from", "message"]:
		if typeof(data.get(key)) != TYPE_STRING or str(data[key]).length() > 500:
			return false
	for key: String in ["water_added", "cut_done", "paused", "completed", "cancelled"]:
		if typeof(data.get(key)) != TYPE_BOOL:
			return false
	if not data.get("binding") is Dictionary or not data.get("ingredients") is Array or data.ingredients.size() > MAX_INGREDIENTS:
		return false
	if not _number(data.get("elapsed")) or float(data.elapsed) < 0.0 or not _integer(data.get("attempts"), 0):
		return false
	var candidate = get_script().new()
	for key: String in ["recipe_id", "phase", "vessel", "heat_level", "cancelled_from", "message", "water_added", "cut_done", "paused", "completed", "cancelled"]:
		candidate.set(key, data[key])
	for ingredient: Variant in data.ingredients:
		if typeof(ingredient) != TYPE_STRING:
			return false
		candidate.ingredients.append(ingredient)
	candidate.binding = data.binding.duplicate(true)
	if not candidate.binding.is_empty():
		if not _binding_valid(candidate.binding):
			return false
		for key: String in ["table_id", "guest_id", "generation"]:
			candidate.binding[key] = int(candidate.binding[key])
	candidate.elapsed = float(data.elapsed)
	candidate.attempts = int(data.attempts)
	if not candidate._valid_state():
		return false
	for key: String in ["binding", "recipe_id", "phase", "ingredients", "water_added", "cut_done", "vessel", "heat_level", "elapsed", "paused", "completed", "cancelled", "cancelled_from", "message", "attempts"]:
		set(key, candidate.get(key))
	return true


func _valid_state() -> bool:
	if phase not in PHASES or completed != (phase == "completed") or cancelled != (phase == "cancelled"):
		return false
	if phase == "idle":
		return binding.is_empty() and recipe_id.is_empty() and ingredients.is_empty() and not water_added and not cut_done and vessel.is_empty() and heat_level.is_empty() and elapsed == 0.0 and attempts == 0 and cancelled_from.is_empty()
	if not RECIPES.has(recipe_id) or not _binding_valid(binding):
		return false
	var current: String = cancelled_from if cancelled else phase
	if cancelled and current not in ["ingredients", "prep", "vessel", "heat", "cooking", "ready", "retry"]:
		return false
	if not cancelled and not cancelled_from.is_empty():
		return false
	var required: Array[String] = required_ingredients()
	var unique: Dictionary = {}
	for ingredient: String in ingredients:
		if ingredient not in required or unique.has(ingredient):
			return false
		unique[ingredient] = true
	if recipe_id == "drink":
		for index: int in range(ingredients.size()):
			if ingredients[index] != required[index]:
				return false
	if water_added and recipe_id != "soup":
		return false
	if cut_done and recipe_id not in ["soup", "stir_fry"]:
		return false
	if not vessel.is_empty() and vessel != str(RECIPES[recipe_id].vessel):
		return false
	if not heat_level.is_empty() and (heat_level not in HEAT_LEVELS or recipe_id not in ["soup", "stir_fry"]):
		return false
	var empty_tools: bool = not cut_done and vessel.is_empty() and heat_level.is_empty() and elapsed == 0.0
	if current == "ingredients":
		return not _ingredients_ready() and empty_tools and (recipe_id != "drink" or attempts == 0)
	if not _ingredients_ready():
		return false
	if recipe_id == "drink":
		return current in ["ready", "completed"] and empty_tools and attempts == 0
	if current == "prep":
		return recipe_id in ["soup", "stir_fry"] and empty_tools
	var correctly_cut: bool = cut_done == (recipe_id in ["soup", "stir_fry"])
	if not correctly_cut:
		return false
	if current == "vessel":
		return vessel.is_empty() and heat_level.is_empty() and elapsed == 0.0
	if vessel != str(RECIPES[recipe_id].vessel):
		return false
	if current == "heat":
		return recipe_id in ["soup", "stir_fry"] and heat_level.is_empty() and elapsed == 0.0
	if current not in ["cooking", "ready", "retry", "completed"] or attempts < 1:
		return false
	if recipe_id in ["soup", "stir_fry"] and heat_level not in HEAT_LEVELS:
		return false
	var duration: float = cook_duration()
	if current == "cooking":
		return elapsed < duration
	if current == "retry":
		return is_equal_approx(elapsed, duration + READY_WINDOW)
	return elapsed >= duration and elapsed < duration + READY_WINDOW


func _number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))


func _integer(value: Variant, minimum: int) -> bool:
	return _number(value) and float(value) >= minimum and float(value) <= 1000000000.0 and floorf(float(value)) == float(value)


func _binding_valid(value: Dictionary) -> bool:
	return value.size() == 3 and _integer(value.get("table_id"), 1) and int(value.table_id) <= 20 and _integer(value.get("guest_id"), 1) and _integer(value.get("generation"), 1)
