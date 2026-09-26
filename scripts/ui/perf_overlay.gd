extends Label

## Debug overlay (review W4): frame time (p50 and max), the longest chunk
## job step, the job queue, chunks shown per second and the node count,
## all over the last WINDOW_MSEC - so the web build's budgets can be tuned
## from numbers. Hidden unless the page has ?debug=1; F3 toggles it.

const WINDOW_MSEC := 5000
const REFRESH_MSEC := 500

@onready var _world := get_node("../..")
var _frames: Array[Vector2i] = []  # [ticks msec, frame usec]
var _counters: Array = []  # [ticks msec, longest step usec since the last, chunks shown so far]
var _next_refresh := 0


func _ready() -> void:
	visible = OS.has_feature("web") and str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('debug') || ''", true)) == "1"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible


func _process(delta: float) -> void:
	if not visible:
		return
	var now := Time.get_ticks_msec()
	_frames.append(Vector2i(now, roundi(delta * 1000000.0)))
	while _frames[0].x < now - WINDOW_MSEC:
		_frames.pop_front()
	if now < _next_refresh:
		return
	_next_refresh = now + REFRESH_MSEC
	var counters: Dictionary = _world.take_perf_counters()
	_counters.append([now, counters["longest_step_usec"], counters["shown"]])
	while _counters[0][0] < now - WINDOW_MSEC:
		_counters.pop_front()
	text = summary(counters["queued"])


## The overlay's text for the samples so far.
func summary(queued: int) -> String:
	var times: Array = _frames.map(func(f: Vector2i) -> int: return f.y)
	times.sort()
	var longest := 0
	for c in _counters:
		longest = maxi(longest, c[1])
	var span := 0.0
	var shown := 0
	if _counters.size() > 1:
		span = (_counters.back()[0] - _counters[0][0]) / 1000.0
		shown = _counters.back()[2] - _counters[0][2]
	return "Frame p50 %.1f ms, max %.1f ms (%d s)\nLongest job step %.1f ms\nQueued chunks %d, shown %.1f/s\nNodes %d" % [
		times[times.size() / 2] / 1000.0 if not times.is_empty() else 0.0,
		times.back() / 1000.0 if not times.is_empty() else 0.0,
		WINDOW_MSEC / 1000,
		longest / 1000.0,
		queued,
		shown / span if span > 0.0 else 0.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)]
