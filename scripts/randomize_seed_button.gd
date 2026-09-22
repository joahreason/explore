extends Button

## Fills the seed field with a fresh random seed and reloads immediately
## with it - no separate Reload press needed.

const SeedReloadScript := preload("res://scripts/seed_reload.gd")


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		return
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	var new_seed := str(randi())
	var seed_input := get_node("../SeedInput") as LineEdit
	if seed_input:
		seed_input.text = new_seed
	SeedReloadScript.reload_with_seed(new_seed)
