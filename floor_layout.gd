extends RefCounted
## Runtime-wide restaurant geometry.  Every Model owns one of these; no layout
## cache is shared between games. Coordinates use the full 1072-unit room
## below the 80-unit HUD so the hall reaches the bottom safe edge.

const HEIGHT := 1072.0
const LEGACY_HEIGHT := 1024.0
const RENDER_SCALE := 0.75
## 24-unit cells keep wide-map routing bounded. G11's authored door lanes are
## deliberately aligned to this grid; do not make a finer grid compensate for
## a bad furniture placement.
const CELL := 24
const CLEARANCE := 2.0
const ACTOR_GROUND_SIZE := Vector2(64, 32)
const EDGE_MARGIN := 4.0
const SEAT_RESERVATION_SIZE := Vector2(64, 32)
const MIN_WIDTH := 1536.0
const MAX_WIDTH := 4096.0
## Revision 3 adds individual reservations for the two side seats.  Revision 2
## is intentionally still constructible so V5 saves are validated against the
## geometry that produced them before the model migrates them.
const LAYOUT_VERSION := 3
const G10_LAYOUT_VERSION := 2
const REVISION_VERSION_FACTOR := 1000000
const LEFT_STRIP := 388.0
const RIGHT_STRIP := 336.0
const G11DecorLayout = preload("res://g11_decor_layout.gd")

var SIZE := Vector2(MIN_WIDTH, HEIGHT)
var COUNTER := Rect2()
var layout_width: float = MIN_WIDTH
var revision: int = 1
var _definitions: Array[Dictionary] = []
var _obstacles: Array[Rect2] = []
var _architecture: Array[Rect2] = []
var _floor_regions: Array[Rect2] = []
var _seat_regions: Array[Rect2] = []
var _seat_keys: Array[int] = []
var _seat_lookup: Dictionary = {}
var _columns: int = 0
var _rows: int = 0
var _walkable := PackedByteArray()
var _neighbors: Array = []
var _seat_masks: Dictionary = {}
var _seat_nodes: Array = []
var _decorations: Array[Dictionary] = []


func _init(width: float = MIN_WIDTH, layout_revision: int = 1) -> void:
	if not valid_width(width) or not valid_saved_revision(width, layout_revision):
		width = MIN_WIDTH
		layout_revision = revision_for_width(width)
	layout_width = snappedf(width, 0.01)
	revision = layout_revision
	SIZE = Vector2(layout_width, LEGACY_HEIGHT if is_legacy_revision(layout_width, revision) else HEIGHT)
	_build_legacy() if is_legacy_revision(layout_width, revision) else _build()


static func valid_width(width: float) -> bool:
	return is_finite(width) and width >= MIN_WIDTH and width <= MAX_WIDTH


static func legacy_revision_for_width(width: float) -> int:
	return int(roundi(snappedf(width, 0.01) * 100.0))


static func revision_for_width(width: float) -> int:
	# The version prefix distinguishes restored architecture from the open-floor
	# V5 layout even when a save is loaded at exactly the same width.
	return LAYOUT_VERSION * REVISION_VERSION_FACTOR + legacy_revision_for_width(width)


static func g10_revision_for_width(width: float) -> int:
	return G10_LAYOUT_VERSION * REVISION_VERSION_FACTOR + legacy_revision_for_width(width)


static func is_legacy_revision(width: float, value: int) -> bool:
	return valid_width(width) and value == legacy_revision_for_width(width)


static func valid_revision(width: float, value: int) -> bool:
	return valid_width(width) and value == revision_for_width(width)


static func valid_saved_revision(width: float, value: int) -> bool:
	return valid_revision(width, value) or value == g10_revision_for_width(width) or is_legacy_revision(width, value)


func table_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Dictionary in _definitions:
		result.append(item.duplicate(true))
	return result


func table_center(id: int) -> Vector2:
	return _definitions[id - 1].center if id >= 1 and id <= _definitions.size() else Vector2(-1, -1)


