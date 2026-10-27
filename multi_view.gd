extends Node2D

signal table_selected(id: int)
const SCALE: float = 0.75
const ROOT := "res://assets/"
const ART_ROOT := "res://restaurant_art/"
const G11Art = preload("res://g11_art.gd")
const G11DecorLayout = preload("res://g11_decor_layout.gd")
const BACKGROUND := ART_ROOT + "restaurant_open_background.png"
const RECIPE_DISHES := {
	"pumpkin_corn_soup": "food/dishes/pumpkin_corn_soup_32.png",
	"pan_fried_mushrooms": "food/dishes/pan_seared_mushrooms_32.png",
	"bake": "food/dishes/cheese_toast_32.png",
	"drink": "food/dishes/iced_latte_32.png",
}
# The original 34x20 generic plate is held from its painted plate centre, while
# the new 32px recipe art is held from its lower plate edge.
const DISH_ANCHOR := Vector2(16,30)
const GENERIC_DISH_ANCHOR := Vector2(17,16)
const FOOD_TABLE_ANCHOR := Vector2(45,-8)
# The delivered front chat sheets sit lower than the legacy seated front art.
# This is a presentation-only support adjustment in source pixels: retain each
# action frame's canonical pivot and keep model-owned seat geometry unchanged.
const FRONT_CHAT_POSE_OFFSET := Vector2(0,-24)
var model: Variant
var selected_table: int = 1
var clock: float = 0.0
var catalog: Dictionary
var textures: Dictionary = {}
var background: Texture2D
var action_metadata: Dictionary = {}
var place_dish_anchor_cache: Dictionary = {}
var decor_cache: Array[Dictionary] = []
var decor_cache_key: String = ""

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	catalog = JSON.parse_string(FileAccess.get_file_as_string("res://asset_catalog.json"))
	if ResourceLoader.exists(BACKGROUND):
		background = load(BACKGROUND) as Texture2D
	else:
		push_warning("Open-door restaurant background is missing; the closed-door artwork is not a navigation fallback.")

func _tex(path: String) -> Texture2D:
	if not textures.has(path): textures[path] = load(ROOT + path)
	return textures[path] as Texture2D

func _prop(path: String, origin: Vector2, scale_factor: float = SCALE) -> void:
	var texture: Texture2D = _tex(path)
	if texture: draw_texture_rect(texture, Rect2(origin.round(), texture.get_size()*scale_factor), false)

func _art_prop(path: String, origin: Vector2) -> void:
	var key: String = ART_ROOT + path
	if not textures.has(key): textures[key] = load(key)
	var texture: Texture2D = textures[key] as Texture2D
	if texture: draw_texture(texture, origin.round())

func _res_prop(path: String, origin: Vector2, scale_factor: float = 1.0) -> void:
	if not textures.has(path): textures[path] = load(path)
	var texture: Texture2D = textures[path] as Texture2D
	if texture:
		draw_texture_rect(texture, Rect2(origin.round(), texture.get_size() * scale_factor), false)

func _g11_decorations() -> Array[Dictionary]:
	var floor: Variant = _floor_instance()
	if floor == null:
		return []
	var key := "%s:%s:%s" % [str(floor.get_instance_id()), str(floor.get("revision")), str(floor.get("layout_width"))]
	if key == decor_cache_key:
		return decor_cache
	if floor.has_method("decoration_definitions"):
		var definitions: Variant = floor.decoration_definitions()
		if definitions is Array:
			decor_cache = definitions
			decor_cache_key = key
			return decor_cache
	decor_cache = G11DecorLayout.build(float(floor.SIZE.x))
	decor_cache_key = key
	return decor_cache

func _draw_g11_decor(layer: String) -> void:
	for entry: Dictionary in _g11_decorations():
		if str(entry.get("layer", "")) == layer:
			_res_prop(str(entry.get("path", "")), Vector2(entry.get("position", Vector2.ZERO)), float(entry.get("scale", 1.0)))

func _g11_object_hit(point: Vector2) -> bool:
	for entry: Dictionary in _g11_decorations():
		var footprint: Rect2 = entry.get("footprint", Rect2())
		if bool(entry.get("collision", false)) and footprint.has_point(point):
			return true
	return false

func _index(seconds: float, clip: Dictionary) -> int:
	var durations: Array = clip.duration_ms
	var total: float = float(clip.duration_total_ms)/1000.0
	var moment: float = fmod(maxf(seconds,0),total) if bool(clip.loop) else maxf(seconds,0)
	for i in range(durations.size()):
		moment -= float(durations[i])/1000.0
		if moment < 0: return i
	return durations.size()-1

func _clip(species: String, group: String, name: String) -> Dictionary:
	var entry: Dictionary = catalog.customers.get(species,catalog.staff.get(species,{}))
	return entry[group].clips[name]


func _action_metadata(species: String) -> Dictionary:
	# Hand anchors are authored beside each animation sheet.  Cache the parsed file
	# because this path is read from the draw loop while a server is placing a dish.
	if action_metadata.has(species):
		return action_metadata[species]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/actions/%s/animation.json" % species))
	action_metadata[species] = parsed if parsed is Dictionary else {}
	return action_metadata[species]


