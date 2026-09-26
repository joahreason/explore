extends Node2D

## Infinite chunk-based procedural world, deterministic per world_seed.
## Rendering here is a debug visualization only (flat colored tiles per
## WorldGen field sample) - the art tileset is intentionally not used yet;
## see scripts/world_gen.gd and scripts/terrain_surface.gd for the actual
## generation/coloring logic. This file just handles chunk streaming.
##
## Phase 17 streaming: a chunk's content (image, markers, labels) is built by
## a job, nearest chunk first, and shown by the main thread a few per frame,
## so crossing a chunk boundary never stalls a frame on a whole row of
## chunks. On desktop the jobs run on one worker thread; where threads are
## unavailable (the web export has thread_support off) they run on the main
## thread, a few small steps per frame (INLINE_BUDGET_USEC). Threading rule: everything
## generation touches - _world_gen (and its water topology cache), the
## generation caches, _view_mode, ResourceManager's static noise caches,
## ResourceDefinition.curve_plan - is only used while holding _gen_mutex
## (held per job step), and the scene tree only on the main
## thread. Tests that call generation functions directly do it after
## flush_chunk_work(), which leaves the worker idle.

const TerrainSurfaceScript := preload("res://scripts/terrain_surface.gd")
const HeatmapColorizerScript := preload("res://scripts/heatmap_colorizer.gd")
const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")
const BiomeOverlayChunkScript := preload("res://scripts/biome_overlay_chunk.gd")
const EnvironmentalStateScript := preload("res://scripts/environmental_state.gd")
const ResourceManagerScript := preload("res://scripts/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resource_placement.gd")
const GameConstants := preload("res://scripts/game_constants.gd")
const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")
const BiomeFinderScript := preload("res://scripts/biome_finder.gd")
const StructureSitesScript := preload("res://scripts/structure_sites.gd")
const ResourceInstanceScript := preload("res://scripts/resource_instance.gd")
const WorldChangesScript := preload("res://scripts/world_changes.gd")
const GameClockScript := preload("res://scripts/game_clock.gd")
const WindScript := preload("res://scripts/wind.gd")
const HarvestEffectScript := preload("res://scripts/harvest_effect.gd")
const TentSleepEffectScript := preload("res://scripts/tent_sleep_effect.gd")
## One material for every marker node: resource sprites sway in the wind by
## their sway value (see _marker_colors()); other draws are unaffected.
const SWAY_SHADER := preload("res://shaders/sway.gdshader")
## Cast shadows under sprites (their silhouettes, thrown by the sun or moon
## - SunShadow - and swaying with them); one material for every chunk.
const CAST_SHADOW_SHADER := preload("res://shaders/cast_shadow.gdshader")
const SunShadowScript := preload("res://scripts/sun_shadow.gd")
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
## Phase 9 ore deposits (and Phase 10 clay): per-tile fields (exists /
## exposed) - see ResourceManager.get_deposit_potential(); ORE_OUTCROPS
## places the exposed part.
const ORE_DEPOSITS := [
	preload("res://resources/iron.tres"),
	preload("res://resources/copper.tres"),
	preload("res://resources/coal.tres"),
	preload("res://resources/clay.tres"),
	preload("res://resources/salt.tres"),
]
## Phase 10 floodplains: a suitability field only (Farming Potential view,
## inspector), nothing placed.
const FARMLAND := preload("res://resources/farmland.tres")
## Guilds sharing the ground, in collision priority order (Phase 8 step 5):
## ore outcrops and rocks are geology and were there first, then trees,
## then wetland plants (Phase 10) that own the wet margins, then shore
## features (shells, beach grass, mud flats), then deadwood left by the
## disturbance (Phase 11), the shrubs that fill in around all of them, then
## cacti on dry ground, and last the pioneer plants and ground cover (Phase
## 12) on what open ground remains.
const GUILD_STACK := [ORE_OUTCROPS, SURFACE_ROCKS, CANOPY_TREES, WETLAND_PLANTS, SHORE_FEATURES, DEADWOOD, SHRUBS, DESERT_PLANTS, PIONEER_PLANTS, GROUND_COVER]

const TILE_SIZE := GameConstants.TILE_SIZE  # world pixels per tile (scripts/game_constants.gd)
const CHUNK_SIZE := 16         # tiles per chunk edge
const MIN_LOAD_RADIUS := 4     # floor on load radius even when zoomed in
const UNLOAD_BUFFER := 2       # extra chunks beyond load radius before freeing (hysteresis)

## LOD: at low zoom, sample each chunk on a coarser grid (1 sample per
## lod_step^2 tiles instead of per-tile) and let the Sprite2D's scale
## stretch it back to the same world-space footprint - same idea as a
## mipmap. Zoomed out means MORE chunks are needed to cover the screen, not
## fewer, so without this every additional chunk still paid full per-tile
## WorldGen.sample() cost (~30-40 noise calls each after all the biome-
## variety fields) even though individual tiles aren't perceivable at that
## zoom anyway. Steps must evenly divide CHUNK_SIZE.
const LOD_THRESHOLDS := [
	{"zoom": 1.0, "step": 1},
	{"zoom": 0.5, "step": 2},
	{"zoom": 0.25, "step": 4},
	{"zoom": 0.0, "step": 8},
]

## Phase 17: how many chunks of per-tile EnvironmentalState + classify_full()
## results _tile_env() keeps (FIFO). Placing one chunk's guild stack reads
## tiles up to about one chunk around it, and chunks are processed nearest
## first, ring by ring, so a few rings of the loaded area catch nearly every
## reuse. One tile
## costs ~5 KB (state ~3 KB, classification ~2 KB), so the whole ~121-chunk
## footprint of the Resources view (~150 MB) is deliberately not kept.
const ENV_CACHE_CHUNKS := 48

## Placed-instance markers are skipped at coarser LOD steps than this: a
## marker would be a pixel or two wide, and zoomed out is exactly when the
## most chunks are loaded (placement costs ~7ms/chunk for oak).
const MAX_PLACEMENT_LOD_STEP := 2

## Without a worker thread: time per frame spent on chunk job steps on the
## main thread (at least one step per frame while any are queued).
const INLINE_BUDGET_USEC := 5000
## Review W1: main-thread time per frame for a "Go to" search without threads.
const TRAVEL_BUDGET_USEC := 4000
## Pixel rows a chunk job bakes per step (see _chunk_job_steps). 2 since
## Phase 13.5: choosing each tile's ground costs ~50 us, so a 4-row band was
## ~4.5 ms on desktop - too big a step for the web fallback.
const IMAGE_BAND_ROWS := 2
## Tile rows per density-warming step ahead of a guild's chunk placement in
## the no-thread fallback (_warm_guild_density): 4 bands per chunk.
const WARM_DENSITY_ROWS := 4
## Polish pass 2: tile codes in the gameplay views' chunk images (alpha,
## out of 255) that shaders/terrain.gdshader reads - water shimmers, grass
## ground takes the season's tint - and the ground materials that count as
## grass. Water codes run WATER_CODE_ICE..WATER_CODE for how liquid it is
## (0..1); solid ice carries no code and stays still. Surf is for the coast
## only (ocean and sea, not lakes or rivers): shallow open sea near the
## coast carries SHALLOW_CODE + 0..7 (shallower = higher) for whitecaps,
## open sea on the shoreline FOAM_CODE + a shore shape, and any ground on a
## sea shore WASH_CODE (WASH_GRASS_CODE for grass, which also takes the
## season's tint) + a shore shape - surf foam and swash. A shape (_shore_shape()) is 1 + the index in
## SHORE_SHAPES of the mask of neighbours across the shoreline: edges 1 -x,
## 2 +x, 4 -y, 8 +y and diagonal corners 16 (-x,-y), 32 (+x,-y), 64 (-x,+y),
## 128 (+x,+y), a corner only when neither edge beside it is set (it would
## be covered) - 46 shapes, mirrored in shaders/terrain.gdshader.
const FOAM_CODE := 50
const WASH_CODE := 100
const WASH_GRASS_CODE := 150
const WATER_CODE_ICE := 200
const WATER_CODE := 220
const SHALLOW_CODE := 240
const GRASS_CODE := 253
const SHORE_SHAPES := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 24, 26, 32, 33, 40, 41, 48, 56, 64, 66, 68, 70, 80, 82, 96, 112, 128, 129, 132, 133, 144, 160, 161, 176, 192, 196, 208, 224, 240]
## Neighbour steps for the mask bits, and the edge bits beside each corner.
const SHORE_STEPS := [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
const CORNER_EDGES := [1 | 4, 2 | 4, 1 | 8, 2 | 8]
## Only tiles this close to sea level can border the shoreline (elevation
## changes by under 0.01 per tile) - a cheap gate before _shore_shape().
## Sea shallower than SHALLOW_DEPTH gets whitecaps.
const SHORE_ELEVATION_MARGIN := 0.03
const SEA_BODIES := ["ocean", "sea"]
const SHALLOW_DEPTH := 0.008
const GRASS_GROUND := ["grass", "dry_grass"]
const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const SeasonsScript := preload("res://scripts/seasons.gd")
## Seconds a newly streamed-in chunk takes to fade in.
const FADE_IN_SEC := 0.2
## Time per frame spent turning finished chunk jobs into nodes (at least one).
const APPLY_BUDGET_USEC := 3000

## Render-method views swap what color a chunk's base image is built from
## (see _color_for) - cheap, one Sprite2D per chunk, no extra layer.
## BASE_BIOME and SUBTYPE additionally draw a label overlay, since text can't
## be baked into a flat pixel image (see _is_label_view). Keep in sync with
## view_mode_dropdown.gd.
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

## Assign a saved WorldGen.tres preset here to tune generation in the
## Inspector; if left empty a default-tuned WorldGen is created at runtime.
@export var world_gen_params: WorldGen
@export var world_seed: int = 1337
@export var target_path: NodePath
## The player (scripts/player.gd): taps walk it (see _on_map_tapped()), its
## position is saved per seed, biome travel moves it.
@export var player_path: NodePath
## Generate chunks on a worker thread where threads exist; off = always on
## the main thread (the web fallback), e.g. for debugging.
@export var threaded_generation: bool = true
## Phase 16: where each seed's gameplay changes are saved
## ("<dir>/<seed>.json"; user:// is the browser's persistent storage on web).
## Under a test harness (a scripted SceneTree, tests/*.gd) the default is
## NOT used - changes stay in memory - so tests never read or overwrite a
## player's saved harvests; a test that wants a file sets its own dir.
const DEFAULT_CHANGES_DIR := "user://world_changes"
@export var changes_dir: String = DEFAULT_CHANGES_DIR

@onready var chunks_root: Node2D = $Chunks
@onready var overlay_root: Node2D = $Overlay
@onready var resources_root: Node2D = $Resources
## Every chunk's cast shadows, drawn under all resource sprites.
@onready var shadows_root: Node2D = $ShadowLayer
@onready var _inspector_panel := $UI/TileInspector
@onready var _seed_input: LineEdit = $UI/SeedInput

var _target: Node2D
var _player: Node2D
## Tile -> whether the player can stand there (not open water; frozen water
## is walkable). Filled for free wherever a chunk image is baked tile by
## tile, else sampled on demand (is_walkable()); guarded by _gen_mutex.
var _walkable: Dictionary = {}
## Chunk -> the shown image padded with a 1-texel border (_padded_image()):
## the border holds the loaded neighbours' edge tiles (_share_borders()), so
## terrain.gdshader can blend ground across chunk borders.
var _chunk_images: Dictionary = {}
var _world_gen: WorldGen
## Landmark layer: sites for the current seed (StructureSites, which caches
## them per cell; used under _gen_mutex like _world_gen).
var _structures: StructureSites
## Sleeping in a camp tent (enter_tent()): the tent's tile while the player
## is inside (null otherwise), and the bouncing tent standing in for its
## marker, which _marker_node() leaves out.
var _tent_tile: Variant = null
var _tent_effect: Node2D
var _seed_text: String = ""  # raw seed text in effect, shown in _seed_input
var _loaded_chunks: Dictionary = {}   # Vector2i chunk -> Sprite2D
var _loaded_overlays: Dictionary = {} # Vector2i chunk -> Node2D (biome overlay), only in a label view
var _loaded_placements: Dictionary = {} # Vector2i chunk -> Node2D (resource markers), only in a placement view
var _raw_guild_chunks: Dictionary = {} # [guild id, chunk] -> that guild's raw placement in the chunk (see _raw_guild_in_rect)
var _env_chunks: Dictionary = {} # chunk -> [states, classifications], per tile (see _tile_env)
var _density_chunks: Dictionary = {} # guild/resource id -> {chunk -> PackedFloat64Array per tile} (see _density_memo)
var _definitions: Dictionary = {} # instance id -> ResourceDefinition (see _definitions_by_id)
## Phase 16: the player's changes to generated objects (harvested ones),
## for the current seed - written on the main thread under _gen_mutex, read
## by generation under it and by marker building on the main thread.
var _changes = WorldChangesScript.new()
## In-game time (GameClock), advanced every frame, saved with _changes;
## DayNight tints the world by it and the clock label shows it.
var clock = GameClockScript.new()
const CLOCK_SAVE_MSEC := 10000
var wind = WindScript.new()
var sway_material := ShaderMaterial.new()
var shadow_material := ShaderMaterial.new()
var terrain_material := ShaderMaterial.new()
## Polish pass 2: the in-game day the sprites' season colours were last
## drawn for; markers are redrawn when it changes (_update_seasons()).
var _season_day: int = -1
var _last_clock_save_msec: int = -CLOCK_SAVE_MSEC
var _chunk_placements: Dictionary = {} # Vector2i chunk -> its shown _placement_chunk() data, to redraw markers after a change
## Phase 18: the resource the Debug views show (a GUILD_STACK member; read
## by generation under _gen_mutex), and member id -> its guild.
var _debug_resource: ResourceDefinition = OAK_RESOURCE
var _guild_of_member: Dictionary = {}
## Phase 13.5: the default "live game" view is the terrain with every placed
## resource on it (RESOURCES); MATERIAL is the bare terrain.
var _view_mode: ViewMode = ViewMode.RESOURCES
var _sprite_images: Dictionary = {}  # sprite_texture -> its Image, for _sprite_covers()
var _last_center: Vector2i = Vector2i(1 << 30, 1 << 30)  # force first update
var _last_load_radius: int = -1
var _last_lod_step: int = -1

# Chunk jobs (see the streaming note at the top). _epoch is bumped by a view
# or LOD change; a loaded chunk whose _shown_epoch differs is stale and gets
# rebuilt. Only the main thread writes _epoch (under _queue_mutex).
var _epoch: int = 0
var _shown_epoch: Dictionary = {}   # Vector2i chunk -> epoch its content was built for
var _jobs_dirty: bool = false       # rebuild the job list on the next _refresh_streaming()
var _jobs: Array = []               # [chunk, epoch, lod step, area], nearest last (popped from the back)
var _in_flight: Dictionary = {}     # chunk -> epoch of a job taken but not yet applied
var _results: Array = []            # finished job data for the main thread
var _ready_results: Array = []      # main thread: taken from _results, not yet applied
var _inline_job: Dictionary = {}     # main thread without a worker: the job being stepped (see _run_inline_steps)
var _queue_mutex := Mutex.new()     # guards _jobs, _in_flight, _results, _epoch writes, _stop_worker
var _gen_mutex := Mutex.new()       # held while generating
var _semaphore := Semaphore.new()
var _worker: Thread
var _stop_worker: bool = false
## Chunks in play (the load square) as of the job being generated - bounds
## the generation caches without reading _loaded_chunks off the main thread.
var _gen_area: int = (2 * MIN_LOAD_RADIUS + 1) * (2 * MIN_LOAD_RADIUS + 1)

## "Go to biome" (travel_to_biome): searches run on their own thread with
## their own WorldGen copy, so they share nothing with chunk generation.
signal biome_travel_finished(biome: String, found: bool, cancelled: bool)
var _finder_gen: WorldGen
var _finder_thread: Thread
var _finder_biome: String = ""
var _finder_seed: int = 0
var _finder_result: Variant = null  # written by the search thread, read after it finishes
var _finder_search: RefCounted  # a search stepped from _process() where there's no thread (web)
var _finder_cancel: bool = false
var _finder_sites: StructureSites  # the search thread's own sites (on _finder_gen), kept while the seed stays
var _travel_visited: Dictionary = {}  # biome -> tiles already traveled to (BiomeFinder's avoid list)


func _ready() -> void:
	sway_material.shader = SWAY_SHADER
	shadow_material.shader = CAST_SHADOW_SHADER
	terrain_material.shader = TERRAIN_SHADER
	for material in [sway_material, shadow_material, terrain_material]:
		GameConstants.apply_to(material)
	world_seed = _resolve_world_seed()
	_world_gen = world_gen_params if world_gen_params != null else WorldGen.new()
	_world_gen.configure(world_seed)
	_structures = StructureSitesScript.new(_world_gen, world_seed)
	if player_path != NodePath():
		_player = get_node(player_path)
		_player.set_shadow_material(shadow_material, shadows_root)
	_load_gameplay_state()

	# A guild's warnings include its members' (oak among them).
	for source in GUILD_STACK + ORE_DEPOSITS + [FARMLAND]:
		for warning in source.get_curve_domain_warnings():
			push_warning(warning)

	if _seed_text != "":
		_seed_input.text = _seed_text

	if target_path != NodePath():
		_target = get_node(target_path)
		_target.connect("info_clicked", _on_tile_clicked)
		_target.connect("map_tapped", _on_map_tapped)
		if _target.has_method("snap_to_player"):
			_target.snap_to_player()

	if threaded_generation and _threads_available():
		_worker = Thread.new()
		_worker.start(_worker_loop)
	_refresh_streaming()


func _exit_tree() -> void:
	if _finder_thread != null:
		_finder_cancel = true
		_finder_thread.wait_to_finish()
		_finder_thread = null
	if _worker == null:
		return
	_queue_mutex.lock()
	_stop_worker = true
	_queue_mutex.unlock()
	_semaphore.post()
	_worker.wait_to_finish()
	_worker = null


## Web only: a "?seed=" query param overrides the exported world_seed - set
## by ReloadButton/RandomizeButton/SeedInput's Enter from whatever's in the
## seed field (see _seed_from_text). If no param was given at all, a fresh
## random seed is generated instead of falling back to the fixed exported
## default, so every plain visit gets a different world, and written into
## the URL so a refresh keeps it. Elsewhere the
## exported world_seed is used (the seed UI regenerates in place instead -
## see regenerate()). Either way, _seed_text is left holding whatever seed
## ended up in effect, so _ready() can show it in the seed field.
func _resolve_world_seed() -> int:
	if not OS.has_feature("web"):
		_seed_text = str(world_seed)
		return world_seed

	var raw = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('seed') || ''", true
	)
	var raw_str := str(raw) if raw != null else ""
	if raw_str == "":
		raw_str = str(randi())
		# Put it in the URL, so refreshing, bookmarking or sharing the page
		# gives the same world (and its save) - review W6.
		JavaScriptBridge.eval("history.replaceState(null, '', '?seed=%s' + location.hash)" % raw_str.uri_encode())
	_seed_text = raw_str
	return _seed_from_text(raw_str)


