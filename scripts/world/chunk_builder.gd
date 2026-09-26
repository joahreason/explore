extends RefCounted

## One chunk's content for the current view, as plain data: its image, its
## biome label grids and its placement instances, built in small steps
## (job_steps()) so the main-thread fallback can spread a chunk over several
## frames. Runs on the chunk worker or inline on the main thread, never
## touches the scene tree, and reads generation only through the
## GenerationContext. Every step runs holding ctx.mutex, so view_mode and
## debug_resource, which generation reads, are only changed holding it too.

const TerrainSurfaceScript := preload("res://scripts/gen/terrain_surface.gd")
const HeatmapColorizerScript := preload("res://scripts/render/heatmap_colorizer.gd")
const BiomeClassifierScript := preload("res://scripts/gen/biome_classifier.gd")
const EnvironmentalStateScript := preload("res://scripts/gen/environmental_state.gd")
const ResourceManagerScript := preload("res://scripts/resources/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resources/resource_placement.gd")
const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")
const ViewModesScript := preload("res://scripts/world/view_modes.gd")
const GenerationContextScript := preload("res://scripts/world/generation_context.gd")
const TerrainCodes := preload("res://scripts/world/terrain_codes.gd")
const CONTENT: WorldContent = preload("res://resources/world_content.tres")
const ViewMode := ViewModesScript.ViewMode
const CHUNK_SIZE := GenerationContextScript.CHUNK_SIZE

## Pixel rows a chunk job bakes per step (see job_steps). 2 since
## Phase 13.5: choosing each tile's ground costs ~50 us, so a 4-row band was
## ~4.5 ms on desktop - too big a step for the web fallback.
const IMAGE_BAND_ROWS := 2
## Placed-instance markers are skipped at coarser LOD steps than this: a
## marker would be a pixel or two wide, and zoomed out is exactly when the
## most chunks are loaded (placement costs ~7ms/chunk for oak).
const MAX_PLACEMENT_LOD_STEP := 2
## Heatmap views are blended on top of the terrain (Phase 13.5) rather than
## replacing it outright, so the terrain stays visible as context for how
## each field actually affects generation (e.g. you can still see the
## coastline/vegetation under a temperature heatmap instead of losing it).
const HEATMAP_OVERLAY_STRENGTH := 0.65

## Generation's seed, WorldGen and caches (shared with ChunkManager).
var ctx: GenerationContextScript
## Phase 13.5: the default "live game" view is the terrain with every placed
## resource on it (RESOURCES); MATERIAL is the bare terrain.
var view_mode: ViewMode = ViewMode.RESOURCES
## Phase 18: the resource the Debug views show (a guild member).
var debug_resource: ResourceDefinition = ViewModesScript.OAK_RESOURCE


func _init(context: GenerationContextScript) -> void:
	ctx = context


## The guild the debug resource is placed with.
func debug_guild() -> ResourceGuild:
	return CONTENT.guild_of(debug_resource)


## Picks the color function for the current view mode. BASE_BIOME has no
## dedicated per-tile color of its own - it keeps the terrain as its base
## image and relies entirely on the drawn label overlay on top.
func color_for(sample: Dictionary, wx: int, wy: int) -> Color:
	var heatmap_color: Variant = _heatmap_color_for(sample, wx, wy)
	if heatmap_color == null:
		return terrain_color(sample, wx, wy)
	var blended := terrain_color(sample, wx, wy).lerp(heatmap_color, HEATMAP_OVERLAY_STRENGTH)
	blended.a = 1.0
	return blended


