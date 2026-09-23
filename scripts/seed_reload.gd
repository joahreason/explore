class_name SeedReload
extends RefCounted

## Shared by ReloadButton, RandomizeButton, and SeedInput's Enter/submit.
## On web all three do the same thing: force a fresh page navigation
## carrying the given seed as a ?seed= query param, which ChunkManager reads
## on the next load (see chunk_manager.gd's _resolve_world_seed). On desktop
## RandomizeButton and SeedInput regenerate the world in place instead (see
## apply_seed); ReloadButton is web-only.


## A seed from the seed UI: on web, reload_with_seed(); elsewhere, regenerate
## the world in place. world: the ChunkManager (World) node.
static func apply_seed(world: Node, seed_text: String) -> void:
	if OS.has_feature("web"):
		reload_with_seed(seed_text)
	else:
		world.regenerate(seed_text)


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