## A purely numeric seed is used directly (matches the exported int seed
## behavior everywhere else in this project); anything else (letters/spaces)
## is hashed to a deterministic int, so the same text always regenerates the
## same world.
static func _seed_from_text(text: String) -> int:
	return int(text) if text.is_valid_int() else text.hash()


## Desktop seed UI (SeedInput's Enter, RandomizeButton - via
## SeedReload.apply_seed()): switches to the seed in seed_text in place, empty
## = a fresh random one. Web reloads the page with ?seed= instead. Every
## loaded chunk belongs to the old world, so they are all dropped and stream
## back in nearest first; the per-seed generation caches are dropped too.
func regenerate(seed_text: String) -> void:
	var text := seed_text.strip_edges()
	if text == "":
		text = str(randi())
	_seed_text = text
	_seed_input.text = text
	_inspector_panel.visible = false  # it describes a tile of the old world

	_gen_mutex.lock()  # generation reads world_seed and the caches
	_save_gameplay_state()  # the old seed's time, before switching
	world_seed = _seed_from_text(text)
	_world_gen.configure(world_seed)
	clear_generation_caches()
	_load_gameplay_state()
	_gen_mutex.unlock()

	for c in _loaded_chunks.keys():
		_unload_chunk(c)
	_invalidate_chunks()
	_finder_cancel = true  # a running search is looking at the old world
	_travel_visited.clear()
	if _target and _target.has_method("snap_to_player"):
		_target.snap_to_player()


func _threads_available() -> bool:
	return not OS.has_feature("web") or OS.has_feature("threads")


## Biome travel dropdown: moves the camera to the nearest tile of `biome`
## (a BiomeClassifier base biome name) - or, if the camera already stands in
## that biome, to the nearest other patch of it; repeated trips to the same
## biome hop onward (see BiomeFinder). The search can take seconds, so it
## runs on a thread, or without threads (web, threaded_generation off) a
## slice per frame from _process() (TRAVEL_BUDGET_USEC); either way
## biome_travel_finished reports the outcome. Ignored while a search runs;
## cancel_biome_travel() stops one.
func travel_to_biome(biome: String) -> void:
	if is_finding_biome():
		return
	if _finder_gen == null:
		_finder_gen = world_gen_params.duplicate() if world_gen_params != null else WorldGen.new()
	_finder_gen.configure(world_seed)
	_finder_biome = biome
	_finder_seed = world_seed
	_finder_cancel = false
	var pos: Vector2 = _player.tile_center(_player.tile()) if _player else (_target.global_position if _target else Vector2.ZERO)
	var start := Vector2i(floori(pos.x / TILE_SIZE), floori(pos.y / TILE_SIZE))
	var avoid: Array = _travel_visited.get(biome, []).duplicate()
	_finder_result = null
	var search := _new_search(biome, start, avoid)
	if threaded_generation and _threads_available():
		_finder_thread = Thread.new()
		_finder_thread.start(_run_search.bind(search))
	else:
		_finder_search = search


func is_finding_biome() -> bool:
	return _finder_thread != null or _finder_search != null


## Stops a running "Go to" search; biome_travel_finished then reports it
## cancelled.
func cancel_biome_travel() -> void:
	if is_finding_biome():
		_finder_cancel = true


## The search for a travel target, not yet run: BiomeFinder, or for a
## structure's display name (StructureSites.DEFINITIONS) a StructureSites
## search - the nearest site of that type other than one at the start or
## already visited - instead of scanning tiles. Both step() until done.
func _new_search(biome: String, start: Vector2i, avoid: Array) -> RefCounted:
	for def in StructureSitesScript.DEFINITIONS:
		if def.display_name == biome:
			if _finder_sites == null or _finder_sites.world_seed != _finder_seed:
				_finder_sites = StructureSitesScript.new(_finder_gen, _finder_seed)
			return _finder_sites.search(def.id, start, avoid)
	return BiomeFinderScript.new(_finder_gen, biome, start, avoid)


## The search thread: runs `search` to the end unless cancelled.
func _run_search(search: RefCounted) -> void:
	while not search.step(Time.get_ticks_usec() + 20000):
		if _finder_cancel:
			return
	_finder_result = search.result


## Main thread, once the search is done: moves the camera there (chunks
## stream in around it) unless the world changed meanwhile.
func _finish_biome_travel() -> void:
	var cancelled := _finder_cancel or _finder_seed != world_seed
	var found := not cancelled and _finder_result != null
	if found:
		var tile: Vector2i = _finder_result
		if _player:
			teleport_player((Vector2(tile) + Vector2(0.5, 0.5)) * TILE_SIZE)
		elif _target:
			_target.global_position = (Vector2(tile) + Vector2(0.5, 0.5)) * TILE_SIZE
		var visited: Array = _travel_visited.get(_finder_biome, [])
		visited.append(tile)
		_travel_visited[_finder_biome] = visited.slice(-8)
	biome_travel_finished.emit(_finder_biome, found, cancelled)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		toggle_biome_overlay()


## Quick keyboard shortcut: hop between Material and Base Biome. The dropdown
## (view_mode_dropdown.gd) covers the full view list via set_view_mode().
func toggle_biome_overlay() -> void:
	set_view_mode(ViewMode.MATERIAL if _view_mode == ViewMode.BASE_BIOME else ViewMode.BASE_BIOME)


func _is_label_view(mode: ViewMode) -> bool:
	return mode == ViewMode.BASE_BIOME or mode == ViewMode.SUBTYPE or mode == ViewMode.MODIFIERS


## Public entry point for the view-mode dropdown. Rebuilds every currently
## loaded chunk's content in place (swap Sprite2D.texture, replace its label
## overlay and markers) rather than adding a second layer - see plan doc §7
## for why heatmap views are render methods, not overlays. The rebuilds are
## queued nearest first like any chunk job; each chunk shows the old view
## until its own rebuild arrives.
func set_view_mode(mode: ViewMode) -> void:
	if mode == _view_mode:
		return
	# Generation reads _view_mode: wait out the chunk being generated.
	_gen_mutex.lock()
	_view_mode = mode
	_gen_mutex.unlock()
	_invalidate_chunks()


## Without a target (target_path unset) the area around the origin stays
## loaded, as the initial load always did.
func _process(delta: float) -> void:
	var hour_before := floori(clock.minutes / 60.0)
	clock.advance(delta)
	if _tent_tile != null and not clock.sleeping:
		_leave_tent()
	wind.advance(delta, clock.rate())
	wind.apply(sway_material, clock.minutes)
	wind.apply(shadow_material, clock.minutes)
	SunShadowScript.apply(shadow_material, clock.minutes)
	terrain_material.set_shader_parameter("water_phase", wind.phase)
	terrain_material.set_shader_parameter("ground_detail", is_time_tinted_view())
	terrain_material.set_shader_parameter("wave_dir", WindScript.direction_at(clock.minutes))
	var grass: Color = SeasonsScript.tint("grass", SeasonsScript.year_fraction(clock))
	terrain_material.set_shader_parameter("grass_tint", Vector4(grass.r, grass.g, grass.b, grass.a))
	_update_seasons()
	# Save the clock when an in-game hour passes (about once a real minute at
	# normal speed), at most every CLOCK_SAVE_MSEC when fast-forwarding.
	if floori(clock.minutes / 60.0) != hour_before and Time.get_ticks_msec() - _last_clock_save_msec >= CLOCK_SAVE_MSEC:
		_last_clock_save_msec = Time.get_ticks_msec()
		_save_gameplay_state()
	if _finder_thread != null and not _finder_thread.is_alive():
		_finder_thread.wait_to_finish()
		_finder_thread = null
		_finish_biome_travel()
	if _finder_search != null and (_finder_cancel or _finder_search.step(Time.get_ticks_usec() + TRAVEL_BUDGET_USEC)):
		if not _finder_cancel:
			_finder_result = _finder_search.result
		_finder_search = null
		_finish_biome_travel()
	_refresh_streaming()
	if _worker == null:
		_run_inline_steps(Time.get_ticks_usec() + INLINE_BUDGET_USEC)
	_apply_results(APPLY_BUDGET_USEC)


