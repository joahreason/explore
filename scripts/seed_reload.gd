class_name SeedReload
extends RefCounted

## Shared by ReloadButton, RandomizeButton, and SeedInput's Enter/submit.
## On web all three do the same thing: force a fresh page navigation
## carrying the given seed as a ?seed= query param, which ChunkManager reads
## on the next load (see chunk_manager.gd's _resolve_world_seed). On desktop
## RandomizeButton and SeedInput regenerate the world in place instead (see
## apply_seed); ReloadButton is web-only.
##
## Mobile web: the seed field opens the on-screen keyboard (export preset
## html/experimental_virtual_keyboard); every seed action closes it again
## (close_keyboard), as does a tap on the map (camera_rig.gd).


## Drops keyboard focus from the seed field (or any Control) and hides the
## on-screen keyboard - after a seed is applied, or when the map is tapped.
## node: any node in the scene (for its viewport).
static func close_keyboard(node: Node) -> void:
	var viewport := node.get_viewport()
	if viewport != null and viewport.gui_get_focus_owner() != null:
		viewport.gui_release_focus()
	DisplayServer.virtual_keyboard_hide()


## A seed from the seed UI: on web, reload_with_seed(); elsewhere, regenerate
## the world in place. world: the ChunkManager (World) node.
static func apply_seed(world: Node, seed_text: String) -> void:
	close_keyboard(world)
	if OS.has_feature("web"):
		reload_with_seed(seed_text)
	else:
		world.regenerate(seed_text)


static func reload_with_seed(seed_text: String) -> void:
	if not OS.has_feature("web"):
		return
	DisplayServer.virtual_keyboard_hide()

	# Cache-busting query string forces the browser to treat this as a new
	# URL rather than reusing GitHub Pages' cached response.
	var query := "?v=" + str(Time.get_ticks_msec())
	var trimmed := seed_text.strip_edges()
	if trimmed != "":
		query += "&seed=" + trimmed.uri_encode()

	var js := "location.href = location.pathname + '%s';" % query
	JavaScriptBridge.eval(js, true)
