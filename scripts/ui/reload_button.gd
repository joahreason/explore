extends Button

## Web export only: forces a fresh navigation instead of trusting whatever
## the browser already has loaded. Mainly for standalone "Add to Home
## Screen" apps on iOS, which can sit open for a long time without ever
## revalidating cached files on their own. Hidden outside Web (the seed
## field and Randomize regenerate in place there), and the view dropdown
## below moves up into its slot.
##
## Also carries whatever is in the seed field (sibling "SeedInput") through
## as a ?seed= query param, which ChunkManager reads on the next load.

const SeedReloadScript := preload("res://scripts/ui/seed_reload.gd")


func _ready() -> void:
	if not OS.has_feature("web"):
		visible = false
		var dropdown := get_node_or_null("../ViewModeDropdown") as Control
		if dropdown:
			var shift := dropdown.offset_top - offset_top
			dropdown.offset_top -= shift
			dropdown.offset_bottom -= shift
		return
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	SeedReloadScript.close_keyboard(self)
	var seed_input := get_node("../SeedInput") as LineEdit
	SeedReloadScript.reload_with_seed(seed_input.text if seed_input else "")