## Phase 13.5: a tile's terrain colour - its water body, or its ground
## material (TerrainSurface) coloured by its fields.
func terrain_color(sample: Dictionary, wx: int, wy: int) -> Color:
	var coded := ViewModesScript.is_tinted(view_mode)
	var water: Variant = TerrainSurfaceScript.water_color(sample, ctx.world_gen.sea_level)
	if water != null:
		var w: Color = water
		var liquid := TerrainSurfaceScript.water_liquid(sample)
		# Frozen water gets no code: no waves, no glints.
		if coded and liquid > 0.0:
			w.a = (TerrainCodes.WATER_CODE_ICE + roundf(liquid * (TerrainCodes.WATER_CODE - TerrainCodes.WATER_CODE_ICE))) / 255.0
			var depth: float = ctx.world_gen.sea_level - sample["elevation"]
			if liquid >= 1.0 and depth < TerrainCodes.SHORE_ELEVATION_MARGIN and TerrainCodes.SEA_BODIES.has(sample["water_body"]):
				var shape := TerrainCodes.shore_shape(ctx.world_gen, wx, wy, true)
				if shape > 0:
					w.a = (TerrainCodes.FOAM_CODE + shape) / 255.0
				elif depth < TerrainCodes.SHALLOW_DEPTH:
					w.a = (TerrainCodes.SHALLOW_CODE + roundi(7.0 * (1.0 - depth / TerrainCodes.SHALLOW_DEPTH))) / 255.0
		return w
	var state := _surface_state(sample, wx, wy)
	var material := TerrainSurfaceScript.material_at(state, ctx.world_seed, wx, wy)
	var color := TerrainSurfaceScript.color_for(material, state, ctx.world_seed, wx, wy)
	if not coded:
		return color
	var grass := TerrainCodes.GRASS_GROUND.has(material.id)
	if grass:
		color.a = TerrainCodes.GRASS_CODE / 255.0
	# A sea shore: near sea level, facing salt water (not a lake), not frozen.
	if sample["elevation"] < ctx.world_gen.sea_level + TerrainCodes.SHORE_ELEVATION_MARGIN and sample["shore_salinity"] > 0.0 and TerrainSurfaceScript.shore_liquid(sample) >= 1.0:
		var shape := TerrainCodes.shore_shape(ctx.world_gen, wx, wy, false)
		if shape > 0:
			color.a = ((TerrainCodes.WASH_GRASS_CODE if grass else TerrainCodes.WASH_CODE) + shape) / 255.0
	return color


## The ground material of a tile, or null on a water body (inspector, tests).
func surface_at(sample: Dictionary, wx: int, wy: int) -> SurfaceMaterial:
	if TerrainSurfaceScript.water_color(sample, ctx.world_gen.sea_level) != null:
		return null
	return TerrainSurfaceScript.material_at(_surface_state(sample, wx, wy), ctx.world_seed, wx, wy)


## A fresh EnvironmentalState for choosing ground, its shade taken from the
## SHADE_LATTICE corners (TerrainSurface.lattice_shade()) - fresh, so the
## interpolated shade never replaces the exact per-tile value placement
## reads from ctx.tile_env()'s cached states.
func _surface_state(sample: Dictionary, wx: int, wy: int) -> EnvironmentalState:
	var state: EnvironmentalState = EnvironmentalStateScript.from_sample(sample)
	state.shade = TerrainSurfaceScript.lattice_shade(wx, wy, corner_shade)
	state.shade_known = true
	return state


## Exact shade at a lattice tile, through the per-tile env cache (the
## state keeps it once computed).
func corner_shade(cx: int, cy: int) -> float:
	var env := ctx.tile_env(cx, cy)
	return ResourceManagerScript.get_shade(env[0], ctx.world_seed, cx, cy, env[1])


## The current view's colour (ViewModes' "color") for a tile. Returns null
## (not a heatmap view, or a label view, which uses the plain Material look
## as its overlay base) so color_for can
## fall back to pure Material with no blending cost. wx/wy are only needed by
## views that depend on position beyond the sample itself (resource density's
## patch noise).
func _heatmap_color_for(sample: Dictionary, wx: int, wy: int):
	var color := ViewModesScript.color(view_mode)
	if color.is_empty():
		return null
	match color[0]:
		"heat":
			var colorizer: Script = HeatmapColorizerScript  # its static functions, by name
			return colorizer.call(color[1], sample)
		"suitability":
			return HeatmapColorizerScript.resource_suitability(_resource_suitability(sample, color[1]))
		"resource_density":
			return HeatmapColorizerScript.resource_density(ctx.resource_density(color[1], wx, wy, sample))
		"guild_density":
			return HeatmapColorizerScript.resource_density(ctx.guild_density(color[1], wx, wy, sample))
		"shade":
			return HeatmapColorizerScript.shade(ctx.guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample))
		"deposits":
			return _deposit_color(sample, wx, wy)
		"debug":
			var value: float = debug_values(wx, wy, sample)[color[1]]
			if color[1] == "score":
				return HeatmapColorizerScript.resource_suitability(value)
			return HeatmapColorizerScript.resource_density(value)
	return null


