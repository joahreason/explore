class_name ResourceDefinition
extends Resource

## Phase 2 of docs/resource-generation-plan.md: data-driven description of one
## placeable resource's environmental preferences (a tree species, an ore
## type, etc.) - no spawning logic lives here or anywhere else yet. Follows
## the same pattern as WorldGen (Resource + @export, tunable/saveable as a
## .tres in the Inspector), the project's existing precedent for a large
## configurable data object.
##
## Curves use Godot's built-in Curve resource (matches the plan's own
## "temperature_curve.sample(temperature)" language exactly) rather than a
## custom curve type. A curve's Y range should stay within the plan's
## "0.0 unsuitable .. 1.0 highly suitable" convention, but its X DOMAIN must
## be set (in the Inspector, via the curve's min_domain/max_domain) to match
## that field's actual natural range from docs/architecture.md §2 - most
## fields are already 0..1, but e.g. temperature and elevation are -1..1,
## and slope is a small unbounded-above magnitude (commonly ~0..0.05) rather
## than 0..1. ResourceManager.get_suitability() (Phase 3) passes each raw
## EnvironmentalState field straight into curve.sample() with no
## renormalization, relying on the curve's own configured domain - this
## keeps the combination formula generic instead of hardcoding per-field
## rescaling. Leaving a curve unassigned means "this factor doesn't
## constrain this resource" (ResourceManager treats a null curve as
## neutral/1.0, never 0.0 - see Phase 3).

@export var id: String
@export var category: String
## Peak density (0..1) this resource reaches on a perfectly suitable tile at
## full patch value - ResourceManager.get_density() (Phase 6) scales it by
## suitability and get_patch_modifier(). Lets a naturally sparse resource
## (e.g. a rare ore) stay sparse even where conditions are ideal.
@export_range(0.0, 1.0) var base_density: float = 1.0

@export_group("Suitability Curves")
@export var temperature_curve: Curve
@export var moisture_curve: Curve
@export var fertility_curve: Curve
@export var elevation_curve: Curve
@export var slope_curve: Curve
@export var drainage_curve: Curve
@export var erosion_curve: Curve
## Phase 10 water-edge inputs: WorldGen's `river` (0 away from a river, rising
## toward its line; >= river_threshold is the river itself), `shore_proximity`
## and `deposition` (sediment on concave ground - floodplains). Listing
## river_curve in required_curves confines a resource to river banks.
@export var river_curve: Curve
@export var shore_curve: Curve
@export var deposition_curve: Curve
## Names of the curves above (e.g. "temperature_curve") that form this
## resource's tolerance envelope: ResourceManager multiplies by the lowest of
## them instead of averaging them in with the rest, so falling outside any
## one means absent. Unlisted curves are preferences that shape abundance.
@export var required_curves: PackedStringArray = []

## Keyed by base_biome/subtype String, WorldGen.Geology int, or WorldGen's
## water_body String ("none"/"ocean"/"sea"/"lake"/"river"/"swamp") - a
## resource with no entry for the tile's biome/subtype/geology/water_body is
## neither penalized nor favored by that factor (see the same null-is-neutral
## rule as curves above, applies identically here).
##
## water_body_weights exists specifically so "is this tile actually water"
## is a per-resource DATA choice, not a hardcoded rule in ResourceManager -
## a land plant sets {"none": 1.0, "ocean": 0.0, "sea": 0.0, "lake": 0.0,
## "river": 0.0} so it can't score high while literally submerged (a real
## bug found via Phase 4's visual validation - elevation/moisture curves
## alone don't reliably exclude water, since e.g. a river can sit well above
## sea_level), while a Phase 10 river/shore plant sets the opposite weights.
@export_group("Categorical Weights")
@export var biome_weights: Dictionary = {}
@export var subtype_weights: Dictionary = {}
@export var geology_weights: Dictionary = {}
@export var water_body_weights: Dictionary = {}

@export_group("Special Affinities")
@export var river_affinity: float = 0.0
@export var shore_affinity: float = 0.0
@export var disturbance_affinity: float = 0.0

