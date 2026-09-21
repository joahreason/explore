extends Button

## Web export only: forces a fresh navigation instead of trusting whatever
## the browser already has loaded. Mainly for standalone "Add to Home
## Screen" apps on iOS, which can sit open for a long time without ever
## revalidating cached files on their own. No-op (hidden) outside Web.


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	# A cache-busting query string forces the browser to treat this as a
	# new URL rather than reusing GitHub Pages' cached response.
	JavaScriptBridge.eval(
		"location.href = location.pathname + '?v=' + Date.now();",
		true
	)
