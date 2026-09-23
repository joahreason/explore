extends Node2D

## Infinite chunk-based procedural world, deterministic per world_seed.
## Rendering here is a debug visualization only (flat colored tiles per
## WorldGen field sample) - the art tileset is intentionally not used yet;
## see scripts/world_gen.gd and scripts/debug_colorizer.gd for the actual
## generation/coloring logic. This file just handles chunk streaming.

const DebugColorizerScript := preload("res://scripts/debug_colorizer.gd")
const HeatmapColorizerScript := preload("res://scripts/heatmap_colorizer.gd")
const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")
const BiomeOverlayChunkScript := preload("res://scripts/biome_overlay_chunk.gd")
const EnvironmentalStateScript := preload("res://scripts/environmental_state.gd")
const ResourceManagerScript := preload("res://scripts/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resource_placement.gd")
const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")
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
## disturbance (Phase 11), the shrubs that fill in around all of them, and
## last the pioneer plants and ground cover (Phase 12) on what open ground
## remains.
const GUILD_STACK := [ORE_OUTCROPS, SURFACE_ROCKS, CANOPY_TREES, WETLAND_PLANTS, SHORE_FEATURES, DEADWOOD, SHRUBS, PIONEER_PLANTS, GROUND_COVER]

const TILE_SIZE := 12          # screen pixels per tile
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
## tiles up to about one chunk around it, and chunks are processed row by
## row, so a few rows of the loaded area catch nearly every reuse. One tile
## costs ~5 KB (state ~3 KB, classification ~2 KB), so the whole ~121-chunk
## footprint of the Resources view (~150 MB) is deliberately not kept.
const ENV_CACHE_CHUNKS := 48

## Placed-instance markers are skipped at coarser LOD steps than this: a
## marker would be a pixel or two wide, and zoomed out is exactly when the
## most chunks are loaded (placement costs ~7ms/chunk for oak).
const MAX_PLACEMENT_LOD_STEP := 2

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
}

## Assign a saved WorldGen.tres preset here to tune generation in the
## Inspector; if left empty a default-tuned WorldGen is created at runtime.
@export var world_gen_params: WorldGen
@export var world_seed: int = 1337
@export var target_path: NodePath

@onready var chunks_root: Node2D = $Chunks
@onready var overlay_root: Node2D = $Overlay
@onready var resources_root: Node2D = $Resources
@onready var _inspector_panel := $UI/TileInspector
@onready var _seed_input: LineEdit = $UI/SeedInput

var _target: Node2D
var _world_gen: WorldGen
var _seed_text: String = ""  # raw seed text in effect, shown in _seed_input
var _loaded_chunks: Dictionary = {}   # Vector2i chunk -> Sprite2D
var _loaded_overlays: Dictionary = {} # Vector2i chunk -> Node2D (biome overlay), only in a label view
var _loaded_placements: Dictionary = {} # Vector2i chunk -> Node2D (resource markers), only in a placement view
var _raw_guild_chunks: Dictionary = {} # [guild id, chunk] -> that guild's raw placement in the chunk (see _raw_guild_in_rect)
var _env_chunks: Dictionary = {} # chunk -> [states, classifications], per tile (see _tile_env)
var _density_chunks: Dictionary = {} # guild/resource id -> {chunk -> PackedFloat64Array per tile} (see _density_memo)
var _view_mode: ViewMode = ViewMode.MATERIAL
var _last_center: Vector2i = Vector2i(1 << 30, 1 << 30)  # force first update
var _last_load_radius: int = -1
var _last_lod_step: int = -1


func _ready() -> void:
	world_seed = _resolve_world_seed()
	_world_gen = world_gen_params if world_gen_params != null else WorldGen.new()
	_world_gen.configure(world_seed)

	# A guild's warnings include its members' (oak among them).
	for source in GUILD_STACK + ORE_DEPOSITS + [FARMLAND]:
		for warning in source.get_curve_domain_warnings():
			push_warning(warning)

	if _seed_text != "":
		_seed_input.text = _seed_text

	if target_path != NodePath():
		_target = get_node(target_path)
		_target.connect("clicked", _on_tile_clicked)

	_update_chunks(_chunk_of(_target.global_position if _target else Vector2.ZERO), _current_load_radius())


