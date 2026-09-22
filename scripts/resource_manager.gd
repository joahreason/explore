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
