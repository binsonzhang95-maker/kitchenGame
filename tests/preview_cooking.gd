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
	view.apply_layout(ResponsiveLayout.calculate(viewport))
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