## Phase 4 of docs/resource-generation-plan.md: full sample -> EnvironmentalState
## -> classify_full() -> ResourceManager.get_suitability(), so the debug view
## reflects biome/subtype weighting too, not just the raw curve factors.
func _resource_suitability(sample: Dictionary, definition: ResourceDefinition) -> float:
	var state = EnvironmentalStateScript.from_sample(sample)
	var classified: Dictionary = BiomeClassifierScript.classify_full(sample)
	return ResourceManagerScript.get_suitability(state, definition, classified)


## Deposits view: the strongest ore at the tile (ores rarely overlap -
## they favor different geology and have their own seams).
func _deposit_color(sample: Dictionary, wx: int, wy: int) -> Color:
	var best: ResourceDefinition = null
	var best_potential := 0.0
	var potentials := ctx.deposit_potentials(sample, wx, wy)
	for ore in potentials:
		if potentials[ore] > best_potential:
			best = ore
			best_potential = potentials[ore]
	if best == null:
		return HeatmapColorizerScript.NO_DEPOSIT
	var exposure: float = ResourceManagerScript.get_exposure(EnvironmentalStateScript.from_sample(sample), best)
	return HeatmapColorizerScript.deposit(best.debug_color, best_potential, exposure)


## lod_step tiles collapse into one sample (taken at the block's center);
## the returned image is (CHUNK_SIZE/lod_step)^2, and the caller scales the
## Sprite2D back up to compensate, so a chunk's world-space footprint never
## changes - only how much per-tile detail it actually shows.
func build_chunk_image(chunk_coord: Vector2i, lod_step: int) -> Image:
	var img := new_image(lod_step)
	_bake_rows(img, chunk_coord, lod_step, 0, img.get_height())
	return img


## What a chunk's base image depends on besides the chunk, its LOD and the
## content: views with equal keys bake identical images (World and Terrain
## Only; the label views and Quality), so ChunkStreamer keeps the image on
## screen across a switch between them (review P4).
func image_key() -> Array:
	var color := ViewModesScript.color(view_mode)
	var key := [ViewModesScript.is_tinted(view_mode), color]
	if not color.is_empty() and color[0] == "debug":
		key.append(debug_resource)
	return key


func new_image(lod_step: int) -> Image:
	var cells := CHUNK_SIZE / lod_step
	# The gameplay views carry water / grass codes in alpha (terrain.gdshader).
	return Image.create(cells, cells, false, Image.FORMAT_RGBA8 if ViewModesScript.is_tinted(view_mode) else Image.FORMAT_RGB8)


## Pixel rows y0..y1-1 of a chunk image (a job step bakes one band).
func _bake_rows(img: Image, chunk_coord: Vector2i, lod_step: int, y0: int, y1: int) -> void:
	var base := chunk_coord * CHUNK_SIZE
	for ly in range(y0, y1):
		for lx in range(img.get_width()):
			var wx := base.x + lx * lod_step + lod_step / 2
			var wy := base.y + ly * lod_step + lod_step / 2
			var sample := ctx.world_gen.sample(wx, wy)
			img.set_pixel(lx, ly, color_for(sample, wx, wy))
			if lod_step == 1:
				ctx.set_walkable(Vector2i(wx, wy), GenerationContextScript.walkable_sample(sample))


## Fills ctx.tile_env() for tile rows y0..y1-1 of a chunk (a warm-up job step).
func _warm_env_rows(chunk: Vector2i, y0: int, y1: int) -> void:
	var base := chunk * CHUNK_SIZE
	for y in range(y0, y1):
		for x in CHUNK_SIZE:
			ctx.tile_env(base.x + x, base.y + y)


