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
@export var base_density: float = 1.0

@export_group("Suitability Curves")
@export var temperature_curve: Curve
@export var moisture_curve: Curve
@export var fertility_curve: Curve
@export var elevation_curve: Curve
@export var slope_curve: Curve
@export var drainage_curve: Curve
@export var erosion_curve: Curve

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

@export_group("Spatial")
@export var cluster_scale: float = 1.0
@export var cluster_strength: float = 0.0
@export var minimum_spacing: float = 1.0
@export var placement_type: String = ""
