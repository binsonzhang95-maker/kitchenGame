extends RefCounted
## Frozen V4 20-table layout and deterministic four-way navigation.
## Positions are foot/support coordinates in the 1536 x 1024 room.
## The four private-room passages require restaurant_open_background.png.
## The original closed-door illustration is not this layout's navigation artwork.
## route() includes the exact endpoints, returns [] for blocked endpoints,
## and never snaps an actor through furniture to reach the grid.

const SIZE := Vector2(1536, 1024)
const CELL: int = 16
const COLUMNS: int = 96
const ROWS: int = 64
const RENDER_SCALE: float = 0.75
const CLEARANCE: float = 2.0
const EDGE_MARGIN: float = 4.0
const COUNTER := Rect2(506, 176, 646, 78)
## Animal ground occupancy. This deliberately does not use the full sprite.
const SEAT_RESERVATION_SIZE := Vector2(64, 32)
const RuntimeLayout = preload("res://floor_layout.gd")

## Kept solely as the frozen V4 geometry validator. Runtime models must call
## create() and retain the returned layout instance instead of using this
## static facade, so a resize in one game cannot mutate another game's map.
static func create(width: float = 1536.0):
	return RuntimeLayout.new(width, RuntimeLayout.revision_for_width(width))

static var _definitions: Array[Dictionary] = []
static var _obstacles: Array[Rect2] = []
static var _floor_regions: Array[Rect2] = []
static var _walkable: PackedByteArray = PackedByteArray()
static var _neighbors: Array = []
static var _seat_regions: Array[Rect2] = []
static var _seat_masks: Dictionary = {}
static var _seat_neighbors: Dictionary = {}
static var _initialized: bool = false


static func table_definitions() -> Array[Dictionary]:
	_ensure_layout()
	var result: Array[Dictionary] = []
	for item: Dictionary in _definitions:
		result.append(item.duplicate(true))
	return result


static func table_center(id: int) -> Vector2:
	_ensure_layout()
	if id < 1 or id > _definitions.size():
		return Vector2(-1, -1)
	return _definitions[id - 1]["center"]


static func seat_point(id: int) -> Vector2:
	if id < 1 or id > 20:
		return Vector2(-1, -1)
	# This is the actual seated sprite support point, not a remote approach proxy.
	return table_center(id) + Vector2(0, 1 if id >= 19 else 12)


static func service_point(id: int) -> Vector2:
	if id < 1 or id > 20:
		return Vector2(-1, -1)
	return table_center(id) + Vector2(84, 24)


static func seat_reservation(id: int) -> Rect2:
	_ensure_layout()
	return _seat_regions[id - 1] if id >= 1 and id <= _seat_regions.size() else Rect2()


static func kitchen_point() -> Vector2:
	return Vector2(856, 278)


static func worker_home(id: int) -> Vector2:
	return Vector2(432 + 64 * clampi(id, 0, 1), 278)


static func entrance_point() -> Vector2:
	return Vector2(768, 928)


static func queue_point(index: int) -> Vector2:
	# The visible queue has eight reserved positions, clear of all furniture.
	return Vector2(940 + 36 * clampi(index, 0, 7), 920)


static func floor_regions() -> Array[Rect2]:
	_ensure_layout()
	return _floor_regions.duplicate()


static func obstacles() -> Array[Rect2]:
	_ensure_layout()
	return _obstacles.duplicate()


static func is_walkable(position: Vector2) -> bool:
	_ensure_layout()
	if not is_finite(position.x) or not is_finite(position.y):
		return false
	if position.x < EDGE_MARGIN or position.x > SIZE.x - EDGE_MARGIN:
		return false
	if position.y < EDGE_MARGIN or position.y > SIZE.y - EDGE_MARGIN:
		return false
	var on_floor: bool = false
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


static func segment_is_walkable(start: Vector2, finish: Vector2) -> bool:
	if not is_walkable(start) or not is_walkable(finish):
		return false
	if not _segment_inside_floor(start, finish):
		return false
	# Exact slab intersection; even corner grazing is blocked.
	for box: Rect2 in _obstacles:
		if _segment_hits_box(start, finish, box):
			return false
	return true


static func route(start: Vector2, finish: Vector2) -> Array[Vector2]:
	# Historical, furniture-only route used by geometry checks and old snapshots.
	return _route_with_seats(start, finish, _all_seat_ids())


## Runtime navigation keeps every seat reserved, except for the assigned
## customer seat or the one reservation an old actor is currently exiting.
static func route_avoiding_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int] = []) -> Array[Vector2]:
	return _route_with_seats(start, finish, seat_exceptions)


