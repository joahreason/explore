extends Button

## Web export only: forces a fresh navigation instead of trusting whatever
## the browser already has loaded. Mainly for standalone "Add to Home
## Screen" apps on iOS, which can sit open for a long time without ever
## revalidating cached files on their own. No-op (hidden) outside Web.
##
## Also carries whatever is in the seed field (sibling "SeedInput") through
## as a ?seed= query param, which ChunkManager reads on the next load.


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	var seed_input := get_node("../SeedInput") as LineEdit
	var seed_text := seed_input.text.strip_edges() if seed_input else ""

	# Cache-busting query string forces the browser to treat this as a new
	# URL rather than reusing GitHub Pages' cached response.
	var query := "?v=" + str(Time.get_ticks_msec())
	if seed_text != "":
		query += "&seed=" + seed_text.uri_encode()

	var js := "location.href = location.pathname + '%s';" % query
	JavaScriptBridge.eval(js, true)
