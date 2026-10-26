extends Node2D
## Decorative only.  It deliberately never adds seats, routes, or hit targets.

const BACKGROUND := preload("res://restaurant_art/restaurant_open_background.png")
const PLANT := preload("res://restaurant_art/props/plant.png")
const LAMP := preload("res://restaurant_art/props/lamp.png")
const PARTITION := preload("res://restaurant_art/props/partition.png")

var content_rect := Rect2(Vector2.ZERO, Vector2(1536, 1152))
var room_rect := Rect2(Vector2(0, 80), Vector2(1536, 1024))
var viewport_size := Vector2(1536, 1152)

func set_layout(layout: Dictionary) -> void:
	content_rect = layout.get("content_rect", content_rect)
	room_rect = layout.get("room_rect", room_rect)
	viewport_size = layout.get("viewport", viewport_size)
	queue_redraw()

func _draw() -> void:
	# Keep the authored 1536 x 1024 restaurant untouched.  Side art is sampled
	# from its clean central wall/floor only: never from a booth, window row or
	# green rug.  room_rect also keeps this join correct after safe-area scaling.
	var room := room_rect
	var scale := room.size.x / 1536.0
	var wall_height := minf(room.size.y, 248.0 * scale)
	for side in [Rect2(0, room.position.y, maxf(0.0, room.position.x), room.size.y), Rect2(room.end.x, room.position.y, maxf(0.0, viewport_size.x - room.end.x), room.size.y)]:
		if side.size.x <= 0.0: continue
		_tile_region(side, Rect2(576, 384, 256, 192), Vector2(256, 192) * scale)
		# The narrow 1080..1120 strip is just cream wall and the top timber line.
		# It may span sideways, unlike the floor tile, because it has no objects
		# that could become a repeated half-window/counter pattern.
		draw_texture_rect_region(BACKGROUND, Rect2(side.position, Vector2(side.size.x, wall_height)), Rect2(1080, 0, 40, 100))
		_draw_props(side, wall_height, scale)

func _tile_region(destination: Rect2, source: Rect2, tile_size: Vector2) -> void:
	if tile_size.x <= 0.0 or tile_size.y <= 0.0: return
	var y := destination.position.y
	while y < destination.end.y:
		var height := minf(tile_size.y, destination.end.y - y)
		var x := destination.position.x
		while x < destination.end.x:
			var width := minf(tile_size.x, destination.end.x - x)
			var source_size := Vector2(source.size.x * width / tile_size.x, source.size.y * height / tile_size.y)
			draw_texture_rect_region(BACKGROUND, Rect2(x, y, width, height), Rect2(source.position, source_size))
			x += width
		y += height

func _draw_props(side: Rect2, wall_height: float, scale: float) -> void:
	# One small rhythm per side is enough at 19.5:9; it remains decorative and
	# deliberately has no seat, hit target or repeating window strip.
	var prop_scale := Vector2.ONE * scale * 1.5
	var plant_size := PLANT.get_size() * prop_scale
	var lamp_size := LAMP.get_size() * prop_scale
	var partition_size := PARTITION.get_size() * prop_scale
	var left_aligned := side.position.x < room_rect.position.x
	var plant_x := side.position.x + 18.0 * scale if left_aligned else side.end.x - plant_size.x - 18.0 * scale
	draw_texture_rect(PLANT, Rect2(Vector2(plant_x, side.end.y - plant_size.y - 28.0 * scale), plant_size), false)
	if side.size.x >= lamp_size.x + 28.0 * scale:
		var lamp_x := side.position.x + (side.size.x - lamp_size.x) * 0.5
		draw_texture_rect(LAMP, Rect2(Vector2(lamp_x, side.position.y + minf(wall_height - lamp_size.y, 70.0 * scale)), lamp_size), false)
	if side.size.x >= partition_size.x + 32.0 * scale:
		var partition_x := side.position.x + (side.size.x - partition_size.x) * 0.5
		draw_texture_rect(PARTITION, Rect2(Vector2(partition_x, side.end.y - partition_size.y - 34.0 * scale), partition_size), false)
