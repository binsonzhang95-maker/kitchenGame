extends SceneTree

const SPECIES := ["cat", "dog", "panda", "capybara", "hamster"]
const SIDE_FRAMES := {
	"sit_down": 4,
	"seated_idle": 2,
	"eat": 4,
	"drink": 4,
	"happy": 4,
	"complain": 4,
	"chat": 4,
	"stand_up": 3,
}
const TRANSITION_PIVOTS := {
	"cat": {
		"sit_down": [[64, 120], [64, 110], [64, 110], [64, 110]],
		"stand_up": [[64, 110], [64, 110], [64, 120]],
	},
	"dog": {
		"sit_down": [[64, 120], [64, 110], [64, 110], [64, 110]],
		"stand_up": [[64, 110], [64, 110], [64, 120]],
	},
	"panda": {
		"sit_down": [[64, 120], [64, 120], [64, 110], [64, 110]],
		"stand_up": [[64, 110], [64, 120], [64, 120]],
	},
	"capybara": {
		"sit_down": [[64, 120], [64, 120], [64, 110], [64, 110]],
		"stand_up": [[64, 110], [64, 120], [64, 120]],
	},
	"hamster": {
		"sit_down": [[64, 120], [64, 110], [64, 110], [64, 110]],
		"stand_up": [[64, 110], [64, 110], [64, 120]],
	},
}
const ASSET_PROPS := ["chair_side", "table_family", "table_family_top", "table_family_front", "dish_group", "cup_side", "bench_queue"]
const RESTAURANT_PROPS := ["menu_board", "wall_frame_1", "wall_frame_2", "wall_frame_3", "wall_shelf", "pendant_lamp", "rug_large", "rug_runner", "doormat", "host_stand", "coat_rack", "plant_big", "service_station", "bar_counter", "wainscot", "ceiling_beam", "window_curtain", "floor_border", "window_view_day", "floor_decal_1", "floor_decal_2", "floor_decal_3", "floor_decal_4", "table_vase_1", "table_vase_2", "table_vase_3", "table_vase_4", "tablecloth_1", "tablecloth_2", "tablecloth_3"]

var assertions := 0
var failures := 0
var png_paths := 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("G11_ASSET_FAIL " + description)


func _json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(parsed is Dictionary, path + " parses as an object")
	return parsed if parsed is Dictionary else {}


func _png(path: String, description: String) -> void:
	png_paths += 1
	_expect(FileAccess.file_exists(path), description + " exists at " + path)
	var image := Image.load_from_file(path)
	_expect(image != null and not image.is_empty(), description + " is loadable")


func _clip_paths(root: String, name: String, clip: Dictionary) -> void:
	var count := int(clip.get("frames", -1))
	var rects: Array = clip.get("frame_rects", [])
	_expect(count == rects.size(), root + " " + name + " frame_rects match frames")
	_png(root.path_join(str(clip.get("sheet", ""))), root + " " + name + " sheet")
	for index in range(rects.size()):
		var frame: Dictionary = rects[index]
		_expect(int(frame.get("x", -1)) == index * 128 and int(frame.get("w", -1)) == 128 and int(frame.get("h", -1)) == 128, root + " " + name + " frame %d is horizontal 128px atlas data" % index)
		_png(root.path_join(str(frame.get("file", ""))), root + " " + name + " frame %d" % index)


func _pivot_sequence(species: String, action: String, count: int) -> Array:
	if action == "sit_down" or action == "stand_up":
		return TRANSITION_PIVOTS[species][action]
	var pivots: Array = []
	for index in range(count):
		pivots.append([64, 110])
	return pivots


