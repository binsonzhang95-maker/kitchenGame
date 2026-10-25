## Frozen pre-visual V2 code, copied only for synthetic migration tests. No player save IO.
extends RefCounted
## Canonical 20-table layout and deterministic four-way navigation.
## Positions are foot/support coordinates in the 1120 x 640 room.
## route() includes the exact endpoints, returns [] for blocked endpoints,
## and never snaps an actor through furniture to reach the grid.

const SIZE := Vector2(1120, 640)
const CELL: int = 16
const COLUMNS: int = 70
const ROWS: int = 40
const CLEARANCE: float = 2.0
const EDGE_MARGIN: float = 4.0
const COUNTER := Rect2(20, 20, 240, 90)

static var _definitions: Array[Dictionary] = []
static var _obstacles: Array[Rect2] = []
static var _walkable: PackedByteArray = PackedByteArray()
static var _neighbors: Array = []
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
	return table_center(id) + Vector2(0, -60)


static func service_point(id: int) -> Vector2:
	if id < 1 or id > 20:
		return Vector2(-1, -1)
	return table_center(id) + Vector2(56, 16)


static func kitchen_point() -> Vector2:
	return Vector2(288, 96)


static func entrance_point() -> Vector2:
	return Vector2(16, 610)


static func queue_point(index: int) -> Vector2:
	# The visible queue has eight reserved positions, clear of all furniture.
	return Vector2(48 + 26 * clampi(index, 0, 7), 608)


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
	for box: Rect2 in _obstacles:
		if _point_in_box(position, box):
			return false
	return true


static func segment_is_walkable(start: Vector2, finish: Vector2) -> bool:
	if not is_walkable(start) or not is_walkable(finish):
		return false
	# Exact slab intersection; even corner grazing is blocked.
	for box: Rect2 in _obstacles:
		if _segment_hits_box(start, finish, box):
			return false
	return true


static func route(start: Vector2, finish: Vector2) -> Array[Vector2]:
	_ensure_grid()
	var empty: Array[Vector2] = []
	if not is_walkable(start) or not is_walkable(finish):
		return empty
	if start.distance_squared_to(finish) < 0.000001:
		return [finish]
	var first: int = _attachment_node(start)
	var last: int = _attachment_node(finish)
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
		var adjacent: PackedInt32Array = _neighbors[current]
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
	return _remove_collinear_points(raw)


static func _ensure_layout() -> void:
	if not _definitions.is_empty():
		return
	var xs: Array[int] = [350, 485, 620, 755, 890]
	var ys: Array[int] = [210, 375, 540]
	var id: int = 1
	for row: int in range(3):
		var columns: int = 4 if row == 2 else 5
		for column: int in range(columns):
			_definitions.append({"id": id, "zone": "hall", "label": "大厅 %02d" % id,
				"center": Vector2(xs[column], ys[row])})
			id += 1
	var private_number: int = 1
	for y: int in [250, 450]:
		for x: int in [65, 200]:
			_definitions.append({"id": id, "zone": "private", "label": "包厢 %02d" % private_number,
				"center": Vector2(x, y)})
			id += 1
			private_number += 1
	var bar_number: int = 1
	for y: int in [250, 450]:
		_definitions.append({"id": id, "zone": "bar", "label": "吧台 %02d" % bar_number,
			"center": Vector2(1045, y)})
		id += 1
		bar_number += 1
	_obstacles.append(COUNTER.grow(CLEARANCE))
	for definition: Dictionary in _definitions:
		var center: Vector2 = definition["center"]
		_obstacles.append(Rect2(center + Vector2(-38, -45), Vector2(76, 76)).grow(CLEARANCE))


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


static func _node_position(index: int) -> Vector2:
	return Vector2((index % COLUMNS) * CELL + CELL / 2, (index / COLUMNS) * CELL + CELL / 2)


static func _attachment_node(position: Vector2) -> int:
	var base := Vector2i(floori(position.x / CELL), floori(position.y / CELL))
	var best: int = -1
	var best_distance: float = INF
	# A bounded local visibility search connects non-grid endpoints without teleporting.
	for y: int in range(maxi(0, base.y - 4), mini(ROWS, base.y + 5)):
		for x: int in range(maxi(0, base.x - 4), mini(COLUMNS, base.x + 5)):
			var index: int = y * COLUMNS + x
			if _walkable[index] == 0:
				continue
			var point: Vector2 = _node_position(index)
			var distance: float = position.distance_squared_to(point)
			if distance < best_distance and segment_is_walkable(position, point):
				best = index
				best_distance = distance
	return best


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
