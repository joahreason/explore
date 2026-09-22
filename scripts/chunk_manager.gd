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
var _view_mode: ViewMode = ViewMode.MATERIAL
var _last_center: Vector2i = Vector2i(1 << 30, 1 << 30)  # force first update
var _last_load_radius: int = -1
var _last_lod_step: int = -1


func _ready() -> void:
	world_seed = _resolve_world_seed()
	_world_gen = world_gen_params if world_gen_params != null else WorldGen.new()
	_world_gen.configure(world_seed)

	# The guild's warnings include its members' (oak among them).
	for warning in CANOPY_TREES.get_curve_domain_warnings():
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

	for chunk_coord in _loaded_chunks.keys():
		_regenerate_chunk_image(chunk_coord)

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

	_refresh_placements()


func _process(_delta: float) -> void:
	if _target == null:
		return

	var lod_step := _current_lod_step()
	if lod_step != _last_lod_step:
		_last_lod_step = lod_step
		for chunk_coord in _loaded_chunks.keys():
			_regenerate_chunk_image(chunk_coord)
		_refresh_placements()

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
## classification to the inspector panel.
func _on_tile_clicked(world_pos: Vector2) -> void:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	var sample := _world_gen.sample(tile.x, tile.y)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	_inspector_panel.show_info(tile, sample, classified)


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
			return HeatmapColorizerScript.resource_density(_resource_density(sample, OAK_RESOURCE, wx, wy))
		ViewMode.TREE_COVER, ViewMode.TREE_PLACEMENT:
			return HeatmapColorizerScript.resource_density(_guild_density(sample, CANOPY_TREES, wx, wy))
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
## base_density via ResourceManager.get_density().
func _resource_density(sample: Dictionary, definition: ResourceDefinition, wx: int, wy: int) -> float:
	var state = EnvironmentalStateScript.from_sample(sample)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	return ResourceManagerScript.get_density(state, definition, world_seed, wx, wy, classified)


## Phase 8 (guilds): the guild's total density, whatever the species mix.
func _guild_density(sample: Dictionary, guild: ResourceGuild, wx: int, wy: int) -> float:
	var state = EnvironmentalStateScript.from_sample(sample)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	return ResourceManagerScript.get_guild_density(state, guild, world_seed, wx, wy, classified)


func _species_shares(sample: Dictionary, guild: ResourceGuild) -> PackedFloat32Array:
	var state = EnvironmentalStateScript.from_sample(sample)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	var suitabilities: PackedFloat32Array = ResourceManagerScript.get_member_suitabilities(state, guild, classified)
	return ResourceManagerScript.get_species_shares(suitabilities, guild.species_sharpness)


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


## Phase 7: which ResourceDefinition or ResourceGuild the current view
## places instances of (null = no placement markers in this view).
## Placement views keep the matching density heatmap as their base image, so
## each marker can be read against the field it was drawn from.
func _placement_source() -> Resource:
	match _view_mode:
		ViewMode.RESOURCE_PLACEMENT_OAK:
			return OAK_RESOURCE
		ViewMode.TREE_PLACEMENT:
			return CANOPY_TREES
		_:
			return null


func _placements_visible() -> bool:
	return _placement_source() != null and _current_lod_step() <= MAX_PLACEMENT_LOD_STEP


## Drops every marker node and rebuilds them for all loaded chunks if the
## current view/LOD shows placements - called on view or LOD change.
func _refresh_placements() -> void:
	for markers in _loaded_placements.values():
		markers.queue_free()
	_loaded_placements.clear()
	if not _placements_visible():
		return
	for chunk_coord in _loaded_chunks.keys():
		_generate_placement_chunk(chunk_coord)


## ResourcePlacement decides instances purely from world coordinates, so
## each chunk is placed on its own and neighbors agree at shared edges.
func _generate_placement_chunk(chunk_coord: Vector2i) -> void:
	var source := _placement_source()
	var base := chunk_coord * CHUNK_SIZE
	var rect := Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
	var instances: Array
	var colors := {}
	if source is ResourceGuild:
		var guild: ResourceGuild = source
		var density_fn := func(wx: int, wy: int) -> float:
			return _guild_density(_world_gen.sample(wx, wy), guild, wx, wy)
		var shares_fn := func(wx: int, wy: int) -> PackedFloat32Array:
			return _species_shares(_world_gen.sample(wx, wy), guild)
		instances = ResourcePlacementScript.place_guild_in_rect(guild, world_seed, rect, density_fn, shares_fn)
		for member in guild.members:
			colors[member.id] = member.debug_color
	else:
		var definition: ResourceDefinition = source
		var density_fn := func(wx: int, wy: int) -> float:
			return _resource_density(_world_gen.sample(wx, wy), definition, wx, wy)
		instances = ResourcePlacementScript.place_in_rect(definition, world_seed, rect, density_fn)
		colors[definition.id] = definition.debug_color
	var markers := ResourceMarkerChunkScript.new()
	markers.setup(instances, base, TILE_SIZE, source.minimum_spacing, colors)
	markers.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	resources_root.add_child(markers)
	_loaded_placements[chunk_coord] = markers