## Phase 17 step 6: a chunk job's work as small steps, so the main-thread
## fallback (no worker) can spread one chunk over several frames - a whole
## Resources chunk is ~42 ms on desktop, several frames' worth on web. Each
## step is a Callable run holding ctx.mutex; together they fill `data` with
## the chunk's content for the current view (plain data, no nodes). In
## order: the image in bands of IMAGE_BAND_ROWS pixel rows, the label grids,
## one step per (guild, chunk) placement the stack filter will read - the
## guilds this view draws, in the chunk and the neighbors their margins reach
## (cached ones return at once) - then the assembly, which by then only reads
## caches. Same result as building it in one go. `fine` (the main-thread
## fallback) also warms ctx.tile_env() for those chunks in IMAGE_BAND_ROWS bands
## first: a guild's first placement in a fresh chunk otherwise samples and
## classifies every candidate tile in one step (up to ~20 ms on desktop). The
## worker skips that - it would compute tiles no candidate needs.
func job_steps(data: Dictionary, fine: bool) -> Array[Callable]:
	var chunk: Vector2i = data["chunk"]
	var lod_step: int = data["lod"]
	var img: Image = data["image"]  # null: the image on screen is kept (review P4)
	var steps: Array[Callable] = []
	if img != null:
		for y0 in range(0, img.get_height(), IMAGE_BAND_ROWS):
			steps.append(_bake_rows.bind(img, chunk, lod_step, y0, mini(y0 + IMAGE_BAND_ROWS, img.get_height())))
	if ViewModesScript.is_label_view(view_mode):
		steps.append(func() -> void: data["overlay"] = overlay_grids(chunk))
	if placements_visible_at(lod_step):
		var depth := stack_depth(placement_layers())
		var margins: Array = ResourcePlacementScript.stack_margins(CONTENT.guilds.slice(0, depth))
		var rect := Rect2i(chunk * CHUNK_SIZE, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
		if fine and depth > 0:
			for c in GenerationContextScript.chunks_in_rect(rect.grow(margins.max())):
				for y0 in range(0, CHUNK_SIZE, IMAGE_BAND_ROWS):
					steps.append(_warm_env_rows.bind(c, y0, y0 + IMAGE_BAND_ROWS))
		for i in depth:
			for c in GenerationContextScript.chunks_in_rect(rect.grow(margins[i])):
				if fine:
					for y0 in range(0, CHUNK_SIZE, GenerationContextScript.WARM_DENSITY_ROWS):
						steps.append(ctx.warm_guild_density.bind(CONTENT.guilds[i], c, y0))
				steps.append(ctx.raw_guild_chunk.bind(CONTENT.guilds[i], c))
		steps.append(func() -> void: data["placements"] = placement_chunk(chunk))
	return steps


## Biome labels are derived from the same WorldGen fields but sampled on a
## (chunk_size+1)^2 grid so boundary outlines line up with tiles one step
## into the neighboring chunk, without that chunk needing to be loaded.
## Fill/outlines always key on base biome; SUBTYPE/MODIFIERS views only
## change the drawn label text ("Forest (Montane)", "Cold, Windy" etc.), not
## the region shapes. -> [biome grid, label grid] for the overlay node.
func overlay_grids(chunk_coord: Vector2i) -> Array:
	var base := chunk_coord * CHUNK_SIZE
	var stride := CHUNK_SIZE + 1
	var show_subtype := view_mode == ViewMode.SUBTYPE
	var show_modifiers := view_mode == ViewMode.MODIFIERS
	var biome_grid := []
	var label_grid := []
	biome_grid.resize(stride * stride)
	label_grid.resize(stride * stride)

	for ly in range(stride):
		for lx in range(stride):
			var sample := ctx.world_gen.sample(base.x + lx, base.y + ly)
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


## Phase 7: the ResourceDefinitions/ResourceGuilds the current view places
## instances of, as [source, marker shape(, shape for members without a
## sprite when drawing SPRITE)] in draw order (empty = no placement markers
## in this view) - ViewModes' "layers"; the World view draws every guild
## over the Material image, trees last (as tinted sheet sprites) so they
## sit on top.
func placement_layers() -> Array:
	var layers: Variant = ViewModesScript.layers(view_mode)
	if layers is Array:
		return layers
	if layers == "world":
		return CONTENT.world_view_placement_layers()
	return [[debug_guild(), ResourceMarkerChunkScript.Shape.CIRCLE]]


func placements_visible_at(lod_step: int) -> bool:
	return not placement_layers().is_empty() and lod_step <= MAX_PLACEMENT_LOD_STEP


## ResourcePlacement decides instances purely from world coordinates, so
## each chunk is placed on its own and neighbors agree at shared edges.
## -> [[layer (a placement_layers() entry), instances], ...] in draw order.
func placement_chunk(chunk_coord: Vector2i) -> Array:
	var base := chunk_coord * CHUNK_SIZE
	var layers := placement_layers()
	var depth := stack_depth(layers)
	var stack := ctx.place_stack_chunk(base, depth) if depth > 0 else {}
	var result := []
	for layer in layers:
		var source: Resource = layer[0]
		var instances: Array = stack[source] if source is ResourceGuild else ctx.place_definition_chunk(source, base)
		if view_mode == ViewMode.QUALITY:
			instances = _quality_markers(instances)
		elif view_mode == ViewMode.DEBUG_PLACEMENT:
			instances = instances.filter(func(inst): return inst["id"] == debug_resource.id)
		result.append([layer, instances])
	# Landmark layer: the World view draws structure stamps first, under the
	# resources (which the structure_mask keeps off the footprint anyway).
	# Its layer has no source Resource (null), so it's not in
	# placement_layers() and the guild stack never sees it.
	if view_mode == ViewMode.RESOURCES:
		var parts := ctx.structures.parts_in_rect(Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)))
		result.push_front([[null, ResourceMarkerChunkScript.Shape.SPRITE], parts])
	return result


