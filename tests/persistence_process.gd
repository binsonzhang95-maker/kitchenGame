extends SceneTree
## Separate-process persistence check. Execute only after Godot run permission is resolved.
## First process:  --script res://tests/persistence_process.gd -- --write <absolute-test-path>
## Second process: --script res://tests/persistence_process.gd -- --read  <same-test-path>
## Use a disposable path; this script refuses the live player save filename.

const Model = preload("res://game_model.gd")
var failures: int = 0


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 2 or arguments[0] not in ["--write", "--read"]:
		push_error("Usage: -- --write|--read <absolute-test-path>")
		quit(2)
		return
	var mode: String = arguments[0]
	var path: String = arguments[1]
	if not path.is_absolute_path() or path.begins_with("res://") or path.begins_with("user://") or path.get_file().is_empty():
		push_error("A real absolute disposable test path is required.")
		quit(2)
		return
	if path.get_file() == "restaurant_save_v1.json" or path.get_file() == "restaurant_save_v1.json.tmp":
		push_error("Refusing to access the player save slot.")
		quit(2)
		return
	var model = Model.new()
	if mode == "--write":
		# A fresh path protects any pre-existing file, regardless of its filename.
		if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".tmp"):
			push_error("Refusing to overwrite an existing test path or temporary file.")
			quit(2)
			return
		model.tick(2.0)
		_check(model.advance("seat"), "seat")
		model.tick(1.5)
		_check(model.advance("order"), "order")
		_check(model.advance("cook"), "cook")
		model.tick(4.0)
		_check(model.advance("serve_food"), "serve_food")
		model.tick(3.0)
		_check(model.advance("serve_drink"), "serve_drink")
		model.tick(3.0)
		model.tick(5.0)
		model.tick(2.4)
		_check(model.advance("pay"), "pay")
		_check_paid(model)
		if failures == 0:
			_check(model.save_to(path) == OK, "save paid leaving state")
		if failures == 0:
			print("PERSISTENCE_WRITE_PASS pid=%d coins=38 paid=true phase=leaving path=%s" % [OS.get_process_id(), path])
	else:
		_check(model.load_from(path), "load snapshot from previous process")
		_check_paid(model)
		var before: Dictionary = model.to_dict()
		_check(not model.advance("pay"), "duplicate payment rejected after restart")
		_check(model.to_dict() == before, "duplicate payment leaves state unchanged")
		if failures == 0:
			print("PERSISTENCE_READ_PASS pid=%d coins=38 paid=true phase=leaving duplicate_payment=false path=%s" % [OS.get_process_id(), path])
	quit(0 if failures == 0 else 1)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error("PERSISTENCE_FAIL: " + description)


func _check_paid(model) -> void:
	_check(model.coins == 38, "balance is exactly 38")
	_check(model.paid, "paid flag is true")
	_check(model.phase == "leaving", "phase is leaving")
	_check(model.served == 1 and model.lost == 0 and model.customer_id == 1, "customer counters survive")