func _place_dish_anchors(species: String) -> Dictionary:
	if place_dish_anchor_cache.has(species):
		return place_dish_anchor_cache[species]
	var action: Dictionary = _action_metadata(species)
	var place: Dictionary = action.get("place_dish",{})
	var frames: Array = place.get("frames",[])
	var hands: Array = []
	for frame: Dictionary in frames:
		var anchor: Array = frame.get("hand_anchor",[])
		hands.append(Vector2(anchor[0],anchor[1]) if anchor.size() == 2 else Vector2.ZERO)
	var release: Vector2 = hands[2] if hands.size() > 2 else Vector2.ZERO
	for event: Dictionary in place.get("events",[]):
		var anchor: Array = event.get("anchor",[])
		if int(event.get("frame",-1)) == 2 and anchor.size() == 2:
			release = Vector2(anchor[0],anchor[1])
	place_dish_anchor_cache[species] = {"hands":hands,"release":release,"release_frame":2}
	return place_dish_anchor_cache[species]


func food_render_plan(table: Dictionary, species: String = "", elapsed: float = -1.0) -> Dictionary:
	# Read-only plan shared by the tabletop and the transient held-dish pass.
	# It also gives isolated visual tests a way to inspect real metadata without
	# duplicating the production mapping or hard-coding animal-specific offsets.
	var recipe_id: String = str(table.get("recipe_id",""))
	var recipe_art: bool = RECIPE_DISHES.has(recipe_id)
	var table_anchor: Vector2 = _table_visual_center(table) if _family_table(table) else Vector2(table.center) + FOOD_TABLE_ANCHOR*SCALE
	var dish_anchor: Vector2 = DISH_ANCHOR if recipe_art else GENERIC_DISH_ANCHOR
	var plan: Dictionary = {
		"texture_path": str(RECIPE_DISHES.get(recipe_id,"props/dish.png")),
		"recipe_art": recipe_art,
		"dish_anchor": dish_anchor,
		"table_anchor": table_anchor,
		"table_origin": table_anchor-dish_anchor*SCALE,
	}
	if species.is_empty():
		return plan
	var anchors: Dictionary = _place_dish_anchors(species)
	var clip: Dictionary = _clip(species,"actions","place_dish")
	var frame: int = _index(elapsed,clip)
	var hands: Array = anchors.hands
	var hand_anchor: Vector2 = hands[frame] if frame < hands.size() else Vector2.ZERO
	var animation_origin: Vector2 = table_anchor-Vector2(anchors.release)*SCALE
	plan.merge({
		"frame":frame,
		"release_anchor":anchors.release,
		"hand_anchor":hand_anchor,
		"animation_origin":animation_origin,
		"handheld_origin":animation_origin+hand_anchor*SCALE-dish_anchor*SCALE,
		"attached":frame < int(anchors.release_frame),
	})
	return plan


func table_food_render_plan(table: Dictionary) -> Dictionary:
	var plan: Dictionary = food_render_plan(table)
	if str(table.phase) in ["drinking","checkout","leaving"]:
		plan.merge({"texture_path":"cleanup/props/empty_plate.png","recipe_art":false,"dish_anchor":GENERIC_DISH_ANCHOR,"table_origin":plan.table_anchor-GENERIC_DISH_ANCHOR*SCALE},true)
	return plan

func _draw_clip(clip: Dictionary, origin: Vector2, elapsed: float, fixed: int = -1) -> int:
	var i: int = _index(elapsed,clip) if fixed < 0 else fixed
	var rect: Array = clip.rects[i]
	var texture: Texture2D = _tex(clip.sheet)
	if texture:
		draw_texture_rect_region(texture,Rect2(origin.round(),Vector2(128,128)*SCALE),Rect2(rect[0],rect[1],rect[2],rect[3]))
	return i

func _floor_instance() -> Variant:
	# Geometry is deliberately instance-owned: a landscape viewport can have a
	# wider restaurant without leaking a resize into another model or save.
	return model.get("floor") if model != null else null

func _tile_background(destination: Rect2, source: Rect2, tile: Vector2) -> void:
	var y := destination.position.y
	while y < destination.end.y:
		var h := minf(tile.y, destination.end.y - y)
		var x := destination.position.x
		while x < destination.end.x:
			var w := minf(tile.x, destination.end.x - x)
			draw_texture_rect_region(background, Rect2(x, y, w, h), Rect2(source.position, Vector2(source.size.x * w / tile.x, source.size.y * h / tile.y)))
			x += w
		y += h

func _draw_wall_piece(piece: Dictionary) -> void:
	if bool(piece.get("tiled", false)):
		_tile_background(piece.destination, piece.source, piece.tile)
	else:
		draw_texture_rect_region(background, piece.destination, piece.source)