## Web only: a "?seed=" query param overrides the exported world_seed - set
## by ReloadButton/RandomizeButton/SeedInput's Enter from whatever's in the
## seed field. A purely numeric seed is used directly (matches the exported
## int seed behavior everywhere else in this project); anything else
## (letters/spaces) is hashed to a deterministic int, so the same text
## always regenerates the same world. If no param was given at all, a fresh
## random seed is generated instead of falling back to the fixed exported
## default, so every plain visit gets a different world. Either way,
## _seed_text is left holding whatever seed ended up in effect, so _ready()
## can show it in the seed field.
func _resolve_world_seed() -> int:
	if not OS.has_feature("web"):
		return world_seed

	var raw = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('seed') || ''", true
	)
	var raw_str := str(raw) if raw != null else ""
	if raw_str == "":
		raw_str = str(randi())
	_seed_text = raw_str
	if raw_str.is_valid_int():
		return int(raw_str)
	return raw_str.hash()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		toggle_biome_overlay()


## Quick keyboard shortcut: hop between Material and Base Biome. The dropdown
## (view_mode_dropdown.gd) covers the full view list via set_view_mode().
func toggle_biome_overlay() -> void:
	set_view_mode(ViewMode.MATERIAL if _view_mode == ViewMode.BASE_BIOME else ViewMode.BASE_BIOME)


func _is_label_view(mode: ViewMode) -> bool:
	return mode == ViewMode.BASE_BIOME or mode == ViewMode.SUBTYPE or mode == ViewMode.MODIFIERS


## Public entry point for the view-mode dropdown. Regenerates every currently
## loaded chunk's image in place (swap Sprite2D.texture) rather than adding a
## second layer - see plan doc §7 for why heatmap views are render methods,
## not overlays.
func set_view_mode(mode: ViewMode) -> void:
	if mode == _view_mode:
		return
	var was_label := _is_label_view(_view_mode)
	_view_mode = mode
	var now_label := _is_label_view(_view_mode)

	_rebuild_loaded_chunks()

	if now_label:
		# Also covers switching BASE_BIOME <-> SUBTYPE directly - labels
		# differ, so existing overlays need rebuilding either way.
		for overlay in _loaded_overlays.values():
			overlay.queue_free()
		_loaded_overlays.clear()
		for chunk_coord in _loaded_chunks.keys():
			_generate_overlay_chunk(chunk_coord)
	elif was_label:
		for overlay in _loaded_overlays.values():
			overlay.queue_free()
		_loaded_overlays.clear()


func _process(_delta: float) -> void:
	if _target == null:
		return

	var lod_step := _current_lod_step()
	if lod_step != _last_lod_step:
		_last_lod_step = lod_step
		_rebuild_loaded_chunks()

	var center := _chunk_of(_target.global_position)
	var load_radius := _current_load_radius()
	if center == _last_center and load_radius == _last_load_radius:
		return
	_last_center = center
	_last_load_radius = load_radius
	_update_chunks(center, load_radius)


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


## Driven by CameraRig's "clicked" signal (a left click/tap that wasn't a
## drag) - samples the single clicked tile fresh (bypassing the topology
## cache is unnecessary here, it's one tile) and hands the full sample +
## classification to the inspector panel, plus the placed resource (if
## any) under the exact click point.
func _on_tile_clicked(world_pos: Vector2) -> void:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	var sample := _world_gen.sample(tile.x, tile.y)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	var deposits := {}
	var state = EnvironmentalStateScript.from_sample(sample)
	var potentials := _deposit_potentials(sample, tile.x, tile.y)
	for ore in potentials:
		deposits[String(ore.id).capitalize()] = Vector2(potentials[ore], ResourceManagerScript.get_exposure(state, ore))
	var farming: float = ResourceManagerScript.get_suitability(state, FARMLAND, classified)
	_inspector_panel.show_info(tile, sample, classified, _resource_at(world_pos / TILE_SIZE), deposits, farming)


func _update_chunks(center: Vector2i, load_radius: int) -> void:
	for cy in range(center.y - load_radius, center.y + load_radius + 1):
		for cx in range(center.x - load_radius, center.x + load_radius + 1):
			var c := Vector2i(cx, cy)
			if not _loaded_chunks.has(c):
				_generate_chunk(c)

	var unload_radius := load_radius + UNLOAD_BUFFER
	for c in _loaded_chunks.keys():
		if Vector2(c - center).length() > unload_radius:
			_unload_chunk(c)


