class_name G11DecorLayout
extends RefCounted

## Pure, width-aware G11 decoration placement. Floor geometry consumes these
## same entries, therefore a visible solid is never silently non-colliding.
##
## The original kitchen is copied at native scale into the centred 704x176
## crop. New wall art is restricted to the two back-wall bands beside that
## crop; this protects the stove, sink and green door at every landscape width.
static func build(width: float) -> Array[Dictionary]:
	var decor: Array[Dictionary] = []
	if width < 1536.0:
		return decor
	var hall_left := 388.0
	var hall_right := width - 336.0
	var kitchen := Rect2((width - 704.0) * 0.5, 0.0, 704.0, 176.0)
	var bands: Array[Rect2] = [Rect2(hall_left, 0.0, maxf(0.0, kitchen.position.x - hall_left), 176.0), Rect2(kitchen.end.x, 0.0, maxf(0.0, hall_right - kitchen.end.x), 176.0)]

	# Floor details are intentionally non-blocking. They only dress walking lanes
	# and must never make a route or a table click disappear.
	_add(decor, "entry_runner", "res://restaurant_art/props/rug_runner.png", Vector2(width * 0.5 - 32.0, 884.0), "floor", Rect2(width * 0.5 - 32.0, 884.0, 64.0, 64.0))
	_add(decor, "entry_mat", "res://restaurant_art/props/doormat.png", Vector2(width * 0.5 - 64.0, 946.0), "floor", Rect2(width * 0.5 - 64.0, 946.0, 128.0, 40.0))
	for x: float in _steps(hall_left + 16.0, hall_right - 32.0, 32.0):
		_add(decor, "floor_border_%d" % int(x), "res://restaurant_art/props/floor_border.png", Vector2(x, 926.0), "floor", Rect2(x, 926.0, 32.0, 32.0))

	# A band only receives an item when its whole native rectangle fits. This
	# makes 1536 intentionally sparse instead of drawing over fixed room art.
	for band_index: int in range(bands.size()):
		var band: Rect2 = bands[band_index]
		_add_wall_repeat(decor, band, band_index)
		_add_wall_slots(decor, band, band_index)

	# These are source-pixel origins, not centres.  Their raw feet are copied from
	# restaurant_art/props.json verbatim and form both the renderer's depth sort
	# and the floor's collision slab.  They live in the clean central hall, never
	# in the retained right-side terrace with its baked rails and pots.
	var host_origin := Vector2(width * 0.5 - 240.0, 850.0) if width >= 2048.0 else Vector2(hall_right - 176.0, 820.0)
	_add_solid(decor, "host_stand", "res://restaurant_art/props/host_stand.png", host_origin, Rect2(6, 65, 53, 30))
	_add_solid(decor, "coat_rack", "res://restaurant_art/props/coat_rack.png", Vector2(400.0, 838.0), Rect2(3, 92, 35, 19))
	_add_solid(decor, "service_station", "res://restaurant_art/props/service_station.png", Vector2(hall_right - 104.0, 816.0), Rect2(5, 66, 87, 29))
	if width >= 2048.0:
		_add_solid(decor, "bar_counter", "res://restaurant_art/props/bar_counter.png", Vector2(hall_right - 400.0, 790.0), Rect2(4, 76, 248, 35))
		_add_solid(decor, "plant_big", "res://restaurant_art/props/plant_big.png", Vector2(hall_right - 530.0, 780.0), Rect2(15, 103, 35, 24))
	return decor


static func _add_wall_repeat(decor: Array[Dictionary], band: Rect2, band_index: int) -> void:
	for x: float in _steps(band.position.x, band.end.x - 64.0, 64.0):
		_add(decor, "beam_%d_%d" % [band_index, int(x)], "res://restaurant_art/props/ceiling_beam.png", Vector2(x, 0.0), "wall")
		_add(decor, "wainscot_%d_%d" % [band_index, int(x)], "res://restaurant_art/props/wainscot.png", Vector2(x, 128.0), "wall")


static func _add_wall_slots(decor: Array[Dictionary], band: Rect2, band_index: int) -> void:
	# Slots deliberately have empty margins between their opaque bounds. The
	# window view starts at curtain-local [8, 28], preserving its supplied frame.
	if band.size.x >= 128.0:
		var curtain := Vector2(band.end.x - 104.0, 20.0)
		_add(decor, "curtain_%d" % band_index, "res://restaurant_art/props/window_curtain.png", curtain, "wall")
		_add(decor, "day_view_%d" % band_index, "res://restaurant_art/props/window_view_day.png", curtain + Vector2(8.0, 28.0), "wall")
	if band.size.x >= 192.0:
		_add(decor, "pendant_%d" % band_index, "res://restaurant_art/props/pendant_lamp.png", Vector2(band.position.x + 64.0, 0.0), "wall")
	# The two bands use complementary, non-overlapping slot families. At 2496px
	# both are wide enough to expose every wall-art variant without crowding the
	# curtain; narrower worlds keep only the window rather than clipping it.
	if band_index == 0 and band.size.x >= 504.0:
		_add(decor, "menu_%d" % band_index, "res://restaurant_art/props/menu_board.png", Vector2(band.position.x + 8.0, 24.0), "wall")
		_add(decor, "shelf_%d" % band_index, "res://restaurant_art/props/wall_shelf.png", Vector2(band.position.x + 184.0, 72.0), "wall")
		_add(decor, "frame_%d_c" % band_index, "res://restaurant_art/props/wall_frame_3.png", Vector2(band.position.x + 328.0, 48.0), "wall")
	elif band_index == 1 and band.size.x >= 408.0:
		_add(decor, "frame_%d_a" % band_index, "res://restaurant_art/props/wall_frame_1.png", Vector2(band.position.x + 8.0, 48.0), "wall")
		_add(decor, "shelf_%d" % band_index, "res://restaurant_art/props/wall_shelf.png", Vector2(band.position.x + 88.0, 72.0), "wall")
		_add(decor, "frame_%d_b" % band_index, "res://restaurant_art/props/wall_frame_2.png", Vector2(band.position.x + 232.0, 48.0), "wall")


static func _steps(first: float, last: float, step: float) -> Array[float]:
	var values: Array[float] = []
	var value := first
	while value <= last:
		values.append(value)
		value += step
	return values


static func _add(decor: Array[Dictionary], id: String, path: String, position: Vector2, layer: String, footprint: Rect2 = Rect2(), collision: bool = false) -> void:
	decor.append({"id": id, "path": path, "position": position, "scale": 1.0, "layer": layer, "footprint": footprint, "collision": collision})


static func _add_solid(decor: Array[Dictionary], id: String, path: String, origin: Vector2, raw_feet: Rect2) -> void:
	# Keep local source metadata as well as the translated collision rectangle.
	# The floor must consume `footprint`, rather than approximating a sprite's
	# opaque bounds or assigning a decorative object a pass-through collision.
	var world_feet := Rect2(origin + raw_feet.position, raw_feet.size)
	decor.append({"id": id, "path": path, "position": origin, "scale": 1.0, "layer": "object", "raw_feet": raw_feet, "footprint": world_feet, "collision": true})
