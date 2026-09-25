class_name WorldGen
extends Resource

## Procedural world generation driven by interacting environmental fields
## rather than elevation alone. Call configure(seed) once, then sample(wx, wy)
## per tile. Pure data - no rendering/art here (see chunk_manager.gd for that).
##
## Dependency flow:
##   elevation -> temperature (lapse + exposure)
##   elevation + wind -> orographic moisture (windward lift / leeward rain shadow)
##   geology -> erosion resistance, resource bias
##   slope + moisture + wind -> erosion -> exposed rock / sediment deposits
##   temperature + moisture + soil + exposure + disturbance -> vegetation
##   geology + erosion -> resource concentration

# --- World scale ---
# Stretches the REGIONAL fields (elevation, climate, hydrology, wind, geology)
# so continents/mountain-ranges/climate-zones span more tiles - i.e. feel
# bigger relative to a player that moves ~1 tile at a time. LOCAL features
# (disturbance scars, resource veins, fine surface jitter) deliberately do
# NOT scale with this - a fire scar or ore vein should stay small no matter
# how big the continents get.
@export_group("Scale")
@export var world_scale: float = 8.0

# --- Elevation / topography ---
@export_group("Elevation")
# Continent scale: low, so oceans and landmasses are large and coherent.
@export var elevation_frequency: float = 0.0012
@export var elevation_octaves: int = 5
@export var ridge_frequency: float = 0.012
@export var ridge_weight: float = 0.3
# Ridges are full mountains where the continent-scale base is high (above
# lowland_ridge_fade.y); below lowland_ridge_fade.x they only RAISE the
# ground above lowland_ridge_level (hills), never cut troughs under it -
# troughs would scatter the lowlands with small ponds instead of letting
# coastlines follow the large base shapes. Just below the coast (over
# COAST_FADE of base) the hills fade out too, so oceans are open water with
# a ragged, hilly shore rather than a spray of islets. The level keeps land
# at ~85% of the world, as before, and most of the old relief (slopes feed
# erosion, cliffs and exposed rock).
@export var lowland_ridge_fade: Vector2 = Vector2(-0.15, 0.25)
@export var lowland_ridge_level: float = 0.2
# Lakes: the hills above no longer leave ponds in ridge troughs, so lakes
# are their own feature - scattered basins where this noise peaks above
# lake_threshold, sunk to just under sea level (small enough for the
# flood fill to call them lakes, or seas if a strait reaches the ocean).
# Only up to lake_max_elevation, so they sit in lowlands and valleys.
@export var lake_frequency: float = 0.012        # local scale - not stretched by world_scale
@export var lake_threshold: float = 0.87
@export var lake_max_elevation: float = 0.35

# --- Temperature ---
@export_group("Climate")
@export var climate_frequency: float = 0.0015
@export var elevation_lapse: float = 0.9
@export var exposure_sun_strength: float = 0.5
@export var micro_variation: float = 0.06
## Regional climate noise is FBM simplex, which clusters near 0 and rarely
## nears +/-1 - without a stretch the world has few truly hot or cold
## regions. climate_contrast scales it (the sum is clamped to -1..1 anyway).
@export var climate_contrast: float = 1.35
## Added to every tile's temperature. Land always sits above sea_level, so
## elevation_lapse alone pulls typical land (elevation ~0..0.3) colder than
## the climate noise says; this offsets that bias so cold regions don't
## dominate the land.
@export var temperature_offset: float = 0.2

# --- Moisture / hydrology ---
@export_group("Hydrology")
@export var rainfall_frequency: float = 0.0025
@export var orographic_strength: float = 3.0
@export var sea_level: float = -0.1
@export var shore_band: float = 0.22
@export var arid_wind_factor: float = 0.35
# Water-body typing: elevation alone still decides what's wet: this just
# labels the wet/waterlogged tiles as ocean/sea/lake/swamp for color+overlay.
# Swamp is NOT "the strip right at the coast" - that's a beach. A swamp is a
# warm, very wet, flat, low-lying spot, which can form far inland (a
# floodplain, a low basin) just as easily as near a shore. Cold, steep, or
# dry ground never becomes a swamp no matter how low its elevation is.
@export var swamp_max_elevation: float = 0.2      # swamp potential fades out above this elevation
@export var swamp_min_temperature: float = -0.15  # colder than this and it won't support marsh/wetland ecology
@export var swamp_threshold: float = 0.32         # combined moisture*lowland*warmth*flatness must clear this