static func segment_avoids_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int] = []) -> bool:
	if not segment_is_walkable(start, finish):
		return false
	var exceptions: Dictionary = _seat_exception_set(seat_exceptions)
	for id: int in range(1, _seat_regions.size() + 1):
		if not exceptions.has(id) and _segment_hits_box(start, finish, _seat_regions[id - 1]):
			return false
	return true


static func path_avoids_seats(start: Vector2, path: Array, seat_exceptions: Array[int] = []) -> bool:
	var exceptions: Dictionary = _seat_exception_set(seat_exceptions)
	var exit_ids: Dictionary = _contained_unexcepted_seats(start, exceptions)
	var previous: Vector2 = start
	for point: Variant in path:
		if not point is Vector2:
			return false
		# route() retains exact endpoints, including a zero-length first waypoint
		# when the endpoint happens to coincide with an attachment node.
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


static func _route_with_seats(start: Vector2, finish: Vector2, seat_exceptions: Array[int]) -> Array[Vector2]:
	_ensure_grid()
	var empty: Array[Vector2] = []
	if not is_walkable(start) or not is_walkable(finish):
		return empty
	if start.distance_squared_to(finish) < 0.000001:
		return [finish]
	var exceptions: Dictionary = _seat_exception_set(seat_exceptions)
	var key: String = _seat_cache_key(exceptions)
	var mask: PackedByteArray = _seat_mask(key, exceptions)
	var neighbors: Array = _seat_neighbor_list(key, mask, exceptions)
	var exit_ids: Dictionary = _contained_unexcepted_seats(start, exceptions)
	var first: int = _exit_attachment_node_with_mask(start, mask, exceptions, exit_ids) if not exit_ids.is_empty() else _attachment_node_with_mask(start, mask, exceptions)
	var last: int = _attachment_node_with_mask(finish, mask, exceptions)
	if first < 0 or last < 0:
		return empty
	var parents := PackedInt32Array()
	parents.resize(COLUMNS * ROWS)
	parents.fill(-2)
	parents[first] = -1
	var pending := PackedInt32Array([first])
	var head: int = 0
	while head < pending.size() and parents[last] == -2:
		var current: int = pending[head]
		head += 1
		var adjacent: PackedInt32Array = neighbors[current]
		for neighbor: int in adjacent:
			if parents[neighbor] == -2:
				parents[neighbor] = current
				pending.append(neighbor)
	if parents[last] == -2:
		return empty
	var reversed: Array[Vector2] = []
	var cursor: int = last
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
	var result: Array[Vector2] = _remove_collinear_points(raw)
	return result if path_avoids_seats(start, result.slice(1), seat_exceptions) else empty


static func _ensure_layout() -> void:
	if not _definitions.is_empty():
		return
	var xs: Array[int] = [540, 800, 1060]
	var ys: Array[int] = [345, 475, 605, 735, 865]
	var id: int = 1
	for row: int in range(ys.size()):
		var count: int = 2 if row == ys.size() - 1 else 3
		for column: int in range(count):
			_definitions.append({"id": id, "zone": "hall", "label": "大厅 %02d" % id,
				"center": Vector2(xs[column], ys[row])})
			id += 1
	var private_number: int = 1
	for center: Vector2 in [Vector2(175, 170), Vector2(160, 390), Vector2(145, 615), Vector2(135, 840)]:
		_definitions.append({"id": id, "zone": "private", "label": "包厢 %02d" % private_number, "center": center})
		id += 1
		private_number += 1
	var bar_number: int = 1
	for center: Vector2 in [Vector2(1352, 350), Vector2(1372, 650)]:
		_definitions.append({"id": id, "zone": "bar", "label": "吧台 %02d" % bar_number,
			"center": center})
		id += 1
		bar_number += 1
	# Floor polygons are represented as overlapping rectangles. Everything outside
	# their union is a wall/counter/exterior, rather than an invisible walkable void.
	_floor_regions.assign([
		Rect2(332, 254, 890, 680), Rect2(332, 150, 56, 784), Rect2(284, 900, 1010, 34),
		Rect2(56, 134, 228, 84), Rect2(24, 346, 244, 90),
		Rect2(12, 572, 242, 94), Rect2(8, 802, 230, 100),
		# Inspected v4 openings, with a small inset from their wooden thresholds.
		# Stop at x388: the first door's kitchen jamb starts around x394.
		Rect2(284, 152, 104, 45), Rect2(268, 349, 120, 61),
		Rect2(254, 575, 134, 66), Rect2(238, 809, 150, 87),
		# v4 removed the real bar pier: opening y446..519, lower wall starts y520.
		Rect2(1280, 208, 208, 264), Rect2(1200, 450, 140, 66), Rect2(1310, 468, 184, 360),
	])
	_obstacles.append(COUNTER.grow(CLEARANCE))
	# Baked plant pots, using their floor contact areas rather than the leaves.
	for pot: Rect2 in [Rect2(60, 130, 48, 28), Rect2(30, 326, 48, 36), Rect2(12, 548, 48, 36), Rect2(10, 794, 48, 40), Rect2(1278, 174, 54, 40), Rect2(1422, 286, 66, 52), Rect2(1456, 782, 38, 46)]:
		_obstacles.append(pot.grow(CLEARANCE))
	for definition: Dictionary in _definitions:
		var center: Vector2 = definition["center"]
		_seat_regions.append(Rect2(seat_point(int(definition.id)) - SEAT_RESERVATION_SIZE * 0.5, SEAT_RESERVATION_SIZE))
		# Ground footprint: the upper sprite pixels are perspective, not solid floor.
		# Leave the chair support point behind the table accessible for real seating.
		var feet := Rect2(center + Vector2(-53, 18), Vector2(106, 28))
		if definition.zone == "bar":
			feet = Rect2(center + Vector2(-48, 24), Vector2(96, 44))
		_obstacles.append(feet.grow(CLEARANCE))