## Keeps the job list in step with the camera: a LOD change makes every
## loaded chunk stale, a new center or radius changes which chunks are wanted.
func _refresh_streaming() -> void:
	var lod_step := _current_lod_step()
	if lod_step != _last_lod_step:
		_last_lod_step = lod_step
		_invalidate_chunks()

	var center := _chunk_of(_target.global_position if _target else Vector2.ZERO)
	var load_radius := _current_load_radius()
	if center == _last_center and load_radius == _last_load_radius and not _jobs_dirty:
		return
	_last_center = center
	_last_load_radius = load_radius
	_update_chunks(center, load_radius)


## View or LOD changed: every loaded chunk is stale. It keeps showing its old
## content until its rebuild (queued with the missing chunks) replaces it.
func _invalidate_chunks() -> void:
	_queue_mutex.lock()
	_epoch += 1
	_queue_mutex.unlock()
	_jobs_dirty = true


## Tests and benchmarks: finishes every chunk job for the current camera,
## view and LOD now (on this thread, alongside the worker) and applies the
## results, as if enough frames had passed. Afterwards the worker is idle
## until something changes, so generation functions are safe to call.
func flush_chunk_work() -> void:
	while true:
		_refresh_streaming()
		while not _inline_job.is_empty():
			if _step_job(_inline_job):
				_inline_job = {}
		while _run_next_job():
			pass
		_apply_results(-1)
		if not has_pending_chunks():
			return
		OS.delay_usec(200)  # the worker is finishing a chunk


func has_pending_chunks() -> bool:
	_queue_mutex.lock()
	var busy := not (_jobs.is_empty() and _in_flight.is_empty() and _results.is_empty())
	_queue_mutex.unlock()
	return busy or not _ready_results.is_empty() or not _inline_job.is_empty() or _jobs_dirty


func _current_zoom() -> float:
	var cam := get_viewport().get_camera_2d()
	return cam.zoom.x if cam else 4.0


## Enough chunks to cover the current camera view (whatever its zoom), plus
## a floor so a fully zoomed-in camera still has a comfortable buffer.
func _current_load_radius() -> int:
	var zoom := _current_zoom()
	var viewport_size := get_viewport().get_visible_rect().size
	var half_extent_px := (viewport_size / zoom) * 0.5
	var half_diagonal_px := half_extent_px.length()
	var chunk_px := CHUNK_SIZE * TILE_SIZE
	var needed := ceili(half_diagonal_px / chunk_px) + 1
	return maxi(MIN_LOAD_RADIUS, needed)


func _current_lod_step() -> int:
	var zoom := _current_zoom()
	for entry in LOD_THRESHOLDS:
		if zoom >= entry["zoom"]:
			return entry["step"]
	return 1


func _chunk_of(world_pos: Vector2) -> Vector2i:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	return Vector2i(floori(float(tile.x) / CHUNK_SIZE), floori(float(tile.y) / CHUNK_SIZE))


## Driven by CameraRig's "info_clicked" signal (a right click / long press) - samples the single clicked tile fresh (bypassing the topology
## cache is unnecessary here, it's one tile) and hands the full sample +
## classification to the inspector panel, plus the placed resource (if
## any) under the exact click point.
func _on_tile_clicked(world_pos: Vector2) -> void:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	_gen_mutex.lock()  # the worker may be generating a chunk
	var sample := _world_gen.sample(tile.x, tile.y)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	var deposits := {}
	var state = EnvironmentalStateScript.from_sample(sample)
	var potentials := _deposit_potentials(sample, tile.x, tile.y)
	for ore in potentials:
		deposits[String(ore.id).capitalize()] = Vector2(potentials[ore], ResourceManagerScript.get_exposure(state, ore))
	var farming: float = ResourceManagerScript.get_suitability(state, FARMLAND, classified)
	var shade: float = ResourceManagerScript.get_shade(state, world_seed, tile.x, tile.y, classified)
	var resource := _resource_at(world_pos / TILE_SIZE)
	var ground := _surface_at(sample, tile.x, tile.y)
	var structure := _structures.site_at(tile)
	var debug_lines: Array = []
	if is_debug_view():
		debug_lines = debug_breakdown(tile.x, tile.y)
	_gen_mutex.unlock()
	_inspector_panel.show_info(tile, sample, classified, resource, deposits, farming, shade, ground.display_name if ground != null else "", debug_lines, structure)


## Unloads chunks beyond load_radius + UNLOAD_BUFFER (hysteresis) and queues
## a job for every chunk within load_radius that is missing or stale, nearest
## first. A chunk whose job for the current epoch is already running isn't
## queued again.
func _update_chunks(center: Vector2i, load_radius: int) -> void:
	_jobs_dirty = false
	var unload_radius := load_radius + UNLOAD_BUFFER
	for c in _loaded_chunks.keys():
		if Vector2(c - center).length() > unload_radius:
			_unload_chunk(c)

	var wanted: Array[Vector2i] = []
	for cy in range(center.y - load_radius, center.y + load_radius + 1):
		for cx in range(center.x - load_radius, center.x + load_radius + 1):
			var c := Vector2i(cx, cy)
			if _shown_epoch.get(c, -1) != _epoch:
				wanted.append(c)
	wanted.sort_custom(_farther_first.bind(center))
	var area := (2 * load_radius + 1) * (2 * load_radius + 1)

	_queue_mutex.lock()
	_jobs.clear()
	for c in wanted:
		if _in_flight.get(c, -1) != _epoch:
			_jobs.append([c, _epoch, _last_lod_step, area])
	var has_jobs := not _jobs.is_empty()
	_queue_mutex.unlock()
	if has_jobs and _worker != null:
		_semaphore.post()


## Job order: farthest from center first (jobs are popped from the back), ties
## by position so the order is deterministic.
static func _farther_first(a: Vector2i, b: Vector2i, center: Vector2i) -> bool:
	var da := (a - center).length_squared()
	var db := (b - center).length_squared()
	if da != db:
		return da > db
	return a.y > b.y or (a.y == b.y and a.x > b.x)


## Takes the nearest queued chunk and runs its whole job (every step),
## leaving the data in _results for _apply_results() - the worker's and
## flush_chunk_work()'s way. Returns false when there was nothing to take
## (or the worker is stopping).
func _run_next_job() -> bool:
	var job := _take_job()
	if job.is_empty():
		return false
	var state := _new_job_state(job, false)
	while not _step_job(state):
		pass
	return true


## Main thread without a worker: runs job steps (taking new jobs as needed)
## until the deadline - at least one step, so a frame spends at most about
## one step past its budget.
func _run_inline_steps(deadline: int) -> void:
	while true:
		if _inline_job.is_empty():
			var job := _take_job()
			if job.is_empty():
				return
			_inline_job = _new_job_state(job, true)
		if _step_job(_inline_job):
			_inline_job = {}
		if Time.get_ticks_usec() >= deadline:
			return


## Pops the nearest queued job for the current epoch and marks it in flight
## (jobs queued before a view/LOD change are dropped - their rebuild is
## queued too); [] if there is none, or the worker is stopping.
func _take_job() -> Array:
	var job: Array = []
	_queue_mutex.lock()
	while not _jobs.is_empty() and not _stop_worker:
		var candidate: Array = _jobs.pop_back()
		if candidate[1] == _epoch:
			_in_flight[candidate[0]] = candidate[1]
			job = candidate
			break
	_queue_mutex.unlock()
	return job


## A taken job ([chunk, epoch, lod step, area]) about to run: its data (filled
## by the steps) and step list (planned by the first _step_job(); fine =
## the main-thread fallback's finer steps, see _chunk_job_steps).
func _new_job_state(job: Array, fine: bool) -> Dictionary:
	var data := {"chunk": job[0], "epoch": job[1], "lod": job[2], "area": job[3], "image": _new_chunk_image(job[2])}
	return {"data": data, "steps": [], "planned": false, "next": 0, "fine": fine}


## Runs one step of a job (holding _gen_mutex). Returns true when the job
## is over: finished, with its data queued in _results, or abandoned because
## a view/LOD/seed change made it stale (its rebuild is queued already).
func _step_job(state: Dictionary) -> bool:
	var data: Dictionary = state["data"]
	_queue_mutex.lock()
	var stale: bool = data["epoch"] != _epoch
	_queue_mutex.unlock()
	if not stale:
		_gen_mutex.lock()
		_gen_area = data["area"]
		if not state["planned"]:
			state["steps"] = _chunk_job_steps(data, state["fine"])
			state["planned"] = true
		var steps: Array = state["steps"]
		if state["next"] < steps.size():
			(steps[state["next"]] as Callable).call()
			state["next"] += 1
		_gen_mutex.unlock()
		if state["next"] < steps.size():
			return false

	_queue_mutex.lock()
	if stale:
		if _in_flight.get(data["chunk"], -1) == data["epoch"]:
			_in_flight.erase(data["chunk"])
	else:
		_results.append(data)
	_queue_mutex.unlock()
	return true


func _worker_loop() -> void:
	while true:
		_semaphore.wait()
		_queue_mutex.lock()
		var stop := _stop_worker
		_queue_mutex.unlock()
		if stop:
			return
		while _run_next_job():
			pass


## Main thread: shows finished jobs until budget_usec is spent (at least one;
## negative = no limit). A result built for an older view/LOD, or for a chunk
## that has since left the unload radius, is dropped.
func _apply_results(budget_usec: int) -> void:
	_queue_mutex.lock()
	_ready_results.append_array(_results)
	_results.clear()
	_queue_mutex.unlock()

	var deadline := Time.get_ticks_usec() + budget_usec
	var i := 0
	while i < _ready_results.size():
		var data: Dictionary = _ready_results[i]
		i += 1
		var chunk_coord: Vector2i = data["chunk"]
		_queue_mutex.lock()
		if _in_flight.get(chunk_coord, -1) == data["epoch"]:
			_in_flight.erase(chunk_coord)
		_queue_mutex.unlock()
		if data["epoch"] != _epoch or Vector2(chunk_coord - _last_center).length() > _last_load_radius + UNLOAD_BUFFER:
			continue
		_apply_chunk_data(data)
		if budget_usec >= 0 and Time.get_ticks_usec() >= deadline:
			break
	_ready_results = _ready_results.slice(i)


## Heatmap views are blended on top of the terrain (Phase 13.5) rather than
## replacing it outright, so the terrain stays visible as context for how
## each field actually affects generation (e.g. you can still see the
## coastline/vegetation under a temperature heatmap instead of losing it).
const HEATMAP_OVERLAY_STRENGTH := 0.65

## Picks the color function for the current view mode. BASE_BIOME has no
## dedicated per-tile color of its own - it keeps the terrain as its base
## image and relies entirely on the drawn label overlay on top.
func _color_for(sample: Dictionary, wx: int, wy: int) -> Color:
	var heatmap_color: Variant = _heatmap_color_for(sample, wx, wy)
	if heatmap_color == null:
		return _terrain_color(sample, wx, wy)
	var blended := _terrain_color(sample, wx, wy).lerp(heatmap_color, HEATMAP_OVERLAY_STRENGTH)
	blended.a = 1.0
	return blended


## Phase 13.5: a tile's terrain colour - its water body, or its ground
## material (TerrainSurface) coloured by its fields.
func _terrain_color(sample: Dictionary, wx: int, wy: int) -> Color:
	var coded := is_time_tinted_view()
	var water: Variant = TerrainSurfaceScript.water_color(sample)
	if water != null:
		var w: Color = water
		var liquid := TerrainSurfaceScript.water_liquid(sample)
		# Frozen water gets no code: no waves, no glints.
		if coded and liquid > 0.0:
			w.a = (WATER_CODE_ICE + roundf(liquid * (WATER_CODE - WATER_CODE_ICE))) / 255.0
			var depth: float = _world_gen.sea_level - sample["elevation"]
			if liquid >= 1.0 and depth < SHORE_ELEVATION_MARGIN and SEA_BODIES.has(sample["water_body"]):
				var shape := _shore_shape(wx, wy, true)
				if shape > 0:
					w.a = (FOAM_CODE + shape) / 255.0
				elif depth < SHALLOW_DEPTH:
					w.a = (SHALLOW_CODE + roundi(7.0 * (1.0 - depth / SHALLOW_DEPTH))) / 255.0
		return w
	var state := _surface_state(sample, wx, wy)
	var material := TerrainSurfaceScript.material_at(state, world_seed, wx, wy)
	var color := TerrainSurfaceScript.color_for(material, state, world_seed, wx, wy)
	if not coded:
		return color
	var grass := GRASS_GROUND.has(material.id)
	if grass:
		color.a = GRASS_CODE / 255.0
	# A sea shore: near sea level, facing salt water (not a lake), not frozen.
	if sample["elevation"] < _world_gen.sea_level + SHORE_ELEVATION_MARGIN and sample["shore_salinity"] > 0.0 and TerrainSurfaceScript.shore_liquid(sample) >= 1.0:
		var shape := _shore_shape(wx, wy, false)
		if shape > 0:
			color.a = ((WASH_GRASS_CODE if grass else WASH_CODE) + shape) / 255.0
	return color


