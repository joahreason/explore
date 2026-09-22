class_name SeedReload
extends RefCounted

## Shared by ReloadButton, RandomizeButton, and SeedInput's Enter/submit -
## all three ultimately do the same thing: force a fresh page navigation
## carrying the given seed as a ?seed= query param, which ChunkManager reads
## on the next load (see chunk_manager.gd's _resolve_world_seed). Web only -
## a no-op elsewhere, since the whole seed UI is hidden outside Web anyway.


static func reload_with_seed(seed_text: String) -> void:
	if not OS.has_feature("web"):
		return

	# Cache-busting query string forces the browser to treat this as a new
	# URL rather than reusing GitHub Pages' cached response.
	var query := "?v=" + str(Time.get_ticks_msec())
	var trimmed := seed_text.strip_edges()
	if trimmed != "":
		query += "&seed=" + trimmed.uri_encode()

	var js := "location.href = location.pathname + '%s';" % query
	JavaScriptBridge.eval(js, true)