## cluster_scale/cluster_strength drive ResourceManager.get_patch_modifier()
## (Phase 5): cluster_scale is the approximate patch (grove/clearing) size in
## tiles, cluster_strength how strongly that patch noise modulates density -
## 0.0 disables it (uniform), 1.0 lets patches range from empty to full.
@export_group("Spatial")
@export var cluster_scale: float = 32.0
@export_range(0.0, 1.0) var cluster_strength: float = 0.0
## Optional reshaping of the 0..1 patch value, as ResourceGuild.cluster_curve:
## a steep curve turns patches into distinct areas with nothing between
## (Phase 9 ore districts).
@export var cluster_curve: Curve
@export var minimum_spacing: float = 1.0
@export var placement_type: String = ""
## Marker color in the placement debug views (and the Deposits view).
@export var debug_color: Color = Color(0.10, 0.32, 0.10)
## Phase 8 step 6: tile (column, row) in the one-bit Urizen sheet
## (urizen_onebit_tileset__v2d0.png, 12 px tiles) drawn for this resource in
## the Resources view; (-1, -1) = no sprite (a plain marker is drawn). The
## sheet's white pixels are tinted by sprite_color.
@export var sprite_tile: Vector2i = Vector2i(-1, -1)
@export var sprite_color: Color = Color(1, 1, 1)
## Drawn width in tiles. Whole multiples of 1 keep the 12 px art crisp.
@export var sprite_size: float = 1.0

## Phase 9 geological deposits: a definition with vein_scale > 0 is an ore
## body rather than a surface object. ResourceManager.get_deposit_potential()
## multiplies its suitability (geology_weights = geological affinity) by its
## own vein noise: ridged, so deposits form seams about vein_scale tiles
## apart, narrower the higher vein_sharpness - and by its patch noise
## (Spatial group), which confines those seams to ore districts instead of a
## map-wide lattice. That is where the ore EXISTS;
## whether it's visible at the surface is WorldGen's rock_exposure.
@export_group("Deposit")
@export var vein_scale: float = 0.0
@export var vein_sharpness: float = 4.0
## What makes the deposit visible (ResourceManager.get_exposure()): an
## EnvironmentalState field, optionally remapped by exposure_curve. Bedrock
## ores use rock_exposure (eroded ground, cliffs); clay (Phase 10) uses
## `river`, since river banks cut into floodplain clay beds.
@export var exposure_field: String = "rock_exposure"
@export var exposure_curve: Curve


## Real value range of the EnvironmentalState field each curve samples
## (docs/architecture.md §2). slope has no fixed upper bound, so only its
## lower end is checked (INF = unchecked).
const CURVE_FIELD_RANGES := {
	"temperature_curve": Vector2(-1.0, 1.0),
	"moisture_curve": Vector2(0.0, 1.0),
	"fertility_curve": Vector2(0.0, 1.0),
	"elevation_curve": Vector2(-1.0, 1.0),
	"slope_curve": Vector2(0.0, INF),
	"drainage_curve": Vector2(0.0, 1.0),
	"erosion_curve": Vector2(0.0, 1.0),
	"river_curve": Vector2(0.0, 1.0),
	"shore_curve": Vector2(0.0, 1.0),
	"deposition_curve": Vector2(0.0, 1.0),
}


## One message per curve whose domain doesn't cover its field's real range,
## plus any required_curves entry that isn't a real curve name (a typo there
## would otherwise silently leave that curve as a mere preference).
## Curve.sample() clamps out-of-domain input to the edge point's value, so a
## temperature curve left at the default 0..1 domain silently gives every
## sub-zero tile the same score - exactly how oak ended up densest in Tundra.
func get_curve_domain_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	for curve_name in CURVE_FIELD_RANGES:
		var curve: Curve = get(curve_name)
		if curve == null:
			continue
		var field_range: Vector2 = CURVE_FIELD_RANGES[curve_name]
		var covers_min := curve.min_domain <= field_range.x
		var covers_max := is_inf(field_range.y) or curve.max_domain >= field_range.y
		if not (covers_min and covers_max):
			warnings.append("ResourceDefinition '%s': %s domain [%s, %s] doesn't cover the field's range [%s, %s]" % [
				id, curve_name, curve.min_domain, curve.max_domain, field_range.x, field_range.y
			])
	if cluster_curve != null and (cluster_curve.min_domain > 0.0 or cluster_curve.max_domain < 1.0):
		warnings.append("ResourceDefinition '%s': cluster_curve domain [%s, %s] doesn't cover [0, 1]" % [
			id, cluster_curve.min_domain, cluster_curve.max_domain
		])
	if exposure_curve != null and (exposure_curve.min_domain > 0.0 or exposure_curve.max_domain < 1.0):
		warnings.append("ResourceDefinition '%s': exposure_curve domain [%s, %s] doesn't cover [0, 1]" % [
			id, exposure_curve.min_domain, exposure_curve.max_domain
		])
	for curve_name in required_curves:
		if not CURVE_FIELD_RANGES.has(curve_name):
			warnings.append("ResourceDefinition '%s': required_curves names unknown curve '%s'" % [id, curve_name])
	return warnings
