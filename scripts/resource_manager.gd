class_name ResourceManager
extends RefCounted

## Phase 3 of docs/resource-generation-plan.md: habitat suitability.
## get_suitability() combines a ResourceDefinition's curves/weights against
## one tile's EnvironmentalState (+ an optional BiomeClassifier.classify_full()
## result, for biome/subtype weighting) into a single 0..1 score. Consumes
## already-computed fields only - never recomputes anything WorldGen.sample()
## already provides (plan Rule 2).
##
## Deliberately NOT a blind product of every factor - the plan warns this
## makes a single weak factor crater every resource's score. Curve-based
## "requirement" factors (temperature/moisture/fertility/elevation/slope/
## drainage/erosion), plus geology/water_body weights, are combined via
## GEOMETRIC MEAN: still
## meaningfully penalizes a genuinely bad match (one factor at 0 still zeroes
## the result - a true requirement), without each additional so-so factor
## multiplicatively compounding the penalty the way straight multiplication
## would. Biome/subtype are separate WEIGHTED MODIFIERS multiplied in after
## the core mean. River/shore/disturbance affinities are ADDITIVE bonuses.
## This mixes multiplicative/weighted/additive per the plan's own guidance,
## while staying fully generic - no per-resource-type branching here.
##
## An unset curve, or a weight map with no entry for the tile's actual
## biome/subtype/geology/water_body, means neutral (1.0) - "this resource has
## no opinion about this factor" - never 0.0 (see ResourceDefinition's doc
## comment for the same convention).

## FBM simplex output clusters around 0 and rarely reaches +/-1, which would
## leave "clearings" and "dense groves" too mild to read. Stretching it (then
## clamping) gives real empty/full patches; tuned visually in Phase 5.
const PATCH_CONTRAST := 1.8

static var _patch_noise_cache: Dictionary = {}


static func get_suitability(
	state: EnvironmentalState, definition: ResourceDefinition, classified: Dictionary = {}
) -> float:
	var core_factors: Array[float] = []
	_add_curve_factor(core_factors, definition.temperature_curve, state.temperature)
	_add_curve_factor(core_factors, definition.moisture_curve, state.moisture)
	_add_curve_factor(core_factors, definition.fertility_curve, state.soil_fertility)
	_add_curve_factor(core_factors, definition.elevation_curve, state.elevation)
	_add_curve_factor(core_factors, definition.slope_curve, state.slope)
	_add_curve_factor(core_factors, definition.drainage_curve, state.drainage)
	_add_curve_factor(core_factors, definition.erosion_curve, state.erosion)
	if not definition.geology_weights.is_empty():
		var geology_factor: float = definition.geology_weights.get(state.geology, 1.0)
		core_factors.append(clampf(geology_factor, 0.0, 1.0))
	if not definition.water_body_weights.is_empty():
		var water_body_factor: float = definition.water_body_weights.get(state.water_body, 1.0)
		core_factors.append(clampf(water_body_factor, 0.0, 1.0))

	var suitability := _geometric_mean(core_factors)

	if not classified.is_empty():
		if not definition.biome_weights.is_empty():
			var biome_modifier: float = definition.biome_weights.get(classified.get("base_biome", ""), 1.0)
			suitability *= biome_modifier
		if not definition.subtype_weights.is_empty():
			var subtype_modifier: float = definition.subtype_weights.get(classified.get("subtype", ""), 1.0)
			suitability *= subtype_modifier

	# A zeroed true requirement (e.g. water_body weight 0.0 on a river tile)
	# must stay excluded - otherwise oak's small positive river_affinity
	# re-adds ~0.1 right on the river it was just excluded from, which
	# Phase 7 placement turned into trees standing in rivers.
	if suitability <= 0.0:
		return 0.0

	suitability += definition.river_affinity * state.river
	suitability += definition.shore_affinity * state.shore_proximity
	suitability += definition.disturbance_affinity * state.disturbance

	return clampf(suitability, 0.0, 1.0)


static func _add_curve_factor(factors: Array[float], curve: Curve, value: float) -> void:
	if curve != null:
		factors.append(clampf(curve.sample(value), 0.0, 1.0))


## Geometric mean of the "true requirement" factors - see class doc for why
## this instead of a straight product. Empty input (a resource with no
## curves/geology preference at all) means "no requirements defined",
## neutral 1.0, consistent with the null-curve convention.
static func _geometric_mean(values: Array[float]) -> float:
	if values.is_empty():
		return 1.0
	var product := 1.0
	for v in values:
		product *= maxf(v, 0.0)
	return pow(product, 1.0 / values.size())


## Phase 5 of docs/resource-generation-plan.md: deterministic per-resource
## distribution/patch noise, so a uniformly suitable area still reads as
## groves/sparse woodland/clearings rather than flat density. Returns a 0..1
## multiplier meant to be applied ON TOP of get_suitability() (Phase 6's
## density = suitability * base_density * patch_modifier) - it never replaces
## suitability, so an unsuitable tile stays unsuitable however high its patch
## value is.
##
## Each resource gets its OWN noise field, seeded from world_seed +
## WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET mixed with definition.id, so
## different resources are decorrelated while the same seed/id/coordinate is
## always identical. definition.id must therefore be unique per resource.
## cluster_scale sets the patch size (tiles), cluster_strength how much the
## patch noise modulates density (0 = uniform 1.0, 1 = full 0..1 range).
static func get_patch_modifier(definition: ResourceDefinition, world_seed: int, wx: int, wy: int) -> float:
	if definition.cluster_strength <= 0.0:
		return 1.0
	var noise := _patch_noise(definition, world_seed)
	var patch := clampf(noise.get_noise_2d(wx, wy) * PATCH_CONTRAST * 0.5 + 0.5, 0.0, 1.0)
	return lerpf(1.0, patch, clampf(definition.cluster_strength, 0.0, 1.0))


static func _patch_noise(definition: ResourceDefinition, world_seed: int) -> FastNoiseLite:
	var scale := maxf(definition.cluster_scale, 1.0)
	var key := "%d|%s|%f" % [world_seed, definition.id, scale]
	if _patch_noise_cache.has(key):
		return _patch_noise_cache[key]
	var noise := FastNoiseLite.new()
	noise.seed = ("%d:%s" % [world_seed + WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET, definition.id]).hash()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / scale
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	_patch_noise_cache[key] = noise
	return noise


## Phase 6 of docs/resource-generation-plan.md: "how much of this resource
## should exist here?", as opposed to get_suitability()'s "would it like this
## environment?". density = suitability * base_density * patch_modifier,
## clamped to [0,1] - a 0..1 fraction of the resource's peak density, which
## Phase 7 placement will interpret. Each term only ever scales the others
## down, so density <= suitability always holds: patch noise can thin out a
## good area but never make an unsuitable tile dense.
static func get_density(
	state: EnvironmentalState,
	definition: ResourceDefinition,
	world_seed: int,
	wx: int,
	wy: int,
	classified: Dictionary = {}
) -> float:
	var suitability := get_suitability(state, definition, classified)
	if suitability <= 0.0:
		return 0.0
	var base_density := clampf(definition.base_density, 0.0, 1.0)
	var patch := get_patch_modifier(definition, world_seed, wx, wy)
	return clampf(suitability * base_density * patch, 0.0, 1.0)
