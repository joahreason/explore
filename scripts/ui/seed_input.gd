extends LineEdit

## Restricts input to letters, numbers, and spaces - anything else typed or
## pasted is silently stripped. Pressing Enter applies whatever seed is
## currently typed (see SeedReload.apply_seed: a page reload on web, an
## in-place regenerate on desktop). ChunkManager sets this field's text to
## the seed actually in effect (see chunk_manager.gd's _seed_text), so it
## always reflects the current world.

const SeedReloadScript := preload("res://scripts/ui/seed_reload.gd")

var _regex := RegEx.new()


func _ready() -> void:
	_regex.compile("[^A-Za-z0-9 ]")
	text_changed.connect(_on_text_changed)
	text_submitted.connect(_on_text_submitted)


func _on_text_changed(new_text: String) -> void:
	var filtered := _regex.sub(new_text, "", true)
	if filtered == new_text:
		return
	var caret := caret_column
	text = filtered
	caret_column = mini(caret, filtered.length())


func _on_text_submitted(new_text: String) -> void:
	# Hand the keyboard back to the map (e.g. the B shortcut) on desktop,
	# where the page doesn't reload.
	release_focus()
	SeedReloadScript.apply_seed(get_node("../.."), new_text)
