class_name AutoplayDriver
extends Node

var app: Variant
var spawn_clock := 0.0
var heartbeat_clock := 0.0
var frames := 0
var ready_sent := false
var error_sent := false


static func requested() -> bool:
	if OS.get_cmdline_user_args().has("--autoplay") or OS.get_cmdline_args().has("--autoplay"):
		return true
	if not OS.has_feature("web"):
		return false
	var query_input := str(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('input') || ''", true))
	return query_input != "device" and bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).has('autoplay')", true))


func _process(delta: float) -> void:
	if not is_instance_valid(app): return
	if not is_instance_valid(app.model):
		if OS.has_feature("web") and not error_sent:
			JavaScriptBridge.eval("window.YggraHost && window.YggraHost.postMessage('error:model missing')", true)
			error_sent = true
		return
	frames += 1
	if OS.has_feature("web") and not ready_sent and frames >= 30:
		JavaScriptBridge.eval("window.YggraHost && window.YggraHost.postMessage('ready')", true)
		ready_sent = true
	for table: Dictionary in app.model.tables:
		var action: String = app.model.table_action(int(table.id))
		if action in ["assign", "order", "pay", "clean"]:
			app.model.act(int(table.id), action)
	if app.model.paused: return
	spawn_clock += delta
	heartbeat_clock += delta
	if heartbeat_clock >= 5.0:
		heartbeat_clock -= 5.0
		if OS.has_feature("web"):
			JavaScriptBridge.eval("window.YggraHost && window.YggraHost.postMessage('tick:%d')" % int(app.model.served), true)
	if spawn_clock >= 3.0:
		spawn_clock -= 3.0
		if app.model.customers.size() < 10:
			app.model.spawn_customer()
