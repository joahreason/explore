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
## factors (temperature/moisture/fertility/elevation/slope/drainage/erosion,
## plus river/shore/deposition/salinity since Phase 10, succession since
## Phase 11) not listed in required_curves, plus geology/water_body weights
## and the succession-gated disturbance_type weight, are combined via
## GEOMETRIC MEAN: still
## meaningfully penalizes a genuinely bad match (one factor at 0 still zeroes
## the result - a true requirement), without each additional so-so factor
## multiplicatively compounding the penalty the way straight multiplication
## would. Biome/subtype are separate WEIGHTED MODIFIERS multiplied in after
## the core mean. River/shore/disturbance affinities are ADDITIVE bonuses.
## This mixes multiplicative/weighted/additive per the plan's own guidance,
## while staying fully generic - no per-resource-type branching here.
##
## Plan Phase 3 amendment (2026-09-22): curves named in
## definition.required_curves are the resource's TOLERANCE ENVELOPE and are
## taken out of the mean - the lowest of them multiplies the result (the
## scarcest requirement limits growth), so being outside any one of them
## means absent instead of merely ~20% less, as a mean of ~6 factors gives.
## Biome weights are applied against the tile's normalized biome SCORES
## (membership), not its argmax label, so a strong biome preference still
## changes smoothly across a boundary instead of speckling where the label
## flickers tile to tile.
##
## An unset curve, or a weight map with no entry for the tile's actual
## biome/subtype/geology/water_body, means neutral (1.0) - "this resource has
## no opinion about this factor" - never 0.0 (see ResourceDefinition's doc
## comment for the same convention).

## FBM simplex output clusters around 0 and rarely reaches +/-1, which would
## leave "clearings" and "dense groves" too mild to read. Stretching it (then
## clamping) gives real empty/full patches; tuned visually in Phase 5.
const PATCH_CONTRAST := 1.8

## Biome membership = score^sharpness, normalized. Raw classifier scores are
## soft (Plains keeps a constant 0.2 floor on every land tile), so a plain
## linear share would blur every biome by its neighbors; the exponent keeps
## the leading biome dominant while staying continuous.
const BIOME_MEMBERSHIP_SHARPNESS := 4.0

## ResourceDefinition curve -> the EnvironmentalState field it samples.
const CURVE_STATE_FIELDS := {
	"temperature_curve": "temperature",
	"moisture_curve": "moisture",
	"fertility_curve": "soil_fertility",
	"elevation_curve": "elevation",
	"slope_curve": "slope",
	"drainage_curve": "drainage",
	"erosion_curve": "erosion",
	"river_curve": "river",
	"shore_curve": "shore_proximity",
	"deposition_curve": "deposition",
	"salinity_curve": "shore_salinity",
	"succession_curve": "succession",
}

static var _patch_noise_cache: Dictionary = {}
static var _vein_noise_cache: Dictionary = {}


static func get_suitability(
	state: EnvironmentalState, definition: ResourceDefinition, classified: Dictionary = {}
) -> float:
	var core_factors: Array[float] = []
	var requirement := 1.0
	for curve_name in CURVE_STATE_FIELDS:
		var curve: Curve = definition.get(curve_name)
		if curve == null:
			continue
		var factor := clampf(curve.sample(state.get(CURVE_STATE_FIELDS[curve_name])), 0.0, 1.0)
		if definition.required_curves.has(curve_name):
			requirement = minf(requirement, factor)
			if requirement <= 0.0:
				return 0.0
		else:
			core_factors.append(factor)
	if not definition.geology_weights.is_empty():
		var geology_factor: float = definition.geology_weights.get(state.geology, 1.0)
		core_factors.append(clampf(geology_factor, 0.0, 1.0))
	if not definition.water_body_weights.is_empty():
		var water_body_factor: float = definition.water_body_weights.get(state.water_body, 1.0)
		core_factors.append(clampf(water_body_factor, 0.0, 1.0))
	if not definition.disturbance_type_weights.is_empty():
		var type_weight: float = definition.disturbance_type_weights.get(state.disturbance_type, 1.0)
		core_factors.append(clampf(lerpf(1.0, type_weight, 1.0 - state.succession), 0.0, 1.0))

	var suitability := requirement * _geometric_mean(core_factors)

	if not classified.is_empty():
		if not definition.biome_weights.is_empty():
			suitability *= _biome_modifier(definition.biome_weights, classified)
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


