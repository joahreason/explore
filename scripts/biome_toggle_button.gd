extends Button

## Calls the same toggle the "B" key already triggers on ChunkManager
## (this button's grandparent: World/UI/BiomeButton -> World).


func _ready() -> void:
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	get_node("../..").toggle_biome_overlay()