## The shore shape of a tile (see SHORE_SHAPES), 0 off the shoreline: which
## neighbours lie across the shoreline from it - ground around a water tile
## (`water`), water around a ground tile. Elevation against sea level
## decides it, so it is exact across chunk borders.
func _shore_shape(wx: int, wy: int, water: bool) -> int:
	var mask := 0
	for i in SHORE_STEPS.size():
		if i >= 4 and mask & CORNER_EDGES[i - 4]:
			continue
		var n: Vector2i = SHORE_STEPS[i]
		if (_world_gen.elevation(wx + n.x, wy + n.y) < _world_gen.sea_level) != water:
			mask |= 1 << i
	return SHORE_SHAPES.find(mask) + 1


## The ground material of a tile, or null on a water body (inspector, tests).
func _surface_at(sample: Dictionary, wx: int, wy: int) -> SurfaceMaterial:
	if TerrainSurfaceScript.water_color(sample) != null:
		return null
	return TerrainSurfaceScript.material_at(_surface_state(sample, wx, wy), world_seed, wx, wy)


## A fresh EnvironmentalState for choosing ground, its shade taken from the
## SHADE_LATTICE corners (TerrainSurface.lattice_shade()) - fresh, so the
## interpolated shade never replaces the exact per-tile value placement
## reads from _tile_env()'s cached states.
func _surface_state(sample: Dictionary, wx: int, wy: int) -> EnvironmentalState:
	var state: EnvironmentalState = EnvironmentalStateScript.from_sample(sample)
	state.shade = TerrainSurfaceScript.lattice_shade(wx, wy, _corner_shade)
	state.shade_known = true
	return state


## Exact shade at a lattice tile, through the per-tile env cache (the
## state keeps it once computed).
func _corner_shade(cx: int, cy: int) -> float:
	var env := _tile_env(cx, cy)
	return ResourceManagerScript.get_shade(env[0], world_seed, cx, cy, env[1])


## Returns null (not a heatmap view, or BASE_BIOME/SUBTYPE/MODIFIERS which
## use the plain Material look as their overlay base) so _color_for can
## fall back to pure Material with no blending cost. wx/wy are only needed by
## views that depend on position beyond the sample itself (resource density's
## patch noise).
func _heatmap_color_for(sample: Dictionary, wx: int, wy: int):
	match _view_mode:
		ViewMode.TEMPERATURE:
			return HeatmapColorizerScript.temperature(sample)
		ViewMode.MOISTURE:
			return HeatmapColorizerScript.moisture(sample)
		ViewMode.TEMP_VARIATION:
			return HeatmapColorizerScript.temp_variation(sample)
		ViewMode.PRECIP_SEASONALITY:
			return HeatmapColorizerScript.precip_seasonality(sample)
		ViewMode.DRAINAGE:
			return HeatmapColorizerScript.drainage(sample)
		ViewMode.DISTURBANCE_AGE:
			return HeatmapColorizerScript.disturbance_age(sample)
		ViewMode.DISTURBANCE_TYPE:
			return HeatmapColorizerScript.disturbance_type(sample)
		ViewMode.FUEL_LOAD:
			return HeatmapColorizerScript.fuel_load(sample)
		ViewMode.FIRE_RISK:
			return HeatmapColorizerScript.fire_risk(sample)
		ViewMode.CAVE_POTENTIAL:
			return HeatmapColorizerScript.cave_potential(sample)
		ViewMode.CLIFF_TENDENCY:
			return HeatmapColorizerScript.cliff_tendency(sample)
		ViewMode.RESOURCE_SUITABILITY_OAK:
			return HeatmapColorizerScript.resource_suitability(_resource_suitability(sample, OAK_RESOURCE))
		ViewMode.RESOURCE_DENSITY_OAK, ViewMode.RESOURCE_PLACEMENT_OAK:
			return HeatmapColorizerScript.resource_density(_resource_density(OAK_RESOURCE, wx, wy, sample))
		ViewMode.TREE_COVER, ViewMode.TREE_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(CANOPY_TREES, wx, wy, sample))
		ViewMode.ROCK_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(SURFACE_ROCKS, wx, wy, sample))
		ViewMode.BERRY_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(SHRUBS, wx, wy, sample))
		ViewMode.WETLAND_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(WETLAND_PLANTS, wx, wy, sample))
		ViewMode.SHORE_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(SHORE_FEATURES, wx, wy, sample))
		ViewMode.SUCCESSION, ViewMode.SUCCESSION_PLACEMENT:
			return HeatmapColorizerScript.succession(sample)
		ViewMode.SHADE:
			return HeatmapColorizerScript.shade(_guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample))
		ViewMode.ROCK_EXPOSURE:
			return HeatmapColorizerScript.rock_exposure(sample)
		ViewMode.DEPOSITS:
			return _deposit_color(sample, wx, wy)
		ViewMode.DEBUG_SUITABILITY:
			return HeatmapColorizerScript.resource_suitability(_debug_values(wx, wy, sample)["score"])
		ViewMode.DEBUG_DENSITY, ViewMode.DEBUG_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_debug_values(wx, wy, sample)["density"])
		ViewMode.DEBUG_PATCH:
			return HeatmapColorizerScript.resource_density(_debug_values(wx, wy, sample)["patch"])
		ViewMode.FARMING_POTENTIAL:
			return HeatmapColorizerScript.resource_suitability(_resource_suitability(sample, FARMLAND))
		_:
			return null


## Phase 4 of docs/resource-generation-plan.md: full sample -> EnvironmentalState
## -> classify_full() -> ResourceManager.get_suitability(), so the debug view
## reflects biome/subtype weighting too, not just the raw curve factors.
func _resource_suitability(sample: Dictionary, definition: ResourceDefinition) -> float:
	var state = EnvironmentalStateScript.from_sample(sample)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	return ResourceManagerScript.get_suitability(state, definition, classified)


## Phase 6: same pipeline as _resource_suitability(), then patch noise +
## base_density via ResourceManager.get_density(). `sample` is the tile's
## WorldGen.sample() if the caller already has it (else taken on a cache miss).
func _resource_density(definition: ResourceDefinition, wx: int, wy: int, sample: Dictionary = {}) -> float:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var memo := _density_memo(definition.id, chunk)
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if is_nan(memo[i]):
		if _structures.is_masked(Vector2i(wx, wy)):
			memo[i] = 0.0
		else:
			var env := _tile_env(wx, wy, sample)
			memo[i] = ResourceManagerScript.get_density(env[0], definition, world_seed, wx, wy, env[1])
	return memo[i]


## Phase 8 (guilds): the guild's total density, whatever the species mix.
## Phase 13: a guild that reads shade gets it from the canopy guild's memo here
## (the same value ResourceManager.get_shade() would compute), so shade and
## the Tree Cover / Shade heatmaps share one evaluation per tile.
## Landmark layer: 0 inside a structure's footprint (the structure_mask,
## StructureSites.is_masked()), so no guild places anything there - the same
## way zero suitability keeps them off water.
func _guild_density(guild: ResourceGuild, wx: int, wy: int, sample: Dictionary = {}) -> float:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var memo := _density_memo(guild.id, chunk)
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if is_nan(memo[i]):
		if _structures.is_masked(Vector2i(wx, wy)):
			memo[i] = 0.0
			return 0.0
		var env := _tile_env(wx, wy, sample)
		if not env[0].shade_known and guild.reads_shade():
			env[0].shade = _guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample)
			env[0].shade_known = true
		memo[i] = ResourceManagerScript.get_guild_density(env[0], guild, world_seed, wx, wy, env[1])
	return memo[i]


## Phase 17: [EnvironmentalState, classify_full() result] for a tile, cached
## per chunk (ENV_CACHE_CHUNKS, oldest chunk dropped first). Placement asks
## for the same tile once per guild with a candidate there and again from
## the neighboring chunk's one-cell ring, and the density heatmaps for every
## tile - ~5 full evaluations per tile in the Resources view before this.
## Both values are pure functions of (seed, tile) and are only read, never
## mutated, so sharing them changes no result. `sample` = the tile's
## WorldGen.sample() if the caller has it, {} = sample on a miss.
func _tile_env(wx: int, wy: int, sample: Dictionary = {}) -> Array:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var entry: Array = _env_chunks.get(chunk, [])
	if entry.is_empty():
		if _env_chunks.size() >= ENV_CACHE_CHUNKS:
			_env_chunks.erase(_env_chunks.keys()[0])
		var states := []
		var classifications := []
		states.resize(CHUNK_SIZE * CHUNK_SIZE)
		classifications.resize(CHUNK_SIZE * CHUNK_SIZE)
		entry = [states, classifications]
		_env_chunks[chunk] = entry
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if entry[0][i] == null:
		var s := sample if not sample.is_empty() else _world_gen.sample(wx, wy)
		entry[0][i] = EnvironmentalStateScript.from_sample(s)
		entry[1][i] = BiomeClassifierScript.classify_full(s)
	return [entry[0][i], entry[1][i]]


## Drops every per-seed generation cache (placements, densities, tile
## environments) - for cold-cache timings in tests; nothing else needs it.
func clear_generation_caches() -> void:
	_gen_mutex.lock()
	_raw_guild_chunks.clear()
	_density_chunks.clear()
	_env_chunks.clear()
	_walkable.clear()
	_structures = StructureSitesScript.new(_world_gen, world_seed)
	_gen_mutex.unlock()


## Phase 17: the density memo of one guild (or single resource) for one
## chunk - a PackedFloat64Array per tile, NAN = not computed yet - shared by
## the placement callbacks (a chunk's one-cell ring is its neighbor's
## interior) and the density heatmaps. Written through by the caller. Valid
## for the seed like _raw_guild_chunks; an id's chunks are dropped once they
## grow well past the loaded area (_gen_area; ~2 KB each).
func _density_memo(id: String, chunk: Vector2i) -> PackedFloat64Array:
	var by_chunk: Dictionary = _density_chunks.get(id, {})
	if not _density_chunks.has(id):
		_density_chunks[id] = by_chunk
	var densities: PackedFloat64Array = by_chunk.get(chunk, PackedFloat64Array())
	if densities.is_empty():
		if by_chunk.size() > 8 * _gen_area:
			by_chunk.clear()
		densities.resize(CHUNK_SIZE * CHUNK_SIZE)
		densities.fill(NAN)
		by_chunk[chunk] = densities
	return densities


## Phase 9: every ORE_DEPOSITS entry's potential at a tile -> {definition: potential}
## (zero entries left out).
func _deposit_potentials(sample: Dictionary, wx: int, wy: int) -> Dictionary:
	var state = EnvironmentalStateScript.from_sample(sample)
	var result := {}
	for ore in ORE_DEPOSITS:
		var potential: float = ResourceManagerScript.get_deposit_potential(state, ore, world_seed, wx, wy)
		if potential > 0.0:
			result[ore] = potential
	return result


## Deposits view: the strongest ore at the tile (ores rarely overlap -
## they favor different geology and have their own seams).
func _deposit_color(sample: Dictionary, wx: int, wy: int) -> Color:
	var best: ResourceDefinition = null
	var best_potential := 0.0
	var potentials := _deposit_potentials(sample, wx, wy)
	for ore in potentials:
		if potentials[ore] > best_potential:
			best = ore
			best_potential = potentials[ore]
	if best == null:
		return HeatmapColorizerScript.NO_DEPOSIT
	var exposure: float = ResourceManagerScript.get_exposure(EnvironmentalStateScript.from_sample(sample), best)
	return HeatmapColorizerScript.deposit(best.debug_color, best_potential, exposure)


func _species_shares(guild: ResourceGuild, wx: int, wy: int) -> PackedFloat32Array:
	var env := _tile_env(wx, wy)
	var scores: PackedFloat32Array = ResourceManagerScript.get_member_scores(env[0], guild, world_seed, wx, wy, env[1])
	return ResourceManagerScript.get_species_shares(scores, guild.species_sharpness)


## lod_step tiles collapse into one sample (taken at the block's center);
## the returned image is (CHUNK_SIZE/lod_step)^2, and the caller scales the
## Sprite2D back up to compensate, so a chunk's world-space footprint never
## changes - only how much per-tile detail it actually shows.
func _build_chunk_image(chunk_coord: Vector2i, lod_step: int) -> Image:
	var img := _new_chunk_image(lod_step)
	_bake_rows(img, chunk_coord, lod_step, 0, img.get_height())
	return img


func _new_chunk_image(lod_step: int) -> Image:
	var cells := CHUNK_SIZE / lod_step
	# The gameplay views carry water / grass codes in alpha (terrain.gdshader).
	return Image.create(cells, cells, false, Image.FORMAT_RGBA8 if is_time_tinted_view() else Image.FORMAT_RGB8)


## Pixel rows y0..y1-1 of a chunk image (a job step bakes one band).
func _bake_rows(img: Image, chunk_coord: Vector2i, lod_step: int, y0: int, y1: int) -> void:
	var base := chunk_coord * CHUNK_SIZE
	for ly in range(y0, y1):
		for lx in range(img.get_width()):
			var wx := base.x + lx * lod_step + lod_step / 2
			var wy := base.y + ly * lod_step + lod_step / 2
			var sample := _world_gen.sample(wx, wy)
			img.set_pixel(lx, ly, _color_for(sample, wx, wy))
			if lod_step == 1:
				_walkable[Vector2i(wx, wy)] = _walkable_sample(sample)


## Fills _tile_env() for tile rows y0..y1-1 of a chunk (a warm-up job step).
func _warm_env_rows(chunk: Vector2i, y0: int, y1: int) -> void:
	var base := chunk * CHUNK_SIZE
	for y in range(y0, y1):
		for x in CHUNK_SIZE:
			_tile_env(base.x + x, base.y + y)