## One non-overlapping draw list for the facade. The middle is split vertically
## only so its lower pixels can occlude actors without painting the wall twice.
static func front_wall_draw_plan(size: Vector2) -> Array[Dictionary]:
	var bottom_y := size.y - 124.0
	var right_x := size.x - 336.0
	var entrance := Rect2(size.x * 0.5 - 112.0, bottom_y, 224.0, 124.0)
	return [
		{"kind":"left_end", "layer":"background", "baseline":bottom_y, "destination":Rect2(0, bottom_y, 388, 124), "source":Rect2(0, 900, 388, 124)},
		{"kind":"left_middle_top", "layer":"background", "baseline":bottom_y, "destination":Rect2(388, bottom_y, maxf(0, entrance.position.x - 388), 34), "source":Rect2(400, 900, 256, 34), "tile":Vector2(256, 34), "tiled":true},
		{"kind":"entrance", "layer":"background", "baseline":bottom_y, "destination":entrance, "source":Rect2(656, 900, 224, 124)},
		{"kind":"right_middle_top", "layer":"background", "baseline":bottom_y, "destination":Rect2(entrance.end.x, bottom_y, maxf(0, right_x - entrance.end.x), 34), "source":Rect2(880, 900, 256, 34), "tile":Vector2(256, 34), "tiled":true},
		{"kind":"right_end", "layer":"background", "baseline":bottom_y, "destination":Rect2(right_x, bottom_y, 336, 124), "source":Rect2(1200, 900, 336, 124)},
		{"kind":"left_middle_front", "layer":"foreground", "baseline":bottom_y, "destination":Rect2(388, bottom_y + 34, maxf(0, entrance.position.x - 388), 90), "source":Rect2(400, 934, 256, 90), "tile":Vector2(256, 90), "tiled":true},
		{"kind":"right_middle_front", "layer":"foreground", "baseline":bottom_y, "destination":Rect2(entrance.end.x, bottom_y + 34, maxf(0, right_x - entrance.end.x), 90), "source":Rect2(880, 934, 256, 90), "tile":Vector2(256, 90), "tiled":true},
	]

func _draw_room_architecture(floor: Variant) -> void:
	if background == null or floor == null:
		return
	var size: Vector2 = floor.SIZE
	var right_x := size.x - 336.0
	# Start with clean authored floor/wall pixels, then restore the fixed original
	# room and terrace strips without stretching any window, mat, plant or rail.
	_tile_background(Rect2(Vector2.ZERO, size), Rect2(576, 384, 256, 192), Vector2(256, 192))
	_tile_background(Rect2(0, 0, size.x, 16), Rect2(1080, 0, 40, 16), Vector2(40, 16))
	_tile_background(Rect2(0, 16, size.x, 160), Rect2(1080, 16, 40, 80), Vector2(40, 80))
	draw_texture_rect_region(background, Rect2(0, 0, 388, 900), Rect2(0, 0, 388, 900))
	draw_texture_rect_region(background, Rect2(right_x, 0, 336, 900), Rect2(1200, 0, 336, 900))
	# Widen the terrace gate for a 64x32 actor footprint; replace the removed
	# rail pixels with the same authored floor tile used by the hall.
	_tile_background(Rect2(right_x, 432, 24, 102), Rect2(576, 384, 24, 102), Vector2(24, 102))
	# Every facade pixel comes from one shared plan, so the fixed ends, repeated
	# bays and open entrance keep the same baseline as the room height changes.
	for piece: Dictionary in front_wall_draw_plan(size):
		if piece.layer == "background":
			_draw_wall_piece(piece)
	# Keep kitchen equipment, nearby back-wall windows and plants at native scale.
	var kitchen_source := Rect2(416, 0, 704, 176)
	var kitchen_destination := Rect2((size.x - kitchen_source.size.x) * 0.5, 0, kitchen_source.size.x, kitchen_source.size.y)
	draw_texture_rect_region(background, kitchen_destination, kitchen_source)
	var lamp_x := 430.0
	while lamp_x < right_x - 32.0:
		var lamp_destination := Rect2(lamp_x, 102, 32, 48)
		if not lamp_destination.intersects(kitchen_destination):
			_art_prop("props/lamp.png", lamp_destination.position)
		lamp_x += 264.0

func _draw_counter(counter: Rect2) -> void:
	# Keep the counter's end caps at their native width; only the deliberately
	# plain middle timber repeats when a wide floor requests a longer counter.
	var source := Rect2(506, 176, 646, 78)
	if counter.size.x < 128.0:
		draw_texture_rect_region(background, counter, source)
		return
	var cap := 64.0
	draw_texture_rect_region(background, Rect2(counter.position, Vector2(cap, counter.size.y)), Rect2(source.position, Vector2(cap, source.size.y)))
	draw_texture_rect_region(background, Rect2(counter.end - Vector2(cap, counter.size.y), Vector2(cap, counter.size.y)), Rect2(source.end - Vector2(cap, source.size.y), Vector2(cap, source.size.y)))
	_tile_background(Rect2(counter.position + Vector2(cap, 0), Vector2(counter.size.x - cap * 2.0, counter.size.y)), Rect2(source.position + Vector2(cap, 0), Vector2(source.size.x - cap * 2.0, source.size.y)), Vector2(source.size.x - cap * 2.0, counter.size.y))

func _floor() -> void:
	var floor: Variant = _floor_instance()
	if floor == null:
		return
	_draw_room_architecture(floor)
	_draw_g11_decor("floor")
	_draw_g11_decor("wall")
	# The bear is live and anchored to the current counter/kitchen geometry.
	var cooking: bool = int(model.chef.table_id) > 0
	var bear_clip: Dictionary = _clip("bear","actions","cook") if cooking else _clip("bear","base","idle")
	# kitchen_point() is the server's service handoff on the guest side of the
	# counter.  The chef instead stands behind its front edge.  Draw the counter
	# after the bear so its foreground panel naturally hides the lower body.
	var counter: Rect2 = floor.COUNTER
	var chef_anchor := Vector2(counter.get_center().x, counter.position.y + 8.0)
	_draw_clip(bear_clip,chef_anchor-Vector2(64,120)*SCALE,float(model.chef.elapsed) if cooking else clock)
	_draw_counter(counter)
	for t in model.tables:
		if int(t.id) == selected_table:
			_selection_halo(t.center + Vector2(0, 44 if t.zone == "bar" else 30))

