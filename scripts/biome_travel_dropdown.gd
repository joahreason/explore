extends OptionButton

## "Go to biome" menu: picking a biome moves the camera to the nearest place
## of it, or to the next patch when already standing in one (see
## ChunkManager.travel_to_biome / BiomeFinder). Landmark structures follow
## the biomes, after a separator: picking one goes to the nearest site of
## it (StructureSites.find()), the next one on each repeat. The first item is a
## placeholder the menu returns to, so picking the same biome again hops on.
## Sits just below the view dropdown (which moves up on desktop - see
## reload_button.gd).

const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")
const StructureSitesScript := preload("res://scripts/structure_sites.gd")
const PLACEHOLDER := "Go to..."
const SPACING := 8

@onready var _world := get_node("../..")


func _ready() -> void:
	var views := get_node_or_null("../ViewModeDropdown") as Control
	if views:
		var height := offset_bottom - offset_top
		offset_top = views.offset_bottom + SPACING
		offset_bottom = offset_top + height
	add_item(PLACEHOLDER)
	for biome in BiomeClassifierScript.BIOME_COLORS:
		add_item(biome)
	add_separator()
	for def in StructureSitesScript.DEFINITIONS:
		add_item(def.display_name)
	item_selected.connect(_on_item_selected)
	_world.biome_travel_finished.connect(_on_travel_finished)


func _on_item_selected(index: int) -> void:
	if index == 0:
		return
	var biome := get_item_text(index)
	disabled = true
	_world.travel_to_biome(biome)
	if _world.is_finding_biome():
		text = "Finding %s..." % biome


func _on_travel_finished(biome: String, found: bool, cancelled: bool) -> void:
	disabled = false
	select(0)
	if not found and not cancelled:
		text = "No %s nearby" % biome