## Heatmap views are blended on top of the Material look rather than
## replacing it outright, so the terrain stays visible as context for how
## each field actually affects generation (e.g. you can still see the
## coastline/vegetation under a temperature heatmap instead of losing it).
const HEATMAP_OVERLAY_STRENGTH := 0.65

## Picks the color function for the current view mode. BASE_BIOME has no
## dedicated per-tile color of its own - it keeps the Material look as its
## base image and relies entirely on the drawn label overlay on top.
func _color_for(sample: Dictionary, wx: int, wy: int) -> Color:
	var heatmap_color: Variant = _heatmap_color_for(sample, wx, wy)
	if heatmap_color == null:
		return DebugColorizerScript.color_for(sample)
	var material_color: Color = DebugColorizerScript.color_for(sample)
	return material_color.lerp(heatmap_color, HEATMAP_OVERLAY_STRENGTH)


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
		ViewMode.ROCK_EXPOSURE:
			return HeatmapColorizerScript.rock_exposure(sample)
		ViewMode.DEPOSITS:
			return _deposit_color(sample, wx, wy)
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
		var env := _tile_env(wx, wy, sample)
		memo[i] = ResourceManagerScript.get_density(env[0], definition, world_seed, wx, wy, env[1])
	return memo[i]


## Phase 8 (guilds): the guild's total density, whatever the species mix.
func _guild_density(guild: ResourceGuild, wx: int, wy: int, sample: Dictionary = {}) -> float:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var memo := _density_memo(guild.id, chunk)
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if is_nan(memo[i]):
		var env := _tile_env(wx, wy, sample)
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
	_raw_guild_chunks.clear()
	_density_chunks.clear()
	_env_chunks.clear()


## Phase 17: the density memo of one guild (or single resource) for one
## chunk - a PackedFloat64Array per tile, NAN = not computed yet - shared by
## the placement callbacks (a chunk's one-cell ring is its neighbor's
## interior) and the density heatmaps. Written through by the caller. Valid
## for the seed like _raw_guild_chunks; an id's chunks are dropped once they
## grow well past the loaded area (~2 KB each).
func _density_memo(id: String, chunk: Vector2i) -> PackedFloat64Array:
	var by_chunk: Dictionary = _density_chunks.get(id, {})
	if not _density_chunks.has(id):
		_density_chunks[id] = by_chunk
	var densities: PackedFloat64Array = by_chunk.get(chunk, PackedFloat64Array())
	if densities.is_empty():
		if by_chunk.size() > 8 * maxi(_loaded_chunks.size(), 1):
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
	var base := chunk_coord * CHUNK_SIZE
	var cells := CHUNK_SIZE / lod_step
	var img := Image.create(cells, cells, false, Image.FORMAT_RGB8)
	for ly in range(cells):
		for lx in range(cells):
			var wx := base.x + lx * lod_step + lod_step / 2
			var wy := base.y + ly * lod_step + lod_step / 2
			var sample := _world_gen.sample(wx, wy)
			img.set_pixel(lx, ly, _color_for(sample, wx, wy))
	return img


func _generate_chunk(chunk_coord: Vector2i) -> void:
	var base := chunk_coord * CHUNK_SIZE
	var lod_step := _current_lod_step()
	var texture := ImageTexture.create_from_image(_build_chunk_image(chunk_coord, lod_step))
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	sprite.scale = Vector2(TILE_SIZE * lod_step, TILE_SIZE * lod_step)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	chunks_root.add_child(sprite)

	_loaded_chunks[chunk_coord] = sprite

	if _is_label_view(_view_mode):
		_generate_overlay_chunk(chunk_coord)

	if _placements_visible():
		_generate_placement_chunk(chunk_coord)


func _regenerate_chunk_image(chunk_coord: Vector2i) -> void:
	var sprite: Sprite2D = _loaded_chunks[chunk_coord]
	var lod_step := _current_lod_step()
	sprite.texture = ImageTexture.create_from_image(_build_chunk_image(chunk_coord, lod_step))
	sprite.scale = Vector2(TILE_SIZE * lod_step, TILE_SIZE * lod_step)


