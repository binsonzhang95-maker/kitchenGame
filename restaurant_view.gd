extends Node2D
## Pixel canvas: every asset remains at its original pixel size, then the room is scaled 2x.
var model
var clock := 0.0
var textures: Dictionary = {}
var metadata: Dictionary = {}
const ROOT := "res://assets/"
const TABLE := Vector2(190, 152)
const SEAT := Vector2(196, 68)
const QUEUE := Vector2(79, 142)
const DOOR := Vector2(-70, 150)
const CLEANUP := Vector2(277, 94)
const HOME := Vector2(352, 113)
const FOOD_SUPPORT := TABLE + Vector2(102, 26)
const CUP_SUPPORT := TABLE + Vector2(130, 26)
const DISH_ORIGIN := Vector2(17, 16)

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for file in ["base/cat/animation.json", "actions/cat/animation.json", "actions/rabbit/animation.json", "actions/bear/animation.json", "drinks/rabbit/animation.json", "drinks/cat/animation.json", "cleanup/rabbit/animation.json", "seating/cat/animation.json"]:
		metadata[file] = JSON.parse_string(FileAccess.get_file_as_string(ROOT + file))

func _tex(path: String) -> Texture2D:
	if not textures.has(path):
		textures[path] = load(ROOT + path)
	return textures[path] as Texture2D

func _prop(path: String, origin: Vector2) -> void:
	var texture := _tex(path)
	if texture:
		draw_texture(texture, origin)

func _frame(path: String, origin: Vector2, index: int, row: int = 0) -> void:
	var texture := _tex(path)
	if texture:
		draw_texture_rect_region(texture, Rect2(origin.round(), Vector2(128, 128)), Rect2(index * 128, row * 128, 128, 128))

func _index(seconds: float, durations: Array, looping: bool = false) -> int:
	var total := 0.0
	for duration in durations:
		total += float(duration) / 1000.0
	var moment := fmod(maxf(seconds, 0.0), total) if looping else maxf(seconds, 0.0)
	for i in range(durations.size()):
		moment -= float(durations[i]) / 1000.0
		if moment < 0.0:
			return i
	return durations.size() - 1

func _rect(box: Rect2, color: String) -> void:
	draw_rect(box, Color(color))

func _room() -> void:
	_rect(Rect2(0, 0, 480, 288), "ead8b5")
	for y in range(76, 288, 24):
		_rect(Rect2(0, y, 480, 1), "d4b78d")
		for x in range(-48 if y % 48 == 4 else 0, 480, 96):
			_rect(Rect2(x, y, 1, 24), "ddc29a")
	_rect(Rect2(0, 0, 480, 74), "f5ecd6")
	_rect(Rect2(0, 72, 480, 6), "937250")
	_rect(Rect2(0, 78, 480, 4), "c5a273")
	# Pale sage window and shelves. Geometry is decoration, never a baked character scene.
	_rect(Rect2(210, 13, 104, 52), "a18059")
	_rect(Rect2(214, 17, 96, 44), "bdd4bf")
	_rect(Rect2(217, 20, 40, 18), "dce6c8")
	_rect(Rect2(260, 17, 4, 44), "a18059")
	_rect(Rect2(214, 38, 96, 4), "a18059")
	_rect(Rect2(206, 63, 112, 5), "b99164")
	_rect(Rect2(350, 32, 93, 5), "b99164")
	for x in [357, 376, 402, 424]:
		_rect(Rect2(x, 19, 11, 13), "d9a779" if x < 400 else "9cb29c")
		_rect(Rect2(x - 1, 18, 13, 3), "997553")
	# Door / waiting rug.
	_rect(Rect2(0, 181, 30, 72), "96704f")
	_rect(Rect2(0, 185, 24, 64), "b8cbb5")
	_rect(Rect2(25, 220, 3, 5), "f6e7bb")
	_rect(Rect2(37, 243, 85, 29), "c2c8a5")
	_rect(Rect2(41, 247, 77, 21), "dce0bc")
	# Kitchen tile wall and simple stove, behind the bear.
	_rect(Rect2(14, 12, 145, 88), "d5dfcf")
	for y in range(12, 100, 16):
		_rect(Rect2(14, y, 145, 1), "b9c9b5")
	for x in range(14, 159, 24):
		_rect(Rect2(x, 12, 1, 88), "b9c9b5")
	# Small plant.
	_rect(Rect2(440, 217, 25, 27), "b88060")
	_rect(Rect2(437, 213, 31, 6), "d1a27d")
	_rect(Rect2(451, 181, 4, 32), "667d56")
	for box in [Rect2(433, 180, 20, 12), Rect2(452, 169, 17, 15), Rect2(453, 193, 19, 12), Rect2(439, 199, 14, 9)]:
		draw_rect(box, Color("8fa778"))
	# Floor shadows below furniture.
	_rect(Rect2(197, 235, 128, 8), "d4bd98")
	_prop("props/chair.png", Vector2(232, 112))