# --- Water Topology ---
# Real bounded/cached flood-fill (see water_topology.gd) - the only piece of
# this generator that isn't a stateless per-tile function. Enclosed bodies
# (fit within the budget) become Lake or Sea (if a strait to open water is
# found nearby); bodies that exceed the budget are Ocean. Seas are thus
# only enclosed bodies joined to open water - rare, and distinct from it.
@export_group("Water Topology")
@export var flood_fill_budget: int = 3500      # tiles; first-touch cost into a large body scales with this
@export var strait_probe_distance: int = 60    # tiles; how far past an enclosed shore to look for open water

# --- Rivers ---
# Approximated, not flow-simulated: a domain-warped noise field whose
# near-zero band traces a winding line, gated to a plausible elevation range
# and widened as it nears sea level (like a river mouth). Not physically
# guaranteed to reach an actual lake/ocean, but reads as a river visually.
@export_group("Rivers")
@export var river_frequency: float = 0.01         # regional scale - stretched by world_scale
@export var river_width: float = 0.05
@export var river_max_elevation: float = 0.55     # fades out above this - approximates a headwaters cutoff
@export var river_threshold: float = 0.5          # river field above this = tile renders/classifies as river
@export var riparian_moisture_boost: float = 0.35 # rivers locally raise moisture, feeding vegetation nearby
# A "near zero" noise band traces both long winding lines AND small closed
# loops around local extrema - loops read as stray blobs, not rivers. Require
# a point further along the line's own tangent (in WORLD TILES, scaled by
# world_scale - not a fraction of river_width, which is a threshold on the
# noise VALUE, not a distance) to also be "on the line": a long river stays
# elongated well past that check, a small loop's far side usually doesn't.
@export var river_elongation_distance: float = 2.5  # tiles, multiplied by world_scale

# --- Beaches ---
@export_group("Beaches")
# Shore proximity used to be pure elevation ("close to sea level"), which
# sanded any low-lying inland spot even with no water anywhere nearby. Now it
# also requires an actual sub-sea-level tile within this radius.
@export var beach_search_radius: float = 25.0     # scales with world_scale

# --- Wind / exposure ---
@export_group("Wind")
@export var wind_strength_frequency: float = 0.002
@export var wind_dir_frequency: float = 0.0018

# --- Seasonality ---
# Static per-tile data only (annual amplitude, not a live day/season clock).
# temp_variation: how much temperature swings across the year on top of the
# annual-mean `temperature` field. precip_seasonality: how unevenly rainfall
# is distributed through the year (low = steady, high = monsoon/dry-season
# contrast) on top of the annual-mean `moisture` field.
@export_group("Seasonality")
@export var temp_variation_frequency: float = 0.0012      # regional - stretched by world_scale
@export var precip_seasonality_frequency: float = 0.0018  # regional - stretched by world_scale

# --- Geology ---
@export_group("Geology")
@export var geology_frequency: float = 0.006

# --- Erosion / sediment ---
@export_group("Erosion")
@export var wind_erosion_factor: float = 0.6
@export var erosion_scale: float = 140.0
@export var deposit_scale: float = 900.0

# --- Vegetation ---
@export_group("Vegetation")
@export var vegetation_exposure_penalty: float = 0.6
@export var vegetation_erosion_penalty: float = 0.7
## Cold limits growth outright: none at/below vegetation_cold_limit, no
## penalty from vegetation_cold_full up.
@export var vegetation_cold_limit: float = -0.9
@export var vegetation_cold_full: float = -0.35
## Heat only limits growth where water is short: heat stress ramps from
## vegetation_heat_start to temperature 1.0 and is scaled by dryness
## (1 - moisture), so hot+wet can reach forest levels while hot+dry thins
## toward savanna and desert.
@export var vegetation_heat_start: float = 0.15
## vegetation ~ (moisture * soil_fertility)^exponent. 1.0 = plain product,
## which compresses land into ~0.05..0.3 (fertility already contains
## moisture); lower values spread it toward the biome thresholds.
@export var vegetation_water_exponent: float = 0.5

# --- Disturbance / history ---
@export_group("Disturbance")
@export var disturbance_frequency: float = 0.004        # lower = fewer, more spread out
@export var disturbance_radius: float = 0.35
@export var disturbance_size_variation: float = 0.6      # 0 = every blob the same size
@export var disturbance_warp_strength: float = 20.0      # tiles; breaks up the perfect-circle look

# --- Resources ---
@export_group("Resources")
@export var resource_frequency: float = 0.02
@export var resource_exposure_requirement: float = 0.15
## cliff_tendency above which bare rock starts showing on steep hard ground
## (rock_exposure's second source, next to erosion - see sample()).
@export var resource_cliff_exposure_requirement: float = 0.1

enum Geology { SEDIMENTARY, METAMORPHIC, IGNEOUS, VOLCANIC }