## Biome labels are derived from the same WorldGen fields but sampled on a
## (chunk_size+1)^2 grid so boundary outlines line up with tiles one step
## into the neighboring chunk, without that chunk needing to be loaded.
## Fill/outlines always key on base biome; SUBTYPE/MODIFIERS views only
## change the drawn label text ("Forest (Montane)", "Cold, Windy" etc.), not
## the region shapes.
func _generate_overlay_chunk(chunk_coord: Vector2i) -> void:
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

	var overlay := BiomeOverlayChunkScript.new()
	overlay.setup(biome_grid, CHUNK_SIZE, TILE_SIZE, label_grid)
	overlay.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	overlay_root.add_child(overlay)
	_loaded_overlays[chunk_coord] = overlay


func _unload_chunk(chunk_coord: Vector2i) -> void:
	var sprite: Sprite2D = _loaded_chunks[chunk_coord]
	sprite.queue_free()
	_loaded_chunks.erase(chunk_coord)

	if _loaded_overlays.has(chunk_coord):
		_loaded_overlays[chunk_coord].queue_free()
		_loaded_overlays.erase(chunk_coord)

	if _loaded_placements.has(chunk_coord):
		_loaded_placements[chunk_coord].queue_free()
		_loaded_placements.erase(chunk_coord)


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
		ViewMode.DEPOSITS:
			return [[ORE_OUTCROPS, ResourceMarkerChunkScript.Shape.HEXAGON]]
		ViewMode.RESOURCES:
			return [
				[ORE_OUTCROPS, ResourceMarkerChunkScript.Shape.SPRITE, ResourceMarkerChunkScript.Shape.HEXAGON],
				[SURFACE_ROCKS, ResourceMarkerChunkScript.Shape.SPRITE],
				[WETLAND_PLANTS, ResourceMarkerChunkScript.Shape.SPRITE, ResourceMarkerChunkScript.Shape.DIAMOND],
				[SHORE_FEATURES, ResourceMarkerChunkScript.Shape.SPRITE, circle],
				[GROUND_COVER, ResourceMarkerChunkScript.Shape.SPRITE],
				[PIONEER_PLANTS, ResourceMarkerChunkScript.Shape.SPRITE],
				[DEADWOOD, ResourceMarkerChunkScript.Shape.SPRITE],
				[SHRUBS, ResourceMarkerChunkScript.Shape.SPRITE, circle],
				[CANOPY_TREES, ResourceMarkerChunkScript.Shape.SPRITE],
			]
		_:
			return []


func _placements_visible() -> bool:
	return not _placement_layers().is_empty() and _current_lod_step() <= MAX_PLACEMENT_LOD_STEP


## On view or LOD change: re-bakes every loaded chunk's image and drops and
## rebuilds its marker node if the current view/LOD shows placements - image
## and markers chunk by chunk, row-major, so both read a chunk's tiles while
## _tile_env()'s bounded window still holds them (baking every image first
## evicted them before placement got there).
func _rebuild_loaded_chunks() -> void:
	for markers in _loaded_placements.values():
		markers.queue_free()
	_loaded_placements.clear()
	var place := _placements_visible()
	for chunk_coord in _chunks_row_major():
		_regenerate_chunk_image(chunk_coord)
		if place:
			_generate_placement_chunk(chunk_coord)


## Loaded chunks sorted by row, then column: neighbors are processed close
## together, so _tile_env()'s bounded cache still catches their shared tiles.
func _chunks_row_major() -> Array:
	var chunks := _loaded_chunks.keys()
	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return chunks


