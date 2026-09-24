class_name EnvironmentalState
extends RefCounted

## Typed wrapper over a WorldGen.sample() Dictionary - the Phase 1 "formalized
## representation" from docs/resource-generation-plan.md, for the new
## resource-generation system to consume with real field access instead of
## string keys. WorldGen.sample() itself is UNCHANGED and keeps returning a
## Dictionary; every existing caller (biome_classifier.gd, biome_subtype.gd,
## biome_modifiers.gd, heatmap_colorizer.gd, terrain_surface.gd (water),
## chunk_manager.gd, tile_inspector_panel.gd) is untouched - this is an
## additional representation, not a replacement (see docs/architecture.md §8
## and the Phase 1 decision in the session that added this file).
##
## Built from one sample() call via from_sample() and never mutated
## afterward - adds no new per-tile state and no risk to determinism. The one
## exception is `shade` (Phase 13), which is not a sample() key: it is
## derived from the canopy guild and attached once, lazily, by
## ResourceManager.get_shade() (a pure function of seed + tile as well). Since
## Phase 17 chunk_manager.gd keeps instances in a bounded per-tile cache
## (_tile_env) and shares them between readers, which relies on exactly that.

var elevation: float
var slope: float
var curvature: float  # WorldGen's "laplacian" key
var temperature: float
var moisture: float

var geology: int  # WorldGen.Geology enum value
var hardness: float
var erosion: float
var deposition: float
var soil_fertility: float
var drainage: float
var cave_potential: float
var cliff_tendency: float
var rock_exposure: float

var river: float
var water_body: String
var water_enclosed: bool
var water_area: int
var water_compactness: float
var water_connected_to_ocean: bool
var shore_proximity: float
var shore_salinity: float  # Phase 10: 0 lake shore .. 1 sea shore

var wind_strength: float
var exposure: float
var temp_variation: float
var precip_seasonality: float

var vegetation: float
var vegetation_potential: float  # Phase 11: vegetation before the scar penalty
var fuel_load: float
var fire_risk: float
var resource: float

var disturbance: float
var disturbance_type: String
var disturbance_age: float
var succession: float  # Phase 11: 0 fresh scar .. 1 mature/undisturbed

## Phase 13: canopy shade, 0 open ground .. 1 dense canopy = the density of
## ResourceManager.SHADE_SOURCE (canopy trees) at this tile. Not part of
## sample(): ResourceManager.get_shade() computes it on first need and sets
## shade_known; until then it reads as 0 (open ground). Guild evaluation
## (ResourceManager.get_member_scores()) attaches it automatically; a caller
## evaluating a shade-reading definition on its own must call get_shade()
## first.
var shade: float = 0.0
var shade_known: bool = false


## Uses load() on its own path rather than the bare class_name so this
## works even when the global script-class cache hasn't indexed this file
## yet (e.g. a headless --script run that never opened the editor). The
## script is kept in a static var and the local is typed: a load() per call
## plus untyped field stores cost ~40us, three times WorldGen.sample()
## itself, on every placement candidate (now ~9us).
static var _script: GDScript

static func from_sample(s: Dictionary):
	if _script == null:
		_script = load("res://scripts/environmental_state.gd")
	var state: EnvironmentalState = _script.new()

	state.elevation = s["elevation"]
	state.slope = s["slope"]
	state.curvature = s["laplacian"]
	state.temperature = s["temperature"]
	state.moisture = s["moisture"]

	state.geology = s["geology"]
	state.hardness = s["hardness"]
	state.erosion = s["erosion"]
	state.deposition = s["deposition"]
	state.soil_fertility = s["soil_fertility"]
	state.drainage = s["drainage"]
	state.cave_potential = s["cave_potential"]
	state.cliff_tendency = s["cliff_tendency"]
	state.rock_exposure = s["rock_exposure"]

	state.river = s["river"]
	state.water_body = s["water_body"]
	state.water_enclosed = s["water_enclosed"]
	state.water_area = s["water_area"]
	state.water_compactness = s["water_compactness"]
	state.water_connected_to_ocean = s["water_connected_to_ocean"]
	state.shore_proximity = s["shore_proximity"]
	state.shore_salinity = s["shore_salinity"]

	state.wind_strength = s["wind_strength"]
	state.exposure = s["exposure"]
	state.temp_variation = s["temp_variation"]
	state.precip_seasonality = s["precip_seasonality"]

	state.vegetation = s["vegetation"]
	state.vegetation_potential = s["vegetation_potential"]
	state.fuel_load = s["fuel_load"]
	state.fire_risk = s["fire_risk"]
	state.resource = s["resource"]

	state.disturbance = s["disturbance"]
	state.disturbance_type = s["disturbance_type"]
	state.disturbance_age = s["disturbance_age"]
	state.succession = s["succession"]

	return state
