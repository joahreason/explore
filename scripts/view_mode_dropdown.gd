extends OptionButton

## Lists every ChunkManager.ViewMode; selecting one calls set_view_mode() on
## the World node (grandparent: World/UI/ViewModeDropdown -> World).

const ChunkManagerScript := preload("res://scripts/chunk_manager.gd")

## Base Biome is deliberately left out of this list for now - it's still
## reachable via the "B" keyboard shortcut (see ChunkManager.toggle_biome_overlay),
## but click-to-inspect (see tile_inspector_panel.gd) now covers per-tile biome
## info without needing a dedicated full-map overlay view.
const ITEMS := [
	{"label": "Material", "mode": ChunkManagerScript.ViewMode.MATERIAL},
	{"label": "Subtype", "mode": ChunkManagerScript.ViewMode.SUBTYPE},
	{"label": "Modifiers", "mode": ChunkManagerScript.ViewMode.MODIFIERS},
	{"label": "Temperature", "mode": ChunkManagerScript.ViewMode.TEMPERATURE},
	{"label": "Moisture", "mode": ChunkManagerScript.ViewMode.MOISTURE},
	{"label": "Temp Variation", "mode": ChunkManagerScript.ViewMode.TEMP_VARIATION},
	{"label": "Precip Seasonality", "mode": ChunkManagerScript.ViewMode.PRECIP_SEASONALITY},
	{"label": "Drainage", "mode": ChunkManagerScript.ViewMode.DRAINAGE},
	{"label": "Disturbance Age", "mode": ChunkManagerScript.ViewMode.DISTURBANCE_AGE},
	{"label": "Disturbance Type", "mode": ChunkManagerScript.ViewMode.DISTURBANCE_TYPE},
	{"label": "Fuel Load", "mode": ChunkManagerScript.ViewMode.FUEL_LOAD},
	{"label": "Fire Risk", "mode": ChunkManagerScript.ViewMode.FIRE_RISK},
	{"label": "Cave Potential", "mode": ChunkManagerScript.ViewMode.CAVE_POTENTIAL},
	{"label": "Cliff Tendency", "mode": ChunkManagerScript.ViewMode.CLIFF_TENDENCY},
	{"label": "Oak Suitability", "mode": ChunkManagerScript.ViewMode.RESOURCE_SUITABILITY_OAK},
	{"label": "Oak Density", "mode": ChunkManagerScript.ViewMode.RESOURCE_DENSITY_OAK},
	{"label": "Oak Placement", "mode": ChunkManagerScript.ViewMode.RESOURCE_PLACEMENT_OAK},
]


func _ready() -> void:
	for item in ITEMS:
		add_item(item["label"])
	item_selected.connect(_on_item_selected)


func _on_item_selected(index: int) -> void:
	var world := get_node("../..")
	world.set_view_mode(ITEMS[index]["mode"])
