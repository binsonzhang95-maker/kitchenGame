extends Node2D

signal table_selected(id: int)
const Floor = preload("res://floor_plan.gd")
const SCALE: float = Floor.RENDER_SCALE
const ROOT := "res://assets/"
const ART_ROOT := "res://restaurant_art/"
const BACKGROUND := ART_ROOT + "restaurant_open_background.png"
var model: Variant
var selected_table: int = 1
var clock: float = 0.0
var catalog: Dictionary
var textures: Dictionary = {}
var background: Texture2D

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

func _draw_clip(clip: Dictionary, origin: Vector2, elapsed: float, fixed: int = -1) -> int:
	var i: int = _index(elapsed,clip) if fixed < 0 else fixed
	var rect: Array = clip.rects[i]
	var texture: Texture2D = _tex(clip.sheet)
	if texture:
		draw_texture_rect_region(texture,Rect2(origin.round(),Vector2(128,128)*SCALE),Rect2(rect[0],rect[1],rect[2],rect[3]))
	return i

func _floor() -> void:
	if background:
		draw_texture(background, Vector2.ZERO)
	# The bear is a live v5 sprite behind the baked service counter.
	var cooking: bool = int(model.chef.table_id) > 0
	var bear_clip: Dictionary = _clip("bear","actions","cook") if cooking else _clip("bear","base","idle")
	_draw_clip(bear_clip,Vector2(856,184)-Vector2(64,120)*SCALE,float(model.chef.elapsed) if cooking else clock)
	if background:
		draw_texture_rect_region(background, Floor.COUNTER, Floor.COUNTER)
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

func _chair(table: Dictionary) -> void:
	if table.zone == "bar":
		_art_prop("props/stool.png", table.center + Vector2(-16,-43))
	else:
		_prop("props/chair.png", table.center-Vector2(28,78)*SCALE)

func _table(table: Dictionary) -> void:
	if table.zone == "bar":
		_art_prop("props/high_table.png", table.center + Vector2(-48,-42))
	else:
		_prop("props/table.png", table.center-Vector2(70,30)*SCALE)

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

func _seated(table: Dictionary, foreground: bool = false) -> void:
	var guest: Dictionary = model.customers.get(table.guest_id,{})
	if guest.is_empty() or guest.state != "seated": return
	# The same support point is used by walking and seated sprites: no proxy jump.
	var origin: Vector2 = Vector2(guest.pos)-Vector2(64,120)*SCALE
	var clip: Dictionary = _clip(guest.species,"seating","sit_down")
	var fixed: int = 3
	var e: float = table.elapsed
	if table.phase == "ordering" and e < 0.92:
		fixed = -1
	elif table.phase == "eating":
		clip = _clip(guest.species,"actions","eat")
		fixed = -1
	elif table.phase == "drinking":
		var drink: Dictionary = _clip(guest.species,"drinks","drink")
		if e < float(drink.duration_total_ms)/1000.0:
			clip = drink
			fixed = -1
	elif table.phase == "checkout" and e < 0.88:
		clip = _clip(guest.species,"actions","happy")
		fixed = -1
	var i: int = fixed if fixed >= 0 else _index(e,clip)
	if foreground:
		if clip.foreground[i] != null: _prop(clip.foreground[i],origin)
	else: _draw_clip(clip,origin,e,fixed)

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
	var c: Vector2 = table.center
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
		_prop("cleanup/props/empty_plate.png" if table.phase in ["drinking","checkout","leaving"] else "props/dish.png",c+Vector2(28,-24)*SCALE)
	var baked_cup: bool = false
	if table.phase == "drinking":
		var guest: Dictionary = model.customers.get(table.guest_id,{})
		if not guest.is_empty(): baked_cup = table.elapsed < float(_clip(guest.species,"drinks","drink").duration_total_ms)/1000.0
	if drink and not baked_cup: _prop("drinks/rabbit/cup.png",c+Vector2(-4,-24)*SCALE)

func _working(worker: Dictionary) -> void:
	var task: Dictionary = _worker_task(worker)
	if task.is_empty():
		_standing(worker,true)
		return
	var table: Dictionary = model.tables[int(task.table_id)-1]
	var c: Vector2 = table.center
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
		var target: Vector2 = c+(Vector2(45,-8) if food else Vector2(7,-6))*SCALE
		var release: Vector2 = Vector2(27,84) if food else Vector2(17,85)
		for event in clip.events:
			var a: Array = event.get("anchor",event.get("world_anchor_from_cell",[]))
			if a.size()==2: release = Vector2(a[0],a[1])
		var origin: Vector2 = target-release*SCALE
		var i: int = _draw_clip(clip,origin,worker.elapsed)
		if i < 2:
			var point: Vector2 = origin+(release+Vector2(13 if i==0 else 3,0))*SCALE
			_prop("props/dish.png" if food else "drinks/rabbit/cup.png",point-(Vector2(17,16) if food else Vector2(11,18))*SCALE)

func _draw() -> void:
	if model == null or catalog.is_empty(): return
	_floor()
	var events: Array[Dictionary] = []
	for t in model.tables:
		events.append({"kind":"chair","y":float(t.center.y),"table":t})
		events.append({"kind":"seated","y":Floor.seat_point(int(t.id)).y,"table":t})
		events.append({"kind":"table","y":float(t.center.y)+(68 if t.zone=="bar" else 45),"table":t})
	for guest in model.customers.values():
		if guest.state in ["queued","walking","leaving"]: events.append({"kind":"guest","y":float(guest.pos.y),"actor":guest})
	for worker in model.workers:
		events.append({"kind":"worker","y":float(worker.pos.y)+60 if worker.state=="working" else float(worker.pos.y),"actor":worker})
	events.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a.y < b.y)
	for event in events:
		match event.kind:
			"chair": _chair(event.table)
			"seated": _seated(event.table)
			"table":
				_table(event.table)
				_table_items(event.table)
				_seated(event.table,true)
			"guest": _standing(event.actor)
			"worker":
				if event.actor.state=="working": _working(event.actor)
				else: _standing(event.actor,true)
	_foreground_architecture()
	for table in model.tables:
		_action_icon(table)

func _foreground_architecture() -> void:
	if not background:
		return
	# Re-use actual foreground wall pixels, stopping before each open doorway.
	# Feet behind a partition remain behind it rather than painting over its rail.
	for region: Rect2 in [Rect2(28,218,256,24),Rect2(8,436,260,26),Rect2(0,666,254,25),Rect2(0,901,238,12)]:
		draw_texture_rect_region(background,region,region)

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
	if model == null or _hit_bubble(point):
		return 0
	for guest: Dictionary in model.customers.values():
		if guest.state in ["queued", "walking", "leaving"] and _hit_walking_guest(guest, point):
			return 0
	# Use the same origin and size as _seated(), including the higher bar seat.
	for table: Dictionary in model.tables:
		var guest: Dictionary = model.customers.get(table.guest_id, {})
		if guest.is_empty() or guest.state != "seated":
			continue
		var origin: Vector2 = (Vector2(guest.pos)-Vector2(64,120)*SCALE).round()
		if Rect2(origin, Vector2(128,128)*SCALE).has_point(point):
			return int(table.id)
	var closest: int = 0
	var distance: float = INF
	for table: Dictionary in model.tables:
		if Rect2(table.center-Vector2(66,82),Vector2(132,164)).has_point(point):
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