func table_capacity(id: int) -> int:
	if id < 1 or id > 20:
		return 0
	# Historical V5 layouts had one reservation per table. Keeping that fact in
	# the geometry is what makes their validation meaningful before migration.
	if revision != revision_for_width(layout_width):
		return 1
	return 1 if id >= 19 else 3


func seat_key(id: int, seat_index: int = 0) -> int:
	if id < 1 or id > 20 or seat_index < 0 or seat_index >= table_capacity(id):
		return -1
	# Back seats retain the historic 1..20 keys. Side seats cannot collide with
	# that range; left is 21..40 and right is 41..60.
	return id if seat_index == 0 else id + 20 * seat_index


func seat_point(id: int, seat_index: int = 0) -> Vector2:
	if seat_key(id, seat_index) < 0:
		return Vector2(-1, -1)
	# The bar stools are drawn one pixel higher than ordinary chairs.  This is
	# the sprite support point used by both navigation and the renderer.
	if seat_index == 0:
		return table_center(id) + Vector2(0, 1 if id >= 19 else 12)
	# G11 side sprites use a 110px pivot and their hand pixels occupy local
	# y=63..102.  At .75 scale, y=+14 places those hands over the tabletop
	# (rather than visibly above it).  These are support points, not artwork
	# offsets; each remains a separate 64x32 reservation.
	if revision == revision_for_width(layout_width) and id == 15 and seat_index == 1:
		# The first private room's original pot leaves this asymmetric, proven
		# support point as the only non-overlapping left chair placement.
		return Vector2(88, 178)
	var side_x := 72.0
	return table_center(id) + Vector2(-side_x if seat_index == 1 else side_x, 14)


func service_point(id: int) -> Vector2:
	if id < 1 or id > 20:
		return Vector2(-1, -1)
	# G10 revision 2 and the historical revision 1 retain their literal
	# definition/service behavior. Only the current G11 map has party-safe
	# worker approach points.
	if revision != revision_for_width(layout_width):
		var historical_offset_x := 84.0
		if not is_legacy_revision(layout_width, revision):
			if id >= 15 and id <= 18:
				historical_offset_x = 73.0
			elif id >= 19:
				historical_offset_x = 62.0
		return table_center(id) + Vector2(historical_offset_x, 24)
	if id >= 1 and id <= 14:
		return table_center(id) + Vector2(84, 52)
	var offset_x := 84.0
	if id >= 15 and id <= 18:
		# These are individually measured against each private-room doorway.
		return [Vector2(312, 174), Vector2(312, 380), Vector2(312, 606), Vector2(312, 844)][id - 15]
	elif id >= 19:
		offset_x = 62.0
	return table_center(id) + Vector2(offset_x, 24)


func actor_ground_footprint(position: Vector2) -> Rect2:
	return Rect2(position - ACTOR_GROUND_SIZE * 0.5, ACTOR_GROUND_SIZE)


func seat_reservation(id: int, seat_index: int = 0) -> Rect2:
	var key := seat_key(id, seat_index)
	return _seat_regions[int(_seat_lookup[key])] if _seat_lookup.has(key) else Rect2()


func family_table(id: int) -> Dictionary:
	if id < 1 or id > _definitions.size():
		return {}
	var definition: Dictionary = _definitions[id - 1]
	return {"id": id, "capacity": table_capacity(id), "zone": str(definition.zone), "center": definition.center, "offset": _table_visual_offset(id), "scale": 1.0}


func table_visual(id: int) -> Dictionary:
	return family_table(id)


func _table_visual_offset(id: int) -> Vector2:
	# This is visual-only data shared with the furniture footprint below. The
	# first private table's visual feet are shifted up and left to stay inside
	# the first room floor and meet its asymmetric left chair without changing
	# that chair's collision support point.
	return Vector2(-8, -4) if revision == revision_for_width(layout_width) and id == 15 else Vector2.ZERO


