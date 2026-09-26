extends RefCounted

## Every view of the map in one table (review A2, §4.1 step 4): its
## dropdown label, how its base image is coloured, which placement layers
## it draws, and its flags. ChunkManager builds and draws chunks from it and
## the view dropdown lists its labels, so a view is added or changed here.
## Constants only; any thread.

const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")
const ResourceManagerScript := preload("res://scripts/resource_manager.gd")

## The guilds and resources particular views show (the stack itself is
## WorldContent's).
const OAK_RESOURCE := preload("res://resources/oak.tres")
const CANOPY_TREES := preload("res://resources/canopy_trees.tres")
const SURFACE_ROCKS := preload("res://resources/surface_rocks.tres")
const SHRUBS := preload("res://resources/shrubs.tres")
const WETLAND_PLANTS := preload("res://resources/wetland_plants.tres")
## Phase 10 shores / river mouths: shells, beach grass, mud flats.
const SHORE_FEATURES := preload("res://resources/shore_features.tres")
## Phase 11 succession: snags, logs and mushrooms on scars that were wooded,
## and pioneer grass/herbs recolonizing them.
const DEADWOOD := preload("res://resources/deadwood.tres")
const PIONEER_PLANTS := preload("res://resources/pioneer_plants.tres")
## Cacti in hot deserts, sagebrush in the cold Barrens.
const DESERT_PLANTS := preload("res://resources/desert_plants.tres")
## Phase 12: meadow grass, herbs and wildflowers on established ground.
const GROUND_COVER := preload("res://resources/ground_cover.tres")
## Phase 9 step 2: placed outcrops where an ore deposit is exposed.
const ORE_OUTCROPS := preload("res://resources/ore_outcrops.tres")
const FARMLAND := preload("res://resources/farmland.tres")

## Render-method views swap what colour a chunk's base image is built from
## - cheap, one Sprite2D per chunk, no extra layer. Label views additionally
## draw a label overlay, since text can't be baked into a flat pixel image.
enum ViewMode {
	MATERIAL,
	BASE_BIOME,
	SUBTYPE,
	MODIFIERS,
	TEMPERATURE,
	MOISTURE,
	TEMP_VARIATION,
	PRECIP_SEASONALITY,
	DRAINAGE,
	DISTURBANCE_AGE,
	DISTURBANCE_TYPE,
	FUEL_LOAD,
	FIRE_RISK,
	CAVE_POTENTIAL,
	CLIFF_TENDENCY,
	RESOURCE_SUITABILITY_OAK,
	RESOURCE_DENSITY_OAK,
	RESOURCE_PLACEMENT_OAK,
	TREE_COVER,
	TREE_PLACEMENT,
	RESOURCES,
	ROCK_PLACEMENT,
	BERRY_PLACEMENT,
	ROCK_EXPOSURE,
	DEPOSITS,
	WETLAND_PLACEMENT,
	FARMING_POTENTIAL,
	SHORE_PLACEMENT,
	SUCCESSION,
	SUCCESSION_PLACEMENT,
	SHADE,
	QUALITY,
	DEBUG_SUITABILITY,
	DEBUG_DENSITY,
	DEBUG_PATCH,
	DEBUG_PLACEMENT,
}

const CIRCLE := ResourceMarkerChunkScript.Shape.CIRCLE
const HEXAGON := ResourceMarkerChunkScript.Shape.HEXAGON

