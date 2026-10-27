extends SceneTree
## Isolated G11 visual-flow contract. It uses normal model routing only: no
## member position, path, phase, or table state is patched by this fixture.
const Model = preload("res://multi_model.gd")
const G11Art = preload("res://g11_art.gd")
const G11DecorLayout = preload("res://g11_decor_layout.gd")
const HallView = preload("res://multi_view.gd")

var assertions := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error("G11_VISUAL_FAIL " + label)

func _run() -> void:
	var model = Model.new(1688.0)
	var view := HallView.new()
	view.model = model
	root.add_child(view) # _draw only exists as an in-tree CanvasItem pass.
	await process_frame
	view.queue_redraw()
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
	_check(view.is_inside_tree() and view.get_canvas_item().is_valid(), "production HallView enters the render tree")
	model.open_for_arrivals = false
	model.auto_seat = false
	model.auto_dispatch = false
	model.auto_cook = false
	model.max_customers = 12
	var hall := model.spawn_party(3, ["cat", "dog", "panda"])
	var private_room := model.spawn_party(3, ["capybara", "hamster", "cat"])
	var bar := model.spawn_customer("dog")
	_check(hall > 0 and private_room > 0 and bar > 0, "three explicit preview parties spawn")
	_check(model.assign_next(1), "full hall party routes to hall table")
	_check(model.assign_next(15), "full private party routes to private table")
	_check(model.assign_next(19), "bar single routes to bar table")
	var arrived := false
	for step: int in range(300):
		var all_seated := true
		for table_id: int in [1, 15, 19]:
			var members := model.table_members(table_id)
			var wanted := 1 if table_id == 19 else 3
			all_seated = all_seated and members.size() == wanted
			for member: Dictionary in members:
				all_seated = all_seated and str(member.state) == "seated" and (member.path as Array).is_empty()
		if all_seated:
			arrived = true
			break
		model.tick(0.1)
	_check(arrived, "all preview parties arrive via normal routing")
	for table_id: int in [1, 15]:
		var members := model.table_members(table_id)
		_check(members.size() == 3, "family table %d exposes three members" % table_id)
		for seat_index: int in range(3):
			var member: Dictionary = members[seat_index]
			_check(int(member.seat_index) == seat_index and (member.path as Array).is_empty(), "member %d completes its own routed seat arrival %d/%d" % [seat_index, table_id, seat_index])
			if seat_index > 0:
				_check(not Vector2(member.pos).is_equal_approx(Vector2(members[0].pos)), "side member %d has an independent rendered position" % seat_index)
	_check(model.table_members(19).size() == 1 and model.floor.table_capacity(19) == 1, "bar stays single-seat")
	for species: String in G11Art.SIDE_SPECIES:
		var action := G11Art.side_action(species, "eat")
		_check(not action.is_empty() and int(action.get("frames", 0)) == 4, species + " delivered side eat clip")
		_check(G11Art.frame_pivot(G11Art.side_manifest(species), action, 0).is_equal_approx(Vector2(64, 110)), species + " seated pivot")
		for frame_index: int in [1, 2, 3]:
			var frame: Dictionary = action.frame_rects[frame_index]
			_check(G11Art.frame_pivot(G11Art.side_manifest(species), action, frame_index).is_equal_approx(Vector2(frame.pivot[0], frame.pivot[1])), "%s frame %d uses its canonical frame_rect pivot" % [species, frame_index])
	_check(G11Art.action_for_table("eating", 1.0, true) == "chat", "selected dining speaker can use delivered chat action")
	# Move one table through the ordinary model actions, then render naturally
	# advancing nonzero eat frames. No actor position, route, phase or clock is
	# patched by this test.
	model.auto_cook = true
	model.auto_dispatch = true
	var reached_eating := false
	for step: int in range(500):
		if model.table_action(1) == "order": model.act(1, "order")
		model.tick(0.1)
		if str(model.tables[0].phase) == "eating":
			reached_eating = true
			break
	_check(reached_eating, "normal order/cook/service flow reaches eating")
	var rendered_nonzero_frames: Dictionary = {}
	for step: int in range(18):
		if str(model.tables[0].phase) != "eating": break
		var side_action := G11Art.side_action("dog", "eat")
		rendered_nonzero_frames[G11Art.frame_index(float(model.tables[0].elapsed), side_action)] = true
		view.clock = float(model.tables[0].elapsed)
		view.queue_redraw()
		if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
		model.tick(0.1)
	for frame_index: int in [1, 2, 3]:
		_check(rendered_nonzero_frames.has(frame_index), "actual production draw loop reached side eat frame %d" % frame_index)
	var paid := false
	var saw_stand_up := false
	var departed := false
	for step: int in range(240):
		if model.table_action(1) == "pay":
			paid = model.act(1, "pay")
		for member: Dictionary in model.table_members(1):
			if str(member.get("transition", "")) == "stand_up":
				saw_stand_up = true
				view.queue_redraw()
				if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
		model.tick(0.1)
		if paid and not model.customers.has(hall):
			departed = true
			break
	_check(paid and saw_stand_up and departed, "normal paid party renders stand-up then completes departure")
	var decor := G11DecorLayout.build(1688.0)
	_check(not decor.is_empty(), "wide scene has G11 decor")
	var solid_ids: Dictionary = {}
	for entry: Dictionary in decor:
		_check(str(entry.path).begins_with("res://") and str(entry.layer) in ["floor", "wall", "object"], "decor entry schema " + str(entry.id))
		if bool(entry.collision):
			solid_ids[str(entry.id)] = true
			var box: Rect2 = entry.footprint
			var raw_feet: Rect2 = entry.get("raw_feet", Rect2())
			_check(raw_feet.has_area() and box.position.is_equal_approx(Vector2(entry.position) + raw_feet.position) and box.size.is_equal_approx(raw_feet.size), "solid uses exact translated raw feet " + str(entry.id))
			for table_id: int in range(1, 21):
				for seat_index: int in range(model.floor.table_capacity(table_id)):
					_check(not box.intersects(model.floor.seat_reservation(table_id, seat_index)), "solid decor clears seat %s/%d" % [str(entry.id), seat_index])
			for queue_index: int in range(8):
				for member_index: int in range(3):
					var queued_position: Vector2 = model.floor.queue_point(queue_index) + (Vector2.ZERO if member_index == 0 else Vector2(member_index * 10, -18))
					_check(not box.intersects(model.floor.actor_ground_footprint(queued_position)), "solid decor clears queued group %s/%d" % [str(entry.id), queue_index])
	for queue_index: int in range(8):
		_check(not model.floor.route_avoiding_seats(model.floor.entrance_point(), model.floor.queue_point(queue_index)).is_empty(), "all queue groups retain a normal route %d" % queue_index)
	for id: String in ["host_stand", "coat_rack", "service_station"]:
		_check(solid_ids.has(id), "narrow G11 ships visible solid " + id)
	var widest := G11DecorLayout.build(2496.0)
	var widest_ids: Dictionary = {}
	for entry: Dictionary in widest:
		widest_ids[str(entry.id)] = true
		if bool(entry.collision):
			_check(str(entry.layer) == "object" and entry.has("raw_feet"), "wide solid remains real colliding furniture " + str(entry.id))
	for id: String in ["host_stand", "coat_rack", "service_station", "bar_counter", "plant_big", "pendant_0", "pendant_1"]:
		_check(widest_ids.has(id), "2496 delivers visible " + id)
	var floor_decor: Array = model.floor.decoration_definitions()
	_check(not floor_decor.is_empty(), "floor consumes the same G11 decor definitions")
	view.queue_free()
	await process_frame
	print("G11_VISUAL_RESULT assertions=%d failures=%d arrived=%s decor=%d" % [assertions, failures, str(arrived), decor.size()])
	quit(0 if failures == 0 else 1)