# hardness = erosion resistance (0 soft/erodes easily .. 1 hard/resists erosion)
const GEOLOGY_HARDNESS := {
	Geology.SEDIMENTARY: 0.25,
	Geology.METAMORPHIC: 0.55,
	Geology.IGNEOUS: 0.7,
	Geology.VOLCANIC: 0.45,
}
# relative likelihood of ore/resource veins per rock type
const GEOLOGY_RESOURCE_BIAS := {
	Geology.SEDIMENTARY: 0.4,
	Geology.METAMORPHIC: 0.8,
	Geology.IGNEOUS: 1.0,
	Geology.VOLCANIC: 1.2,
}
# baseline permeability (0 clay-like/waterlogging .. 1 free-draining) before
# slope/curvature/moisture adjust it per-tile - sedimentary rock is often
# fine-grained (shale/clay), metamorphic is dense/low-permeability, igneous
# is commonly fractured (good drainage), volcanic is mixed (fractured basalt
# vs. fine ash) so sits in the middle.
const GEOLOGY_DRAINAGE_BIAS := {
	Geology.SEDIMENTARY: 0.4,
	Geology.METAMORPHIC: 0.45,
	Geology.IGNEOUS: 0.7,
	Geology.VOLCANIC: 0.55,
}
# baseline soil fertility from parent rock, independent of hardness - a hard
# rock isn't necessarily poor soil (volcanic ash/basalt weathers into some of
# the most fertile soil on Earth) and a soft rock isn't necessarily rich
# (many shales are nutrient-poor); granite-family igneous rock in particular
# weathers slowly into comparatively poor soil despite eroding a bit faster
# than metamorphic.
const GEOLOGY_FERTILITY_BIAS := {
	Geology.SEDIMENTARY: 0.55,
	Geology.METAMORPHIC: 0.35,
	Geology.IGNEOUS: 0.45,
	Geology.VOLCANIC: 0.85,
}
# cave/sinkhole potential - classic karst dissolution (limestone-like
# sedimentary rock) is the dominant real-world mechanism, with volcanic lava
# tubes as a distinct minor contributor; granite/metamorphic rarely cave.
const GEOLOGY_CAVE_BIAS := {
	Geology.SEDIMENTARY: 0.8,
	Geology.METAMORPHIC: 0.2,
	Geology.IGNEOUS: 0.1,
	Geology.VOLCANIC: 0.35,
}

const DISTURBANCE_TYPES := ["fire", "flood", "storm", "landslide"]

var _elev_base := FastNoiseLite.new()
var _elev_ridge := FastNoiseLite.new()
var _climate := FastNoiseLite.new()
var _rainfall := FastNoiseLite.new()
var _wind_strength := FastNoiseLite.new()
var _wind_dir := FastNoiseLite.new()
var _geology := FastNoiseLite.new()
var _disturbance := FastNoiseLite.new()
var _disturbance_cell := FastNoiseLite.new()
var _disturbance_warp := FastNoiseLite.new()
var _resource_vein := FastNoiseLite.new()
var _micro := FastNoiseLite.new()
var _river_line := FastNoiseLite.new()
var _river_warp := FastNoiseLite.new()
var _temp_variation := FastNoiseLite.new()
var _precip_seasonality := FastNoiseLite.new()
var _lake := FastNoiseLite.new()

const WaterTopologyScript := preload("res://scripts/water_topology.gd")
var _water_topology = WaterTopologyScript.new()

var _configured_seed: int = -1

# Seed offsets in use, so new fields don't collide: +1 elev_base, +2
# elev_ridge, +3 climate, +4 rainfall, +5 wind_strength, +6 wind_dir,
# +7 geology, +8 disturbance/disturbance_cell (shared), +9 resource_vein,
# +10 micro, +11 disturbance_warp, +12 river_line, +13 river_warp,
# +14 (unused - was water_region), +15 temp_variation, +16 precip_seasonality,
# +17 per-resource distribution/patch noise (not owned here - see
# ResourceManager.get_patch_modifier(), which derives one seed per
# ResourceDefinition.id from world_seed + this offset), +18 per-resource
# placement rolls (likewise not owned here - see ResourcePlacement),
# +19 per-deposit vein noise (not owned here - see
# ResourceManager.get_vein_value()).
# +20 surface-material patch noise (Phase 13.5; not owned here - see
# TerrainSurface, one noise per material id).
# +21 lake basins.
# +22 landmark/structure site hashes (not owned here - see StructureSites:
# position, type, rotation, age and stamp rolls per coarse site cell).
# Next free offset: +23.
const RESOURCE_DISTRIBUTION_SEED_OFFSET := 17
const RESOURCE_PLACEMENT_SEED_OFFSET := 18
const DEPOSIT_VEIN_SEED_OFFSET := 19
const SURFACE_PATCH_SEED_OFFSET := 20
const LAKE_SEED_OFFSET := 21
const STRUCTURE_SITE_SEED_OFFSET := 22