## Phase 17 step 6: a chunk job's work as small steps, so the main-thread
## fallback (no worker) can spread one chunk over several frames - a whole
## Resources chunk is ~42 ms on desktop, several frames' worth on web. Each
## step is a Callable run holding _gen_mutex; together they fill `data` with
## the chunk's content for the current view (plain data, no nodes). In
## order: the image in bands of IMAGE_BAND_ROWS pixel rows, the label grids,
## one step per (guild, chunk) placement the stack filter will read - the
## guilds this view draws, in the chunk and the neighbors their margins reach
## (cached ones return at once) - then the assembly, which by then only reads
## caches. Same result as building it in one go. `fine` (the main-thread
## fallback) also warms _tile_env() for those chunks in IMAGE_BAND_ROWS bands
## first: a guild's first placement in a fresh chunk otherwise samples and
## classifies every candidate tile in one step (up to ~20 ms on desktop). The
## worker skips that - it would compute tiles no candidate needs.
func _chunk_job_steps(data: Dictionary, fine: bool) -> Array[Callable]:
	var chunk: Vector2i = data["chunk"]
	var lod_step: int = data["lod"]
	var img: Image = data["image"]
	var steps: Array[Callable] = []
	for y0 in range(0, img.get_height(), IMAGE_BAND_ROWS):
		steps.append(_bake_rows.bind(img, chunk, lod_step, y0, mini(y0 + IMAGE_BAND_ROWS, img.get_height())))
	if _is_label_view(_view_mode):
		steps.append(func() -> void: data["overlay"] = _overlay_grids(chunk))
	if _placements_visible_at(lod_step):
		var depth := _stack_depth(_placement_layers())
		var margins: Array = ResourcePlacementScript.stack_margins(GUILD_STACK.slice(0, depth))
		var rect := Rect2i(chunk * CHUNK_SIZE, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
		if fine and depth > 0:
			for c in _chunks_in_rect(rect.grow(margins.max())):
				for y0 in range(0, CHUNK_SIZE, IMAGE_BAND_ROWS):
					steps.append(_warm_env_rows.bind(c, y0, y0 + IMAGE_BAND_ROWS))
		for i in depth:
			for c in _chunks_in_rect(rect.grow(margins[i])):
				if fine:
					for y0 in range(0, CHUNK_SIZE, WARM_DENSITY_ROWS):
						steps.append(_warm_guild_density.bind(GUILD_STACK[i], c, y0))
				steps.append(_raw_guild_chunk.bind(GUILD_STACK[i], c))
		steps.append(func() -> void: data["placements"] = _placement_chunk(chunk))
	return steps


## Main thread: shows one finished job - creates the chunk's Sprite2D or
## swaps its texture, and replaces its label overlay and marker node.
func _apply_chunk_data(data: Dictionary) -> void:
	var chunk_coord: Vector2i = data["chunk"]
	var lod_step: int = data["lod"]
	var base := chunk_coord * CHUNK_SIZE
	var sprite: Sprite2D = _loaded_chunks.get(chunk_coord)
	var fresh := sprite == null
	if fresh:
		sprite = Sprite2D.new()
		sprite.centered = false
		sprite.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.material = terrain_material
		chunks_root.add_child(sprite)
		_loaded_chunks[chunk_coord] = sprite
	var padded := _padded_image(data["image"])
	_chunk_images[chunk_coord] = padded
	_share_borders(chunk_coord)
	sprite.texture = ImageTexture.create_from_image(padded)
	sprite.region_enabled = true
	sprite.region_rect = Rect2(1, 1, padded.get_width() - 2, padded.get_height() - 2)
	sprite.scale = Vector2(TILE_SIZE * lod_step, TILE_SIZE * lod_step)
	_shown_epoch[chunk_coord] = data["epoch"]

	_free_chunk_node(_loaded_overlays, chunk_coord)
	if data.has("overlay"):
		var overlay := BiomeOverlayChunkScript.new()
		overlay.setup(data["overlay"][0], CHUNK_SIZE, TILE_SIZE, data["overlay"][1])
		overlay.position = sprite.position
		overlay_root.add_child(overlay)
		_loaded_overlays[chunk_coord] = overlay

	_free_chunk_node(_loaded_placements, chunk_coord)
	_chunk_placements.erase(chunk_coord)
	if data.has("placements"):
		_chunk_placements[chunk_coord] = data["placements"]
		var markers := _marker_node(base, data["placements"])
		resources_root.add_child(markers)
		_loaded_placements[chunk_coord] = markers
	# Polish: a chunk that newly streams in fades in (FADE_IN_SEC) instead of
	# popping; rebuilding one already on screen (view change) swaps in place.
	if fresh:
		var markers_node = _loaded_placements.get(chunk_coord)
		var shadow_node = markers_node.shadow_layer() if markers_node != null else null
		for node in [sprite, _loaded_overlays.get(chunk_coord), markers_node, shadow_node]:
			if node != null:
				node.modulate.a = 0.0
				node.create_tween().tween_property(node, "modulate:a", 1.0, FADE_IN_SEC)


## A chunk image with a 1-texel border, its edge tiles repeated there until
## a neighbour fills it (_share_borders()); the sprite shows only the inside
## (region_rect).
static func _padded_image(img: Image) -> Image:
	var n := img.get_width()
	var padded := Image.create(n + 2, n + 2, false, img.get_format())
	padded.blit_rect(img, Rect2i(0, 0, n, n), Vector2i(1, 1))
	for i in range(-1, n + 1):
		var c := clampi(i, 0, n - 1)
		padded.set_pixel(i + 1, 0, img.get_pixel(c, 0))
		padded.set_pixel(i + 1, n + 1, img.get_pixel(c, n - 1))
		padded.set_pixel(0, i + 1, img.get_pixel(0, c))
		padded.set_pixel(n + 1, i + 1, img.get_pixel(n - 1, c))
	return padded


const NEIGHBOUR_STEPS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]


## Main thread, when a chunk is shown: fills its border from each loaded
## neighbour of the same size (LOD) and theirs from it, re-uploading the
## neighbours' textures - so tile blending carries across chunk borders.
func _share_borders(chunk_coord: Vector2i) -> void:
	var img: Image = _chunk_images[chunk_coord]
	var n := img.get_width() - 2
	for d in NEIGHBOUR_STEPS:
		var other: Image = _chunk_images.get(chunk_coord + d)
		if other == null or other.get_width() != img.get_width():
			continue
		_copy_border(img, other, d, n)
		_copy_border(other, img, -d, n)
		var sprite: Sprite2D = _loaded_chunks.get(chunk_coord + d)
		if sprite != null and sprite.texture is ImageTexture:
			(sprite.texture as ImageTexture).update(other)


## Copies into `dst`'s border on side `d` the matching edge tiles of `src`,
## the neighbour on that side (n = tiles per side).
static func _copy_border(dst: Image, src: Image, d: Vector2i, n: int) -> void:
	var xs := [0] if d.x < 0 else ([n + 1] if d.x > 0 else range(1, n + 1))
	var ys := [0] if d.y < 0 else ([n + 1] if d.y > 0 else range(1, n + 1))
	for y in ys:
		for x in xs:
			dst.set_pixel(x, y, src.get_pixel(x - d.x * n, y - d.y * n))


func _free_chunk_node(nodes: Dictionary, chunk_coord: Vector2i) -> void:
	if nodes.has(chunk_coord):
		nodes[chunk_coord].queue_free()
		nodes.erase(chunk_coord)


## Biome labels are derived from the same WorldGen fields but sampled on a
## (chunk_size+1)^2 grid so boundary outlines line up with tiles one step
## into the neighboring chunk, without that chunk needing to be loaded.
## Fill/outlines always key on base biome; SUBTYPE/MODIFIERS views only
## change the drawn label text ("Forest (Montane)", "Cold, Windy" etc.), not
## the region shapes. -> [biome grid, label grid] for the overlay node.
func _overlay_grids(chunk_coord: Vector2i) -> Array:
	var base := chunk_coord * CHUNK_SIZE
	var stride := CHUNK_SIZE + 1
	var show_subtype := _view_mode == ViewMode.SUBTYPE
	var show_modifiers := _view_mode == ViewMode.MODIFIERS
	var biome_grid := []
	var label_grid := []
	biome_grid.resize(stride * stride)
	label_grid.resize(stride * stride)

	for ly in range(stride):
		for lx in range(stride):
			var sample := _world_gen.sample(base.x + lx, base.y + ly)
			var i := ly * stride + lx
			if show_subtype:
				var full: Dictionary = BiomeClassifierScript.classify_full(sample)
				var base_biome: String = full["base_biome"]
				var subtype: String = full["subtype"]
				biome_grid[i] = base_biome
				label_grid[i] = "%s (%s)" % [base_biome, subtype] if subtype != "" else base_biome
			elif show_modifiers:
				var full: Dictionary = BiomeClassifierScript.classify_full(sample)
				var base_biome: String = full["base_biome"]
				var tags: Array = full["modifiers"]
				biome_grid[i] = base_biome
				label_grid[i] = "%s: %s" % [base_biome, ", ".join(tags)] if not tags.is_empty() else base_biome
			else:
				var base_biome: String = BiomeClassifierScript.classify(sample)
				biome_grid[i] = base_biome
				label_grid[i] = base_biome
	return [biome_grid, label_grid]


func _unload_chunk(chunk_coord: Vector2i) -> void:
	_free_chunk_node(_loaded_chunks, chunk_coord)
	_chunk_images.erase(chunk_coord)
	_shown_epoch.erase(chunk_coord)
	_free_chunk_node(_loaded_overlays, chunk_coord)
	_free_chunk_node(_loaded_placements, chunk_coord)
	_chunk_placements.erase(chunk_coord)


## Phase 7: the ResourceDefinitions/ResourceGuilds the current view places
## instances of, as [source, marker shape(, shape for members without a
## sprite when drawing SPRITE)] in draw order (empty = no
## placement markers in this view). Placement views keep the matching
## density heatmap as their base image, so each marker can be read against
## the field it was drawn from; the Resources view draws every guild over
## the Material image, trees last (as tinted sheet sprites) so they sit on
## top.
func _placement_layers() -> Array:
	var circle := ResourceMarkerChunkScript.Shape.CIRCLE
	match _view_mode:
		ViewMode.RESOURCE_PLACEMENT_OAK:
			return [[OAK_RESOURCE, circle]]
		ViewMode.TREE_PLACEMENT:
			return [[CANOPY_TREES, circle]]
		ViewMode.ROCK_PLACEMENT:
			return [[SURFACE_ROCKS, circle]]
		ViewMode.BERRY_PLACEMENT:
			return [[SHRUBS, circle]]
		ViewMode.WETLAND_PLACEMENT:
			return [[WETLAND_PLANTS, circle]]
		ViewMode.SHORE_PLACEMENT:
			return [[SHORE_FEATURES, circle]]
		ViewMode.SUCCESSION_PLACEMENT:
			return [[DEADWOOD, circle], [PIONEER_PLANTS, circle]]
		ViewMode.SHADE:
			return [[GROUND_COVER, circle], [DEADWOOD, circle], [SHRUBS, circle]]
		ViewMode.DEPOSITS:
			return [[ORE_OUTCROPS, ResourceMarkerChunkScript.Shape.HEXAGON]]
		ViewMode.QUALITY:
			return [[ORE_OUTCROPS, ResourceMarkerChunkScript.Shape.HEXAGON], [CANOPY_TREES, circle], [SHRUBS, circle]]
		ViewMode.DEBUG_PLACEMENT:
			return [[debug_guild(), circle]]
		ViewMode.RESOURCES:
			return [
				[ORE_OUTCROPS, ResourceMarkerChunkScript.Shape.SPRITE, ResourceMarkerChunkScript.Shape.HEXAGON],
				[SURFACE_ROCKS, ResourceMarkerChunkScript.Shape.SPRITE],
				[WETLAND_PLANTS, ResourceMarkerChunkScript.Shape.SPRITE, ResourceMarkerChunkScript.Shape.DIAMOND],
				[SHORE_FEATURES, ResourceMarkerChunkScript.Shape.SPRITE, circle],
				[GROUND_COVER, ResourceMarkerChunkScript.Shape.SPRITE],
				[PIONEER_PLANTS, ResourceMarkerChunkScript.Shape.SPRITE],
				[DEADWOOD, ResourceMarkerChunkScript.Shape.SPRITE],
				[DESERT_PLANTS, ResourceMarkerChunkScript.Shape.SPRITE],
				[SHRUBS, ResourceMarkerChunkScript.Shape.SPRITE, circle],
				[CANOPY_TREES, ResourceMarkerChunkScript.Shape.SPRITE],
			]
		_:
			return []


func _placements_visible_at(lod_step: int) -> bool:
	return not _placement_layers().is_empty() and lod_step <= MAX_PLACEMENT_LOD_STEP


## ResourcePlacement decides instances purely from world coordinates, so
## each chunk is placed on its own and neighbors agree at shared edges.
## -> [[layer (a _placement_layers() entry), instances], ...] in draw order.
func _placement_chunk(chunk_coord: Vector2i) -> Array:
	var base := chunk_coord * CHUNK_SIZE
	var layers := _placement_layers()
	var depth := _stack_depth(layers)
	var stack := _place_stack_chunk(base, depth) if depth > 0 else {}
	var result := []
	for layer in layers:
		var source: Resource = layer[0]
		var instances: Array = stack[source] if source is ResourceGuild else _place_definition_chunk(source, base)
		if _view_mode == ViewMode.QUALITY:
			instances = _quality_markers(instances)
		elif _view_mode == ViewMode.DEBUG_PLACEMENT:
			instances = instances.filter(func(inst): return inst["id"] == _debug_resource.id)
		result.append([layer, instances])
	# Landmark layer: the World view draws structure stamps first, under the
	# resources (which the structure_mask keeps off the footprint anyway).
	# Its layer has no source Resource (null), so it's not in
	# _placement_layers() and the guild stack never sees it.
	if _view_mode == ViewMode.RESOURCES:
		var parts := _structures.parts_in_rect(Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)))
		result.push_front([[null, ResourceMarkerChunkScript.Shape.SPRITE], parts])
	return result