func _selection_halo(center: Vector2) -> void:
	var outline := PackedVector2Array()
	for index: int in range(32):
		var angle: float = TAU * index / 32.0
		outline.append(center + Vector2(cos(angle) * 68, sin(angle) * 30))
	draw_colored_polygon(outline, Color(0.80,0.88,0.64,0.22))
	outline.append(outline[0])
	draw_polyline(outline, Color(0.46,0.64,0.38,0.78), 2.0)

func _table_capacity(table: Dictionary) -> int:
	var floor: Variant = _floor_instance()
	return int(floor.table_capacity(int(table.id))) if floor != null and floor.has_method("table_capacity") else 1

func _family_table(table: Dictionary) -> bool:
	# Capacity describes the available geometry, not the party currently dining.
	# A free or solo table keeps the original compact top, front and cloth.
	return table.zone != "bar" and _table_members(table).size() > 1

func _table_visual_center(table: Dictionary) -> Vector2:
	# Geometry owns this tiny art-only offset.  In particular, private table 15
	# must use its shifted family-table feet while all actor supports remain at
	# their separately routed seat points.
	var center := Vector2(table.center)
	var floor: Variant = _floor_instance()
	if floor != null and floor.has_method("table_visual"):
		var visual: Variant = floor.table_visual(int(table.id))
		if visual is Dictionary:
			center = Vector2(visual.get("center", center)) + Vector2(visual.get("offset", Vector2.ZERO))
	return center

func _table_members(table: Dictionary) -> Array[Dictionary]:
	# Avoid querying the model's typed member API for the overwhelmingly common
	# empty-table case. Apart from saving an allocation in every draw, this keeps
	# the renderer independent of an implementation detail in that API's empty
	# branch; a table without an owner cannot have visible members.
	if int(table.get("guest_id", 0)) <= 0:
		return []
	if model != null and model.has_method("table_members"):
		var members: Variant = model.table_members(int(table.id))
		if members is Array:
			return members
	var guest: Dictionary = model.customers.get(table.guest_id, {})
	return [{"party_id": int(table.guest_id), "member_index": 0, "seat_index": 0, "seat_role": "back", "species": str(guest.get("species", "")), "state": str(guest.get("state", "")), "pos": guest.get("pos", Vector2.ZERO), "path": guest.get("path", [])}] if not guest.is_empty() else []

func _seat_point(table_id: int, seat_index: int) -> Vector2:
	var floor: Variant = _floor_instance()
	return floor.seat_point(table_id, seat_index) if floor != null else Vector2.ZERO

func _draw_mirrored_prop(path: String, support: Vector2, anchor: Vector2, size: Vector2, mirrored: bool) -> void:
	var texture: Texture2D = _tex(path)
	if texture == null:
		return
	if not mirrored:
		draw_texture_rect(texture, Rect2((support - anchor * SCALE).round(), size * SCALE), false)
		return
	draw_set_transform(support + Vector2(anchor.x * SCALE, -anchor.y * SCALE), 0.0, Vector2(-SCALE, SCALE))
	draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _chair(table: Dictionary) -> void:
	if table.zone == "bar":
		_art_prop("props/stool.png", table.center + Vector2(-16,-43))
		return
	var back_support := _seat_point(int(table.id), 0)
	_draw_mirrored_prop("props/chair.png", back_support, Vector2(28, 79), Vector2(56, 80), false)
	if not _family_table(table):
		return
	for seat_index: int in [1, 2]:
		_draw_mirrored_prop("props/chair_side.png", _seat_point(int(table.id), seat_index), Vector2(28, 79), Vector2(56, 80), seat_index == 2)

func _table_origin(table: Dictionary) -> Vector2:
	var center := _table_visual_center(table) if _family_table(table) else Vector2(table.center)
	return center - (Vector2(100, 32) if _family_table(table) else Vector2(70, 25)) * SCALE

func _table_top(table: Dictionary) -> void:
	if table.zone == "bar":
		_art_prop("props/high_table.png", table.center + Vector2(-48,-42))
		return
	_prop("props/table_family_top.png" if _family_table(table) else "props/table_top.png", _table_origin(table))
	if not _family_table(table):
		# Stable variants make ordinary legacy tables less repetitive without
		# stretching a cloth over the native 200px family table.
		_res_prop("res://restaurant_art/props/tablecloth_%d.png" % ((int(table.id) - 1) % 3 + 1), _table_origin(table), SCALE)

func _table_front(table: Dictionary) -> void:
	if table.zone != "bar":
		_prop("props/table_family_front.png" if _family_table(table) else "props/table_front.png", _table_origin(table))

func _table_vase(table: Dictionary) -> void:
	if table.zone == "bar":
		return
	var variant := (int(table.id) * 17) % 4 + 1
	_res_prop("res://restaurant_art/props/table_vase_%d.png" % variant, (_table_visual_center(table) if _family_table(table) else Vector2(table.center)) + Vector2(-7, -19))

func _direction(actor: Dictionary) -> String:
	var path: Array = actor.path
	var point: Vector2 = actor.pos
	for p in path:
		var delta: Vector2 = p-point
		if delta.length() < 0.5: continue
		if absf(delta.x) > absf(delta.y): return "right" if delta.x > 0 else "left"
		return "down" if delta.y > 0 else "up"
	return "idle"

