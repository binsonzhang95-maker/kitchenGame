extends SceneTree

const Layout = preload("res://responsive_layout.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run()

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("RESPONSIVE_LAYOUT_FAIL " + label)

func _near(a: float, b: float) -> bool:
	return is_equal_approx(a, b)

func _run() -> void:
	var ipad := Layout.calculate(Vector2(1536, 1152))
	_check(ipad.content_rect == Rect2(Vector2.ZERO, Layout.DESIGN_SIZE), "4:3 retains the authored 1536x1152 frame")
	_check(_near(float(ipad.scale), 1.0), "4:3 does not upscale")
	var sixteen_nine := Layout.calculate(Vector2(2048, 1152))
	_check(sixteen_nine.content_rect.position == Vector2(256, 0) and _near(float(sixteen_nine.scale), 1.0), "16:9 centres unchanged content")
	var phone := Layout.calculate(Vector2(2496, 1152))
	_check(phone.content_rect.position == Vector2(480, 0) and _near(float(phone.scale), 1.0), "19.5:9 centres unchanged content")
	var protected := Layout.calculate(Vector2(2496, 1152), {"left":150, "right":150, "bottom":60})
	_check(_near(float(protected.scale), 1092.0 / 1152.0), "bottom inset uniformly shrinks content")
	_check(Rect2(protected.room_rect).end.y <= 1092.01, "all room tables stay above protected home area")
	_check(Rect2(protected.content_rect).encloses(protected.room_rect), "safe content encloses the complete room")
	var again := Layout.calculate(Vector2(2496, 1152))
	_check(again.content_rect == phone.content_rect and _near(float(again.scale), float(phone.scale)), "resize round-trip has no accumulated offset")
	var invalid := Layout.calculate(Vector2(1536, 1152), {"left":99999, "right":-10, "top":NAN, "bottom":99999})
	_check(float(invalid.safe_insets.left) <= 1536.0 * 0.45 and float(invalid.safe_insets.bottom) <= 1152.0 * 0.45, "invalid bridge insets are bounded")
	print("RESPONSIVE_LAYOUT_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
