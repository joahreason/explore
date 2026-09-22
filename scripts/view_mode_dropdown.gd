extends OptionButton

## Lists every ChunkManager.ViewMode; selecting one calls set_view_mode() on
## the World node (grandparent: World/UI/ViewModeDropdown -> World).

const ChunkManagerScript := preload("res://scripts/chunk_manager.gd")

const ITEMS := [
	{"label": "Material", "mode": ChunkManagerScript.ViewMode.MATERIAL},
	{"label": "Base Biome", "mode": ChunkManagerScript.ViewMode.BASE_BIOME},
	{"label": "Temperature", "mode": ChunkManagerScript.ViewMode.TEMPERATURE},
	{"label": "Moisture", "mode": ChunkManagerScript.ViewMode.MOISTURE},
	{"label": "Temp Variation", "mode": ChunkManagerScript.ViewMode.TEMP_VARIATION},
	{"label": "Precip Seasonality", "mode": ChunkManagerScript.ViewMode.PRECIP_SEASONALITY},
	{"label": "Drainage", "mode": ChunkManagerScript.ViewMode.DRAINAGE},
]


func _ready() -> void:
	for item in ITEMS:
		add_item(item["label"])
	item_selected.connect(_on_item_selected)


func _on_item_selected(index: int) -> void:
	var world := get_node("../..")
	world.set_view_mode(ITEMS[index]["mode"])