func _standing(actor: Dictionary, worker: bool = false) -> void:
	var species: String = actor.species
	var point: Vector2 = actor.pos
	var direction: String = _direction(actor)
	var clip: Dictionary = _clip(species,"base",direction)
	if worker and actor.state == "to_table":
		var task: Dictionary = _worker_task(actor)
		if not task.is_empty() and task.kind in ["food","drink"]:
			if direction == "idle": direction = "left"
			clip = _clip(species,"actions","carry_walk_"+direction) if task.kind == "food" else _clip(species,"drinks","carry_drinks_"+direction)
	_draw_clip(clip,point-Vector2(64,120)*SCALE,clock)

func _member_chatting(table: Dictionary, member: Dictionary) -> bool:
	var members := _table_members(table)
	if members.size() < 2 or str(table.phase) not in ["ordering", "awaiting_cook", "cooking", "food_ready", "serving_food", "waiting_drink", "eating"]:
		return false
	var party_id := int(member.get("party_id", table.get("guest_id", 0)))
	var speaker := (int(floorf(clock / 2.4)) + party_id) % members.size()
	return int(member.get("member_index", 0)) == speaker

func _member_seated_action(table: Dictionary, member: Dictionary) -> String:
	# Transition fields come from the model and are the only authority for a
	# departure pose. A timed-out queue or a cancelled in-flight worker never
	# receives this field, so it continues to render as a walker.
	if str(member.get("transition", "")) == "stand_up":
		return "stand_up"
	# Arrival begins only once every route has reached its physical support point.
	# No camera/perspective offset is added here: the model owns both the clock and
	# the position, and each party member starts at elapsed zero together.
	if str(member.get("state", "")) == "seated" and float(member.get("arrival", 99.0)) < 0.92:
		return "sit_down"
	return G11Art.action_for_table(str(table.phase), float(table.elapsed), _member_chatting(table, member))

func _draw_g11_frame(path: String, frame: Dictionary, support: Vector2, pivot: Vector2, mirrored: bool, single_frame: bool = false) -> void:
	var texture: Texture2D = _tex(path)
	if texture == null:
		return
	# Side bodies and hand overlays are individual 128px files.  Only the
	# front-facing sheet clips use their atlas coordinates.
	var source := Rect2(0, 0, float(frame.get("w", 128)), float(frame.get("h", 128))) if single_frame else Rect2(float(frame.get("x", 0)), float(frame.get("y", 0)), float(frame.get("w", 128)), float(frame.get("h", 128)))
	if not mirrored:
		draw_texture_rect_region(texture, Rect2((support - pivot * SCALE).round(), source.size * SCALE), source)
		return
	draw_set_transform(support + Vector2(pivot.x * SCALE, -pivot.y * SCALE), 0.0, Vector2(-SCALE, SCALE))
	draw_texture_rect_region(texture, Rect2(Vector2.ZERO, source.size), source)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_side_member(table: Dictionary, member: Dictionary, foreground: bool) -> void:
	var species := str(member.get("species", ""))
	var action_name := _member_seated_action(table, member)
	var manifest := G11Art.side_manifest(species)
	var action := G11Art.side_action(species, action_name)
	if manifest.is_empty() or action.is_empty():
		return
	var action_elapsed := float(table.elapsed)
	if action_name == "sit_down":
		action_elapsed = float(member.get("arrival", 0.0))
	elif action_name == "stand_up":
		action_elapsed = float(member.get("transition_elapsed", member.get("stand_elapsed", 0.0)))
	# Looping clips may use a subtle party stagger.  One-shot sit/stand clips
	# must start at frame zero together, or companions visibly pop into seats.
	if bool(action.get("loop", false)):
		action_elapsed += float(member.get("member_index", 0)) * 0.17
	var index := G11Art.frame_index(action_elapsed, action)
	var files: Array = action.get("hands_foreground", []) if foreground else action.get("frame_rects", [])
	if index < 0 or index >= files.size():
		return
	var path := "side/%s/%s" % [species, str(files[index].get("file", ""))] if not foreground else "side/%s/%s" % [species, str(files[index])]
	var frame: Dictionary = action.get("frame_rects", [])[index]
	_draw_g11_frame(path, frame, Vector2(member.get("pos", Vector2.ZERO)), G11Art.frame_pivot(manifest, action, index), int(member.get("seat_index", 0)) == 2, true)

func _front_member_clip(table: Dictionary, member: Dictionary) -> Dictionary:
	var species := str(member.get("species", ""))
	var action_name := _member_seated_action(table, member)
	if action_name == "chat":
		var chat := G11Art.front_action(species, "chat")
		if not chat.is_empty():
			return {"g11_front": true, "action": chat}
	var clip: Dictionary = _clip(species, "seating", "sit_down")
	# The delivered front atlas has sit_down but no stand_up.  Reuse its actual
	# frames in reverse below; never look up an invented legacy clip.
	if action_name == "stand_up":
		pass
	elif table.phase == "eating":
		clip = _clip(species, "actions", "eat")
	elif table.phase == "drinking":
		var drink: Dictionary = _clip(species, "drinks", "drink")
		if float(table.elapsed) < float(drink.duration_total_ms) / 1000.0:
			clip = drink
	elif table.phase == "checkout" and float(table.elapsed) < 0.88:
		clip = _clip(species, "actions", "happy")
	return clip

