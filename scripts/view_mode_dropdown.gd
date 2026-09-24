extends OptionButton

## Lists every ChunkManager.ViewMode; selecting one calls set_view_mode() on
## the World node (grandparent: World/UI/ViewModeDropdown -> World). The first item
## is the default view (ChunkManager._view_mode: World = terrain + every
## placed resource, Phase 13.5), since the dropdown starts on it.

const ChunkManagerScript := preload("res://scripts/chunk_manager.gd")

## Base Biome is deliberately left out of this list for now - it's still
## reachable via the "B" keyboard shortcut (see ChunkManager.toggle_biome_overlay),
## but click-to-inspect (see tile_inspector_panel.gd) now covers per-tile biome
## info without needing a dedicated full-map overlay view. The per-resource
## debug views (Oak Suitability/Density/Placement, Tree Cover, Tree/Rock/Berry/
## Wetland Placement) are left out too: Resources shows every placed object, and
## clicking one names it in the inspector. They still exist in ChunkManager
## (tests use them) for re-adding here while tuning a resource.
const ITEMS := [
	{"label": "World", "mode": ChunkManagerScript.ViewMode.RESOURCES},
	{"label": "Terrain Only", "mode": ChunkManagerScript.ViewMode.MATERIAL},
	{"label": "Deposits", "mode": ChunkManagerScript.ViewMode.DEPOSITS},
	{"label": "Quality", "mode": ChunkManagerScript.ViewMode.QUALITY},
	{"label": "Debug: Suitability", "mode": ChunkManagerScript.ViewMode.DEBUG_SUITABILITY},
	{"label": "Debug: Density", "mode": ChunkManagerScript.ViewMode.DEBUG_DENSITY},
	{"label": "Debug: Patch Noise", "mode": ChunkManagerScript.ViewMode.DEBUG_PATCH},
	{"label": "Debug: Placement", "mode": ChunkManagerScript.ViewMode.DEBUG_PLACEMENT},
	{"label": "Farming Potential", "mode": ChunkManagerScript.ViewMode.FARMING_POTENTIAL},
	{"label": "Subtype", "mode": ChunkManagerScript.ViewMode.SUBTYPE},
	{"label": "Modifiers", "mode": ChunkManagerScript.ViewMode.MODIFIERS},
	{"label": "Temperature", "mode": ChunkManagerScript.ViewMode.TEMPERATURE},
	{"label": "Moisture", "mode": ChunkManagerScript.ViewMode.MOISTURE},
	{"label": "Temp Variation", "mode": ChunkManagerScript.ViewMode.TEMP_VARIATION},
	{"label": "Precip Seasonality", "mode": ChunkManagerScript.ViewMode.PRECIP_SEASONALITY},
	{"label": "Drainage", "mode": ChunkManagerScript.ViewMode.DRAINAGE},
	{"label": "Disturbance Age", "mode": ChunkManagerScript.ViewMode.DISTURBANCE_AGE},
	{"label": "Disturbance Type", "mode": ChunkManagerScript.ViewMode.DISTURBANCE_TYPE},
	{"label": "Succession", "mode": ChunkManagerScript.ViewMode.SUCCESSION},
	{"label": "Shade", "mode": ChunkManagerScript.ViewMode.SHADE},
	{"label": "Fuel Load", "mode": ChunkManagerScript.ViewMode.FUEL_LOAD},
	{"label": "Fire Risk", "mode": ChunkManagerScript.ViewMode.FIRE_RISK},
	{"label": "Cave Potential", "mode": ChunkManagerScript.ViewMode.CAVE_POTENTIAL},
	{"label": "Cliff Tendency", "mode": ChunkManagerScript.ViewMode.CLIFF_TENDENCY},
	{"label": "Rock Exposure", "mode": ChunkManagerScript.ViewMode.ROCK_EXPOSURE},
]


func _ready() -> void:
	for item in ITEMS:
		add_item(item["label"])
	item_selected.connect(_on_item_selected)


func _on_item_selected(index: int) -> void:
	var world := get_node("../..")
	world.set_view_mode(ITEMS[index]["mode"])
