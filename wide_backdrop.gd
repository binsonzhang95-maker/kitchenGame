extends Node2D
## Viewport-only underlay. The actual room is drawn by MultiView across
## model.floor.SIZE; this node intentionally contains no side-room illusion.

const BACKGROUND := preload("res://restaurant_art/restaurant_empty_background.png")

var safe_rect := Rect2(Vector2.ZERO, Vector2(1536, 1152))
var viewport_size := Vector2(1536, 1152)

func set_layout(layout: Dictionary) -> void:
	safe_rect = layout.get("safe_rect", safe_rect)
	viewport_size = layout.get("viewport", viewport_size)
	queue_redraw()

func _draw() -> void:
	# The sampled floor only fills unplayable safe-area gutters. The world begins
	# at room_rect and owns every visible table, actor, and hit target.
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color("efe3c4"))
	if safe_rect.position.x > 0.0:
		_draw_margin(Rect2(0, 0, safe_rect.position.x, viewport_size.y))
	if safe_rect.end.x < viewport_size.x:
		_draw_margin(Rect2(safe_rect.end.x, 0, viewport_size.x - safe_rect.end.x, viewport_size.y))

func _draw_margin(rect: Rect2) -> void:
	if rect.size.x <= 0.0:
		return
	var y := rect.position.y
	while y < rect.end.y:
		var height := minf(192.0, rect.end.y - y)
		draw_texture_rect_region(BACKGROUND, Rect2(rect.position.x, y, rect.size.x, height), Rect2(576, 384, 256, height))
		y += height
