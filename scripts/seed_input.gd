extends LineEdit

## Restricts input to letters, numbers, and spaces - anything else typed or
## pasted is silently stripped. Pressing Enter reloads immediately with
## whatever seed is currently typed (see SeedReload). ChunkManager sets this
## field's text to the seed actually in effect on load (see
## chunk_manager.gd's _seed_text), so it always reflects the current world.

const SeedReloadScript := preload("res://scripts/seed_reload.gd")

var _regex := RegEx.new()


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
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
	SeedReloadScript.reload_with_seed(new_text)