func _cat() -> void:
	var p: String = model.phase
	var e: float = model.elapsed
	if p in ["dirty", "collecting", "wiping", "ready_next"]:
		return
	if p == "entering":
		_frame("base/cat/walk.png", DOOR.lerp(QUEUE, clampf(e / 2.0, 0, 1)), int(clock / 0.16) % 4, 2)
	elif p == "queued":
		_frame("base/cat/idle.png", QUEUE, _index(clock, [1600, 140], true))
	elif p == "seating":
		if e < 0.58:
			_frame("base/cat/walk.png", QUEUE.lerp(SEAT, e / 0.58), int(clock / 0.16) % 4, 3)
		else:
			_frame("seating/cat/sit_down.png", SEAT, _index(e - 0.58, metadata["seating/cat/animation.json"].duration_ms))
	elif p == "leaving":
		var start: Vector2 = SEAT if model.table_used else QUEUE
		var point := start.lerp(DOOR, clampf(e / 2.0, 0, 1))
		_frame("base/cat/walk.png", point, int(clock / 0.16) % 4, 1)
	elif p == "eating":
		_frame("actions/cat/eat.png", SEAT, _index(e, metadata["actions/cat/animation.json"].actions.eat.duration_ms, true))
	elif p == "drinking" and e < 1.16:
		_frame("drinks/cat/drink.png", SEAT, _index(e, [240, 220, 420, 280]))
	elif p == "checkout" and e < 0.88:
		_frame("actions/cat/happy.png", SEAT, _index(e, metadata["actions/cat/animation.json"].actions.happy.duration_ms))
	else:
		_frame("seating/cat/sit_down.png", SEAT, 3)

func _bear() -> void:
	if model.phase == "cooking":
		_frame("actions/bear/cook.png", Vector2(25, 9), _index(model.elapsed, metadata["actions/bear/animation.json"].cook.duration_ms, true))
	elif model.phase == "food_ready":
		_frame("actions/bear/serve.png", Vector2(25, 9), _index(model.elapsed, metadata["actions/bear/animation.json"].serve.duration_ms))
	else:
		_frame("base/bear/idle.png", Vector2(25, 9), _index(clock, [1600, 140], true))
	_rect(Rect2(12, 108, 150, 12), "ac8057")
	_rect(Rect2(16, 120, 142, 35), "d9b58a")
	_rect(Rect2(20, 125, 62, 24), "e7cca5")
	_rect(Rect2(88, 125, 65, 24), "e7cca5")
	_rect(Rect2(68, 130, 5, 3), "937454")
	_rect(Rect2(98, 130, 5, 3), "937454")
	if model.phase == "food_ready":
		var serve: Dictionary = metadata["actions/bear/animation.json"].serve
		var i := _index(model.elapsed, serve.duration_ms)
		var anchor: Array = serve.frames[i].dish_anchor
		_prop("props/dish.png", Vector2(25, 9) + Vector2(anchor[0], anchor[1]) - DISH_ORIGIN)

func _service_origin(food: bool) -> Vector2:
	# Derive the standing position from the real release hand so one world prop
	# remains at exactly the same support point after detaching.
	if food:
		var food_clip: Dictionary = metadata["actions/rabbit/animation.json"].place_dish
		var hand_anchor: Array = food_clip.frames[int(food_clip.release_event.frame)].hand_anchor
		return FOOD_SUPPORT - Vector2(hand_anchor[0], hand_anchor[1])
	var cup_clip: Dictionary = metadata["drinks/rabbit/animation.json"].place_cup
	var cup_anchor: Array = cup_clip.frames[int(cup_clip.release_frame)].world_cup_anchor
	return CUP_SUPPORT - Vector2(cup_anchor[0], cup_anchor[1])

func _route(seconds: float, destination: Vector2) -> Vector2:
	var progress := clampf(seconds / 2.2, 0, 1)
	if progress < 0.35:
		return Vector2(96, 60).lerp(Vector2(96, 146), progress / 0.35)
	if progress < 0.78:
		return Vector2(96, 146).lerp(Vector2(destination.x, 146), (progress - 0.35) / 0.43)
	return Vector2(destination.x, 146).lerp(destination, (progress - 0.78) / 0.22)