## Phase 14 Quality view: only the instances that have a quality, each a
## copy (the placement caches stay untouched) filled by its quality. Quality
## is computed here, for shown instances only, never during placement.
func _quality_markers(instances: Array) -> Array:
	var result := []
	for inst in instances:
		var entity = get_resource_instance(inst)
		if entity != null and entity.quality >= 0.0:
			var marker: Dictionary = inst.duplicate()
			marker["fill"] = HeatmapColorizerScript.quality(entity.quality)
			result.append(marker)
	return result


## Phase 15: the gameplay record (ResourceInstance) of a placed instance -
## the one place views, the inspector and later gameplay get an instance's
## quality, size, health and harvest state from, with the player's changes
## (Phase 16) applied. Built on demand (pure, so
## rebuilding gives the same record); null for an unknown resource id. Call
## with _gen_mutex held or the worker idle, like other generation queries.
func get_resource_instance(inst: Dictionary):
	var definition: ResourceDefinition = _definitions_by_id().get(inst["id"])
	if definition == null:
		return null
	var record = ResourceInstanceScript.create(inst, definition, _instance_quality(inst))
	_changes.apply(record)
	return record


## Phase 14: ResourceManager.get_quality() for a placed instance (-1.0 = its
## resource has no quality), from the cached state of the tile it stands on.
func _instance_quality(inst: Dictionary) -> float:
	var definition: ResourceDefinition = _definitions_by_id().get(inst["id"])
	if definition == null or definition.quality_profile == null:
		return -1.0
	var pos: Vector2 = inst["position"]
	var wx := floori(pos.x)
	var wy := floori(pos.y)
	var env := _tile_env(wx, wy)
	var roll := ResourcePlacementScript.instance_roll(inst, world_seed)
	return ResourceManagerScript.get_quality(env[0], definition, world_seed, wx, wy, roll, env[1])


## Instance id -> ResourceDefinition for every member of GUILD_STACK (and
## Oak Placement's single definition), built on first use.
func _definitions_by_id() -> Dictionary:
	if _definitions.is_empty():
		_definitions[OAK_RESOURCE.id] = OAK_RESOURCE
		for guild in GUILD_STACK:
			for member in guild.members:
				_definitions[member.id] = member
	return _definitions


## A guild's instances depend only on the guilds above it in GUILD_STACK, so
## a view places the stack only down to the lowest guild it draws: that many
## guilds (0 = none, e.g. Oak Placement's single definition).
func _stack_depth(layers: Array) -> int:
	var depth := 0
	for layer in layers:
		depth = maxi(depth, GUILD_STACK.find(layer[0]) + 1)
	return depth


## Main thread: one marker node drawing a chunk's _placement_chunk() layers,
## minus the instances the player harvested (Phase 16) - filtered here, when
## the node is built, so a job generated before a harvest can't show it.
func _marker_node(base: Vector2i, placements: Array) -> Node2D:
	var markers := ResourceMarkerChunkScript.new()
	markers.material = sway_material
	for entry in placements:
		var layer: Array = entry[0]
		var source: Resource = layer[0]
		if source == null:  # structure parts (_placement_chunk()): each carries its sheet tile and tint
			var sprites := {}
			for inst in entry[1]:
				sprites[inst["id"]] = {"tile": inst["sheet"], "size": 1.0}
			var parts: Array = entry[1]
			if _tent_tile != null:  # the occupied tent is drawn by _tent_effect
				parts = parts.filter(func(p): return Vector2i((p["position"] as Vector2).floor()) != _tent_tile)
			# Structures stay on the grid: each part stands on its tile's
			# bottom middle rather than a jittered pivot.
			parts = parts.map(func(p):
				var part: Dictionary = p.duplicate()
				part["pivot"] = (p["position"] as Vector2).floor() + Vector2(0.5, 1.0)
				return part)
			markers.add_instances(parts, base, TILE_SIZE, 1.0, {}, ResourceMarkerChunkScript.Shape.SPRITE, sprites)
			continue
		var as_sprites: bool = layer[1] == ResourceMarkerChunkScript.Shape.SPRITE
		var fallback: int = layer[2] if layer.size() > 2 else ResourceMarkerChunkScript.Shape.TRIANGLE
		var first: int = markers.instance_count()
		var kept := _unchanged(entry[1])
		markers.add_instances(kept, base, TILE_SIZE, source.minimum_spacing, _marker_colors(source, as_sprites), layer[1], _sprite_tiles(source), fallback)
		if as_sprites and source is ResourceGuild:
			var defs := _definitions_by_id()
			var casts: Array[bool] = []
			for inst in kept:
				casts.append(defs[inst["id"]].casts_shadow)
			if casts.has(true):
				markers.add_shadows(first, shadow_material, casts)
	markers.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	var shadows: Node2D = markers.shadow_layer()
	if shadows != null:
		shadows.position = markers.position
		shadows_root.add_child(shadows)
	return markers


## Phase 8 step 5: the first `depth` guilds of GUILD_STACK for one chunk,
## after the cross-guild footprint check -> {guild: instances}. A guild's
## instances are the same whatever the depth (only higher guilds affect it),
## so each guild's view shows exactly what the Resources view does.
func _place_stack_chunk(base: Vector2i, depth: int = GUILD_STACK.size()) -> Dictionary:
	return _place_stack(Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)), depth)


## Same as _place_stack_chunk() for any tile rect.
func _place_stack(rect: Rect2i, depth: int = GUILD_STACK.size()) -> Dictionary:
	var guilds := GUILD_STACK.slice(0, depth)
	var raw_fn := func(i: int, r: Rect2i) -> Array:
		return _raw_guild_in_rect(guilds[i], r)
	var placed: Array = ResourcePlacementScript.place_stack_with(guilds, rect, raw_fn)
	var result := {}
	for i in guilds.size():
		result[guilds[i]] = placed[i]
	return result


## The placed resource instance under a click (tile units), or {} if none:
## one whose tile is the clicked tile (sprites are drawn filling their tile,
## see resource_marker_chunk.gd), else the nearest instance whose debug
## marker covers the point (marker radius = 0.35 x its guild's spacing).
## In the World view (sprites) only what is drawn under the point counts:
## the frontmost (southernmost pivot) sprite whose art covers it
## (_sprite_covers()) - a tree's canopy reaching into the tile above picks
## the tree, and a click on the ground beside or below a resource isn't
## pulled onto it (instances without a sprite still go by their tile).
## Works in any view - instances exist whether or not their markers are
## drawn. Adds "guild_name" and "name" for display, and "entity": its
## ResourceInstance (Phase 15: quality, size, health, harvest state).
## include_harvested = false skips what the player harvested (Phase 16:
## harvesting picks among what is still standing; info also finds the
## harvested one, which reports "harvested").
func _resource_at(point: Vector2, include_harvested: bool = true) -> Dictionary:
	var tile := Vector2i(floori(point.x), floori(point.y))
	var stack := _place_stack(Rect2i(tile - Vector2i(2, 2), Vector2i(5, 5)))
	var candidates := []
	for guild in GUILD_STACK:
		candidates.append([guild, stack[guild]])
	var best := _pick(point, candidates, include_harvested)
	if not best.is_empty():
		best["name"] = String(best["id"]).capitalize()
		best["guild_name"] = String(best["guild"]).capitalize()
		best["entity"] = get_resource_instance(best)
	return best


## The pick rule of _resource_at() over `candidates`, [[source (a guild or
## ResourceDefinition), instances], ...]; a copy of the picked instance, or {}.
func _pick(point: Vector2, candidates: Array, include_harvested: bool) -> Dictionary:
	var tile := Vector2i(floori(point.x), floori(point.y))
	var best := {}
	var best_dist := INF
	var sprites := _view_mode == ViewMode.RESOURCES
	for layer in candidates:
		var reach := maxf(layer[0].minimum_spacing * 0.35, 0.5)
		for inst in layer[1]:
			if not include_harvested and _changes.is_instance_harvested(inst):
				continue
			var pos: Vector2 = inst["position"]
			var in_tile := Vector2i(pos.floor()) == tile
			# An instance in the clicked tile always beats one merely in reach.
			var dist := point.distance_to(pos) - (1000.0 if in_tile else 0.0)
			var near := dist <= reach
			if sprites and not sprite_drawn(inst).is_empty():
				# Only covering art counts; the frontmost wins.
				in_tile = false
				near = _sprite_covers(inst, point)
				dist = -ResourceMarkerChunkScript.pivot(inst).y - 2000.0
			if (in_tile or near) and dist < best_dist:
				best = inst.duplicate()
				best_dist = dist
	return best


## The shown instances standing within 2 tiles of `tile` (the rect
## _resource_at() places), as _pick() candidates: what the current view
## draws, nothing where it draws no markers (heatmap and terrain views,
## zoomed out past MAX_PLACEMENT_LOD_STEP). Main thread; no generation.
func _drawn_near(tile: Vector2i) -> Array:
	var rect := Rect2i(tile - Vector2i(2, 2), Vector2i(5, 5))
	var result := []
	var center := Vector2i((Vector2(tile) / CHUNK_SIZE).floor())
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for entry in _chunk_placements.get(center + Vector2i(dx, dy), []):
				if entry[0][0] == null:  # skip the structure-parts layer
					continue
				var near := (entry[1] as Array).filter(func(inst): return rect.has_point(Vector2i((inst["position"] as Vector2).floor())))
				if not near.is_empty():
					result.append([entry[0][0], near])
	return result


## Whether the World view draws an opaque pixel of `inst`'s sprite at
## `point` (tile units).
func _sprite_covers(inst: Dictionary, point: Vector2) -> bool:
	var drawn := sprite_drawn(inst)
	if drawn.is_empty():
		return false
	var rect: Rect2 = drawn[1]
	var image: Image = sprite_image(drawn[0])
	var px := Vector2i(((point * TILE_SIZE - rect.position) * Vector2(image.get_size()) / rect.size).floor())
	return Rect2i(Vector2i.ZERO, image.get_size()).has_point(px) and image.get_pixelv(px).a > 0.5


## A point (tile units) on a placed resource's drawn sprite - its opaque
## pixel nearest its pivot - where a click picks it in the World view
## (unless something drawn in front covers it); its position if it has no
## sprite.
func sprite_point(inst: Dictionary) -> Vector2:
	var drawn := sprite_drawn(inst)
	if drawn.is_empty():
		return inst["position"]
	var rect: Rect2 = drawn[1]
	var image := sprite_image(drawn[0])
	var pivot := (ResourceMarkerChunkScript.pivot(inst) * TILE_SIZE).round()
	var best := Vector2.INF
	for y in image.get_height():
		for x in image.get_width():
			var p := rect.position + Vector2(x + 0.5, y + 0.5)
			if image.get_pixel(x, y).a > 0.5 and p.distance_squared_to(pivot) < best.distance_squared_to(pivot):
				best = p
	return best / TILE_SIZE


## How the World view draws a placed resource's sprite:
## [texture, rect in world px, draw alpha carrying its sway (sway_alpha())],
## as ResourceMarkerChunk draws it; [] if it has no sprite.
func sprite_drawn(inst: Dictionary) -> Array:
	var definition: ResourceDefinition = _definitions_by_id().get(inst.get("id", ""))
	if definition == null or definition.sprite_tile.x < 0:
		return []
	var sprite := {"tile": definition.sprite_tile, "size": definition.sprite_size, "texture": definition.sprite_texture}
	return ResourceMarkerChunkScript.sprite_draw(sprite, (ResourceMarkerChunkScript.pivot(inst) * TILE_SIZE).round()) + [sway_alpha(definition.sway)]


## A sprite texture's pixels (cached), for hit tests and outlines.
func sprite_image(texture: Texture2D) -> Image:
	if not _sprite_images.has(texture):
		_sprite_images[texture] = texture.get_image()
	return _sprite_images[texture]


## place_guild_in_rect() for any rect, assembled from per-chunk placements
## cached in _raw_guild_chunks - exact, since placement is chunk-independent.
## The stack filter needs every guild but the lowest in a rect grown past the
## chunk, so without the cache each chunk would re-place its neighbors' edges
## (tree placement cost ~1.6x, rocks ~2.3x). Placement depends only on seed
## and guild data, so entries stay valid across view changes; the cache is
## just dropped when it grows well past the loaded area.
func _raw_guild_in_rect(guild: ResourceGuild, rect: Rect2i) -> Array:
	var result := []
	for c in _chunks_in_rect(rect):
		for inst in _raw_guild_chunk(guild, c):
			var pos: Vector2 = inst["position"]
			if rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
				result.append(inst)
	return result