func kitchen_point() -> Vector2:
	return Vector2(layout_width * 0.5 + 88, 278)


func worker_home(id: int) -> Vector2:
	return Vector2(layout_width * 0.5 - 176 + 64 * clampi(id, 0, 1), 278)


func entrance_point() -> Vector2:
	return Vector2(layout_width * 0.5, 1000.0 if is_legacy_revision(layout_width, revision) else HEIGHT - 96)


func queue_point(index: int) -> Vector2:
	if is_legacy_revision(layout_width, revision):
		return Vector2(layout_width * 0.5 - 126 + 36 * clampi(index, 0, 7), 985)
	# G11 parties stage two companions at +10/+20,-18 from this anchor.  At the
	# narrowest width, the former +172 anchor put those companion ground slabs
	# into the original right terrace fence.  This is deliberately revision-gated:
	# G10 rev2 keeps its saved +172 queue geometry and rev1 returned above.
	var base_x := layout_width * 0.5 + (112.0 if revision == revision_for_width(layout_width) else 172.0)
	return Vector2(base_x + 36 * clampi(index, 0, 7), HEIGHT - 110)


func floor_regions() -> Array[Rect2]:
	return _floor_regions.duplicate()


func decoration_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Dictionary in _decorations:
		result.append(item.duplicate(true))
	return result


func obstacles() -> Array[Rect2]:
	return _obstacles.duplicate()


func architecture_obstacles() -> Array[Rect2]:
	return _architecture.duplicate()


func is_architecture_at(position: Vector2) -> bool:
	for box: Rect2 in _architecture:
		if _point_in_box(position, box):
			return true
	return false


func left_strip_width() -> float:
	return 155.0 if is_legacy_revision(layout_width, revision) else LEFT_STRIP


func right_strip_width() -> float:
	return 155.0 if is_legacy_revision(layout_width, revision) else RIGHT_STRIP


func is_walkable(position: Vector2) -> bool:
	if not is_finite(position.x) or not is_finite(position.y):
		return false
	if position.x < EDGE_MARGIN or position.x > SIZE.x - EDGE_MARGIN or position.y < EDGE_MARGIN or position.y > SIZE.y - EDGE_MARGIN:
		return false
	var on_floor := false
	for region: Rect2 in _floor_regions:
		if _point_in_box(position, region):
			on_floor = true
			break
	if not on_floor:
		return false
	for box: Rect2 in _obstacles:
		if _point_in_box(position, box):
			return false
	return true


func segment_is_walkable(start: Vector2, finish: Vector2) -> bool:
	if not is_walkable(start) or not is_walkable(finish) or not _segment_inside_floor(start, finish):
		return false
	for box: Rect2 in _obstacles:
		if _segment_hits_box(start, finish, box):
			return false
	return true


func route(start: Vector2, finish: Vector2) -> Array[Vector2]:
	return _route_with_seats(start, finish, _all_seat_ids())


func route_avoiding_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int] = []) -> Array[Vector2]:
	return _route_with_seats(start, finish, seat_exceptions)


func segment_avoids_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int] = []) -> bool:
	if not segment_is_walkable(start, finish):
		return false
	var exceptions := _seat_exception_set(seat_exceptions)
	for seat_index: int in range(_seat_regions.size()):
		if not exceptions.has(_seat_keys[seat_index]) and _segment_hits_box(start, finish, _seat_regions[seat_index]):
			return false
	return true


func path_avoids_seats(start: Vector2, path: Array, seat_exceptions: Array[int] = []) -> bool:
	var exceptions := _seat_exception_set(seat_exceptions)
	var exit_ids := _contained_unexcepted_seats(start, exceptions)
	var previous := start
	for point: Variant in path:
		if not point is Vector2:
			return false
		if previous.is_equal_approx(point):
			continue
		if not exit_ids.is_empty():
			if not _segment_exits_reserved_seats(previous, point, exceptions, exit_ids):
				return false
			exit_ids.clear()
		elif not segment_avoids_seats(previous, point, seat_exceptions):
			return false
		previous = point
	return true


