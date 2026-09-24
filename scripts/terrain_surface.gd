class_name TerrainSurface
extends RefCounted

## Phase 13.5 terrain surface layer: which ground a tile shows (one discrete
## SurfaceMaterial per land tile) and its colour. Replaces the old averaged
## Material blend, which made large areas one uniform, biome-coloured tone.
##
## Choice: every material scores suitability (ResourceManager.get_suitability
## over the tile's EnvironmentalState, x its base_density prevalence) times
## its own patch noise (cluster_scale / cluster_strength, seeded from
## world_seed + WorldGen.SURFACE_PATCH_SEED_OFFSET and the material id); the
## highest score wins. Suitability says what the ground COULD be, the patch
## noise which candidate wins here - so ground forms organic patches (dirt
## in a grassland, mud and pools in a swamp) that follow the fields, with no
## per-biome rules. Pure function of (seed, tile, the tile's state incl. its
## shade) - see lattice_shade() for the shade input.
##
## Water bodies (ocean, sea, lake, river) keep their depth/ice colouring;
## swamp tiles are ground, chosen like any land (marsh pools, mud, grass...).

const ResourceManagerScript := preload("res://scripts/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resource_placement.gd")

## In priority order for exact ties (practically never); dirt is the
## fallback when nothing scores.
const MATERIALS := [
	preload("res://resources/terrain/grass.tres"),
	preload("res://resources/terrain/dry_grass.tres"),
	preload("res://resources/terrain/dirt.tres"),
	preload("res://resources/terrain/forest_floor.tres"),
	preload("res://resources/terrain/mud.tres"),
	preload("res://resources/terrain/marsh.tres"),
	preload("res://resources/terrain/sand.tres"),
	preload("res://resources/terrain/beach_sand.tres"),
	preload("res://resources/terrain/gravel.tres"),
	preload("res://resources/terrain/rock.tres"),
	preload("res://resources/terrain/snow.tres"),
	preload("res://resources/terrain/burnt_ground.tres"),
]
const FALLBACK := 2  # dirt

## Shade (Phase 13 canopy cover) costs ~50 us per tile - far more than the
## rest of the choice - so the terrain samples it every SHADE_LATTICE tiles
## and blends bilinearly between (lattice_shade()); forest-floor edges are
## soft anyway.
const SHADE_LATTICE := 4

const PATCH_CONTRAST := 1.8
const _JITTER_SALT := 1

static var _patch_noise_cache: Dictionary = {}

const OCEAN_SHALLOW := Color(0.2, 0.45, 0.8)
const OCEAN_DEEP := Color(0.05, 0.12, 0.45)
const SEA_SHALLOW := Color(0.22, 0.5, 0.72)
const SEA_DEEP := Color(0.1, 0.32, 0.55)
const LAKE_SHALLOW := Color(0.3, 0.66, 0.72)
const LAKE_DEEP := Color(0.16, 0.46, 0.56)
const RIVER_WATER := Color(0.32, 0.62, 0.8)
const ICE := Color(0.75, 0.85, 0.95)
const SEA_LEVEL := -0.1


## Water-body colour for a WorldGen sample, or null for ground (land and
## swamp).
static func water_color(s: Dictionary) -> Variant:
	var elevation: float = s["elevation"]
	var temperature: float = s["temperature"]
	match s["water_body"]:
		"ocean":
			return _water(elevation, temperature, 0.6, OCEAN_SHALLOW, OCEAN_DEEP)
		"sea":
			return _water(elevation, temperature, 0.3, SEA_SHALLOW, SEA_DEEP)
		"lake":
			return _water(elevation, temperature, 0.15, LAKE_SHALLOW, LAKE_DEEP)
		"river":
			return RIVER_WATER
	return null


## The ground material of a land tile. state.shade must already hold the
## tile's shade (the caller sets it - see lattice_shade()).
static func material_at(state: EnvironmentalState, world_seed: int, wx: int, wy: int) -> SurfaceMaterial:
	var best: SurfaceMaterial = null
	var best_score := 0.0
	for material in MATERIALS:
		var suitability: float = ResourceManagerScript.get_suitability(state, material) * material.base_density
		if suitability <= best_score:
			continue  # patch <= 1, so it can't win
		var score := suitability * _patch(material, world_seed, wx, wy)
		if score > best_score:
			best = material
			best_score = score
	return best if best != null else MATERIALS[FALLBACK]