static func _segment_inside_floor(start: Vector2, finish: Vector2) -> bool:
	# Exact union of segment/region intervals; a route cannot leap a thin wall gap.
	var spans: Array[Vector2] = []
	var difference: Vector2 = finish - start
	for region: Rect2 in _floor_regions:
		var low: float = 0.0
		var high: float = 1.0
		var intersects: bool = true
		for axis: int in range(2):
			if absf(difference[axis]) < 0.000001:
				if start[axis] < region.position[axis] or start[axis] > region.end[axis]:
					intersects = false
					break
			else:
				var a: float = (region.position[axis] - start[axis]) / difference[axis]
				var b: float = (region.end[axis] - start[axis]) / difference[axis]
				low = maxf(low, minf(a, b))
				high = minf(high, maxf(a, b))
				if low > high:
					intersects = false
					break
		if intersects:
			spans.append(Vector2(low, high))
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var covered: float = 0.0
	for span: Vector2 in spans:
		if span.x > covered + 0.000001:
			return false
		covered = maxf(covered, span.y)
		if covered >= 1.0 - 0.000001:
			return true
	return false


static func _ensure_grid() -> void:
	if _initialized:
		return
	_ensure_layout()
	_walkable.resize(COLUMNS * ROWS)
	_neighbors.resize(COLUMNS * ROWS)
	for index: int in range(COLUMNS * ROWS):
		_walkable[index] = 1 if is_walkable(_node_position(index)) else 0
	for index: int in range(COLUMNS * ROWS):
		var adjacent := PackedInt32Array()
		if _walkable[index] == 1:
			var cell := Vector2i(index % COLUMNS, index / COLUMNS)
			for direction: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
				var next: Vector2i = cell + direction
				if next.x < 0 or next.x >= COLUMNS or next.y < 0 or next.y >= ROWS:
					continue
				var neighbor: int = next.y * COLUMNS + next.x
				if _walkable[neighbor] == 1 and segment_is_walkable(_node_position(index), _node_position(neighbor)):
					adjacent.append(neighbor)
		_neighbors[index] = adjacent
	_initialized = true


static func _all_seat_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: int in range(1, 21):
		ids.append(id)
	return ids


static func _seat_exception_set(seat_exceptions: Array[int]) -> Dictionary:
	_ensure_layout()
	var result: Dictionary = {}
	for id: int in seat_exceptions:
		if id >= 1 and id <= _seat_regions.size():
			result[id] = true
	return result