## One entry per view. Keys, all optional:
## - label: its name in the view dropdown ("" or absent = not listed; the
##   dropdown lists them in this table's order, the first being the
##   default view).
## - color: what its base image shows over the terrain, blended
##   (absent = the terrain itself): ["heat", <HeatmapColorizer function of
##   the tile sample>], ["suitability", definition], ["resource_density",
##   definition], ["guild_density", guild], ["shade"], ["deposits"], or
##   ["debug", "score" | "density" | "patch"] for the debug resource.
## - layers: the placement layers it draws, [source, marker shape(, shape
##   for members without a sprite when drawing SPRITE)] in draw order, or
##   "world" (WorldContent's World-view layers) or "debug" (the debug
##   resource's guild). Placement views keep the matching density heatmap as
##   their base image, so each marker can be read against the field it was
##   drawn from.
## - tinted: a gameplay view - day/night tint, clouds, particles, and tile
##   codes for the terrain shader.
## - label_view: draws the biome label overlay.
## - debug: a Debug view of the debug resource (resource dropdown and the
##   inspector's breakdown).
const VIEWS := {
	ViewMode.RESOURCES: {"label": "World", "tinted": true, "layers": "world"},
	ViewMode.MATERIAL: {"label": "Terrain Only", "tinted": true},
	ViewMode.DEPOSITS: {"label": "Deposits", "color": ["deposits"], "layers": [[ORE_OUTCROPS, HEXAGON]]},
	ViewMode.QUALITY: {"label": "Quality", "layers": [[ORE_OUTCROPS, HEXAGON], [CANOPY_TREES, CIRCLE], [SHRUBS, CIRCLE]]},
	ViewMode.DEBUG_SUITABILITY: {"label": "Debug: Suitability", "debug": true, "color": ["debug", "score"]},
	ViewMode.DEBUG_DENSITY: {"label": "Debug: Density", "debug": true, "color": ["debug", "density"]},
	ViewMode.DEBUG_PATCH: {"label": "Debug: Patch Noise", "debug": true, "color": ["debug", "patch"]},
	ViewMode.DEBUG_PLACEMENT: {"label": "Debug: Placement", "debug": true, "color": ["debug", "density"], "layers": "debug"},
	ViewMode.FARMING_POTENTIAL: {"label": "Farming Potential", "color": ["suitability", FARMLAND]},
	ViewMode.SUBTYPE: {"label": "Subtype", "label_view": true},
	ViewMode.MODIFIERS: {"label": "Modifiers", "label_view": true},
	ViewMode.TEMPERATURE: {"label": "Temperature", "color": ["heat", "temperature"]},
	ViewMode.MOISTURE: {"label": "Moisture", "color": ["heat", "moisture"]},
	ViewMode.TEMP_VARIATION: {"label": "Temp Variation", "color": ["heat", "temp_variation"]},
	ViewMode.PRECIP_SEASONALITY: {"label": "Precip Seasonality", "color": ["heat", "precip_seasonality"]},
	ViewMode.DRAINAGE: {"label": "Drainage", "color": ["heat", "drainage"]},
	ViewMode.DISTURBANCE_AGE: {"label": "Disturbance Age", "color": ["heat", "disturbance_age"]},
	ViewMode.DISTURBANCE_TYPE: {"label": "Disturbance Type", "color": ["heat", "disturbance_type"]},
	ViewMode.SUCCESSION: {"label": "Succession", "color": ["heat", "succession"]},
	ViewMode.SHADE: {"label": "Shade", "color": ["shade"], "layers": [[GROUND_COVER, CIRCLE], [DEADWOOD, CIRCLE], [SHRUBS, CIRCLE]]},
	ViewMode.FUEL_LOAD: {"label": "Fuel Load", "color": ["heat", "fuel_load"]},
	ViewMode.FIRE_RISK: {"label": "Fire Risk", "color": ["heat", "fire_risk"]},
	ViewMode.CAVE_POTENTIAL: {"label": "Cave Potential", "color": ["heat", "cave_potential"]},
	ViewMode.CLIFF_TENDENCY: {"label": "Cliff Tendency", "color": ["heat", "cliff_tendency"]},
	ViewMode.ROCK_EXPOSURE: {"label": "Rock Exposure", "color": ["heat", "rock_exposure"]},
	# Not in the dropdown. Base Biome is reachable with the "B" key
	# (ChunkManager.toggle_biome_overlay); the inspector covers per-tile
	# biome info. The per-resource views are kept for tests and for
	# re-listing while tuning a resource: World shows every placed object,
	# and clicking one names it in the inspector.
	ViewMode.BASE_BIOME: {"label_view": true},
	ViewMode.RESOURCE_SUITABILITY_OAK: {"color": ["suitability", OAK_RESOURCE]},
	ViewMode.RESOURCE_DENSITY_OAK: {"color": ["resource_density", OAK_RESOURCE]},
	ViewMode.RESOURCE_PLACEMENT_OAK: {"color": ["resource_density", OAK_RESOURCE], "layers": [[OAK_RESOURCE, CIRCLE]]},
	ViewMode.TREE_COVER: {"color": ["guild_density", CANOPY_TREES]},
	ViewMode.TREE_PLACEMENT: {"color": ["guild_density", CANOPY_TREES], "layers": [[CANOPY_TREES, CIRCLE]]},
	ViewMode.ROCK_PLACEMENT: {"color": ["guild_density", SURFACE_ROCKS], "layers": [[SURFACE_ROCKS, CIRCLE]]},
	ViewMode.BERRY_PLACEMENT: {"color": ["guild_density", SHRUBS], "layers": [[SHRUBS, CIRCLE]]},
	ViewMode.WETLAND_PLACEMENT: {"color": ["guild_density", WETLAND_PLANTS], "layers": [[WETLAND_PLANTS, CIRCLE]]},
	ViewMode.SHORE_PLACEMENT: {"color": ["guild_density", SHORE_FEATURES], "layers": [[SHORE_FEATURES, CIRCLE]]},
	ViewMode.SUCCESSION_PLACEMENT: {"color": ["heat", "succession"], "layers": [[DEADWOOD, CIRCLE], [PIONEER_PLANTS, CIRCLE]]},
}


## The dropdown's views, in order: [{label, mode}].
static func listed() -> Array:
	var items := []
	for mode in VIEWS:
		if VIEWS[mode].get("label", "") != "":
			items.append({"label": VIEWS[mode]["label"], "mode": mode})
	return items


static func color(mode: ViewMode) -> Array:
	return VIEWS[mode].get("color", [])


## The view's placement layers (a copy), or "world" / "debug" for
## ChunkManager to resolve; [] = no placement markers.
static func layers(mode: ViewMode) -> Variant:
	var layers: Variant = VIEWS[mode].get("layers", [])
	return layers.duplicate(true) if layers is Array else layers


static func is_tinted(mode: ViewMode) -> bool:
	return VIEWS[mode].get("tinted", false)


static func is_label_view(mode: ViewMode) -> bool:
	return VIEWS[mode].get("label_view", false)


static func is_debug(mode: ViewMode) -> bool:
	return VIEWS[mode].get("debug", false)