func _clip_pivots(species: String, action: String, clip: Dictionary) -> void:
	var count := int(clip.get("frames", -1))
	var expected := _pivot_sequence(species, action, count)
	var declared: Array = clip.get("per_frame_pivot", [])
	var rects: Array = clip.get("frame_rects", [])
	_expect(declared.size() == count, species + " " + action + " has one declared pivot per frame")
	_expect(rects.size() == count, species + " " + action + " has one frame rect per frame")
	for index in range(count):
		var declared_pivot: Array = declared[index] if index < declared.size() and declared[index] is Array else []
		var rect: Dictionary = rects[index] if index < rects.size() and rects[index] is Dictionary else {}
		var rect_pivot: Array = rect.get("pivot", [])
		_expect(declared_pivot.size() == 2 and int(declared_pivot[0]) == int(expected[index][0]) and int(declared_pivot[1]) == int(expected[index][1]), species + " " + action + " declared pivot %d preserves source contract" % index)
		_expect(rect_pivot.size() == 2 and int(rect_pivot[0]) == int(expected[index][0]) and int(rect_pivot[1]) == int(expected[index][1]), species + " " + action + " frame_rect pivot %d preserves source contract" % index)


func _run() -> void:
	for species: String in SPECIES:
		var side_root := "res://assets/side/" + species
		var side := _json(side_root.path_join("g11_animation.json"))
		_expect(side.get("schema") == "g11.side_animation.v1", species + " side metadata uses the G11 canonical schema")
		var pivot: Array = side.get("pivot", [])
		_expect(side.get("direction") == "right" and pivot.size() == 2 and int(pivot[0]) == 64 and int(pivot[1]) == 110, species + " side metadata has the right-facing seated pivot")
		var side_actions: Dictionary = side.get("actions", {})
		_expect(side_actions.size() == SIDE_FRAMES.size(), species + " has eight side actions")
		for action: String in SIDE_FRAMES:
			_expect(side_actions.has(action), species + " side has " + action)
			if side_actions.has(action):
				var clip: Dictionary = side_actions[action]
				_expect(int(clip.get("frames", -1)) == int(SIDE_FRAMES[action]), species + " " + action + " frame count")
				_clip_paths(side_root, action, clip)
				_clip_pivots(species, action, clip)
				if action == "eat":
					var hands: Array = clip.get("hands_foreground", [])
					_expect(hands.size() == 4, species + " eat has four hands foreground frames")
					for hand: String in hands:
						_png(side_root.path_join(hand), species + " eat foreground")

		var action_root := "res://assets/actions/" + species
		var action_metadata := _json(action_root.path_join("animation.json"))
		var actions: Dictionary = action_metadata.get("actions", {})
		for preserved: String in ["eat", "complain", "happy"]:
			_expect(actions.has(preserved), species + " preserves legacy " + preserved)
		_expect(actions.has("chat"), species + " adds chat to the existing actions map")
		if actions.has("chat"):
			var chat: Dictionary = actions["chat"]
			_expect(chat.get("direction") == "front_down" and bool(chat.get("loop", false)), species + " chat is a looping front-down clip")
			_expect(int(chat.get("frames", -1)) == 4, species + " chat has four frames")
			_clip_paths(action_root, "chat", chat)

	var anchors := _json("res://assets/props/anchors.json")
	_expect(anchors.has("table") and anchors.has("chair"), "legacy asset prop anchors remain")
	for name: String in ASSET_PROPS:
		_expect(anchors.has(name), "G11 asset prop anchor " + name)
		_png("res://assets/props/" + name + ".png", "G11 asset prop " + name)

	var restaurant := _json("res://restaurant_art/props.json")
	var props: Dictionary = restaurant.get("props", {})
	_expect(props.has("plant") and props.has("high_table"), "legacy restaurant props remain")
	for name: String in RESTAURANT_PROPS:
		_expect(props.has(name), "G11 restaurant prop metadata " + name)
		if props.has(name):
			_png("res://restaurant_art/" + str(props[name].get("file", "")), "G11 restaurant prop " + name)
	_expect(restaurant.get("g11_variant_aliases", {}).has("floor_decals.png"), "batch2 aliases are retained outside the normalized props map")
	_expect(png_paths == 267, "exactly 267 G11 PNG runtime paths are covered")
	print("G11_ASSET_RESULT assertions=%d failures=%d png_paths=%d" % [assertions, failures, png_paths])
	quit(0 if failures == 0 else 1)