func configure(world_seed: int) -> void:
	if _configured_seed == world_seed:
		return
	_configured_seed = world_seed
	# A cached lake result from a previous seed would be silently wrong data
	# for this one - not currently reachable in practice (chunk_manager.gd
	# always creates a fresh WorldGen per page load) but cheap to guard.
	_water_topology = WaterTopologyScript.new()

	# Regional fields - stretched by world_scale.
	_setup(_elev_base, world_seed + 1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, elevation_frequency / world_scale, elevation_octaves)
	_setup(_elev_ridge, world_seed + 2, FastNoiseLite.TYPE_SIMPLEX, ridge_frequency / world_scale, 3)
	_setup(_climate, world_seed + 3, FastNoiseLite.TYPE_SIMPLEX, climate_frequency / world_scale, 3)
	_setup(_rainfall, world_seed + 4, FastNoiseLite.TYPE_SIMPLEX, rainfall_frequency / world_scale, 3)
	_setup(_wind_strength, world_seed + 5, FastNoiseLite.TYPE_SIMPLEX, wind_strength_frequency / world_scale, 2)
	_setup(_wind_dir, world_seed + 6, FastNoiseLite.TYPE_SIMPLEX, wind_dir_frequency / world_scale, 2)
	_setup(_geology, world_seed + 7, FastNoiseLite.TYPE_CELLULAR, geology_frequency / world_scale, 1)
	_geology.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	_setup(_river_line, world_seed + 12, FastNoiseLite.TYPE_SIMPLEX, river_frequency / world_scale, 2)
	_setup(_river_warp, world_seed + 13, FastNoiseLite.TYPE_SIMPLEX, river_frequency * 3.0 / world_scale, 2)
	_setup(_temp_variation, world_seed + 15, FastNoiseLite.TYPE_SIMPLEX, temp_variation_frequency / world_scale, 2)
	_setup(_precip_seasonality, world_seed + 16, FastNoiseLite.TYPE_SIMPLEX, precip_seasonality_frequency / world_scale, 2)

	# Local features - intentionally NOT scaled by world_scale.
	_setup(_disturbance, world_seed + 8, FastNoiseLite.TYPE_CELLULAR, disturbance_frequency, 1)
	_disturbance.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	# Same seed+frequency as _disturbance so this shares the exact same Voronoi
	# cells - only the return type differs, giving a per-blob random value.
	_setup(_disturbance_cell, world_seed + 8, FastNoiseLite.TYPE_CELLULAR, disturbance_frequency, 1)
	_disturbance_cell.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	_setup(_disturbance_warp, world_seed + 11, FastNoiseLite.TYPE_SIMPLEX, disturbance_frequency * 2.5, 2)
	_setup(_resource_vein, world_seed + 9, FastNoiseLite.TYPE_SIMPLEX, resource_frequency, 2)
	_setup(_micro, world_seed + 10, FastNoiseLite.TYPE_SIMPLEX, 0.05, 1)
	_setup(_lake, world_seed + LAKE_SEED_OFFSET, FastNoiseLite.TYPE_SIMPLEX, lake_frequency, 1)


func _setup(n: FastNoiseLite, s: int, type: FastNoiseLite.NoiseType, freq: float, octaves: int) -> void:
	n.seed = s
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5


## Base range below the coast over which hills fade into open sea.
const COAST_FADE := 0.15


## Raw elevation in roughly -1..1 (continent-scale base + ridged detail).
func elevation(wx: float, wy: float) -> float:
	var base := _elev_base.get_noise_2d(wx, wy)
	var ridge := 1.0 - absf(_elev_ridge.get_noise_2d(wx, wy))
	var r := ridge * 2.0 - 1.0
	var land_term := lerpf(maxf(r, lowland_ridge_level), r, smoothstep(lowland_ridge_fade.x, lowland_ridge_fade.y, base))
	# Base value at which the flat lowland meets sea level.
	var coast_base := (sea_level - lowland_ridge_level * ridge_weight) / (1.0 - ridge_weight)
	var term := lerpf(lowland_ridge_level, land_term, smoothstep(coast_base - COAST_FADE, coast_base, base))
	var h := base * (1.0 - ridge_weight) + term * ridge_weight
	# Lake basins: a bowl easing down to just under sea level at the peak.
	var basin := smoothstep(lake_threshold, lake_threshold + 0.12, _lake.get_noise_2d(wx, wy))
	if basin > 0.0 and h > sea_level:
		# Not in the coastal flats (a basin there would just join the sea),
		# nor high up.
		basin *= smoothstep(sea_level + 0.02, sea_level + 0.08, h) * (1.0 - smoothstep(lake_max_elevation - 0.1, lake_max_elevation, h))
		h = lerpf(h, sea_level - 0.02, basin)
	return clampf(h, -1.0, 1.0)


