extends RefCounted
## One coordinate contract for every 1536 x 1152 game surface.
## The simulation never sees these values: it continues to use its authored
## 1536 x 1024 room coordinates below the 80px header.

const DESIGN_SIZE := Vector2(1536, 1152)
const TOP_BAR := 80.0
const BOTTOM_BAR := 48.0

static func calculate(viewport: Vector2, requested_insets: Dictionary = {}) -> Dictionary:
	var screen := Vector2(maxf(1.0, viewport.x), maxf(1.0, viewport.y))
	var safe := _sanitize_insets(screen, requested_insets)
	var usable := Rect2(Vector2(safe.left, safe.top), screen - Vector2(safe.left + safe.right, safe.top + safe.bottom))
	usable.size.x = maxf(1.0, usable.size.x)
	usable.size.y = maxf(1.0, usable.size.y)
	# Do not upscale the original iPad composition.  Only shrink if a real
	# inset or a smaller window would otherwise clip controls or the 20 tables.
	var scale := minf(1.0, minf(usable.size.x / DESIGN_SIZE.x, usable.size.y / DESIGN_SIZE.y))
	var content_size := DESIGN_SIZE * scale
	var content_origin := usable.position + (usable.size - content_size) * 0.5
	return {
		"viewport": screen,
		"safe_insets": safe,
		"safe_rect": usable,
		"scale": scale,
		"content_rect": Rect2(content_origin, content_size),
		"room_rect": Rect2(content_origin + Vector2(0, TOP_BAR) * scale, Vector2(DESIGN_SIZE.x, DESIGN_SIZE.y - TOP_BAR - BOTTOM_BAR) * scale),
	}

static func web_safe_insets(viewport: Vector2) -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var source := """
(function(){
 var a=window.YggraSafeArea||{}, keys=['left','right','top','bottom'];
 var e=document.createElement('div'); e.style.cssText='position:fixed;visibility:hidden;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)'; document.body.appendChild(e);
 var s=getComputedStyle(e), n=function(v){var x=parseFloat(v);return Number.isFinite(x)?x:null}, safe={}, hostKnown=false, cssNonzero=false;
 var css={left:n(s.paddingLeft),right:n(s.paddingRight),top:n(s.paddingTop),bottom:n(s.paddingBottom)};
 keys.forEach(function(k){ var host=(typeof a[k]==='number' && Number.isFinite(a[k])) ? a[k] : null; if(host!==null){safe[k]=host;hostKnown=true;}else{safe[k]=css[k]===null?0:css[k];} if(css[k]!==null && css[k]!==0)cssNonzero=true; }); e.remove();
 var width=0,height=0; try { var canvas=document.querySelector('canvas'), rect=canvas&&canvas.getBoundingClientRect(); if(rect&&Number.isFinite(rect.width)&&Number.isFinite(rect.height)&&rect.width>0&&rect.height>0){width=rect.width;height=rect.height;} } catch(_) {}
 if(width<=0||height<=0){width=Number.isFinite(window.innerWidth)?window.innerWidth:0;height=Number.isFinite(window.innerHeight)?window.innerHeight:0;}
 var ua=navigator.userAgent||'', ipadDesktop=(navigator.platform==='MacIntel' && (navigator.maxTouchPoints||0)>1);
 return JSON.stringify({safe:safe,width:width,height:height,host_known:hostKnown,css_nonzero:cssNonzero,mobile:/Mobi|Android|iPhone|iPad|iPod/i.test(ua)||ipadDesktop});
})()
"""
	var raw: Variant = JavaScriptBridge.eval(source, true)
	var parsed: Variant = JSON.parse_string(str(raw))
	if not (parsed is Dictionary):
		return {}
	return web_safe_insets_from_data(parsed as Dictionary, viewport)

## Kept data-only so the Web bridge can be tested without a browser runtime.
static func web_safe_insets_from_data(data: Dictionary, viewport: Vector2) -> Dictionary:
	var css_size := Vector2(_finite_number(data.get("width", 0.0)), _finite_number(data.get("height", 0.0)))
	var css_safe: Dictionary = data.get("safe", {}) if data.get("safe", {}) is Dictionary else {}
	var result: Dictionary = _css_to_logical(css_safe, css_size, viewport)
	var host_known := data.get("host_known", false) is bool and bool(data.get("host_known", false))
	var css_nonzero := data.get("css_nonzero", false) is bool and bool(data.get("css_nonzero", false))
	var mobile := data.get("mobile", false) is bool and bool(data.get("mobile", false))
	if mobile and not host_known and not css_nonzero and result.values().all(func(v): return is_zero_approx(float(v))):
		# Hosts without the bridge still need space for a landscape notch/home bar.
		result.bottom = 60.0
		if viewport.x / maxf(1.0, viewport.y) >= 1.6:
			result.left = 150.0
			result.right = 150.0
	return result

static func _css_to_logical(css: Dictionary, css_size: Vector2, logical: Vector2) -> Dictionary:
	if css_size.x <= 0.0 or css_size.y <= 0.0:
		return {}
	var sx := logical.x / css_size.x
	var sy := logical.y / css_size.y
	return {"left":maxf(0.0, _finite_number(css.get("left", 0.0)) * sx), "right":maxf(0.0, _finite_number(css.get("right", 0.0)) * sx), "top":maxf(0.0, _finite_number(css.get("top", 0.0)) * sy), "bottom":maxf(0.0, _finite_number(css.get("bottom", 0.0)) * sy)}

static func _sanitize_insets(viewport: Vector2, value: Dictionary) -> Dictionary:
	var left := clampf(_finite_number(value.get("left", 0.0)), 0.0, viewport.x * 0.45)
	var right := clampf(_finite_number(value.get("right", 0.0)), 0.0, viewport.x * 0.45)
	var top := clampf(_finite_number(value.get("top", 0.0)), 0.0, viewport.y * 0.45)
	var bottom := clampf(_finite_number(value.get("bottom", 0.0)), 0.0, viewport.y * 0.45)
	return {"left":left, "right":right, "top":top, "bottom":bottom}

static func _finite_number(value: Variant) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return 0.0
	var number := float(value)
	return number if is_finite(number) else 0.0
