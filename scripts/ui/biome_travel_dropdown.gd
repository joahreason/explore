extends OptionButton

## "Go to biome" menu: picking a biome moves the camera to the nearest place
## of it, or to the next patch when already standing in one (see
## ChunkManager.travel_to_biome / BiomeFinder). Landmark structures follow
## the biomes, after a separator: picking one goes to the nearest site of
## it (StructureSites.find()), the next one on each repeat. The first item is a
## placeholder the menu returns to, so picking the same biome again hops on.
## While a search runs the menu shows it, and the first item cancels it.
## Sits just below the view dropdown in the menu.

const BiomeClassifierScript := preload("res://scripts/gen/biome_classifier.gd")
const StructureSitesScript := preload("res://scripts/gen/structure_sites.gd")
const PLACEHOLDER := "Go to..."
const CANCEL := "Cancel search"

@onready var _world := get_node("../../..")


func _ready() -> void:
	add_item(PLACEHOLDER)
	for biome in BiomeClassifierScript.BIOME_COLORS:
		add_item(biome)
	add_separator()
	for def in StructureSitesScript.CONTENT.structures:
		add_item(def.display_name)
	item_selected.connect(_on_item_selected)
	_world.biome_travel_finished.connect(_on_travel_finished)


func _on_item_selected(index: int) -> void:
	if _world.is_finding_biome():
		_world.cancel_biome_travel()  # any pick while searching cancels
		return
	if index == 0:
		return
	var biome := get_item_text(index)
	_world.travel_to_biome(biome)
	if _world.is_finding_biome():
		set_item_text(0, CANCEL)
		text = "Finding %s..." % biome


func _on_travel_finished(biome: String, found: bool, cancelled: bool) -> void:
	set_item_text(0, PLACEHOLDER)
	select(0)
	if not found and not cancelled:
		text = "No %s nearby" % biome