## Membership-weighted biome modifier (see BIOME_MEMBERSHIP_SHARPNESS).
## Water/Beach tiles carry no scores - they are categorical facts decided
## upstream - so they fall back to the label's weight.
static func _biome_modifier(weights: Dictionary, classified: Dictionary) -> float:
	var scores: Dictionary = classified.get("scores", {})
	if scores.is_empty():
		return weights.get(classified.get("base_biome", ""), 1.0)
	var total := 0.0
	var weighted := 0.0
	for biome in scores:
		var membership := pow(maxf(scores[biome], 0.0), BIOME_MEMBERSHIP_SHARPNESS)
		total += membership
		weighted += membership * float(weights.get(biome, 1.0))
	return weighted / total if total > 0.0 else 1.0


## Geometric mean of the preference factors - see class doc for why
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
	return _patch_value(definition.id, definition.cluster_scale, definition.cluster_strength, world_seed, wx, wy, definition.cluster_curve)


## Guild counterpart of get_patch_modifier(): the guild's own patch noise,
## reshaped by guild.cluster_curve when set.
static func get_guild_patch_modifier(guild: ResourceGuild, world_seed: int, wx: int, wy: int) -> float:
	return _patch_value(guild.id, guild.cluster_scale, guild.cluster_strength, world_seed, wx, wy, guild.cluster_curve)


static func _patch_value(id: String, cluster_scale: float, cluster_strength: float, world_seed: int, wx: int, wy: int, cluster_curve: Curve = null) -> float:
	if cluster_strength <= 0.0:
		return 1.0
	var noise := _patch_noise(id, cluster_scale, world_seed)
	var patch := clampf(noise.get_noise_2d(wx, wy) * PATCH_CONTRAST * 0.5 + 0.5, 0.0, 1.0)
	if cluster_curve != null:
		patch = clampf(cluster_curve.sample(patch), 0.0, 1.0)
	return lerpf(1.0, patch, clampf(cluster_strength, 0.0, 1.0))


static func _patch_noise(id: String, cluster_scale: float, world_seed: int) -> FastNoiseLite:
	var scale := maxf(cluster_scale, 1.0)
	var key := "%d|%s|%f" % [world_seed, id, scale]
	if _patch_noise_cache.has(key):
		return _patch_noise_cache[key]
	var noise := FastNoiseLite.new()
	noise.seed = ("%d:%s" % [world_seed + WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET, id]).hash()
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