## Phase 14 (no-thread fallback): evaluates a guild's density at the
## placement candidates of rows y0..y0+WARM_DENSITY_ROWS of a chunk ahead of
## _raw_guild_chunk(), which then reads it from the memo - the same values,
## in smaller steps (a dense canopy chunk is ~20 ms of density work in one
## go). Nothing to do once the chunk's placement is cached.
func _warm_guild_density(guild: ResourceGuild, chunk: Vector2i, y0: int) -> void:
	if _raw_guild_chunks.has([guild.id, chunk]):
		return
	var band := Rect2i(chunk * CHUNK_SIZE + Vector2i(0, y0), Vector2i(CHUNK_SIZE, WARM_DENSITY_ROWS))
	for tile in ResourcePlacementScript.candidate_tiles(guild.id, guild.minimum_spacing, world_seed, band, ResourceManagerScript.get_guild_density_bound(guild)):
		_guild_density(guild, tile.x, tile.y)


## One guild's raw placement in one chunk, from _raw_guild_chunks or placed
## and cached now.
func _raw_guild_chunk(guild: ResourceGuild, chunk: Vector2i) -> Array:
	var key := [guild.id, chunk]
	if not _raw_guild_chunks.has(key):
		if _raw_guild_chunks.size() > 8 * GUILD_STACK.size() * _gen_area:
			_raw_guild_chunks.clear()
		var density_fn := func(wx: int, wy: int) -> float:
			return _guild_density(guild, wx, wy)
		var shares_fn := func(wx: int, wy: int) -> PackedFloat32Array:
			return _species_shares(guild, wx, wy)
		var chunk_rect := Rect2i(chunk * CHUNK_SIZE, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
		_raw_guild_chunks[key] = ResourcePlacementScript.place_guild_in_rect(guild, world_seed, chunk_rect, density_fn, shares_fn, ResourceManagerScript.get_guild_density_bound(guild))
	return _raw_guild_chunks[key]


## Chunks a tile rect overlaps, row by row.
func _chunks_in_rect(rect: Rect2i) -> Array[Vector2i]:
	var c0 := Vector2i(floori(rect.position.x / float(CHUNK_SIZE)), floori(rect.position.y / float(CHUNK_SIZE)))
	var c1 := Vector2i(floori((rect.end.x - 1) / float(CHUNK_SIZE)), floori((rect.end.y - 1) / float(CHUNK_SIZE)))
	var chunks: Array[Vector2i] = []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			chunks.append(Vector2i(cx, cy))
	return chunks


## A single ResourceDefinition placed on its own (Oak Placement).
func _place_definition_chunk(definition: ResourceDefinition, base: Vector2i) -> Array:
	var density_fn := func(wx: int, wy: int) -> float:
		return _resource_density(definition, wx, wy)
	return ResourcePlacementScript.place_in_rect(definition, world_seed, Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)), density_fn, ResourceManagerScript.get_density_bound(definition))


## Instance id -> marker color for a ResourceDefinition or ResourceGuild:
## debug_color, or sprite_color for members drawn as sprites - its alpha
## then carries the member's sway (sway_alpha()).
func _marker_colors(source: Resource, as_sprites: bool = false) -> Dictionary:
	var colors := {}
	for member in (source.members if source is ResourceGuild else [source]):
		if as_sprites and member.sprite_tile.x >= 0:
			colors[member.id] = sprite_fill(member)
		else:
			colors[member.id] = member.debug_color
	return colors


## The colour a resource's sprite is drawn with in the World view: its
## sprite_color in today's season colour (Seasons, its season_class), with
## its sway in the alpha (sway_alpha()).
func sprite_fill(definition: ResourceDefinition) -> Color:
	var c: Color = SeasonsScript.apply(definition.sprite_color, SeasonsScript.tint(definition.season_class, SeasonsScript.year_fraction(clock)))
	c.a = sway_alpha(definition.sway)
	return c


## A sprite's draw-colour alpha carrying its sway to the sway shader
## (shaders/sway.gdshader turns it back into sway and draws opaque):
## 1 - sway / 2, so opaque (alpha 1) draws never sway.
static func sway_alpha(sway: float) -> float:
	return 1.0 - clampf(sway, 0.0, 1.0) * 0.5


## Instance id -> {"tile", "size"} (resource_marker_chunk.gd), for members
## that have a sprite.
func _sprite_tiles(source: Resource) -> Dictionary:
	var tiles := {}
	for member in (source.members if source is ResourceGuild else [source]):
		if member.sprite_tile.x >= 0:
			tiles[member.id] = {"tile": member.sprite_tile, "size": member.sprite_size, "texture": member.sprite_texture}
	return tiles


## Phase 16: the instances of a placement list the player hasn't harvested.
func _unchanged(instances: Array) -> Array:
	if _changes.is_empty():
		return instances
	return instances.filter(func(inst): return not _changes.is_instance_harvested(inst))


## Phase 16: the file this seed's gameplay changes are saved to, or "" when
## they aren't saved (the default dir under a test harness, see changes_dir).
func changes_path() -> String:
	if changes_dir == "" or (changes_dir == DEFAULT_CHANGES_DIR and get_tree().get_script() != null):
		return ""
	return "%s/%d.json" % [changes_dir, world_seed]


## Phase 16: harvests the resource at `world_pos` - the player's tap walks
## up to it first (_on_map_tapped()) - the resource under the click, as
## hover_target() picks it (only what is drawn, ignoring what's already
## harvested) - records it in the gameplay changes, saves them, and redraws
## that chunk's markers.
## Returns the harvested ResourceInstance, or null if nothing was there.
func _on_harvest_clicked(world_pos: Vector2):
	var inst := hover_target(world_pos / TILE_SIZE)
	_gen_mutex.lock()  # the worker may be generating a chunk
	var entity = get_resource_instance(inst) if not inst.is_empty() else null
	if entity != null:
		_changes.harvest(entity.key, entity.resource_id)
		_changes.apply(entity)
		_save_gameplay_state()
	_gen_mutex.unlock()
	if entity != null:
		_redraw_markers(Vector2i((entity.world_position / CHUNK_SIZE).floor()))
		_spawn_harvest_effect(entity)
	return entity


## Polish: the pop-and-specks feedback at a harvested object's tile centre
## (where its sprite was drawn), in its sprite colour.
func _spawn_harvest_effect(entity) -> void:
	var definition: ResourceDefinition = _definitions_by_id().get(entity.resource_id)
	if definition == null:
		return
	var effect := HarvestEffectScript.new()
	var has_sprite := definition.sprite_tile.x >= 0
	var texture: Texture2D = ResourceMarkerChunkScript.sprite_texture(definition.sprite_tile) if has_sprite else null
	if has_sprite and definition.sprite_texture != null:
		texture = definition.sprite_texture
	var color: Color = sprite_fill(definition) if has_sprite else definition.debug_color
	effect.setup(texture, color, definition.sprite_size * ResourceMarkerChunkScript.SPRITE_SIZE, entity.key, definition.sprite_texture != null)
	effect.position = (ResourceMarkerChunkScript.pivot({"position": entity.world_position}) * TILE_SIZE).round()
	effect.name = "HarvestEffect"
	resources_root.add_child(effect)


## Rebuilds one loaded chunk's marker node from its stored placements (no
## generation), e.g. after a harvest.
func _redraw_markers(chunk_coord: Vector2i) -> void:
	if not _chunk_placements.has(chunk_coord):
		return
	_free_chunk_node(_loaded_placements, chunk_coord)
	var markers := _marker_node(chunk_coord * CHUNK_SIZE, _chunk_placements[chunk_coord])
	resources_root.add_child(markers)
	_loaded_placements[chunk_coord] = markers


## Phase 18 (developer tooling): whether a view is one of the Debug views,
## which show _debug_resource's suitability / density / patch noise /
## placement and add its factor breakdown to the inspector.
func is_debug_view(mode: ViewMode = _view_mode) -> bool:
	return mode in [ViewMode.DEBUG_SUITABILITY, ViewMode.DEBUG_DENSITY, ViewMode.DEBUG_PATCH, ViewMode.DEBUG_PLACEMENT]


## Every resource the Debug views can show: each GUILD_STACK member, in
## stack order.
func debug_resources() -> Array[ResourceDefinition]:
	var list: Array[ResourceDefinition] = []
	for guild in GUILD_STACK:
		for member in guild.members:
			list.append(member)
	return list


func debug_resource() -> ResourceDefinition:
	return _debug_resource


## The guild the debug resource is placed with.
func debug_guild() -> ResourceGuild:
	if _guild_of_member.is_empty():
		for guild in GUILD_STACK:
			for member in guild.members:
				_guild_of_member[member.id] = guild
	return _guild_of_member[_debug_resource.id]


## Picks the resource the Debug views show; rebuilds them if one is showing.
func set_debug_resource(definition: ResourceDefinition) -> void:
	if definition == _debug_resource:
		return
	_gen_mutex.lock()
	_debug_resource = definition
	debug_guild()
	_gen_mutex.unlock()
	if is_debug_view():
		_invalidate_chunks()


## The debug resource at a tile, as the guild sees it:
##   score   - its member score (suitability; exposed deposit for an ore),
##   cover   - the guild's cover (environment: how much can grow),
##   patch   - the guild's patch factor: stand membership at full suitability
##             for a stand-mode guild (Phase 14), else its patch modifier,
##   best    - the best member's score (caps the guild),
##   share   - this resource's species share of the guild,
##   density - guild density x share (its expected instances per cell).
func _debug_values(wx: int, wy: int, sample: Dictionary = {}) -> Dictionary:
	var guild := debug_guild()
	var env := _tile_env(wx, wy, sample)
	if not env[0].shade_known and guild.reads_shade():
		env[0].shade = _guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample)
		env[0].shade_known = true
	var scores: PackedFloat32Array = ResourceManagerScript.get_member_scores(env[0], guild, world_seed, wx, wy, env[1])
	var index := guild.members.find(_debug_resource)
	var best := 0.0
	for s in scores:
		best = maxf(best, s)
	var cover := ResourceManagerScript.get_guild_cover(env[0], guild)
	var patch := ResourceManagerScript.get_stand_membership(guild, cover, world_seed, wx, wy) if guild.cover_sets_area \
		else ResourceManagerScript.get_guild_patch_modifier(guild, world_seed, wx, wy)
	var share: float = ResourceManagerScript.get_species_shares(scores, guild.species_sharpness)[index]
	return {"score": scores[index], "cover": cover, "patch": patch, "best": best, "share": share,
		"density": _guild_density(guild, wx, wy, sample) * share}


## Phase 18: the inspector's breakdown of the debug resource at a tile - its
## suitability factor by factor (ResourceManager.explain_suitability()), then
## how the guild turns that into density. Call with _gen_mutex held.
func debug_breakdown(wx: int, wy: int) -> Array[String]:
	var guild := debug_guild()
	var v := _debug_values(wx, wy)
	var env := _tile_env(wx, wy)
	var lines: Array[String] = ["[b]%s[/b] (%s)" % [String(_debug_resource.id).capitalize(), String(guild.id).capitalize()]]
	lines.append_array(ResourceManagerScript.explain_suitability(env[0], _debug_resource, env[1])["lines"])
	if _debug_resource.vein_scale > 0.0:
		lines.append("member score (exposed deposit): %.3f" % v["score"])
	lines.append("guild cover (%s): %.2f" % [guild.cover_field if guild.cover_field != "" else "full", v["cover"]])
	lines.append("%s: %.2f" % ["stand membership" if guild.cover_sets_area else "patch modifier", v["patch"]])
	lines.append("best member score: %.2f   species share: %.2f" % [v["best"], v["share"]])
	lines.append("guild density: %.3f   %s density: %.3f" % [_guild_density(guild, wx, wy), _debug_resource.id, v["density"]])
	return lines


## This seed's saved changes and time (a new world: none, START_MINUTES).
func _load_gameplay_state() -> void:
	clock.wake()
	_leave_tent()
	_changes.load_file(changes_path(), world_seed)
	clock.minutes = _changes.time_minutes if _changes.time_minutes >= 0.0 else GameClockScript.START_MINUTES
	if _player:
		_player.teleport(_changes.player_position if _changes.has_player_position else _nearest_walkable(Vector2i.ZERO))


## Saves the changes and the current time for this seed (nothing under a
## test harness with the default dir - see changes_path()).
func _save_gameplay_state() -> void:
	_changes.time_minutes = clock.minutes
	if _player:
		_changes.player_position = _player.position
		_changes.has_player_position = true
	_changes.save(changes_path(), world_seed)


## Saves on quit, and whenever the game loses focus or is paused (a browser
## tab can close without a close request; review W6).
func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_save_gameplay_state()


## Views the day/night cycle tints (DayNight): the gameplay views only.
func is_time_tinted_view() -> bool:
	return _view_mode == ViewMode.RESOURCES or _view_mode == ViewMode.MATERIAL


