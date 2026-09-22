extends LineEdit

## Restricts input to letters, numbers, and spaces - anything else typed or
## pasted is silently stripped.

var _regex := RegEx.new()


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
	_regex.compile("[^A-Za-z0-9 ]")
	text_changed.connect(_on_text_changed)


func _on_text_changed(new_text: String) -> void:
	var filtered := _regex.sub(new_text, "", true)
	if filtered == new_text:
		return
	var caret := caret_column
	text = filtered
	caret_column = mini(caret, filtered.length())
