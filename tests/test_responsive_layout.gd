extends SceneTree

const Layout = preload("res://responsive_layout.gd")
const HallView = preload("res://multi_view.gd")
const WideBackdrop = preload("res://wide_backdrop.gd")
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
	_check(ipad.content_rect == Rect2(Vector2.ZERO, Layout.DESIGN_SIZE), "4:3 retains the authored vertical rhythm")
	_check(_near(float(ipad.scale), 1.0) and ipad.world_size == Vector2(1536, 1072), "4:3 gives the removed footer space to the room")
	_check((ipad.room_rect as Rect2).end.y == ipad.content_rect.end.y and (ipad.room_rect as Rect2).size.y == 1072.0, "hall reaches the content bottom with no footer gap")
	var sixteen_nine := Layout.calculate(Vector2(2048, 1152))
	_check(sixteen_nine.content_rect == Rect2(Vector2.ZERO, Vector2(2048, 1152)) and _near(float(sixteen_nine.scale), 1.0), "16:9 uses all usable width")
	_check(_near((sixteen_nine.world_size as Vector2).x, 2048.0), "16:9 world expands instead of centering a 1536 room")
	var phone := Layout.calculate(Vector2(2496, 1152))
	_check(phone.content_rect == Rect2(Vector2.ZERO, Vector2(2496, 1152)) and _near(float(phone.scale), 1.0), "19.5:9 uses all usable width")
	_check((phone.world_size as Vector2).x > 1536.0, "19.5:9 world has reachable outer columns")
	var protected := Layout.calculate(Vector2(2496, 1152), {"left":150, "right":150, "bottom":60})
	_check(_near(float(protected.scale), 1092.0 / 1152.0), "bottom inset uniformly shrinks content")
	_check(Rect2(protected.room_rect).end.y <= 1092.01, "all room tables stay above protected home area")
	_check(Rect2(protected.content_rect).grow(0.1).encloses(protected.room_rect), "safe content encloses the complete room")
	_check(absf((protected.world_size as Vector2).x - 2316.66) < 0.02, "safe horizontal width becomes model world width")
	for spec: Dictionary in [
		{"size":Vector2(956, 440), "insets":{"left":62.0, "right":62.0, "top":0.0, "bottom":21.0}, "name":"iPhone Pro Max"},
		{"size":Vector2(844, 390), "insets":{"left":47.0, "right":47.0, "top":0.0, "bottom":21.0}, "name":"iPhone landscape"},
	]:
		var safe_phone := Layout.calculate(spec.size, spec.insets, true)
		var backdrop := WideBackdrop.new()
		backdrop.set_layout(safe_phone)
		_check(backdrop.coverage_rect() == Rect2(Vector2.ZERO, spec.size), str(spec.name) + " architecture covers the full viewport")
		_check((safe_phone.content_rect as Rect2).end.y == (safe_phone.safe_rect as Rect2).end.y, str(spec.name) + " playable world stops above the home indicator")
		_check((safe_phone.safe_rect as Rect2).grow(0.1).encloses(safe_phone.room_rect as Rect2), str(spec.name) + " playable hall stays between side insets")
		var bands := backdrop.architecture_rects()
		_check(bands.size() == 3 and bands[0].size.x > 0.0 and bands[1].size.x > 0.0 and bands[2].size.y > 0.0, str(spec.name) + " has left, right and bottom architecture bands")
		backdrop.free()
	_check(Layout.query_has_host_app("?input=device&host=app") and not Layout.query_has_host_app("?input=device"), "host=app is independent of input=device")
	for spec: Dictionary in [
		{"size":Vector2(844, 390), "name":"844x390"},
		{"size":Vector2(667, 375), "name":"667x375"},
		{"size":Vector2(1024, 768), "name":"1024x768"},
	]:
		var compact := Layout.calculate(spec.size)
		_check(compact.content_rect.position == Vector2.ZERO and compact.content_rect.size == spec.size, str(spec.name) + " content spans the viewport")
		_check(_near((compact.room_rect as Rect2).size.x, spec.size.x), str(spec.name) + " room span and click transform agree")
		_check((compact.world_size as Vector2).x >= 1536.0, str(spec.name) + " preserves minimum authored world width")
	var narrowed := Layout.with_world_width(Layout.calculate(Vector2(1536, 1152), {"left":64, "right":96, "top":24, "bottom":36}), 2496.0)
	var narrowed_safe: Rect2 = narrowed.safe_rect
	var narrowed_content: Rect2 = narrowed.content_rect
	var narrowed_room: Rect2 = narrowed.room_rect
	var narrowed_scale := float(narrowed.scale)
	_check(_near(narrowed_scale, narrowed_safe.size.x / 2496.0), "rejected wide world shrinks to the safe width")
	_check(narrowed_scale <= narrowed_safe.size.x / 2496.0 + 0.0001 and narrowed_scale <= narrowed_safe.size.y / Layout.DESIGN_SIZE.y + 0.0001, "rejected wide world never exceeds either safe-axis scale limit")
	_check(narrowed_safe.grow(0.01).encloses(narrowed_content) and narrowed_safe.grow(0.01).encloses(narrowed_room), "rejected wide world keeps content and room inside safe insets")
	_check(_near(narrowed_content.size.x / 2496.0, narrowed_scale) and _near(narrowed_content.size.y / Layout.DESIGN_SIZE.y, narrowed_scale), "rejected wide world retains one uniform transform for render and clicks")
	var again := Layout.calculate(Vector2(2496, 1152))
	_check(again.content_rect == phone.content_rect and _near(float(again.scale), float(phone.scale)), "resize round-trip has no accumulated offset")
	for width: float in [1536.0, 2496.0, 4096.0]:
		var plan := HallView.front_wall_draw_plan(Vector2(width, Layout.ROOM_HEIGHT))
		var baseline := Layout.ROOM_HEIGHT - 124.0
		var kinds := {}
		var overlaps := false
		for index in range(plan.size()):
			var piece: Dictionary = plan[index]
			_check(_near(float(piece.baseline), baseline), "front wall %s shares the end-piece baseline at width %d" % [piece.kind, int(width)])
			kinds[piece.kind] = true
			for other_index in range(index):
				if (piece.destination as Rect2).intersects(plan[other_index].destination as Rect2):
					overlaps = true
		_check(kinds.size() == plan.size() and not overlaps, "front wall draw list has no duplicate or overlapping piece at width %d" % int(width))
	var invalid := Layout.calculate(Vector2(1536, 1152), {"left":99999, "right":-10, "top":NAN, "bottom":99999})
	_check(float(invalid.safe_insets.left) <= 1536.0 * 0.45 and float(invalid.safe_insets.bottom) <= 1152.0 * 0.45, "invalid bridge insets are bounded")
	print("RESPONSIVE_LAYOUT_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