func _build() -> void:
	_definitions.clear()
	_obstacles.clear()
	_architecture.clear()
	_floor_regions.clear()
	_seat_regions.clear()
	_seat_keys.clear()
	_seat_lookup.clear()
	_seat_masks.clear()
	_seat_nodes.clear()
	_decorations.clear()
	var extra := layout_width - MIN_WIDTH
	var xs: Array[float] = [540.0 + extra * 0.2, 800.0 + extra * 0.5, 1060.0 + extra * 0.8]
	var ys: Array[float] = [345.0, 475.0, 605.0, 735.0, 865.0]
	var id := 1
	for row: int in range(ys.size()):
		var count := 2 if row == ys.size() - 1 else 3
		for column: int in range(count):
			_definitions.append({"id": id, "zone": "hall", "label": "大厅 %02d" % id, "center": Vector2(xs[column], ys[row])})
			id += 1
	# G11's private rooms use the reviewed party-safe anchors. Revision 2 stays
	# frozen for migration validation.
	var private_centers: Array[Vector2] = []
	private_centers.assign([Vector2(188,164), Vector2(188,376), Vector2(116,606), Vector2(188,836)] if revision == revision_for_width(layout_width) else [Vector2(175,170), Vector2(160,390), Vector2(145,615), Vector2(135,840)])
	for index: int in range(private_centers.size()):
		_definitions.append({"id": 15 + index, "zone": "private", "label": "包厢 %02d" % (index + 1), "center": private_centers[index]})
	for index: int in range(2):
		_definitions.append({"id": 19 + index, "zone": "bar", "label": "吧台 %02d" % (index + 1), "center": Vector2(layout_width - (184.0 if index == 0 else 164.0), 350.0 if index == 0 else 650.0)})
	_definitions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.id) < int(b.id))
	COUNTER = Rect2(layout_width * 0.5 - 323.0, 176.0, 646.0, 78.0)
	var right_shift := layout_width - MIN_WIDTH
	# The fixed side strips retain the original room and terrace floors. Only the
	# clean central hall grows; openings are at least three 24-unit cells wide.
	_floor_regions.assign([
		Rect2(332, 254, layout_width - LEFT_STRIP - RIGHT_STRIP + 56, 694), Rect2(332, 150, 56, 798),
		Rect2(layout_width * 0.5 - 60, HEIGHT - 124, 120, 108), Rect2(layout_width * 0.5 + 60, HEIGHT - 140, 430, 50),
		Rect2(56, 134, 228, 84), Rect2(24, 346, 244, 90), Rect2(12, 572, 242, 94), Rect2(8, 802, 230, 100),
		Rect2(284, 152, 104, 45), Rect2(268, 349, 120, 61), Rect2(254, 575, 134, 66), Rect2(238, 809, 150, 87),
		Rect2(1280 + right_shift, 208, 208, 226), Rect2(1200 + right_shift, 432, 140, 102), Rect2(1310 + right_shift, 468, 184, 360),
	])
	# Shared architectural ground geometry mirrors the visible partitions, rail
	# posts and front wall. Door/terrace/entrance gaps remain absent from it.
	_architecture.assign([
		Rect2(0, 222, 284, 20), Rect2(0, 440, 268, 22), Rect2(0, 670, 254, 21), Rect2(0, 906, 238, 16),
		Rect2(284, 218, 48, 128), Rect2(268, 410, 64, 162), Rect2(254, 641, 78, 161),
		Rect2(1200 + right_shift, 208, 24, 224), Rect2(1200 + right_shift, 534, 24, 400),
		Rect2(1200 + right_shift, 208, 294, 20), Rect2(1470 + right_shift, 208, 24, 620), Rect2(1310 + right_shift, 808, 184, 20),
		Rect2(LEFT_STRIP, HEIGHT - 90, layout_width * 0.5 - 60 - LEFT_STRIP, 90),
		Rect2(layout_width * 0.5 + 60, HEIGHT - 90, layout_width * 0.5 - RIGHT_STRIP - 60, 90),
	])
	_obstacles.append(COUNTER.grow(CLEARANCE))
	for box: Rect2 in _architecture:
		_obstacles.append(_architecture_clearance(box))
	for pot: Rect2 in [Rect2(60,130,48,28), Rect2(30,326,48,36), Rect2(12,548,48,36), Rect2(10,794,48,40), Rect2(1278+right_shift,174,54,40), Rect2(1422+right_shift,286,66,52), Rect2(1456+right_shift,782,38,46)]:
		_obstacles.append(pot.grow(CLEARANCE))
	_add_furniture_obstacles()
	_add_g11_decor_obstacles()


