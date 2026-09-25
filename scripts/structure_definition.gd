class_name StructureDefinition
extends "res://scripts/resource_definition.gd"

## Landmark layer: one kind of rare, discrete site (an abandoned camp,
## standing stones, ruins; later natural features). WHERE it can stand is the
## inherited suitability data - curves, required curves, water_body weights -
## evaluated at the site's centre tile by the same
## ResourceManager.get_suitability() as every resource, without biome weights
## (plan Rules 2, 3 and 6: the environment decides, not the biome label).
## StructureSites turns that into sites; this file only describes them.

@export_group("Site")
@export var display_name: String = ""
## Chance that a site cell whose centre suits this structure (suitability 1)
## gets one; scaled by the suitability. Several structures suiting one cell
## share it (StructureSites.pick_type()).
@export_range(0.0, 1.0) var frequency: float = 0.1
## Suitability below this places nothing, however lucky the roll.
@export_range(0.0, 1.0) var min_suitability: float = 0.35
## Footprint: every tile within this many tiles of the centre. Resource
## placement skips it (StructureSites.is_masked()), and every stamp part
## must lie inside it.
@export var radius: int = 3
## > 0: open water (ocean, sea, lake or river - not swamp) must lie within
## this many tiles of the centre, found by probing rays around it. Checked
## after the type roll picks this structure: no water, no site in that cell
## (so frequency is tuned with this veto included).
@export var water_within: int = 0
## A site's age is drawn uniformly from this range (0 fresh .. 1 ancient).
@export var age_range: Vector2 = Vector2(0.0, 1.0)

@export_group("Stamp")
## The tile stamp around the centre, one Dictionary per part:
##   "at": Vector2i offset from the centre (rotated with the site),
##   "tile": Vector2i tile in the one-bit Urizen sheet,
##   "kind": String, the key into kind_colors and what the inspector names,
##   "chance": float, optional, the share of sites that have this part (1),
##   "decay": float, optional, how readily age removes it (0 = never).
## A part survives when its chance roll passes and its decay roll is at or
## above age x decay - so old sites lose walls, not their campfire ring.
@export var parts: Array[Dictionary] = []
## kind -> sprite tint.
@export var kind_colors: Dictionary = {}
## Plants growing through: at age 1 and vegetation 1, this share of the
## footprint's free tiles grows one of overgrowth_tiles; it scales with age
## and with the centre's vegetation (overgrowth_vegetation_weight = how much
## vegetation matters, 0 = not at all).
@export_range(0.0, 1.0) var overgrowth: float = 0.0
@export_range(0.0, 1.0) var overgrowth_vegetation_weight: float = 1.0
@export var overgrowth_tiles: Array[Vector2i] = []
@export var overgrowth_color: Color = Color(0.35, 0.6, 0.25)


func get_curve_domain_warnings() -> PackedStringArray:
	var warnings := super.get_curve_domain_warnings()
	for part in parts:
		var at: Vector2i = part.get("at", Vector2i.ZERO)
		if at.x * at.x + at.y * at.y > radius * radius:
			warnings.append("StructureDefinition '%s': part at %s lies outside radius %d" % [id, at, radius])
		if not kind_colors.has(part.get("kind", "")):
			warnings.append("StructureDefinition '%s': part kind '%s' has no colour" % [id, part.get("kind", "")])
	return warnings