## Phase 14 Quality view: only the instances that have a quality, each a
## copy (the placement caches stay untouched) filled by its quality. Quality
## is computed here, for shown instances only, never during placement.
func _quality_markers(instances: Array) -> Array:
	var result := []
	for inst in instances:
		var quality := instance_quality(inst)
		if quality >= 0.0:
			var marker: Dictionary = inst.duplicate()
			marker["fill"] = HeatmapColorizerScript.quality(quality)
			result.append(marker)
	return result


## Phase 14: ResourceManager.get_quality() for a placed instance (-1.0 = its
## resource has no quality), from the cached state of the tile it stands on.
func instance_quality(inst: Dictionary) -> float:
	var definition: ResourceDefinition = CONTENT.definitions_by_id().get(inst["id"])
	if definition == null or definition.quality_profile == null:
		return -1.0
	var pos: Vector2 = inst["position"]
	var wx := floori(pos.x)
	var wy := floori(pos.y)
	var env := ctx.tile_env(wx, wy)
	var roll := ResourcePlacementScript.instance_roll(inst, ctx.world_seed)
	return ResourceManagerScript.get_quality(env[0], definition, ctx.world_seed, wx, wy, roll, env[1])


## A guild's instances depend only on the guilds above it in the stack, so
## a view places the stack only down to the lowest guild it draws: that many
## guilds (0 = none, e.g. Oak Placement's single definition).
func stack_depth(layers: Array) -> int:
	var depth := 0
	for layer in layers:
		if layer[0] is ResourceGuild:  # not a lone definition (Oak Placement)
			depth = maxi(depth, CONTENT.guilds.find(layer[0]) + 1)
	return depth


## The debug resource at a tile, as the guild sees it:
##   score   - its member score (suitability; exposed deposit for an ore),
##   cover   - the guild's cover (environment: how much can grow),
##   patch   - the guild's patch factor: stand membership at full suitability
##             for a stand-mode guild (Phase 14), else its patch modifier,
##   best    - the best member's score (caps the guild),
##   share   - this resource's species share of the guild,
##   density - guild density x share (its expected instances per cell).
func debug_values(wx: int, wy: int, sample: Dictionary = {}) -> Dictionary:
	var guild := debug_guild()
	var env := ctx.tile_env(wx, wy, sample)
	if not env[0].shade_known and guild.reads_shade():
		env[0].shade = ctx.guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample)
		env[0].shade_known = true
	var scores: PackedFloat32Array = ResourceManagerScript.get_member_scores(env[0], guild, ctx.world_seed, wx, wy, env[1])
	var index := guild.members.find(debug_resource)
	var best := 0.0
	for s in scores:
		best = maxf(best, s)
	var cover := ResourceManagerScript.get_guild_cover(env[0], guild)
	var patch := ResourceManagerScript.get_stand_membership(guild, cover, ctx.world_seed, wx, wy) if guild.cover_sets_area \
		else ResourceManagerScript.get_guild_patch_modifier(guild, ctx.world_seed, wx, wy)
	var share: float = ResourceManagerScript.get_species_shares(scores, guild.species_sharpness)[index]
	return {"score": scores[index], "cover": cover, "patch": patch, "best": best, "share": share,
		"density": ctx.guild_density(guild, wx, wy, sample) * share}