## The tile's colour for a material: its base (per geology where given),
## the two field-driven tints, and a small per-tile brightness jitter.
static func color_for(material: SurfaceMaterial, state: EnvironmentalState, world_seed: int, wx: int, wy: int) -> Color:
	var color: Color = material.geology_colors.get(state.geology, material.ground_color)
	color = _tint(color, state, material.tint_field, material.tint_range, material.tint_color)
	color = _tint(color, state, material.tint2_field, material.tint2_range, material.tint2_color)
	if material.jitter > 0.0:
		var seed := ResourcePlacementScript._resource_seed("terrain", world_seed)
		var unit: float = ResourcePlacementScript._cell_unit(seed, Vector2i(wx, wy), _JITTER_SALT)
		var factor := 1.0 + (unit * 2.0 - 1.0) * material.jitter
		color = Color(color.r * factor, color.g * factor, color.b * factor)
	return color


## Shade at a tile, blended bilinearly from the SHADE_LATTICE corners around
## it. corner_fn(cx, cy) -> float returns the exact shade at a lattice tile
## (cx, cy multiples of SHADE_LATTICE), e.g. ResourceManager.get_shade() -
## callers may cache it (chunk_manager does, per tile).
static func lattice_shade(wx: int, wy: int, corner_fn: Callable) -> float:
	var x0 := floori(wx / float(SHADE_LATTICE)) * SHADE_LATTICE
	var y0 := floori(wy / float(SHADE_LATTICE)) * SHADE_LATTICE
	var fx := (wx - x0) / float(SHADE_LATTICE)
	var fy := (wy - y0) / float(SHADE_LATTICE)
	var top := lerpf(corner_fn.call(x0, y0), corner_fn.call(x0 + SHADE_LATTICE, y0), fx)
	var bottom := lerpf(corner_fn.call(x0, y0 + SHADE_LATTICE), corner_fn.call(x0 + SHADE_LATTICE, y0 + SHADE_LATTICE), fx)
	return lerpf(top, bottom, fy)


## 1 - strength .. 1: the material's patch-noise multiplier at a tile.
static func _patch(material: SurfaceMaterial, world_seed: int, wx: int, wy: int) -> float:
	if material.cluster_strength <= 0.0:
		return 1.0
	var key := "%d|%s" % [world_seed, material.id]
	var noise: FastNoiseLite = _patch_noise_cache.get(key)
	if noise == null:
		noise = FastNoiseLite.new()
		noise.seed = ("%d:%s" % [world_seed + WorldGen.SURFACE_PATCH_SEED_OFFSET, material.id]).hash()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 1.0 / maxf(material.cluster_scale, 1.0)
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		noise.fractal_octaves = 2
		_patch_noise_cache[key] = noise
	var patch := clampf(noise.get_noise_2d(wx, wy) * PATCH_CONTRAST * 0.5 + 0.5, 0.0, 1.0)
	return lerpf(1.0, patch, clampf(material.cluster_strength, 0.0, 1.0))


static func _tint(color: Color, state: EnvironmentalState, field: String, field_range: Vector2, tint: Color) -> Color:
	if field == "" or tint.a <= 0.0:
		return color
	var amount := smoothstep(field_range.x, field_range.y, float(state.get(field))) * tint.a
	return Color(lerpf(color.r, tint.r, amount), lerpf(color.g, tint.g, amount), lerpf(color.b, tint.b, amount))


static func _water(elevation: float, temperature: float, depth_range: float, shallow: Color, deep: Color) -> Color:
	var depth_t := clampf(inverse_lerp(SEA_LEVEL, SEA_LEVEL - depth_range, elevation), 0.0, 1.0)
	var color := shallow.lerp(deep, depth_t)
	var frozen_t := clampf(smoothstep(-0.15, -0.55, temperature), 0.0, 1.0)
	return color.lerp(ICE, frozen_t)
