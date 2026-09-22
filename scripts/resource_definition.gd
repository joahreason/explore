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
## custom curve type - a fresh Curve defaults to a 0..1 domain/range, which
## is the "0.0 unsuitable .. 1.0 highly suitable" convention the plan asks
## for throughout. Leaving a curve unassigned means "this factor doesn't
## constrain this resource" (ResourceManager, once it exists, should treat a
## null curve as neutral/1.0 rather than 0.0 - see Phase 3).

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

## Keyed by base_biome/subtype String, or WorldGen.Geology int - a resource
## with no entry for the tile's biome/subtype/geology is neither penalized
## nor favored by that factor (see the same null-is-neutral rule as curves
## above, applies identically here).
@export_group("Categorical Weights")
@export var biome_weights: Dictionary = {}
@export var subtype_weights: Dictionary = {}
@export var geology_weights: Dictionary = {}

@export_group("Special Affinities")
@export var river_affinity: float = 0.0
@export var shore_affinity: float = 0.0
@export var disturbance_affinity: float = 0.0

@export_group("Spatial")
@export var cluster_scale: float = 1.0
@export var cluster_strength: float = 0.0
@export var minimum_spacing: float = 1.0
@export var placement_type: String = ""