func _front_member_frame_index(table: Dictionary, member: Dictionary, clip: Dictionary) -> int:
	var action_name := _member_seated_action(table, member)
	var elapsed := float(table.elapsed)
	if action_name == "sit_down":
		elapsed = float(member.get("arrival", 0.0))
	elif action_name == "stand_up":
		elapsed = float(member.get("transition_elapsed", member.get("stand_elapsed", 0.0)))
		var frames: Array = clip.get("rects", [])
		return maxi(0, frames.size() - 1 - _index(elapsed, clip))
	if action_name == "seated_idle":
		return maxi(0, (clip.get("rects", []) as Array).size() - 1)
	return _index(elapsed, clip)

func _seated(table: Dictionary, foreground: bool = false) -> void:
	for member: Dictionary in _table_members(table):
		if str(member.get("state", "")) != "seated" and str(member.get("transition", "")) != "stand_up":
			continue
		var side := int(member.get("seat_index", 0)) > 0 and G11Art.has_side_species(str(member.get("species", "")))
		if side:
			_draw_side_member(table, member, foreground)
			continue
		if foreground:
			var normal_clip := _front_member_clip(table, member)
			if not bool(normal_clip.get("g11_front", false)):
				var normal_index := _front_member_frame_index(table, member, normal_clip)
				var foregrounds: Array = normal_clip.get("foreground", [])
				if normal_index >= 0 and normal_index < foregrounds.size() and foregrounds[normal_index] != null:
					_prop(str(foregrounds[normal_index]), Vector2(member.get("pos", Vector2.ZERO)) - Vector2(64, 110) * SCALE)
			continue
		var clip := _front_member_clip(table, member)
		if bool(clip.get("g11_front", false)):
			var action: Dictionary = clip.action
			var frame_index := G11Art.frame_index(float(table.elapsed), action)
			var frames: Array = action.get("frame_rects", [])
			if frame_index < frames.size():
				_draw_g11_frame("actions/%s/chat.png" % str(member.species), frames[frame_index], Vector2(member.pos) + FRONT_CHAT_POSE_OFFSET * SCALE, G11Art.frame_pivot({}, action, frame_index), false)
		else:
			var fixed := _front_member_frame_index(table, member, clip)
			_draw_clip(clip, Vector2(member.get("pos", Vector2.ZERO)) - Vector2(64, 110) * SCALE, 0.0, fixed)

func _worker_task(worker: Dictionary) -> Dictionary:
	for task in model.tasks:
		if int(task.id) == int(worker.task_id): return task
	return {}

func _work_for_table(id: int) -> Dictionary:
	for w in model.workers:
		if w.state != "working": continue
		var task: Dictionary = _worker_task(w)
		if not task.is_empty() and int(task.table_id) == id:
			return {"worker":w,"task":task}
	return {}

func _stack(point: Vector2, table: Dictionary, species: String = "rabbit") -> void:
	var info: Dictionary = catalog.cleanup[species]
	if table.food: _prop("cleanup/props/empty_plate.png",point-Vector2(17,20)*SCALE)
	if table.drink:
		var cup_size: Array = info.get("cup_render_size",[22,20])
		var cup_origin: Array = info.get("cup_origin",[11,20])
		var cup_offset: Array = info.get("cup_offset_from_plate",[1,-10])
		var origin: Vector2 = point+Vector2(cup_offset[0],cup_offset[1])*SCALE-Vector2(cup_origin[0],cup_origin[1])*SCALE
		draw_texture_rect(_tex("cleanup/props/empty_cup.png"),Rect2(origin.round(),Vector2(cup_size[0],cup_size[1])*SCALE),false)

func _table_items(table: Dictionary) -> void:
	var c := _table_visual_center(table) if _family_table(table) else Vector2(table.center)
	var work: Dictionary = _work_for_table(table.id)
	if table.phase in ["dirty","collecting","wiping"]:
		var opacity: float = 1.0
		var picked: bool = table.phase == "wiping"
		var species: String = "rabbit"
		if not work.is_empty():
			species = work.worker.species
			var info: Dictionary = catalog.cleanup[species]
			var cleanup_name: String = "wipe" if table.phase == "wiping" else "collect"
			var clip: Dictionary = info.clips[cleanup_name]
			var i: int = _index(table.elapsed,clip)
			if table.phase == "wiping": opacity = float(clip.stain_remaining_fraction[i])
			elif i >= 1: picked = true
		if opacity > 0:
			draw_texture_rect(_tex("cleanup/props/stain.png"),Rect2(c+Vector2(-10,-8)*SCALE,Vector2(36,18)*SCALE),false,Color(1,1,1,opacity))
		if not picked: _stack(c+Vector2(38,10)*SCALE,table,species)
		return
	var food: bool = table.food
	var drink: bool = table.drink
	if not work.is_empty():
		var kind: String = work.task.kind
		if kind in ["food","drink"]:
			var clip: Dictionary = _clip(work.worker.species,"actions" if kind == "food" else "drinks","place_dish" if kind == "food" else "place_cup")
			if _index(work.worker.elapsed,clip) >= 2:
				if kind == "food": food = true
				else: drink = true
	if food:
		var food_plan: Dictionary = table_food_render_plan(table)
		# The mixed platter is neutral scenery; the ordered recipe remains the
		# primary, truthful dish on top of it.
		if _family_table(table) and _table_members(table).size() > 1:
			_prop("props/dish_group.png", _table_visual_center(table) - Vector2(28, 19) * SCALE)
		_prop(food_plan.texture_path,food_plan.table_origin)
	var baked_cup: bool = false
	if table.phase == "drinking":
		for member: Dictionary in _table_members(table):
			if int(member.get("seat_index", 0)) > 0 and G11Art.has_side_species(str(member.get("species", ""))):
				var drink_action := G11Art.side_action(str(member.get("species", "")), "drink")
				# The cup is baked only while that side member is genuinely playing
				# the one-shot drink frames; leave the tabletop cup after it returns
				# to idle instead of making it disappear for the whole phase.
				if float(table.elapsed) < float(drink_action.get("duration_total_ms", 1160)) / 1000.0:
					baked_cup = true
					break
		if not baked_cup:
			var guest: Dictionary = model.customers.get(table.guest_id,{})
			if not guest.is_empty(): baked_cup = table.elapsed < float(_clip(guest.species,"drinks","drink").duration_total_ms)/1000.0
	if drink and not baked_cup: _prop("drinks/rabbit/cup.png",c+Vector2(-4,-24)*SCALE)