func _build_legacy() -> void:
	_definitions.clear()
	_obstacles.clear()
	_architecture.clear()
	_floor_regions.clear()
	_seat_regions.clear()
	_seat_keys.clear()
	_seat_lookup.clear()
	_seat_masks.clear()
	_seat_nodes.clear()
	_decorations.clear()
	var xs: Array[float] = []
	for column: int in range(5): xs.append(lerpf(155.0, layout_width - 155.0, float(column) / 4.0))
	var ys: Array[float] = [340.0, 490.0, 645.0, 800.0]
	for row: int in range(4): _definitions.append({"id":15+row,"zone":"private","label":"包厢 %02d"%(row+1),"center":Vector2(xs[0],ys[row])})
	var id := 1
	for column: int in range(1,4):
		for row: int in range(4): _definitions.append({"id":id,"zone":"hall","label":"大厅 %02d"%id,"center":Vector2(xs[column],ys[row])}); id += 1
	_definitions.append({"id":13,"zone":"hall","label":"大厅 13","center":Vector2(xs[4],ys[0])})
	_definitions.append({"id":14,"zone":"hall","label":"大厅 14","center":Vector2(xs[4],ys[1])})
	_definitions.append({"id":19,"zone":"bar","label":"吧台 01","center":Vector2(xs[4],ys[2])})
	_definitions.append({"id":20,"zone":"bar","label":"吧台 02","center":Vector2(xs[4],ys[3])})
	_definitions.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return int(a.id)<int(b.id))
	COUNTER = Rect2(layout_width*0.5-323.0,176,646,78)
	_floor_regions.append(Rect2(EDGE_MARGIN,256,layout_width-EDGE_MARGIN*2,LEGACY_HEIGHT-272))
	_obstacles.append(COUNTER.grow(CLEARANCE))
	_add_furniture_obstacles()


func _architecture_clearance(box: Rect2) -> Rect2:
	var margin := ACTOR_GROUND_SIZE * 0.5 + Vector2(CLEARANCE, CLEARANCE)
	return Rect2(box.position - margin, box.size + margin * 2.0)


func _add_furniture_obstacles() -> void:
	for definition: Dictionary in _definitions:
		var center: Vector2 = definition.center
		for seat_index: int in range(table_capacity(int(definition.id))):
			var key := seat_key(int(definition.id), seat_index)
			_seat_lookup[key] = _seat_regions.size()
			_seat_keys.append(key)
			_seat_regions.append(Rect2(seat_point(int(definition.id), seat_index) - SEAT_RESERVATION_SIZE * 0.5, SEAT_RESERVATION_SIZE))
		# All eighteen multi-person tables may render the larger G11 family art.
		# Its visual origin is center-(100,32)*.75 and source feet are
		# [10,65,190,109], giving this conservative raw ground slab.
		var feet := Rect2(center + _table_visual_offset(int(definition.id)) + Vector2(-67.5, 24.75), Vector2(135, 33)) if table_capacity(int(definition.id)) > 1 else Rect2(center + Vector2(-53, 18), Vector2(106, 28))
		if definition.zone == "bar": feet = Rect2(center + Vector2(-48, 24), Vector2(96, 44))
		_obstacles.append(feet.grow(CLEARANCE))


