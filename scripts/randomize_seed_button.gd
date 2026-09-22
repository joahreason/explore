extends Button

## Fills the seed field with a fresh random seed - press Reload afterward to
## actually apply it (this just populates the text, it doesn't reload).


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	var seed_input := get_node("../SeedInput") as LineEdit
	if seed_input:
		seed_input.text = str(randi())