## Player (user request): a tap / left click (CameraRig "map_tapped") walks
## the player there along find_path() - around water; to the nearest
## reachable tile if the spot itself can't be reached. Tapping a resource
## walks up to it (within one tile) and harvests it on arrival
## (_on_harvest_clicked()), unless another tap redirects the player first.
## Tapping a camp tent likewise walks up to it and goes in to sleep
## (enter_tent()). A tap while asleep wakes the player first (and only
## wakes them, on the tent they're in).
## Returns the path.
func _on_map_tapped(world_pos: Vector2) -> Array[Vector2i]:
	if _player == null:
		_on_harvest_clicked(world_pos)
		return []
	var goal := Vector2i((world_pos / TILE_SIZE).floor())
	if _tent_tile != null:
		var was_in: Vector2i = _tent_tile
		clock.wake()
		_leave_tent()
		if goal == was_in:  # tapping the tent they're in just wakes them
			return []
	var tent := is_tent(goal)
	var inst := {} if tent else hover_target(world_pos / TILE_SIZE)
	var on_arrive := Callable()
	# Where the walk ends: the tapped point, or next to a tapped resource or
	# tent (its pivot, the base of its sprite).
	var object_at := Vector2.ZERO
	if tent:
		var tent_tile := goal
		on_arrive = func() -> void: enter_tent(tent_tile)
		object_at = (Vector2(goal) + Vector2(0.5, 1.0)) * TILE_SIZE
	elif not inst.is_empty():
		goal = Vector2i((inst["position"] as Vector2).floor())
		on_arrive = func() -> void: _on_harvest_clicked(world_pos)
		object_at = ResourceMarkerChunkScript.pivot(inst) * TILE_SIZE
	var to_object := tent or not inst.is_empty()
	_gen_mutex.lock()
	var path := find_path(_player.tile(), goal, to_object)
	var end: Vector2i = path[-1] if not path.is_empty() else _player.tile()
	var points: Array[Vector2] = []
	for t in path:
		points.append((Vector2(t) + Vector2(0.5, 0.5)) * TILE_SIZE)
	if to_object:
		if maxi(absi(end.x - goal.x), absi(end.y - goal.y)) > 1:
			on_arrive = Callable()  # stopped short (unreachable): no harvest
		else:
			# Stand beside it, on the side the walk comes from.
			var from: Vector2 = points[-1] if not points.is_empty() else _player.position
			var side := from - object_at
			side = side.normalized() if side.length() > 0.5 else Vector2.DOWN
			var stand := object_at + side * STAND_OFF * TILE_SIZE
			if is_walkable(Vector2i((stand / TILE_SIZE).floor())):
				_set_last(points, stand, end)
	elif end == goal:
		_set_last(points, world_pos, end)
	points = _smooth_path(_player.position, points)
	_gen_mutex.unlock()
	_player.walk(points, on_arrive)
	return path


## How far (tiles) from a tapped resource's or tent's base the player stops.
const STAND_OFF := 0.6


## Makes `point` the walk's last point: it replaces the last tile centre,
## or is the only point when the walk stays on the start tile (`end`).
func _set_last(points: Array[Vector2], point: Vector2, end: Vector2i) -> void:
	if points.is_empty() or Vector2i((point / TILE_SIZE).floor()) != end:
		points.append(point)
	else:
		points[-1] = point


## String-pulls a walk: drops every point the player can skip by walking
## straight to a later one over walkable ground (_walkable_line()), so the
## walk is free rather than tile to tile. Call with _gen_mutex held.
func _smooth_path(start: Vector2, points: Array[Vector2]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var from := start
	var i := 0
	while i < points.size():
		var j := points.size() - 1
		while j > i and not _walkable_line(from, points[j]):
			j -= 1
		result.append(points[j])
		from = points[j]
		i = j + 1
	return result


## Whether the straight walk from `a` to `b` (world px) stays on walkable
## tiles, with a little clearance either side so it never grazes a water
## corner. Call with _gen_mutex held.
func _walkable_line(a: Vector2, b: Vector2) -> bool:
	var d := b - a
	var n := ceili(d.length() / (TILE_SIZE * 0.25)) + 1
	var side := d.orthogonal().normalized() * 3.0 if d.length() > 0.0 else Vector2.ZERO
	for k in n + 1:
		var p := a + d * (float(k) / n)
		for q in [p, p + side, p - side]:
			if not is_walkable(Vector2i(((q as Vector2) / TILE_SIZE).floor())):
				return false
	return true


## Whether a camp tent stands on `tile` (a "tent" part of the site there).
func is_tent(tile: Vector2i) -> bool:
	_gen_mutex.lock()  # site_at() may build the site, sampling the world
	var site := _structures.site_at(tile)
	_gen_mutex.unlock()
	for part in site.get("parts", []):
		if part["tile"] == tile and part["kind"] == "tent":
			return true
	return false


## How the World view draws the camp tent on `tile`: [texture, rect in
## world px, draw alpha 1 (rigid)] (a structure part, on its tile's bottom
## middle); [] if no tent stands there.
func tent_drawn(tile: Vector2i) -> Array:
	_gen_mutex.lock()  # site_at() may build the site, sampling the world
	var site := _structures.site_at(tile)
	_gen_mutex.unlock()
	for part in site.get("parts", []):
		if part["tile"] == tile and part["kind"] == "tent":
			return ResourceMarkerChunkScript.sprite_draw({"tile": part["sheet"], "size": 1.0}, (Vector2(tile) + Vector2(0.5, 1.0)) * TILE_SIZE) + [1.0]
	return []


## Sleeping in a tent (user request): the player goes inside the tent on
## `tile` (hidden), the tent bounces with Zs coming out (TentSleepEffect)
## and time speeds up until the next night start or dawn
## (GameClock.sleep()); _process() brings the player out when the clock
## wakes. Nothing happens if there's no tent there.
func enter_tent(tile: Vector2i) -> void:
	if _player == null or not is_tent(tile):
		return
	_leave_tent()
	_tent_tile = tile
	_player.visible = false
	var chunk := Vector2i((Vector2(tile) / CHUNK_SIZE).floor())
	_redraw_markers(chunk)
	var def: StructureDefinition = _structures.site_at(tile)["definition"]
	var tent_sheet := Vector2i.ZERO
	for part in def.parts:
		if part["kind"] == "tent":
			tent_sheet = part["tile"]
	_tent_effect = TentSleepEffectScript.new()
	_tent_effect.name = "TentSleep"
	# Above the marker chunks (re)added to Resources after it, and the
	# Overlay, so the Zs are never hidden behind neighbouring sprites.
	_tent_effect.z_index = 1
	_tent_effect.setup(ResourceMarkerChunkScript.sprite_texture(tent_sheet), def.kind_colors["tent"], ResourceMarkerChunkScript.SPRITE_SIZE)
	# Its tent stands on the tile's bottom edge, as the marker's does.
	_tent_effect.position = (Vector2(tile) + Vector2(0.5, 1.0)) * TILE_SIZE - Vector2(0, ResourceMarkerChunkScript.SPRITE_SIZE * 0.5)
	resources_root.add_child(_tent_effect)
	clock.sleep()


## Whether the player is asleep in a tent.
func is_in_tent() -> bool:
	return _tent_tile != null


## The player comes out of the tent (shown again where they went in) and
## the tent's own marker returns. Leaves the clock alone.
func _leave_tent() -> void:
	if _tent_tile == null:
		return
	var tile: Vector2i = _tent_tile
	_tent_tile = null
	if is_instance_valid(_tent_effect):
		_tent_effect.name = "TentSleepFading"  # frees itself once its Zs fade
		_tent_effect.wake()
	_tent_effect = null
	if _player:
		_player.visible = true
	_redraw_markers(Vector2i((Vector2(tile) / CHUNK_SIZE).floor()))


## Moves the player to the walkable tile nearest `world_pos` (its centre if
## the spot itself is water) and centres the camera on them.
func teleport_player(world_pos: Vector2) -> void:
	if _player == null:
		return
	clock.wake()
	_leave_tent()
	var tile := Vector2i((world_pos / TILE_SIZE).floor())
	_gen_mutex.lock()
	var walkable := is_walkable(tile)
	_gen_mutex.unlock()
	_player.teleport(world_pos if walkable else _nearest_walkable(tile))
	if _target and _target.has_method("snap_to_player"):
		_target.snap_to_player()


## Max tiles A* expands per path: enough to route round a lake across the
## screen; beyond it the player heads for the closest tile found.
const MAX_PATH_NODES := 6000
const PATH_STEPS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


## A* over tiles, 8 directions (no cutting a corner past water): the tiles
## to step through from `from` (excluded) to `to`, or to within one tile of
## it with `near` (walking up to a resource). If `to` can't be reached
## within MAX_PATH_NODES, the path to the closest tile explored. Call with
## _gen_mutex held (is_walkable() may sample).
func find_path(from: Vector2i, to: Vector2i, near: bool = false) -> Array[Vector2i]:
	var done := func(t: Vector2i) -> bool:
		return t == to or (near and maxi(absi(t.x - to.x), absi(t.y - to.y)) <= 1)
	var came := {from: from}
	var cost := {from: 0.0}
	var open_f: Array[float] = [_octile(from, to)]
	var open_t: Array[Vector2i] = [from]
	var best := from
	var best_h := _octile(from, to)
	var expanded := 0
	var reached := false
	while not open_t.is_empty() and expanded < MAX_PATH_NODES:
		var current: Vector2i = _heap_pop(open_f, open_t)
		if done.call(current):
			best = current
			reached = true
			break
		expanded += 1
		var h := _octile(current, to)
		if h < best_h:
			best_h = h
			best = current
		for step in PATH_STEPS:
			var next: Vector2i = current + step
			if not is_walkable(next):
				continue
			if step.x != 0 and step.y != 0 and not (is_walkable(current + Vector2i(step.x, 0)) and is_walkable(current + Vector2i(0, step.y))):
				continue
			var g: float = cost[current] + (1.41421356 if step.x != 0 and step.y != 0 else 1.0)
			if g < cost.get(next, INF):
				cost[next] = g
				came[next] = current
				_heap_push(open_f, open_t, g + _octile(next, to), next)
	var path: Array[Vector2i] = []
	var t := best
	while t != from:
		path.push_front(t)
		t = came[t]
	return path


static func _octile(a: Vector2i, b: Vector2i) -> float:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return maxi(dx, dy) + 0.41421356 * mini(dx, dy)


static func _heap_push(f: Array[float], t: Array[Vector2i], priority: float, tile: Vector2i) -> void:
	f.append(priority)
	t.append(tile)
	var i := f.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if f[parent] <= f[i]:
			break
		var pf := f[parent]
		f[parent] = f[i]
		f[i] = pf
		var pt := t[parent]
		t[parent] = t[i]
		t[i] = pt
		i = parent


static func _heap_pop(f: Array[float], t: Array[Vector2i]) -> Vector2i:
	var top := t[0]
	var last := f.size() - 1
	f[0] = f[last]
	t[0] = t[last]
	f.resize(last)
	t.resize(last)
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < f.size() and f[l] < f[m]:
			m = l
		if r < f.size() and f[r] < f[m]:
			m = r
		if m == i:
			break
		var mf := f[m]
		f[m] = f[i]
		f[i] = mf
		var mt := t[m]
		t[m] = t[i]
		t[i] = mt
		i = m
	return top


## Whether the player can stand on a tile: anything but open water (a sea,
## lake or river that isn't frozen solid). Call with _gen_mutex held.
func is_walkable(tile: Vector2i) -> bool:
	var known = _walkable.get(tile)
	if known != null:
		return known
	if _walkable.size() > 400000:
		_walkable.clear()
	var walkable := _walkable_sample(_world_gen.sample(tile.x, tile.y))
	_walkable[tile] = walkable
	return walkable


static func _walkable_sample(sample: Dictionary) -> bool:
	return TerrainSurfaceScript.water_liquid(sample) <= 0.0


## The walkable tile nearest `tile` (spiral search), as a world position at
## its centre; `tile` itself if none within 64 tiles.
func _nearest_walkable(tile: Vector2i) -> Vector2:
	_gen_mutex.lock()
	var found := tile
	var done := is_walkable(tile)
	for r in range(1, 65):
		if done:
			break
		for dy in range(-r, r + 1):
			for dx in [-r, r] if absi(dy) != r else range(-r, r + 1):
				if not done and is_walkable(tile + Vector2i(dx, dy)):
					found = tile + Vector2i(dx, dy)
					done = true
	_gen_mutex.unlock()
	return (Vector2(found) + Vector2(0.5, 0.5)) * TILE_SIZE


## Polish (HoverHighlight): the resource a left click at `point` (tile
## units) would harvest, or {}: _resource_at()'s pick among what is drawn
## there (_drawn_near()) and not harvested. It never generates or waits on
## the worker, so hovering can't stall a frame; where the view draws no
## markers there's nothing to pick. No "entity" or display names.
func hover_target(point: Vector2) -> Dictionary:
	return _pick(point, _drawn_near(Vector2i(point.floor())), false)


## Polish pass 2: sprites take their season colour (Seasons, per
## ResourceDefinition.season_class) when their markers are built; once per
## in-game day every loaded chunk's markers are redrawn from their stored
## placements (no generation), so colours drift through the year. Only the
## World view draws sprites.
func _update_seasons() -> void:
	var day: int = clock.day_index()
	if day == _season_day:
		return
	_season_day = day
	if _view_mode != ViewMode.RESOURCES:
		return
	for chunk in _chunk_placements.keys():
		_redraw_markers(chunk)


## Polish pass 2 (AmbientParticles): the environment at a tile for the
## particle rules - {} when generation holds the lock this instant (the
## caller just tries elsewhere later; the main thread never waits on it).
func ambient_env(tile: Vector2i) -> Dictionary:
	if not _gen_mutex.try_lock():
		return {}
	var env := _tile_env(tile.x, tile.y)
	var state: EnvironmentalState = env[0]
	var shade: float = ResourceManagerScript.get_shade(state, world_seed, tile.x, tile.y, env[1])
	var result := {
		"hour": clock.hour_of_day(),
		"year": SeasonsScript.year_fraction(clock),
		"wind": WindScript.strength_at(clock.minutes),
		"wind_dir": WindScript.direction_at(clock.minutes),
		"temperature": state.temperature,
		"moisture": state.moisture,
		"vegetation": state.vegetation,
		"shade": shade,
		"water": state.water_body in ["ocean", "sea", "lake", "river"],
		"biome": String(env[1].get("base_biome", "")),
	}
	_gen_mutex.unlock()
	return result