func _add_g11_decor_obstacles() -> void:
	# G11 visual dressing belongs only to the current runtime revision.  Legacy
	# V5 and frozen V4 geometry must remain byte-for-byte their historic maps.
	if revision != revision_for_width(layout_width):
		return
	_decorations.assign(G11DecorLayout.build(layout_width))
	for item: Dictionary in _decorations:
		if bool(item.get("collision", false)):
			var footprint: Rect2 = item.get("footprint", Rect2())
			if footprint.size.x > 0.0 and footprint.size.y > 0.0:
				_obstacles.append(_architecture_clearance(footprint))


func _build_grid() -> void:
	if _columns > 0:
		return
	_columns = ceili(layout_width / CELL)
	_rows = ceili(HEIGHT / CELL)
	_walkable.resize(_columns * _rows)
	_neighbors.resize(_columns * _rows)
	_seat_nodes.resize(_seat_regions.size())
	for id: int in range(_seat_regions.size()):
		_seat_nodes[id] = PackedInt32Array()
	for index: int in range(_walkable.size()):
		_walkable[index] = 1 if is_walkable(_node_position(index)) else 0
		if _walkable[index] == 1:
			for id: int in range(_seat_regions.size()):
				if _point_in_box(_node_position(index), _seat_regions[id]):
					_seat_nodes[id].append(index)
	for index: int in range(_walkable.size()):
		var adjacent := PackedInt32Array()
		if _walkable[index] == 1:
			var cell := Vector2i(index % _columns, index / _columns)
			for direction: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
				var next := cell + direction
				if next.x >= 0 and next.x < _columns and next.y >= 0 and next.y < _rows:
					var neighbor := next.y * _columns + next.x
					if _walkable[neighbor] == 1 and segment_is_walkable(_node_position(index), _node_position(neighbor)):
						adjacent.append(neighbor)
		_neighbors[index] = adjacent


func _route_with_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int]) -> Array[Vector2]:
	var empty: Array[Vector2] = []
	if not is_walkable(start) or not is_walkable(finish):
		return empty
	_build_grid()
	if start.distance_squared_to(finish) < 0.000001:
		return [finish]
	var exceptions := _seat_exception_set(seat_exceptions)
	var key := _seat_cache_key(exceptions)
	var mask := _seat_mask(key, exceptions)
	var exit_ids := _contained_unexcepted_seats(start, exceptions)
	var first := _exit_attachment_node_with_mask(start, mask, exceptions, exit_ids) if not exit_ids.is_empty() else _attachment_node_with_mask(start, mask, exceptions)
	var last := _attachment_node_with_mask(finish, mask, exceptions)
	if first < 0 or last < 0:
		return empty
	var parents := PackedInt32Array()
	parents.resize(_columns * _rows)
	parents.fill(-2)
	parents[first] = -1
	var pending := PackedInt32Array([first])
	var head := 0
	while head < pending.size() and parents[last] == -2:
		var current := pending[head]
		head += 1
		for neighbor: int in _neighbors[current]:
			if mask[neighbor] == 1 and parents[neighbor] == -2:
				parents[neighbor] = current
				pending.append(neighbor)
	if parents[last] == -2:
		return empty
	var reversed: Array[Vector2] = []
	var cursor := last
	while cursor >= 0:
		reversed.append(_node_position(cursor))
		cursor = parents[cursor]
	reversed.reverse()
	var raw: Array[Vector2] = [start]
	for point: Vector2 in reversed:
		if raw[-1].distance_squared_to(point) > 0.000001:
			raw.append(point)
	if raw[-1].distance_squared_to(finish) > 0.000001:
		raw.append(finish)
	var result := _remove_collinear_points(raw)
	return result if path_avoids_seats(start, result.slice(1), seat_exceptions) else empty