func _working(worker: Dictionary) -> void:
	var task: Dictionary = _worker_task(worker)
	if task.is_empty():
		_standing(worker,true)
		return
	var table: Dictionary = model.tables[int(task.table_id)-1]
	var c := _table_visual_center(table) if _family_table(table) else Vector2(table.center)
	var species: String = worker.species
	if task.kind == "clean":
		var info: Dictionary = catalog.cleanup[species]
		var action: String = "wipe" if table.phase == "wiping" else "collect"
		var clip: Dictionary = info.clips[action]
		var offset: Vector2 = Vector2(info.render_offset[0],info.render_offset[1])*SCALE
		var origin: Vector2 = c+Vector2(25,-88)*SCALE+offset
		if species == "fox": origin.y -= 6*SCALE
		var i: int = _draw_clip(clip,origin,table.elapsed)
		var anchor: Variant = clip.prop_anchors[i]
		if action == "collect" and i in [1,2] and anchor != null:
			_stack(origin+Vector2(anchor[0],anchor[1])*SCALE,table,species)
		elif action == "wipe" and anchor != null:
			var cloth: Array = info.props.cloth.origin if species == "rabbit" else info.cloth_origin
			_prop("cleanup/props/cloth.png",origin+Vector2(anchor[0]-cloth[0],anchor[1]-cloth[1])*SCALE)
	else:
		var food: bool = task.kind == "food"
		var clip: Dictionary = _clip(species,"actions" if food else "drinks","place_dish" if food else "place_cup")
		var target: Vector2 = c+(Vector2(7,-6) if not food else FOOD_TABLE_ANCHOR)*SCALE
		var release: Vector2 = Vector2(17,85)
		var food_plan: Dictionary = {}
		if food:
			food_plan = food_render_plan(table,species,worker.elapsed)
			target = food_plan.table_anchor
			release = food_plan.release_anchor
		else:
			for event in clip.events:
				var a: Array = event.get("anchor",event.get("world_anchor_from_cell",[]))
				if a.size()==2: release = Vector2(a[0],a[1])
		var origin: Vector2 = target-release*SCALE
		var i: int = _draw_clip(clip,origin,worker.elapsed)
		if food and bool(food_plan.attached):
			_prop(food_plan.texture_path,food_plan.handheld_origin)
		elif not food and i < 2:
			var point: Vector2 = origin+(release+Vector2(13 if i==0 else 3,0))*SCALE
			_prop("drinks/rabbit/cup.png",point-Vector2(11,18)*SCALE)

func _draw() -> void:
	if model == null or catalog.is_empty() or _floor_instance() == null: return
	_floor()
	var events: Array[Dictionary] = []
	for t in model.tables:
		events.append({"kind":"chair","y":float(t.center.y),"order":0,"table":t})
		events.append({"kind":"seated","y":_floor_instance().seat_point(int(t.id)).y,"order":1,"table":t})
		events.append({"kind":"table","y":float((_table_visual_center(t) if _family_table(t) else Vector2(t.center)).y)+(68 if t.zone=="bar" else 45),"order":3,"table":t})
	for entry: Dictionary in _g11_decorations():
		if str(entry.get("layer", "")) == "object":
			var footprint: Rect2 = entry.get("footprint", Rect2(Vector2(entry.position), Vector2.ZERO))
			events.append({"kind":"decor","y":footprint.end.y,"order":2,"entry":entry})
	for party_id: Variant in model.customers:
		var members: Array[Dictionary] = model.party_members(int(party_id)) if model.has_method("party_members") else [model.customers[party_id]]
		for guest: Dictionary in members:
			if str(guest.get("state", "")) in ["queued", "walking", "leaving"] and str(guest.get("transition", "")) != "stand_up":
				events.append({"kind":"guest","y":float(Vector2(guest.get("pos", Vector2.ZERO)).y),"order":2,"actor":guest})
	for worker in model.workers:
		events.append({"kind":"worker","y":float(worker.pos.y)+60 if worker.state=="working" else float(worker.pos.y),"order":2,"actor":worker})
	events.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.y < b.y if not is_equal_approx(a.y, b.y) else int(a.order) < int(b.order))
	for event in events:
		match event.kind:
			"chair": _chair(event.table)
			"seated": _seated(event.table)
			"table":
				_table_top(event.table)
				_table_vase(event.table)
				_seated(event.table,true)
				_table_front(event.table)
				_table_items(event.table)
			"decor": _res_prop(str(event.entry.get("path", "")), Vector2(event.entry.get("position", Vector2.ZERO)), float(event.entry.get("scale", 1.0)))
			"guest": _standing(event.actor)
			"worker":
				if event.actor.state=="working": _working(event.actor)
				else: _standing(event.actor,true)
	_foreground_architecture()
	for table in model.tables:
		_action_icon(table)