## Phase 8 amendment (guilds, see ResourceGuild): each member's
## get_suitability() at this tile, in guild.members order.
static func get_member_suitabilities(
	state: EnvironmentalState, guild: ResourceGuild, classified: Dictionary = {}
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for member in guild.members:
		result.append(get_suitability(state, member, classified))
	return result


## What each member competes with in a guild, in guild.members order: its
## get_suitability(), except for a deposit (vein_scale > 0), which scores its
## EXPOSED deposit (Phase 9 step 2: an ore outcrop only appears where ore
## exists and bedrock shows - or, for clay, where a river bank cuts into
## it). Unexposed tiles skip the deposit math entirely.
static func get_member_scores(
	state: EnvironmentalState, guild: ResourceGuild, world_seed: int, wx: int, wy: int, classified: Dictionary = {}
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for member in guild.members:
		if member.vein_scale <= 0.0:
			result.append(get_suitability(state, member, classified))
		elif get_exposure(state, member) <= 0.0:
			result.append(0.0)
		else:
			var potential := get_deposit_potential(state, member, world_seed, wx, wy, classified)
			result.append(get_exposed_deposit(potential, state, member))
	return result


## Each member's share of the guild's instances at a tile:
## s_i^sharpness / sum_j s_j^sharpness. All zeros where no member can live.
static func get_species_shares(suitabilities: PackedFloat32Array, sharpness: float) -> PackedFloat32Array:
	var shares := PackedFloat32Array()
	var total := 0.0
	for s in suitabilities:
		var w := pow(maxf(s, 0.0), maxf(sharpness, 0.0)) if s > 0.0 else 0.0
		shares.append(w)
		total += w
	if total > 0.0:
		for i in shares.size():
			shares[i] /= total
	return shares


## Guild counterpart of get_density(): cover(cover_field) * base_density *
## the guild's patch noise * the best member's score (get_member_scores():
## suitability, or exposed deposit for ores). An empty cover_field means full
## cover (the members' scores alone decide). guild.density_curve, if set,
## reshapes the result. The environment sets how much can grow; the
## best-member cap keeps the guild off tiles none of its members tolerate
## (and thins it toward every member's limits) without letting the member
## mix change the total.
static func get_guild_density(
	state: EnvironmentalState, guild: ResourceGuild, world_seed: int, wx: int, wy: int, classified: Dictionary = {}
) -> float:
	var field := 1.0 if guild.cover_field == "" else clampf(float(state.get(guild.cover_field)), 0.0, 1.0)
	var cover := clampf(guild.cover_curve.sample(field), 0.0, 1.0) if guild.cover_curve != null else field
	var patch := get_guild_patch_modifier(guild, world_seed, wx, wy)
	# Cheap factors first: member suitabilities are the costly part, and most
	# tiles have no cover for guilds like wetland plants (dry ground).
	if cover <= 0.0 or patch <= 0.0:
		return 0.0
	var best := 0.0
	for s in get_member_scores(state, guild, world_seed, wx, wy, classified):
		best = maxf(best, s)
	if best <= 0.0:
		return 0.0
	var density := clampf(cover * clampf(guild.base_density, 0.0, 1.0) * patch * best, 0.0, 1.0)
	if guild.density_curve != null:
		density = clampf(guild.density_curve.sample(density), 0.0, 1.0)
	return density


## Phase 9 of docs/resource-generation-plan.md: how much of an ore deposit
## EXISTS here, exposed or not - geological affinity (get_suitability(),
## chiefly geology_weights) x the ore's own vein noise x its patch noise
## (the ore district) x base_density, 0..1. Zero for a definition that isn't
## a deposit (vein_scale <= 0).
static func get_deposit_potential(
	state: EnvironmentalState,
	definition: ResourceDefinition,
	world_seed: int,
	wx: int,
	wy: int,
	classified: Dictionary = {}
) -> float:
	if definition.vein_scale <= 0.0:
		return 0.0
	var suitability := get_suitability(state, definition, classified)
	if suitability <= 0.0:
		return 0.0
	var district := get_patch_modifier(definition, world_seed, wx, wy)
	if district <= 0.0:
		return 0.0
	var vein := get_vein_value(definition, world_seed, wx, wy)
	return clampf(suitability * district * vein * clampf(definition.base_density, 0.0, 1.0), 0.0, 1.0)


## The part of get_deposit_potential() visible at the surface: potential x
## the deposit's exposure at the tile (get_exposure(); rock_exposure when no
## definition is given). The rest is hidden - "resource exists" and
## "resource is exposed" stay separate fields.
static func get_exposed_deposit(potential: float, state: EnvironmentalState, definition: ResourceDefinition = null) -> float:
	var exposure := get_exposure(state, definition) if definition != null else state.rock_exposure
	return clampf(potential * exposure, 0.0, 1.0)


## 0..1: how much of a deposit shows at this tile - its exposure_field
## (rock_exposure for bedrock ores), through exposure_curve if set.
static func get_exposure(state: EnvironmentalState, definition: ResourceDefinition) -> float:
	var field := clampf(float(state.get(definition.exposure_field)), 0.0, 1.0)
	if definition.exposure_curve != null:
		return clampf(definition.exposure_curve.sample(field), 0.0, 1.0)
	return field


## Ridged vein noise, pow(1 - |n|, vein_sharpness): 1 along a seam's center
## line, falling off to either side. Each deposit id gets its own field
## (seeded from world_seed + WorldGen.DEPOSIT_VEIN_SEED_OFFSET and the id,
## like get_patch_modifier()), so different ores don't share seams.
static func get_vein_value(definition: ResourceDefinition, world_seed: int, wx: int, wy: int) -> float:
	var noise := _vein_noise(definition.id, definition.vein_scale, world_seed)
	var n := clampf(noise.get_noise_2d(wx, wy), -1.0, 1.0)
	return pow(1.0 - absf(n), maxf(definition.vein_sharpness, 0.0))


static func _vein_noise(id: String, vein_scale: float, world_seed: int) -> FastNoiseLite:
	var scale := maxf(vein_scale, 1.0)
	var key := "%d|%s|%f" % [world_seed, id, scale]
	if _vein_noise_cache.has(key):
		return _vein_noise_cache[key]
	var noise := FastNoiseLite.new()
	noise.seed = ("%d:%s" % [world_seed + WorldGen.DEPOSIT_VEIN_SEED_OFFSET, id]).hash()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 1.0 / scale
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	_vein_noise_cache[key] = noise
	return noise