func _all_seat_ids() -> Array[int]:
	var ids: Array[int] = []
	for key: int in _seat_keys: ids.append(key)
	return ids

func _seat_exception_set(seat_exceptions: Array[int]) -> Dictionary:
	var result := {}
	for key: int in seat_exceptions:
		if _seat_lookup.has(key): result[key] = true
	return result

func _contained_unexcepted_seats(position: Vector2, exceptions: Dictionary) -> Dictionary:
	var result := {}
	for index: int in range(_seat_regions.size()):
		var key: int = _seat_keys[index]
		if not exceptions.has(key) and _point_in_box(position, _seat_regions[index]): result[key] = true
	return result

func _seat_cache_key(exceptions: Dictionary) -> String:
	var ids: Array[int] = []
	for id: Variant in exceptions: ids.append(int(id))
	ids.sort()
	return ",".join(ids)

func _seat_mask(key: String, exceptions: Dictionary) -> PackedByteArray:
	_build_grid()
	if _seat_masks.has(key): return _seat_masks[key]
	var result: PackedByteArray = _walkable.duplicate()
	for seat_index: int in range(_seat_nodes.size()):
		if not exceptions.has(_seat_keys[seat_index]):
			for index: int in _seat_nodes[seat_index]:
				result[index] = 0
	_seat_masks[key] = result
	return result

func _node_position(index: int) -> Vector2:
	return Vector2((index % _columns) * CELL + CELL * 0.5, (index / _columns) * CELL + CELL * 0.5)


## Used only during a real viewport resize.  It keeps the actor near its
## geometrically mapped location when a moved table makes that exact point
## illegal; it never returns a point in furniture or another seat.
func nearest_walkable_avoiding_seats(position: Vector2, seat_exceptions: Array[int] = [], maximum_distance: float = 120.0) -> Vector2:
	var exceptions := _seat_exception_set(seat_exceptions)
	if is_walkable(position) and _contained_unexcepted_seats(position, exceptions).is_empty():
		return position
	_build_grid()
	var mask := _seat_mask(_seat_cache_key(exceptions), exceptions)
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var cells := ceili(maximum_distance / float(CELL))
	var best := Vector2(-1, -1)
	var best_distance := INF
	for y: int in range(maxi(0, base.y - cells), mini(_rows, base.y + cells + 1)):
		for x: int in range(maxi(0, base.x - cells), mini(_columns, base.x + cells + 1)):
			var index := y * _columns + x
			if mask[index] == 0:
				continue
			var point := _node_position(index)
			var distance := point.distance_squared_to(position)
			if distance <= maximum_distance * maximum_distance and distance < best_distance and _fallback_exit_is_clear(position, point, exceptions):
				best = point
				best_distance = distance
	return best


func _fallback_exit_is_clear(start: Vector2, finish: Vector2, exceptions: Dictionary) -> bool:
	# If scaling has placed an actor inside a moved table/seat, let it leave only
	# that collision.  It may not jump through any second piece of furniture or
	# a different reserved seat to reach a convenient point on the far side.
	for box: Rect2 in _obstacles:
		if _segment_hits_box(start, finish, box) and not _point_in_box(start, box):
			return false
	for seat_index: int in range(_seat_regions.size()):
		var key: int = _seat_keys[seat_index]
		if not exceptions.has(key) and _segment_hits_box(start, finish, _seat_regions[seat_index]) and not _point_in_box(start, _seat_regions[seat_index]):
			return false
	return true

func _attachment_node_with_mask(position: Vector2, mask: PackedByteArray, exceptions: Dictionary) -> int:
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var best := -1
	var best_distance := INF
	for y: int in range(maxi(0, base.y - 5), mini(_rows, base.y + 6)):
		for x: int in range(maxi(0, base.x - 5), mini(_columns, base.x + 6)):
			var index := y * _columns + x
			if mask[index] == 0: continue
			var point := _node_position(index)
			var distance := position.distance_squared_to(point)
			if distance < best_distance and _segment_walkable_with_exceptions(position, point, exceptions):
				best = index
				best_distance = distance
	return best