static func _contained_unexcepted_seats(position: Vector2, exceptions: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for id: int in range(1, _seat_regions.size() + 1):
		if not exceptions.has(id) and _point_in_box(position, _seat_regions[id - 1]):
			result[id] = true
	return result


static func _seat_cache_key(exceptions: Dictionary) -> String:
	var ids: Array[int] = []
	for id: Variant in exceptions:
		ids.append(int(id))
	ids.sort()
	return ",".join(ids)


static func _seat_mask(key: String, exceptions: Dictionary) -> PackedByteArray:
	if _seat_masks.has(key):
		return _seat_masks[key]
	var result := PackedByteArray()
	result.resize(COLUMNS * ROWS)
	for index: int in range(result.size()):
		result[index] = _walkable[index]
		if result[index] == 0:
			continue
		for id: int in range(1, _seat_regions.size() + 1):
			if not exceptions.has(id) and _point_in_box(_node_position(index), _seat_regions[id - 1]):
				result[index] = 0
				break
	_seat_masks[key] = result
	return result


static func _seat_neighbor_list(key: String, mask: PackedByteArray, exceptions: Dictionary) -> Array:
	if _seat_neighbors.has(key):
		return _seat_neighbors[key]
	var result: Array = []
	result.resize(COLUMNS * ROWS)
	var ids: Array[int] = []
	for id: Variant in exceptions:
		ids.append(int(id))
	for index: int in range(COLUMNS * ROWS):
		var adjacent := PackedInt32Array()
		if mask[index] == 1:
			for neighbor: int in _neighbors[index]:
				if mask[neighbor] == 1 and segment_avoids_seats(_node_position(index), _node_position(neighbor), ids):
					adjacent.append(neighbor)
		result[index] = adjacent
	_seat_neighbors[key] = result
	return result


static func _node_position(index: int) -> Vector2:
	return Vector2((index % COLUMNS) * CELL + CELL / 2, (index / COLUMNS) * CELL + CELL / 2)


static func _attachment_node(position: Vector2) -> int:
	return _attachment_node_with_mask(position, _walkable, {})


static func _attachment_node_with_mask(position: Vector2, mask: PackedByteArray, exceptions: Dictionary) -> int:
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var best: int = -1
	var best_distance: float = INF
	# A bounded local visibility search connects non-grid endpoints without teleporting.
	for y: int in range(maxi(0, base.y - 4), mini(ROWS, base.y + 5)):
		for x: int in range(maxi(0, base.x - 4), mini(COLUMNS, base.x + 5)):
			var index: int = y * COLUMNS + x
			if mask[index] == 0:
				continue
			var point: Vector2 = _node_position(index)
			var distance: float = position.distance_squared_to(point)
			if distance < best_distance and _segment_walkable_with_exceptions(position, point, exceptions):
				best = index
				best_distance = distance
	return best


static func _exit_attachment_node_with_mask(position: Vector2, mask: PackedByteArray, exceptions: Dictionary, exit_ids: Dictionary) -> int:
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var best: int = -1
	var best_distance: float = INF
	# An actor restored in a newly reserved support area may take exactly one
	# visible segment out to an unmasked node. BFS itself never sees that seat.
	for y: int in range(maxi(0, base.y - 4), mini(ROWS, base.y + 5)):
		for x: int in range(maxi(0, base.x - 4), mini(COLUMNS, base.x + 5)):
			var index: int = y * COLUMNS + x
			if mask[index] == 0:
				continue
			var point: Vector2 = _node_position(index)
			var distance: float = position.distance_squared_to(point)
			if distance < best_distance and _segment_exits_reserved_seats(position, point, exceptions, exit_ids):
				best = index
				best_distance = distance
	return best


static func _segment_walkable_with_exceptions(start: Vector2, finish: Vector2, exceptions: Dictionary) -> bool:
	var ids: Array[int] = []
	for id: Variant in exceptions:
		ids.append(int(id))
	return segment_avoids_seats(start, finish, ids)


static func _segment_exits_reserved_seats(start: Vector2, finish: Vector2, exceptions: Dictionary, exit_ids: Dictionary) -> bool:
	if not segment_is_walkable(start, finish):
		return false
	# A straight segment through a convex rectangle that starts inside and ends
	# outside leaves it once. Every hit must therefore be one of the seats the
	# actor started in; no other reservation can be crossed on the exit prefix.
	for id: int in range(1, _seat_regions.size() + 1):
		if exceptions.has(id) or not _segment_hits_box(start, finish, _seat_regions[id - 1]):
			continue
		if not exit_ids.has(id) or _point_in_box(finish, _seat_regions[id - 1]):
			return false
	return true


static func _point_in_box(point: Vector2, box: Rect2) -> bool:
	return point.x >= box.position.x and point.x <= box.end.x and point.y >= box.position.y and point.y <= box.end.y


static func _segment_hits_box(start: Vector2, finish: Vector2, box: Rect2) -> bool:
	var low: float = 0.0
	var high: float = 1.0
	var difference: Vector2 = finish - start
	for axis: int in range(2):
		var origin: float = start[axis]
		var direction: float = difference[axis]
		var minimum: float = box.position[axis]
		var maximum: float = box.end[axis]
		if absf(direction) < 0.000001:
			if origin < minimum or origin > maximum:
				return false
			continue
		var near: float = (minimum - origin) / direction
		var far: float = (maximum - origin) / direction
		if near > far:
			var swap: float = near
			near = far
			far = swap
		low = maxf(low, near)
		high = minf(high, far)
		if low > high:
			return false
	return true


static func _remove_collinear_points(points: Array[Vector2]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for point: Vector2 in points:
		if result.size() >= 2:
			var previous: Vector2 = result[-1] - result[-2]
			var next: Vector2 = point - result[-1]
			if absf(previous.cross(next)) < 0.0001 and previous.dot(next) > 0:
				result[-1] = point
				continue
		result.append(point)
	return result
