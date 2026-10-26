class_name DeviceBridge
extends Node

const DeviceEventMapperScript = preload("res://device_event_mapper.gd")
const MAX_PAYLOADS_PER_PUSH := 64

var app: Variant
var mapper := DeviceEventMapperScript.new()
var link_state := "offline"
var last_error := ""
var _connected_posted := false
var _push_callback: JavaScriptObject
var _link_callback: JavaScriptObject
var _js_api: JavaScriptObject


static func requested() -> bool:
	return OS.has_feature("web") and str(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('input') || ''", true)) == "device"


func _ready() -> void:
	if OS.has_feature("web"):
		_install_js_api()


func _install_js_api() -> void:
	_push_callback = JavaScriptBridge.create_callback(_js_push)
	_link_callback = JavaScriptBridge.create_callback(_js_set_link)
	_js_api = JavaScriptBridge.create_object("Object")
	_js_api.push = _push_callback
	_js_api.setLink = _link_callback
	JavaScriptBridge.get_interface("window").YggraDevice = _js_api


func _js_push(args: Array) -> void:
	if not args.is_empty():
		push_text(str(args[0]), false)


func _js_set_link(args: Array) -> void:
	if not args.is_empty():
		set_link(str(args[0]))


func push_text(text: String, collect_results := true) -> Array[Dictionary]:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		last_error = "push expects a JSON array"
		return []
	return push_payloads(parsed, collect_results)


func push_payloads(payloads: Array, collect_results := true) -> Array[Dictionary]:
	if payloads.size() > MAX_PAYLOADS_PER_PUSH:
		last_error = "push accepts at most %d payloads" % MAX_PAYLOADS_PER_PUSH
		return []
	last_error = ""
	var handled: Array[Dictionary] = []
	for payload: Variant in payloads:
		if not payload is Dictionary:
			continue
		for mapped: Dictionary in mapper.map(payload):
			var adapter: Variant = _adapter()
			var session: Variant = _session()
			if adapter == null or session == null:
				if collect_results:
					handled.append({"event": mapped.duplicate(true), "result": {}})
				continue
			var event: Dictionary = adapter.event_envelope()
			for key: String in mapped:
				event[key] = mapped[key]
			var result: Dictionary = app.receive_toy_event(event)
			if collect_results:
				handled.append({"event": mapped.duplicate(true), "result": result})
			if str(adapter.state().get("connection", "")) == "connected" and not _connected_posted:
				_connected_posted = true
				_post_host("link:connected")
	return handled


func set_link(state: String) -> bool:
	if state not in ["lan", "cloud", "offline"]:
		return false
	link_state = state
	_connected_posted = false
	var adapter: Variant = _adapter()
	if state == "offline":
		if adapter != null:
			adapter.disconnect_simulator()
		mapper.reset()
		_post_host("link:lost")
	else:
		mapper.reset()
		if adapter != null:
			adapter.connect_simulator()
		_post_host("link:aligning")
	return true


func kitchen_ready() -> void:
	mapper.reset()
	_connected_posted = false
	var adapter: Variant = _adapter()
	if adapter == null:
		return
	if link_state == "offline":
		adapter.disconnect_simulator()
	else:
		adapter.connect_simulator()
		_post_host("link:aligning")


func _adapter() -> Variant:
	return app.input_adapter if app != null else null


func _session() -> Variant:
	return app.cooking_session if app != null else null


func _post_host(message: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.YggraHost && window.YggraHost.postMessage(%s)" % JSON.stringify(message), true)
