extends SceneTree
## A real Godot kitchen-interface preview; not restaurant-flow acceptance.
const Session = preload("res://cooking_session.gd")
const View = preload("res://cooking_view.gd")
const ResponsiveLayout = preload("res://responsive_layout.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	root.title = "做菜界面 · 隔离预览"
	var session = Session.new()
	assert(session.setup({"table_id":1,"guest_id":1,"generation":1}, "soup"))
	for action in ["add_potato", "add_carrot", "add_water", "cut", "pot", "heat_medium"]:
		assert(session.act(action))
	session.tick(2.0)
	var view = View.new()
	root.add_child(view)
	# Lay out against the real requested preview viewport using production scaling.
	await process_frame
	var viewport := root.get_visible_rect().size
	var insets := _requested_insets()
	if not insets.is_empty():
		var render_size := Vector2(root.get_texture().get_width(), root.get_texture().get_height())
		insets.left *= viewport.x / render_size.x
		insets.right *= viewport.x / render_size.x
		insets.top *= viewport.y / render_size.y
		insets.bottom *= viewport.y / render_size.y
	view.apply_layout(ResponsiveLayout.calculate(viewport, insets))
	view.open(session, {"table_label":"1号桌"})
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://verification/cooking_interface_preview.png"
	var pixels := root.get_texture().get_image()
	var error := pixels.save_png(path)
	print("COOKING_INTERFACE_PREVIEW error=%d viewport=%dx%d path=%s" % [error, pixels.get_width(), pixels.get_height(), ProjectSettings.globalize_path(path)])
	view.free()
	pixels = null
	await process_frame
	quit(0 if error == OK else 1)

func _requested_insets() -> Dictionary:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--insets="):
			continue
		var parts := argument.trim_prefix("--insets=").split(",")
		if parts.size() == 4:
			return {"left":parts[0].to_float(), "right":parts[1].to_float(), "top":parts[2].to_float(), "bottom":parts[3].to_float()}
	return {}
