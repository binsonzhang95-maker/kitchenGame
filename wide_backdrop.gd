extends Node2D
## Non-interactive architecture below the safe playable hall. The room and all
## hit targets remain inside room_rect; flat pixel-art walls fill unsafe bands.

const WOOD_DARK := Color("753e28")
const WOOD_MID := Color("b87442")
const WOOD_LIGHT := Color("d89555")
const PATH_DARK := Color("a86f4b")
const PATH_MID := Color("e1bd8d")
const PATH_LIGHT := Color("f0d3a8")

var content_rect := Rect2(Vector2.ZERO, Vector2(1536, 1152))
var room_rect := Rect2(Vector2(0, 80), Vector2(1536, 1072))
var viewport_size := Vector2(1536, 1152)
var layout_scale := 1.0

func set_layout(layout: Dictionary) -> void:
	content_rect = layout.get("content_rect", content_rect)
	room_rect = layout.get("room_rect", room_rect)
	viewport_size = layout.get("viewport", viewport_size)
	layout_scale = maxf(0.0001, float(layout.get("scale", 1.0)))
	queue_redraw()

func coverage_rect() -> Rect2:
	return Rect2(Vector2.ZERO, viewport_size)

func architecture_rects() -> Array[Rect2]:
	var result: Array[Rect2] = []
	if room_rect.position.x > 0.0:
		result.append(Rect2(0, 0, room_rect.position.x, content_rect.end.y))
	if room_rect.end.x < viewport_size.x:
		result.append(Rect2(room_rect.end.x, 0, viewport_size.x - room_rect.end.x, content_rect.end.y))
	if content_rect.end.y < viewport_size.y:
		result.append(Rect2(0, content_rect.end.y, viewport_size.x, viewport_size.y - content_rect.end.y))
	return result

func _draw() -> void:
	var left_width := floori(room_rect.position.x)
	var right_x := ceili(room_rect.end.x)
	var content_bottom := ceili(content_rect.end.y)
	if left_width > 0:
		_draw_side_wall(Rect2i(0, 0, left_width, content_bottom), false)
	if right_x < ceili(viewport_size.x):
		_draw_side_wall(Rect2i(right_x, 0, ceili(viewport_size.x) - right_x, content_bottom), true)
	if content_bottom < ceili(viewport_size.y):
		_draw_ground(Rect2i(0, content_bottom, ceili(viewport_size.x), ceili(viewport_size.y) - content_bottom))

func _draw_side_wall(rect: Rect2i, inner_edge_left: bool) -> void:
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	draw_rect(rect, WOOD_MID)
	var board_width := maxi(8, roundi(28.0 * layout_scale))
	var seam_width := maxi(1, roundi(2.0 * layout_scale))
	for x: int in range(rect.position.x + board_width, rect.end.x, board_width):
		draw_rect(Rect2i(x, rect.position.y, seam_width, rect.size.y), WOOD_DARK)
		draw_rect(Rect2i(x + seam_width, rect.position.y, seam_width, rect.size.y), WOOD_LIGHT)
	var beam_height := maxi(3, roundi(8.0 * layout_scale))
	var beam_step := maxi(32, roundi(128.0 * layout_scale))
	for y: int in range(rect.position.y + beam_step, rect.end.y, beam_step):
		draw_rect(Rect2i(rect.position.x, y, rect.size.x, beam_height), WOOD_DARK)
		draw_rect(Rect2i(rect.position.x, y + beam_height, rect.size.x, seam_width), WOOD_LIGHT)
	var post_width := mini(rect.size.x, maxi(6, roundi(14.0 * layout_scale)))
	var post_x := rect.position.x if inner_edge_left else rect.end.x - post_width
	draw_rect(Rect2i(post_x, rect.position.y, post_width, rect.size.y), WOOD_DARK)
	var highlight_x := post_x + post_width - seam_width if inner_edge_left else post_x
	draw_rect(Rect2i(highlight_x, rect.position.y, seam_width, rect.size.y), WOOD_LIGHT)

func _draw_ground(rect: Rect2i) -> void:
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var plinth_height := mini(rect.size.y, maxi(6, roundi(18.0 * layout_scale)))
	draw_rect(Rect2i(rect.position, Vector2i(rect.size.x, plinth_height)), WOOD_DARK)
	if plinth_height >= rect.size.y:
		return
	var path := Rect2i(rect.position + Vector2i(0, plinth_height), Vector2i(rect.size.x, rect.size.y - plinth_height))
	draw_rect(path, PATH_MID)
	var outline := maxi(1, roundi(2.0 * layout_scale))
	draw_rect(Rect2i(path.position, Vector2i(path.size.x, outline)), PATH_DARK)
	var tile_width := maxi(24, roundi(96.0 * layout_scale))
	for x: int in range(path.position.x + tile_width, path.end.x, tile_width):
		draw_rect(Rect2i(x, path.position.y + outline, outline, path.size.y - outline), PATH_DARK)
		draw_rect(Rect2i(x + outline, path.position.y + outline, outline, path.size.y - outline), PATH_LIGHT)