func _exit_attachment_node_with_mask(position: Vector2, mask: PackedByteArray, exceptions: Dictionary, exit_ids: Dictionary) -> int:
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var best := -1
	var best_distance := INF
	for y: int in range(maxi(0, base.y - 5), mini(_rows, base.y + 6)):
		for x: int in range(maxi(0, base.x - 5), mini(_columns, base.x + 6)):
			var index := y * _columns + x
			if mask[index] == 0: continue
			var point := _node_position(index)
			var distance := position.distance_squared_to(point)
			if distance < best_distance and _segment_exits_reserved_seats(position, point, exceptions, exit_ids):
				best = index
				best_distance = distance
	return best

func _segment_walkable_with_exceptions(start: Vector2, finish: Vector2, exceptions: Dictionary) -> bool:
	var ids: Array[int] = []
	for id: Variant in exceptions: ids.append(int(id))
	return segment_avoids_seats(start, finish, ids)

func _segment_exits_reserved_seats(start: Vector2, finish: Vector2, exceptions: Dictionary, exit_ids: Dictionary) -> bool:
	if not segment_is_walkable(start, finish): return false
	for seat_index: int in range(_seat_regions.size()):
		var key: int = _seat_keys[seat_index]
		if not exceptions.has(key) and _segment_hits_box(start, finish, _seat_regions[seat_index]) and (not exit_ids.has(key) or _point_in_box(finish, _seat_regions[seat_index])):
			return false
	return true

func _segment_inside_floor(start: Vector2, finish: Vector2) -> bool:
	var spans: Array[Vector2] = []
	var difference := finish - start
	for region: Rect2 in _floor_regions:
		var low := 0.0
		var high := 1.0
		var intersects := true
		for axis: int in range(2):
			if absf(difference[axis]) < 0.000001:
				if start[axis] < region.position[axis] or start[axis] > region.end[axis]: intersects = false; break
			else:
				var a := (region.position[axis] - start[axis]) / difference[axis]
				var b := (region.end[axis] - start[axis]) / difference[axis]
				low = maxf(low, minf(a, b)); high = minf(high, maxf(a, b))
				if low > high: intersects = false; break
		if intersects: spans.append(Vector2(low, high))
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var covered := 0.0
	for span: Vector2 in spans:
		if span.x > covered + 0.000001: return false
		covered = maxf(covered, span.y)
		if covered >= 1.0 - 0.000001: return true
	return false

func _point_in_box(point: Vector2, box: Rect2) -> bool:
	return point.x >= box.position.x and point.x <= box.end.x and point.y >= box.position.y and point.y <= box.end.y

func _segment_hits_box(start: Vector2, finish: Vector2, box: Rect2) -> bool:
	var low := 0.0
	var high := 1.0
	var difference := finish - start
	for axis: int in range(2):
		var origin: float = start[axis]; var direction: float = difference[axis]
		var minimum: float = box.position[axis]; var maximum: float = box.end[axis]
		if absf(direction) < 0.000001:
			if origin < minimum or origin > maximum: return false
			continue
		var near := (minimum - origin) / direction; var far := (maximum - origin) / direction
		if near > far: var swap := near; near = far; far = swap
		low = maxf(low, near); high = minf(high, far)
		if low > high: return false
	return true

func _remove_collinear_points(points: Array[Vector2]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point: Vector2 in points:
		if result.size() >= 2:
			var previous := result[-1] - result[-2]
			var next := point - result[-1]
			if absf(previous.cross(next)) < 0.0001 and previous.dot(next) > 0:
				result[-1] = point
				continue
		result.append(point)
	return result
