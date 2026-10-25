extends SceneTree
## Two distinct headless runs:
## --script res://tests/multi_persistence.gd -- --write /tmp/multi_test_<unique>.json
## --script res://tests/multi_persistence.gd -- --read /tmp/multi_test_<unique>.json
## Writer refuses pre-existing paths. Reader deletes only the verified test files.
const Model = preload("res://multi_model.gd")
const Support = preload("res://tests/multi_test_support.gd")
var assertions: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("MULTI_PERSISTENCE_FAIL " + description)


func _run() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 2 or arguments[0] not in ["--write", "--read"]:
		push_error("Usage: -- --write|--read /tmp/multi_test_<unique>.json")
		quit(2)
		return
	var mode: String = arguments[0]
	var path: String = arguments[1].simplify_path()
	if not (path.begins_with("/tmp/") or path.begins_with("/private/tmp/")) or not path.get_file().begins_with("multi_test_") or not path.ends_with(".json"):
		push_error("Only an explicit disposable /tmp/multi_test_*.json path is accepted; never a player save.")
		quit(2)
		return
	var metadata_path: String = path + ".testmeta.json"
	if mode == "--write":
		for candidate: String in [path, path + ".tmp", metadata_path]:
			if FileAccess.file_exists(candidate):
				push_error("Refusing to overwrite existing file: " + candidate)
				quit(2)
				return
		var model = Support.persistence_fixture()
		_expect(model != null, "construct paid statistics and a second claimed service task")
		if model != null:
			_expect(model.validate_invariants().is_empty(), "writer model invariants")
			_expect(int(model.coins) == 38 and int(model.served) == 1 and bool(model.paused), "writer keeps complete paused state")
			_expect(model.tasks.size() == 1 and model.tasks[0].state == "claimed", "writer has one live claim")
			if failures == 0:
				_expect(model.save_to(path) == OK, "write model through real V2 save API")
			if failures == 0:
				var meta: Dictionary = {"test": "multi_persistence_v2", "writer_pid": OS.get_process_id(), "path": path, "snapshot": model.to_dict()}
				var file: FileAccess = FileAccess.open(metadata_path, FileAccess.WRITE)
				_expect(file != null, "write test-only comparison sidecar")
				if file != null:
					file.store_string(JSON.stringify(meta, "\t"))
					file.flush()
					_expect(file.get_error() == OK, "sidecar flush")
					file.close()
			if failures == 0:
				print("MULTI_PERSISTENCE_WRITE_PASS pid=%d coins=38 served=1 claimed_task=%d path=%s" % [OS.get_process_id(), int(model.tasks[0].id), path])
	else:
		if not FileAccess.file_exists(metadata_path):
			push_error("Missing test sidecar; refusing unknown save file")
			quit(2)
			return
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if not meta is Dictionary or meta.get("test") != "multi_persistence_v2" or meta.get("path") != path or not meta.get("snapshot") is Dictionary:
			push_error("Invalid test identity sidecar; refusing unknown save file")
			quit(2)
			return
		_expect(int(meta.writer_pid) != OS.get_process_id(), "reader is a different process from writer")
		var model = Model.new()
		_expect(model.load_from(path), "fresh process loads complete V2 state")
		_expect(Support.same(model.to_dict(), meta.snapshot), "all restored fields match writer snapshot")
		_expect(model.validate_invariants().is_empty(), "reader model invariants")
		if not model.tasks.is_empty():
			var task: Dictionary = model.tasks[0]
			_expect(task.state == "claimed" and int(model.workers[int(task.worker_id)].task_id) == int(task.id), "claim ownership and pending route survive restart")
		var frozen: Dictionary = model.to_dict().duplicate(true)
		model.tick(10.0)
		_expect(Support.same(model.to_dict(), frozen), "restored pause freezes gameplay")
		model.paused = false
		model.auto_dispatch = true
		for step: int in range(2400):
			for table: Dictionary in model.tables:
				var action: String = str(model.table_action(int(table.id)))
				if action in ["order", "pay", "clean"]:
					_expect(model.act(int(table.id), action), "reader advances pending workload")
					if action == "pay":
						_expect(not model.act(int(table.id), "pay"), "restart cannot duplicate payment")
			model.tick(0.1)
			if int(model.served) == 2 and Support.all_clear(model):
				break
		_expect(int(model.coins) == 76 and int(model.served) == 2 and int(model.lost) == 0 and Support.all_clear(model), "restored claim completes with exactly 76 coins and two served")
		_expect(model.validate_invariants().is_empty(), "finished reader invariants")
		if failures == 0:
			for candidate: String in [path, path + ".tmp", metadata_path]:
				if FileAccess.file_exists(candidate):
					_expect(DirAccess.remove_absolute(candidate) == OK, "remove this verified disposable test file")
		if failures == 0:
			print("MULTI_PERSISTENCE_READ_PASS writer_pid=%d reader_pid=%d coins=76 served=2 claims_completed=true" % [int(meta.writer_pid), OS.get_process_id()])
	print("MULTI_PERSISTENCE_RESULT mode=%s assertions=%d failures=%d" % [mode, assertions, failures])
	quit(0 if failures == 0 else 1)