## ResourcePlacement decides instances purely from world coordinates, so
## each chunk is placed on its own and neighbors agree at shared edges.
func _generate_placement_chunk(chunk_coord: Vector2i) -> void:
	var base := chunk_coord * CHUNK_SIZE
	var markers := ResourceMarkerChunkScript.new()
	# A guild's instances depend only on the guilds above it in GUILD_STACK,
	# so place the stack only down to the lowest guild this view draws.
	var depth := 0
	for layer in _placement_layers():
		depth = maxi(depth, GUILD_STACK.find(layer[0]) + 1)
	var stack := _place_stack_chunk(base, depth) if depth > 0 else {}
	for layer in _placement_layers():
		var source: Resource = layer[0]
		var instances: Array = stack[source] if source is ResourceGuild else _place_definition_chunk(source, base)
		var as_sprites: bool = layer[1] == ResourceMarkerChunkScript.Shape.SPRITE
		var fallback: int = layer[2] if layer.size() > 2 else ResourceMarkerChunkScript.Shape.TRIANGLE
		markers.add_instances(instances, base, TILE_SIZE, source.minimum_spacing, _marker_colors(source, as_sprites), layer[1], _sprite_tiles(source), fallback)
	markers.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	resources_root.add_child(markers)
	_loaded_placements[chunk_coord] = markers


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
## the nearest instance whose drawn marker covers the point (marker radius =
## 0.35 x its guild's spacing, as in resource_marker_chunk.gd). Works in any
## view - instances exist whether or not their markers are drawn. Adds
## "guild_name" and "name" for display.
func _resource_at(point: Vector2) -> Dictionary:
	var tile := Vector2i(floori(point.x), floori(point.y))
	var stack := _place_stack(Rect2i(tile - Vector2i(2, 2), Vector2i(5, 5)))
	var best := {}
	var best_dist := INF
	for guild in GUILD_STACK:
		var reach := maxf(guild.minimum_spacing * 0.35, 0.5)
		for inst in stack[guild]:
			var dist := point.distance_to(inst["position"])
			if dist <= reach and dist < best_dist:
				best = inst.duplicate()
				best_dist = dist
	if not best.is_empty():
		best["name"] = String(best["id"]).capitalize()
		best["guild_name"] = String(best["guild"]).capitalize()
	return best


## place_guild_in_rect() for any rect, assembled from per-chunk placements
## cached in _raw_guild_chunks - exact, since placement is chunk-independent.
## The stack filter needs every guild but the lowest in a rect grown past the
## chunk, so without the cache each chunk would re-place its neighbors' edges
## (tree placement cost ~1.6x, rocks ~2.3x). Placement depends only on seed
## and guild data, so entries stay valid across view changes; the cache is
## just dropped when it grows well past the loaded area.
func _raw_guild_in_rect(guild: ResourceGuild, rect: Rect2i) -> Array:
	if _raw_guild_chunks.size() > 8 * GUILD_STACK.size() * maxi(_loaded_chunks.size(), 1):
		_raw_guild_chunks.clear()
	var c0 := Vector2i(floori(rect.position.x / float(CHUNK_SIZE)), floori(rect.position.y / float(CHUNK_SIZE)))
	var c1 := Vector2i(floori((rect.end.x - 1) / float(CHUNK_SIZE)), floori((rect.end.y - 1) / float(CHUNK_SIZE)))
	var result := []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var key := [guild.id, Vector2i(cx, cy)]
			if not _raw_guild_chunks.has(key):
				var density_fn := func(wx: int, wy: int) -> float:
					return _guild_density(guild, wx, wy)
				var shares_fn := func(wx: int, wy: int) -> PackedFloat32Array:
					return _species_shares(guild, wx, wy)
				var chunk_rect := Rect2i(Vector2i(cx, cy) * CHUNK_SIZE, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
				_raw_guild_chunks[key] = ResourcePlacementScript.place_guild_in_rect(guild, world_seed, chunk_rect, density_fn, shares_fn, ResourceManagerScript.get_guild_density_bound(guild))
			for inst in _raw_guild_chunks[key]:
				var pos: Vector2 = inst["position"]
				if rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
					result.append(inst)
	return result


## A single ResourceDefinition placed on its own (Oak Placement).
func _place_definition_chunk(definition: ResourceDefinition, base: Vector2i) -> Array:
	var density_fn := func(wx: int, wy: int) -> float:
		return _resource_density(definition, wx, wy)
	return ResourcePlacementScript.place_in_rect(definition, world_seed, Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)), density_fn, ResourceManagerScript.get_density_bound(definition))


## Instance id -> marker color for a ResourceDefinition or ResourceGuild:
## debug_color, or sprite_color for members drawn as sprites.
func _marker_colors(source: Resource, as_sprites: bool = false) -> Dictionary:
	var colors := {}
	for member in (source.members if source is ResourceGuild else [source]):
		colors[member.id] = member.sprite_color if as_sprites and member.sprite_tile.x >= 0 else member.debug_color
	return colors


## Instance id -> {"tile", "size"} (resource_marker_chunk.gd), for members
## that have a sprite.
func _sprite_tiles(source: Resource) -> Dictionary:
	var tiles := {}
	for member in (source.members if source is ResourceGuild else [source]):
		if member.sprite_tile.x >= 0:
			tiles[member.id] = {"tile": member.sprite_tile, "size": member.sprite_size}
	return tiles
