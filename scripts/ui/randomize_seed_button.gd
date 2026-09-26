extends Button

## Fills the seed field with a fresh random seed and applies it immediately
## (see SeedReload.apply_seed: a page reload on web, an in-place regenerate
## on desktop) - no separate Reload press needed.

const SeedReloadScript := preload("res://scripts/ui/seed_reload.gd")


func _ready() -> void:
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	var new_seed := str(randi())
	var seed_input := get_node("../SeedInput") as LineEdit
	if seed_input:
		seed_input.text = new_seed
	SeedReloadScript.apply_seed(get_node("../.."), new_seed)