func _rabbit() -> void:
	var p: String = model.phase
	var e: float = model.elapsed
	if p in ["serving_food", "serving_drink"]:
		var food := p == "serving_food"
		var service_origin := _service_origin(food)
		if e < 2.2:
			var path := "actions/rabbit/carry_walk.png" if food else "drinks/rabbit/carry_drinks.png"
			var row := 0 if e / 2.2 < 0.35 else (2 if e / 2.2 < 0.78 else 3)
			_frame(path, _route(e, service_origin), int(clock / 0.14) % 4, row)
		else:
			var clip: Dictionary = metadata["actions/rabbit/animation.json"].place_dish if food else metadata["drinks/rabbit/animation.json"].place_cup
			var i := _index(e - 2.2, clip.duration_ms)
			_frame("actions/rabbit/place_dish.png" if food else "drinks/rabbit/place_cup.png", service_origin, i)
			if i < 2:
				var anchor: Array = clip.frames[i].dish_anchor if food else clip.frames[i].cup_anchor
				var offset := DISH_ORIGIN if food else Vector2(11, 18)
				_prop("props/dish.png" if food else "drinks/rabbit/cup.png", service_origin + Vector2(anchor[0], anchor[1]) - offset)
	elif p == "collecting":
		var clip: Dictionary = metadata["cleanup/rabbit/animation.json"].collect
		var i := _index(e, clip.duration_ms)
		_frame("cleanup/rabbit/collect.png", CLEANUP, i)
		if i in [1, 2]:
			var anchor: Array = clip.hand_prop_anchors[i]
			_draw_stack(CLEANUP + Vector2(anchor[0], anchor[1]))
	elif p == "wiping":
		var clip: Dictionary = metadata["cleanup/rabbit/animation.json"].wipe
		var i := _index(e, clip.duration_ms)
		_frame("cleanup/rabbit/wipe.png", CLEANUP, i)
		if i < 3:
			var anchor: Array = clip.cloth_bottom_center[i]
			_prop("cleanup/props/cloth.png", CLEANUP + Vector2(anchor[0], anchor[1]) - Vector2(13, 14))
	else:
		_frame("base/rabbit/idle.png", HOME, _index(clock, [1600, 140], true))

func _draw_stack(point: Vector2) -> void:
	if model.food_delivered:
		_prop("cleanup/props/empty_plate.png", point - Vector2(17, 20))
	if model.drink_delivered:
		_prop("cleanup/props/empty_cup.png", point + Vector2(1, -10) - Vector2(11, 20))

func _table_props() -> void:
	var p: String = model.phase
	var e: float = model.elapsed
	var clear_stages := ["entering", "queued", "seating", "ordering", "awaiting_cook", "cooking", "food_ready", "ready_next"]
	if p in clear_stages:
		return
	var dirty: bool = p in ["dirty", "collecting", "wiping"]
	if dirty:
		var alpha := 1.0
		if p == "wiping":
			var clip: Dictionary = metadata["cleanup/rabbit/animation.json"].wipe
			alpha = float(clip.stain_remaining_fraction[_index(e, clip.duration_ms)])
		if alpha > 0:
			draw_texture(_tex("cleanup/props/stain.png"), TABLE + Vector2(74, 16), Color(1, 1, 1, alpha))
		var picked: bool = p == "wiping" or (p == "collecting" and _index(e, metadata["cleanup/rabbit/animation.json"].collect.duration_ms) >= 1)
		if not picked:
			_draw_stack(TABLE + Vector2(109, 39))
		return
	var food_clip: Dictionary = metadata["actions/rabbit/animation.json"].place_dish
	var cup_clip: Dictionary = metadata["drinks/rabbit/animation.json"].place_cup
	var food_visible: bool = model.food_delivered or (p == "serving_food" and e >= 2.2 and _index(e - 2.2, food_clip.duration_ms) >= int(food_clip.release_event.frame))
	var cup_visible: bool = model.drink_delivered or (p == "serving_drink" and e >= 2.2 and _index(e - 2.2, cup_clip.duration_ms) >= int(cup_clip.release_frame))
	if food_visible:
		if p in ["drinking", "checkout", "leaving"]:
			_prop("cleanup/props/empty_plate.png", FOOD_SUPPORT - DISH_ORIGIN)
		else:
			_prop("props/dish.png", FOOD_SUPPORT - DISH_ORIGIN)
	# The drinking animation contains its own cup. Only expose the world cup after it ends.
	if cup_visible and not (p == "drinking" and e < 1.16):
		_prop("drinks/rabbit/cup.png", CUP_SUPPORT - Vector2(11, 18))

func _draw() -> void:
	if model == null:
		return
	_room()
	_bear()
	_cat()
	_prop("props/table_top.png", TABLE)
	_prop("props/table_front.png", TABLE)
	_table_props()
	_rabbit()
	# Supplied full-cell foreground layers keep hands above the table occluder.
	if model.phase == "eating":
		var i := _index(model.elapsed, metadata["actions/cat/animation.json"].actions.eat.duration_ms, true)
		_prop("actions/cat/hands_foreground/eat_%02d.png" % i, SEAT)
	elif model.phase == "drinking" and model.elapsed < 1.16:
		var i := _index(model.elapsed, [240, 220, 420, 280])
		var foreground: String = metadata["drinks/cat/animation.json"].frames[i].foreground_file
		_prop("drinks/cat/" + foreground, SEAT)
