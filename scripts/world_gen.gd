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
@export var elevation_frequency: float = 0.004
@export var elevation_octaves: int = 5
@export var ridge_frequency: float = 0.012
@export var ridge_weight: float = 0.3

# --- Temperature ---
@export_group("Climate")
@export var climate_frequency: float = 0.0015
@export var elevation_lapse: float = 0.9
@export var exposure_sun_strength: float = 0.5
@export var micro_variation: float = 0.06

# --- Moisture / hydrology ---
@export_group("Hydrology")
@export var rainfall_frequency: float = 0.0025
@export var orographic_strength: float = 3.0
@export var sea_level: float = -0.1
@export var shore_band: float = 0.22
@export var arid_wind_factor: float = 0.35

# --- Wind / exposure ---
@export_group("Wind")
@export var wind_strength_frequency: float = 0.002
@export var wind_dir_frequency: float = 0.0018

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

var _configured_seed: int = -1


func configure(world_seed: int) -> void:
	if _configured_seed == world_seed:
		return
	_configured_seed = world_seed

	# Regional fields - stretched by world_scale.
	_setup(_elev_base, world_seed + 1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, elevation_frequency / world_scale, elevation_octaves)
	_setup(_elev_ridge, world_seed + 2, FastNoiseLite.TYPE_SIMPLEX, ridge_frequency / world_scale, 3)
	_setup(_climate, world_seed + 3, FastNoiseLite.TYPE_SIMPLEX, climate_frequency / world_scale, 3)
	_setup(_rainfall, world_seed + 4, FastNoiseLite.TYPE_SIMPLEX, rainfall_frequency / world_scale, 3)
	_setup(_wind_strength, world_seed + 5, FastNoiseLite.TYPE_SIMPLEX, wind_strength_frequency / world_scale, 2)
	_setup(_wind_dir, world_seed + 6, FastNoiseLite.TYPE_SIMPLEX, wind_dir_frequency / world_scale, 2)
	_setup(_geology, world_seed + 7, FastNoiseLite.TYPE_CELLULAR, geology_frequency / world_scale, 1)
	_geology.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

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


func _setup(n: FastNoiseLite, s: int, type: FastNoiseLite.NoiseType, freq: float, octaves: int) -> void:
	n.seed = s
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5


## Raw elevation in roughly -1..1 (continent-scale base + ridged detail).
func elevation(wx: float, wy: float) -> float:
	var base := _elev_base.get_noise_2d(wx, wy)
	var ridge := 1.0 - absf(_elev_ridge.get_noise_2d(wx, wy))
	var h := base * (1.0 - ridge_weight) + (ridge * 2.0 - 1.0) * ridge_weight
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
	var climate := _climate.get_noise_2d(fx, fy)
	var micro := _micro.get_noise_2d(fx * 3.0, fy * 3.0) * micro_variation
	var temperature := clampf(climate - e * elevation_lapse - dy * exposure_sun_strength + micro, -1.0, 1.0)

	# --- moisture (rainfall + orographic lift/shadow + shoreline + wind aridity) ---
	var rainfall01 := (_rainfall.get_noise_2d(fx, fy) + 1.0) * 0.5
	var orographic := upslope_component * orographic_strength
	var shore_bonus := clampf(1.0 - smoothstep(sea_level, sea_level + shore_band, e), 0.0, 1.0) * 0.4
	var moisture01 := clampf(rainfall01 + orographic + shore_bonus - exposure01 * arid_wind_factor, 0.0, 1.0)

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
	var soil_fertility := clampf((1.0 - hardness) * 0.5 + moisture01 * 0.5 + deposition01 * 0.3, 0.0, 1.0)

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

	var disturbance01 := clampf(1.0 - smoothstep(0.0, effective_radius, dist_norm), 0.0, 1.0)

	# --- vegetation (derived, not biome-assigned) ---
	var temp_suit := 1.0 - clampf(absf(temperature), 0.0, 1.0)
	var vegetation01 := clampf(temp_suit * moisture01 * soil_fertility, 0.0, 1.0)
	vegetation01 *= 1.0 - exposure01 * vegetation_exposure_penalty
	vegetation01 *= 1.0 - erosion01 * vegetation_erosion_penalty
	vegetation01 *= 1.0 - disturbance01

	# --- resources (geology-driven veins, need erosion to be exposed) ---
	# Sharpen the ridge so veins are rare, narrow seams rather than a scratchy
	# lattice covering the whole map.
	var vein_raw := _resource_vein.get_noise_2d(fx, fy)
	var ridged_vein := pow(1.0 - absf(vein_raw), 4.0)
	var exposure_gate := smoothstep(resource_exposure_requirement, resource_exposure_requirement + 0.25, erosion01)
	var resource01 := clampf(ridged_vein * float(GEOLOGY_RESOURCE_BIAS[geology]) * exposure_gate, 0.0, 1.0)

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
		"vegetation": vegetation01,
		"exposure": exposure01,
		"resource": resource01,
	}


func _geology_from_raw(v: float) -> int:
	if v < -0.5:
		return Geology.SEDIMENTARY
	elif v < 0.0:
		return Geology.METAMORPHIC
	elif v < 0.5:
		return Geology.IGNEOUS
	return Geology.VOLCANIC