func _foreground_architecture() -> void:
	if background == null or _floor_instance() == null:
		return
	var width: float = _floor_instance().SIZE.x
	var right_shift := width - 1536.0
	# Original partition/rail pixels occlude actors whose feet are behind them.
	for region: Rect2 in [Rect2(0,218,284,24), Rect2(0,436,268,26), Rect2(0,666,254,25), Rect2(0,901,238,13)]:
		draw_texture_rect_region(background, region, region)
	for source: Rect2 in [Rect2(1200,208,24,224), Rect2(1200,534,24,400), Rect2(1470,208,24,620), Rect2(1310,808,184,20)]:
		draw_texture_rect_region(background, Rect2(source.position + Vector2(right_shift,0), source.size), source)
	# Draw only the lower half of the shared facade plan after actors. Its upper
	# half was drawn before them, so no wall pixel or plant is duplicated.
	for piece: Dictionary in front_wall_draw_plan(_floor_instance().SIZE):
		if piece.layer == "foreground":
			_draw_wall_piece(piece)

func _action_icon(table: Dictionary) -> void:
	var action: String = model.table_action(int(table.id))
	if action not in ["order", "cook", "pay", "clean"]:
		return
	# Small, wordless affordances are the only permanent operation markers.
	var center: Vector2 = table.center + Vector2(0, 61 if table.zone=="bar" else 47)
	if action == "pay":
		draw_circle(center, 10, Color("916d35"))
		draw_circle(center-Vector2(0,1), 8, Color("e4bb54"))
		draw_line(center+Vector2(-2,-5),center+Vector2(-2,3),Color("fff0af"),2)
		draw_line(center+Vector2(2,-4),center+Vector2(2,4),Color("b78333"),2)
	elif action == "clean":
		_prop("cleanup/props/cloth.png",center-Vector2(8,6),0.6)
	else:
		_prop("props/dish.png",center-Vector2(13,8),0.75)

func _hit_bubble(point: Vector2) -> bool:
	# Bubbles are visual-only, so reject their visible bounds before table picking.
	var global_point: Vector2 = to_global(point)
	for layer: Node in get_children():
		var script: Script = layer.get_script() as Script
		if script == null or script.resource_path != "res://bubble_layer.gd":
			continue
		var visuals: Dictionary = layer.get("_visuals")
		for visual: Dictionary in visuals.values():
			var sprite: AnimatedSprite2D = visual.sprite
			if sprite.is_visible_in_tree():
				var texture: Texture2D = sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)
				if texture != null:
					var size: Vector2 = texture.get_size()
					var origin: Vector2 = sprite.offset - size * 0.5 if sprite.centered else sprite.offset
					if Rect2(origin, size).has_point(sprite.to_local(global_point)):
						return true
			var label: Label = visual.label
			if label.is_visible_in_tree() and Rect2(Vector2.ZERO, label.size).has_point(label.get_global_transform().affine_inverse() * global_point):
				return true
	return false

func _hit_walking_guest(guest: Dictionary, point: Vector2) -> bool:
	var origin: Vector2 = (Vector2(guest.pos)-Vector2(64,120)*SCALE).round()
	return Rect2(origin, Vector2(128,128)*SCALE).has_point(point)

func _table_at_point(point: Vector2) -> int:
	var floor: Variant = _floor_instance()
	if model == null or _hit_bubble(point) or _g11_object_hit(point) or (floor != null and floor.is_architecture_at(point)):
		return 0
	for party_id: Variant in model.customers:
		var members: Array[Dictionary] = model.party_members(int(party_id)) if model.has_method("party_members") else [model.customers[party_id]]
		for guest: Dictionary in members:
			if str(guest.get("state", "")) in ["queued", "walking", "leaving"] and _hit_walking_guest(guest, point):
				return 0
	for table: Dictionary in model.tables:
		for member: Dictionary in _table_members(table):
			if str(member.get("state", "")) != "seated" and str(member.get("transition", "")) != "stand_up":
				continue
			var origin: Vector2 = (Vector2(member.get("pos", Vector2.ZERO)) - Vector2(64, 110) * SCALE).round()
			if Rect2(origin, Vector2(128,128) * SCALE).has_point(point):
				return int(table.id)
	var closest: int = 0
	var distance: float = INF
	for table: Dictionary in model.tables:
		var visual_size := Vector2(96, 84) if table.zone == "bar" else (Vector2(200, 110) if _family_table(table) else Vector2(140, 90)) * SCALE
		var visual_origin := Vector2(table.center) + Vector2(-48, -42) if table.zone == "bar" else _table_origin(table)
		var table_hit := Rect2(visual_origin, visual_size).grow(10.0).has_point(point)
		for seat_index: int in range(_table_capacity(table)):
			if floor != null and floor.seat_reservation(int(table.id), seat_index).grow(12.0).has_point(point):
				table_hit = true
		if table_hit:
			var candidate: float = point.distance_squared_to(table.center)
			if candidate < distance:
				distance = candidate
				closest = int(table.id)
	return closest

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var picked: int = _table_at_point(point)
		if picked > 0:
			table_selected.emit(picked)
			get_viewport().set_input_as_handled()