## Full environmental sample for one tile. Everything downstream is derived
## from a shared set of fields rather than independent per-material noise.
func sample(wx: int, wy: int) -> Dictionary:
	var fx := float(wx)
	var fy := float(wy)

	# --- topography ---
	var e := elevation(fx, fy)
	var e_x1 := elevation(fx + 1.0, fy)
	var e_x0 := elevation(fx - 1.0, fy)
	var e_y1 := elevation(fx, fy + 1.0)
	var e_y0 := elevation(fx, fy - 1.0)
	var dx := (e_x1 - e_x0) * 0.5
	var dy := (e_y1 - e_y0) * 0.5
	var slope := sqrt(dx * dx + dy * dy)
	var laplacian := e_x1 + e_x0 + e_y1 + e_y0 - 4.0 * e

	# --- wind ---
	var wind_angle := _wind_dir.get_noise_2d(fx, fy) * PI
	var wind_vec := Vector2(cos(wind_angle), sin(wind_angle))
	var wind_strength01 := (_wind_strength.get_noise_2d(fx, fy) + 1.0) * 0.5
	var upslope_component := dx * wind_vec.x + dy * wind_vec.y
	var exposure01 := clampf(wind_strength01 * (0.3 + 0.7 * clampf(e, 0.0, 1.0) + slope * 2.0), 0.0, 1.0)

	# --- temperature (elevation lapse + slope sun exposure + regional climate) ---
	var climate := _climate.get_noise_2d(fx, fy) * climate_contrast + temperature_offset
	var micro := _micro.get_noise_2d(fx * 3.0, fy * 3.0) * micro_variation
	var temperature := clampf(climate - e * elevation_lapse - dy * exposure_sun_strength + micro, -1.0, 1.0)

	# --- seasonality (static data only - see @export_group("Seasonality") doc) ---
	var temp_variation01 := (_temp_variation.get_noise_2d(fx, fy) + 1.0) * 0.5
	var precip_seasonality01 := (_precip_seasonality.get_noise_2d(fx, fy) + 1.0) * 0.5

	# --- moisture (rainfall + orographic lift/shadow + shoreline + wind aridity) ---
	var rainfall01 := (_rainfall.get_noise_2d(fx, fy) + 1.0) * 0.5
	var orographic := upslope_component * orographic_strength
	# How close this tile is to sea level, purely geometric (not climate-
	# driven) - used both as a small moisture bump and, separately, to give
	# coastlines an actual sandy beach fringe regardless of local climate.
	# Elevation alone isn't enough: a low inland plain can sit at the same
	# elevation band with no water anywhere near it, so also require an
	# actual sub-sea-level tile nearby before counting this as "shore."
	var shore_proximity := clampf(1.0 - smoothstep(sea_level, sea_level + shore_band, e), 0.0, 1.0)
	# Phase 10 (shores): which kind of water that shore faces - the share of
	# the probes that found water whose body is the sea/ocean rather than an
	# enclosed lake (WaterTopology, same test as water_body below). 0 away
	# from any shore.
	var shore_salinity := 0.0
	if shore_proximity > 0.0:
		var search_radius := beach_search_radius * (world_scale / 8.0)
		var wet_probes := 0
		var salty_probes := 0
		var directions: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, 1.0), Vector2(0.0, -1.0)]
		for dir in directions:
			var probe: Vector2 = Vector2(fx, fy) + dir * search_radius
			if elevation(probe.x, probe.y) < sea_level:
				wet_probes += 1
				var probe_topo: Dictionary = _water_topology.classify(
					floori(probe.x), floori(probe.y), elevation, sea_level, flood_fill_budget, strait_probe_distance
				)
				if not probe_topo["enclosed"] or probe_topo["connected_to_ocean"]:
					salty_probes += 1
		if wet_probes == 0:
			shore_proximity = 0.0
		else:
			shore_salinity = float(salty_probes) / wet_probes
	var moisture01 := clampf(rainfall01 + orographic + shore_proximity * 0.4 - exposure01 * arid_wind_factor, 0.0, 1.0)

	# --- rivers (approximated, not flow-simulated - see class doc) ---
	var rwarp_x := _river_warp.get_noise_2d(fx, fy) * (20.0 * world_scale)
	var rwarp_y := _river_warp.get_noise_2d(fx - 500.0, fy + 500.0) * (20.0 * world_scale)
	var wfx := fx + rwarp_x
	var wfy := fy + rwarp_y
	var river_line := absf(_river_line.get_noise_2d(wfx, wfy))
	var river_shape := 1.0 - smoothstep(0.0, river_width, river_line)

	# A "near zero" band traces both long winding lines and small closed
	# loops around local extrema - loops are stray blobs, not rivers. Probe a
	# point further along this point's own tangent (perpendicular to the
	# noise gradient, estimated via finite difference): a genuinely long
	# river is elongated along that tangent and stays "on," while a small
	# loop's far side usually falls outside its own thin ring.
	if river_shape > 0.0:
		var check_dist := river_elongation_distance * world_scale
		# Estimate the gradient at roughly the same scale as the check itself
		# (a 1-tile step is essentially measuring noise floor against an
		# ~800-tile wavelength field, too unstable to give a real direction).
		var grad_step := check_dist * 0.5
		var line_x1 := absf(_river_line.get_noise_2d(wfx + grad_step, wfy))
		var line_y1 := absf(_river_line.get_noise_2d(wfx, wfy + grad_step))
		var grad := Vector2(line_x1 - river_line, line_y1 - river_line)
		var tangent := Vector2(-grad.y, grad.x)
		tangent = tangent.normalized() if tangent.length() > 0.0001 else Vector2(1.0, 0.0)
		var ahead := absf(_river_line.get_noise_2d(wfx + tangent.x * check_dist, wfy + tangent.y * check_dist))
		var behind := absf(_river_line.get_noise_2d(wfx - tangent.x * check_dist, wfy - tangent.y * check_dist))
		var elongation_gate := minf(
			1.0 - smoothstep(0.0, river_width * 1.5, ahead),
			1.0 - smoothstep(0.0, river_width * 1.5, behind)
		)
		river_shape *= elongation_gate

	# Only between the coast and a plausible headwaters elevation, widening
	# toward the coast like a river mouth and tapering out upstream.
	var river_lowland_gate := smoothstep(sea_level, sea_level + shore_band, e)
	var river_highland_gate := 1.0 - smoothstep(river_max_elevation - 0.15, river_max_elevation, e)
	var river01 := clampf(river_shape * river_lowland_gate * river_highland_gate, 0.0, 1.0)

	# Riparian effect: rivers locally raise moisture, which then feeds
	# vegetation/erosion below through the existing formulas - no separate
	# "greener near rivers" rule needed.
	moisture01 = clampf(moisture01 + river01 * riparian_moisture_boost, 0.0, 1.0)

	# --- geology (independent rock domains) ---
	var geo_raw := _geology.get_noise_2d(fx, fy)
	var geology: int = _geology_from_raw(geo_raw)
	var hardness: float = GEOLOGY_HARDNESS[geology]

	# --- erosion / sediment (slope + moisture + wind, resisted by geology) ---
	var water_erosion := slope * moisture01
	var wind_erosion := slope * exposure01 * wind_erosion_factor
	var erosion01 := clampf((water_erosion + wind_erosion) * (1.0 - hardness) * erosion_scale, 0.0, 1.0)
	var deposition01 := clampf(laplacian * deposit_scale, 0.0, 1.0)

	# --- soil fertility (geology parent material + moisture + deposition) ---
	# Fertility now comes from its own geology bias, not (1-hardness) - hard
	# volcanic rock weathers into some of the most fertile soil on Earth,
	# while some soft rock is nutrient-poor, so hardness alone was a poor
	# proxy.
	var soil_fertility := clampf(GEOLOGY_FERTILITY_BIAS[geology] * 0.5 + moisture01 * 0.5 + deposition01 * 0.3, 0.0, 1.0)

	# --- cave/sinkhole and cliff-formation potential ---
	# Caves need both soluble/fractured rock AND water to have dissolved it
	# over time. Cliffs are steep ground on hard rock that resists erosion
	# differentially from what used to surround it.
	var cave_potential := clampf(float(GEOLOGY_CAVE_BIAS[geology]) * (0.3 + 0.7 * moisture01), 0.0, 1.0)
	var cliff_tendency := clampf(hardness * smoothstep(0.004, 0.01, slope) * 1.5, 0.0, 1.0)

	# --- drainage (permeability - distinct from fertility) ---
	# Steep/convex ground sheds water (good drainage); concave basins pool it
	# (poor drainage); already-saturated or low-lying-near-water ground drains
	# less freely simply because it's already full. Heavy rain + poor
	# drainage reads as marsh/swamp; heavy rain + good drainage reads as
	# forest; low rain + very high drainage reads as arid land - those
	# readings fall out of how `drainage` later combines with moisture in the
	# classifier, not from any special-casing here.
	var curvature_signed := clampf(laplacian * deposit_scale, -1.0, 1.0)
	var drainage := float(GEOLOGY_DRAINAGE_BIAS[geology])
	drainage += slope * 40.0
	drainage -= curvature_signed * 0.3
	drainage -= moisture01 * 0.15
	drainage -= shore_proximity * 0.2
	drainage = clampf(drainage, 0.0, 1.0)

	# --- water body typing (ocean/sea/lake/swamp/river) ---
	# Real bounded/cached flood-fill (water_topology.gd) decides enclosure
	# and, for enclosed bodies, whether a nearby strait reaches open water -
	# genuine topology, not a size threshold. A body that exceeds the fill
	# budget is "open/unbounded" by definition - the ocean (a capped fill's
	# shape depends on which tile triggered it, so nothing finer is read
	# from it; see water_topology.gd's doc comment).
	var water_body := "none"
	var water_enclosed := false
	var water_area := -1
	var water_compactness := 0.0
	var water_connected_to_ocean := false
	if e < sea_level:
		var topo: Dictionary = _water_topology.classify(
			wx, wy, elevation, sea_level, flood_fill_budget, strait_probe_distance
		)
		water_enclosed = topo["enclosed"]
		water_area = topo["area"]
		water_compactness = topo["compactness"]
		water_connected_to_ocean = topo["connected_to_ocean"]
		if water_enclosed:
			water_body = "sea" if water_connected_to_ocean else "lake"
		else:
			water_body = "ocean"
	elif river01 > river_threshold:
		water_body = "river"
	else:
		# Swamp: warm + very wet + flat + low-lying, all at once - not just
		# "close to the coast" (that's shore_proximity's job, for beaches).
		var swamp_lowland := 1.0 - smoothstep(sea_level, swamp_max_elevation, e)
		var swamp_warmth := smoothstep(swamp_min_temperature, swamp_min_temperature + 0.2, temperature)
		var swamp_flatness := 1.0 - smoothstep(0.0013, 0.0065, slope)
		var swampiness := moisture01 * swamp_lowland * swamp_warmth * swamp_flatness
		if swampiness > swamp_threshold:
			water_body = "swamp"

	# --- disturbance (fire/flood/clearing scars with outward recovery) ---
	# Domain-warp the sampling position first so blobs aren't perfect circles -
	# straight cellular distance is radially symmetric around each feature point.
	var warp_x := _disturbance_warp.get_noise_2d(fx, fy) * disturbance_warp_strength
	var warp_y := _disturbance_warp.get_noise_2d(fx + 1000.0, fy - 1000.0) * disturbance_warp_strength
	var dfx := fx + warp_x
	var dfy := fy + warp_y

	# Cellular RETURN_DISTANCE is empirically ~[-1, 0.1] (near -1 = at a feature
	# point/epicenter, rising outward), not 0..1 - normalize before use.
	var dist_raw := _disturbance.get_noise_2d(dfx, dfy)
	var dist_norm := clampf(inverse_lerp(-1.0, 0.1, dist_raw), 0.0, 1.0)

	# Per-blob radius so scars vary in size instead of all being identical.
	var cell_value := _disturbance_cell.get_noise_2d(dfx, dfy)
	var size_mult: float = lerp(1.0 - disturbance_size_variation, 1.0 + disturbance_size_variation, (cell_value + 1.0) * 0.5)
	var effective_radius := disturbance_radius * size_mult

	# Type and age are pseudo-independent remaps of the SAME cell_value (no
	# extra noise sample) - different multipliers before taking the
	# fractional part decorrelate them from each other and from size_mult
	# above, even though all three ultimately come from one number per blob.
	# Both are constant across a whole blob, unlike disturbance01 below which
	# also falls off with distance from the epicenter.
	var type_raw := cell_value * 5.17
	var type01 := type_raw - floorf(type_raw)
	var disturbance_type: String = DISTURBANCE_TYPES[int(type01 * DISTURBANCE_TYPES.size()) % DISTURBANCE_TYPES.size()]

	var age_raw := cell_value * 7.3
	var disturbance_age := age_raw - floorf(age_raw)

	var disturbance01 := clampf(1.0 - smoothstep(0.0, effective_radius, dist_norm), 0.0, 1.0)
	# Phase 11 succession stage, 0 = freshly cleared .. 1 = mature/undisturbed:
	# the blob's age where the scar's footprint is full, rising to 1 toward
	# its edge (edges recover first) and exactly 1 outside it. Uses the
	# footprint before the age fade below, so type/age - constant across the
	# whole cellular cell - never leak into undisturbed land.
	var succession := 1.0 - disturbance01 * (1.0 - disturbance_age)
	# Ecological succession: an old scar fades even at its own epicenter, not
	# just with distance - a young disturbance stays stark/bare, an old one
	# has mostly recovered.
	disturbance01 *= 1.0 - disturbance_age * 0.6

	# --- vegetation (derived, not biome-assigned) ---
	# Cold limits outright; heat only where it's dry (see the exports above).
	var cold_suit := smoothstep(vegetation_cold_limit, vegetation_cold_full, temperature)
	var heat_stress := smoothstep(vegetation_heat_start, 1.0, temperature) * (1.0 - moisture01)
	var temp_suit := cold_suit * (1.0 - heat_stress)
	var water := pow(clampf(moisture01 * soil_fertility, 0.0, 1.0), vegetation_water_exponent)
	var vegetation01 := clampf(temp_suit * water, 0.0, 1.0)
	vegetation01 *= 1.0 - exposure01 * vegetation_exposure_penalty
	vegetation01 *= 1.0 - erosion01 * vegetation_erosion_penalty
	# What would grow here undisturbed - Phase 11 vegetation guilds take their
	# cover from this and let each species' succession_curve decide what grows
	# on a scar, instead of the blanket scar penalty below.
	var vegetation_potential := vegetation01
	vegetation01 *= 1.0 - disturbance01

	# --- fire propensity (dryness + heat + wind + accumulated fuel) ---
	# fuel_load: how much burnable material has built up - vegetation that
	# hasn't been recently disturbed (disturbance01 already fades with both
	# distance from an epicenter AND age, so "not disturbed" already means
	# "had time to accumulate fuel," no separate age term needed here).
	var fuel_load := vegetation01 * (1.0 - disturbance01)
	var fire_dryness := 1.0 - moisture01
	var fire_heat := smoothstep(-0.1, 0.5, temperature)
	# A pronounced dry season raises fire risk even where annual-average
	# moisture looks fine (Mediterranean/monsoon-adjacent climates).
	var fire_seasonal_bonus := 1.0 + precip_seasonality01 * 0.5
	var fire_risk := clampf(
		fire_dryness * fire_heat * (0.5 + 0.5 * wind_strength01) * fuel_load * fire_seasonal_bonus,
		0.0, 1.0
	)

	# --- resources (geology-driven veins, need erosion to be exposed) ---
	# Sharpen the ridge so veins are rare, narrow seams rather than a scratchy
	# lattice covering the whole map.
	var vein_raw := _resource_vein.get_noise_2d(fx, fy)
	var ridged_vein := pow(1.0 - absf(vein_raw), 4.0)
	var exposure_gate := smoothstep(resource_exposure_requirement, resource_exposure_requirement + 0.25, erosion01)
	var resource01 := clampf(ridged_vein * float(GEOLOGY_RESOURCE_BIAS[geology]) * exposure_gate, 0.0, 1.0)
	# How much bedrock shows at the surface (0 buried .. 1 bare): eroded
	# ground or steep hard cliffs. Phase 9 deposits exist underground either
	# way; this is what decides whether one is visible (see
	# ResourceManager.get_exposed_deposit()).
	var cliff_gate := smoothstep(resource_cliff_exposure_requirement, resource_cliff_exposure_requirement + 0.3, cliff_tendency)
	var rock_exposure := 0.0 if water_body != "none" else maxf(exposure_gate, cliff_gate)

	return {
		"elevation": e,
		"slope": slope,
		"laplacian": laplacian,
		"temperature": temperature,
		"moisture": moisture01,
		"geology": geology,
		"hardness": hardness,
		"erosion": erosion01,
		"deposition": deposition01,
		"soil_fertility": soil_fertility,
		"disturbance": disturbance01,
		"disturbance_type": disturbance_type,
		"disturbance_age": disturbance_age,
		"succession": succession,
		"vegetation": vegetation01,
		"vegetation_potential": vegetation_potential,
		"exposure": exposure01,
		"resource": resource01,
		"water_body": water_body,
		"water_enclosed": water_enclosed,
		"water_area": water_area,
		"water_compactness": water_compactness,
		"water_connected_to_ocean": water_connected_to_ocean,
		"river": river01,
		"shore_proximity": shore_proximity,
		"shore_salinity": shore_salinity,
		"wind_strength": wind_strength01,
		"temp_variation": temp_variation01,
		"precip_seasonality": precip_seasonality01,
		"drainage": drainage,
		"fuel_load": fuel_load,
		"fire_risk": fire_risk,
		"cave_potential": cave_potential,
		"cliff_tendency": cliff_tendency,
		"rock_exposure": rock_exposure,
	}


func _geology_from_raw(v: float) -> int:
	if v < -0.5:
		return Geology.SEDIMENTARY
	elif v < 0.0:
		return Geology.METAMORPHIC
	elif v < 0.5:
		return Geology.IGNEOUS
	return Geology.VOLCANIC
