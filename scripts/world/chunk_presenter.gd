extends RefCounted

## Main thread: what the world shows of each loaded chunk. Turns a finished
## chunk job's data into its terrain Sprite2D (borders shared with its
## neighbours), its biome label overlay and its resource markers with their
## shadows, styles sprites by season, and redraws a chunk's markers from its
## stored placements after a harvest. The shown placements (chunk_placements)
## are what picking reads. Only this and ChunkManager touch the scene tree.

const GameConstants := preload("res://scripts/game_constants.gd")
const GenerationContextScript := preload("res://scripts/world/generation_context.gd")
const ChunkBuilderScript := preload("res://scripts/world/chunk_builder.gd")
const ViewModesScript := preload("res://scripts/world/view_modes.gd")
const BiomeOverlayChunkScript := preload("res://scripts/render/biome_overlay_chunk.gd")
const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")
const SeasonsScript := preload("res://scripts/render/seasons.gd")
const CONTENT: WorldContent = preload("res://resources/world_content.tres")

const TILE_SIZE := GameConstants.TILE_SIZE
const CHUNK_SIZE := GenerationContextScript.CHUNK_SIZE
## Seconds a newly streamed-in chunk's label overlay takes to fade in.
const FADE_IN_SEC := 0.2
const NEIGHBOUR_STEPS: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]

var loaded_chunks: Dictionary = {}   # Vector2i chunk -> Sprite2D
var loaded_overlays: Dictionary = {} # Vector2i chunk -> Node2D (biome overlay), only in a label view
var loaded_placements: Dictionary = {} # Vector2i chunk -> Node2D (resource markers), only in a placement view
## Chunk -> its shown ChunkBuilder.placement_chunk() data, to redraw markers
## after a change and for picking.
var chunk_placements: Dictionary = {}
## Chunk -> the shown image padded with a 1-texel border (_padded_image()):
## the border holds the loaded neighbours' edge tiles (_share_borders()), so
## terrain.gdshader can blend ground across chunk borders.
var chunk_images: Dictionary = {}
## Polish pass 2: the in-game day the sprites' season colours were last
## drawn for; markers are redrawn when it changes (update_seasons()).
var season_day: int = -1

var _chunks_root: Node2D
var _overlay_root: Node2D
var _resources_root: Node2D
var _shadows_root: Node2D
var _terrain_material: ShaderMaterial
var _sway_material: ShaderMaterial
var _shadow_material: ShaderMaterial
var _session  # WorldSession: harvested instances, the occupied tent, the clock
var _builder: ChunkBuilderScript  # the view mode


func _init(roots: Dictionary, materials: Dictionary, session, builder: ChunkBuilderScript) -> void:
	_chunks_root = roots["chunks"]
	_overlay_root = roots["overlay"]
	_resources_root = roots["resources"]
	_shadows_root = roots["shadows"]
	_terrain_material = materials["terrain"]
	_sway_material = materials["sway"]
	_shadow_material = materials["shadow"]
	_session = session
	_builder = builder


## Shows one finished job - creates the chunk's Sprite2D or swaps its
## texture, and replaces its label overlay and marker node.
func show_chunk(data: Dictionary) -> void:
	var chunk_coord: Vector2i = data["chunk"]
	var lod_step: int = data["lod"]
	var base := chunk_coord * CHUNK_SIZE
	var sprite: Sprite2D = loaded_chunks.get(chunk_coord)
	var fresh := sprite == null
	if fresh:
		sprite = Sprite2D.new()
		sprite.centered = false
		sprite.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.material = _terrain_material
		_chunks_root.add_child(sprite)
		loaded_chunks[chunk_coord] = sprite
	if data["image"] != null:  # null: keep the one shown (ChunkStreamer, review P4)
		var padded := _padded_image(data["image"])
		chunk_images[chunk_coord] = padded
		_share_borders(chunk_coord)
		sprite.texture = ImageTexture.create_from_image(padded)
		sprite.region_enabled = true
		sprite.region_rect = Rect2(1, 1, padded.get_width() - 2, padded.get_height() - 2)
		sprite.scale = Vector2(TILE_SIZE * lod_step, TILE_SIZE * lod_step)

	_free_chunk_node(loaded_overlays, chunk_coord)
	if data.has("overlay"):
		var overlay := BiomeOverlayChunkScript.new()
		overlay.setup(data["overlay"][0], CHUNK_SIZE, TILE_SIZE, data["overlay"][1])
		overlay.position = sprite.position
		_overlay_root.add_child(overlay)
		loaded_overlays[chunk_coord] = overlay

	_free_chunk_node(loaded_placements, chunk_coord)
	chunk_placements.erase(chunk_coord)
	if data.has("placements"):
		chunk_placements[chunk_coord] = data["placements"]
		var markers := marker_node(base, data["placements"])
		_resources_root.add_child(markers)
		loaded_placements[chunk_coord] = markers
	# Polish: a label overlay that newly streams in fades in (FADE_IN_SEC)
	# instead of popping; rebuilding one already on screen (view change)
	# swaps in place. Only overlays: the terrain, sway and shadow shaders
	# replace COLOR (so modulate never shows), and sway.gdshader and
	# cast_shadow.gdshader read data packed into the vertex colour, which
	# modulate would scale - sprites bent like grass mid-fade (review C1).
	var overlay_node = loaded_overlays.get(chunk_coord)
	if fresh and overlay_node != null:
		overlay_node.modulate.a = 0.0
		overlay_node.create_tween().tween_property(overlay_node, "modulate:a", 1.0, FADE_IN_SEC)


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


## When a chunk is shown: fills its border from each loaded neighbour of the
## same size (LOD) and theirs from it, re-uploading the neighbours'
## textures - so tile blending carries across chunk borders.
func _share_borders(chunk_coord: Vector2i) -> void:
	var img: Image = chunk_images[chunk_coord]
	var n := img.get_width() - 2
	for d in NEIGHBOUR_STEPS:
		var other: Image = chunk_images.get(chunk_coord + d)
		if other == null or other.get_width() != img.get_width():
			continue
		_copy_border(img, other, d, n)
		_copy_border(other, img, -d, n)
		var sprite: Sprite2D = loaded_chunks.get(chunk_coord + d)
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


func unload_chunk(chunk_coord: Vector2i) -> void:
	_free_chunk_node(loaded_chunks, chunk_coord)
	chunk_images.erase(chunk_coord)
	_free_chunk_node(loaded_overlays, chunk_coord)
	_free_chunk_node(loaded_placements, chunk_coord)
	chunk_placements.erase(chunk_coord)


## One marker node drawing a chunk's ChunkBuilder.placement_chunk() layers,
## minus the instances the player harvested (Phase 16) - filtered here, when
## the node is built, so a job generated before a harvest can't show it.
func marker_node(base: Vector2i, placements: Array) -> Node2D:
	var markers := ResourceMarkerChunkScript.new()
	markers.material = _sway_material
	for entry in placements:
		var layer: Array = entry[0]
		var source: Resource = layer[0]
		if source == null:  # structure parts (ChunkBuilder.placement_chunk()): each carries its sheet tile and tint
			var sprites := {}
			for inst in entry[1]:
				sprites[inst["id"]] = {"tile": inst["sheet"], "size": 1.0}
			var parts: Array = entry[1]
			if _session.tent_tile != null:  # the occupied tent is drawn by ChunkManager's tent effect
				parts = parts.filter(func(p): return Vector2i((p["position"] as Vector2).floor()) != _session.tent_tile)
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
		var kept: Array = _session.unchanged(entry[1])
		markers.add_instances(kept, base, TILE_SIZE, source.minimum_spacing, marker_colors(source, as_sprites), layer[1], sprite_tiles(source), fallback)
		if as_sprites and source is ResourceGuild:
			var defs := CONTENT.definitions_by_id()
			var casts: Array[bool] = []
			for inst in kept:
				casts.append(defs[inst["id"]].casts_shadow)
			if casts.has(true):
				markers.add_shadows(first, _shadow_material, casts)
	markers.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	var shadows: Node2D = markers.shadow_layer()
	if shadows != null:
		shadows.position = markers.position
		_shadows_root.add_child(shadows)
	return markers


## Instance id -> marker color for a ResourceDefinition or ResourceGuild:
## debug_color, or sprite_color for members drawn as sprites - its alpha
## then carries the member's sway (sway_alpha()).
func marker_colors(source: Resource, as_sprites: bool = false) -> Dictionary:
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
	var c: Color = SeasonsScript.apply(definition.sprite_color, SeasonsScript.tint(definition.season_class, SeasonsScript.year_fraction(_session.clock)))
	c.a = sway_alpha(definition.sway)
	return c


## A sprite's draw-colour alpha carrying its sway to the sway shader
## (shaders/sway.gdshader turns it back into sway and draws opaque):
## 1 - sway / 2, so opaque (alpha 1) draws never sway.
static func sway_alpha(sway: float) -> float:
	return 1.0 - clampf(sway, 0.0, 1.0) * 0.5


## Instance id -> {"tile", "size"} (resource_marker_chunk.gd), for members
## that have a sprite.
func sprite_tiles(source: Resource) -> Dictionary:
	var tiles := {}
	for member in (source.members if source is ResourceGuild else [source]):
		if member.sprite_tile.x >= 0:
			tiles[member.id] = {"tile": member.sprite_tile, "size": member.sprite_size, "texture": member.sprite_texture}
	return tiles


## Rebuilds one loaded chunk's marker node from its stored placements (no
## generation), e.g. after a harvest.
func redraw_markers(chunk_coord: Vector2i) -> void:
	if not chunk_placements.has(chunk_coord):
		return
	_free_chunk_node(loaded_placements, chunk_coord)
	var markers := marker_node(chunk_coord * CHUNK_SIZE, chunk_placements[chunk_coord])
	_resources_root.add_child(markers)
	loaded_placements[chunk_coord] = markers


## Sprites take their season colour (Seasons, per
## ResourceDefinition.season_class) when their markers are built; once per
## in-game day every loaded marker node is recoloured in place
## (ResourceMarkerChunk.recolor(), review P3), so colours drift through the
## year. Only the World view draws sprites.
func update_seasons() -> void:
	var day: int = _session.clock.day_index()
	if day == season_day:
		return
	season_day = day
	if _builder.view_mode != ViewModesScript.ViewMode.RESOURCES:
		return
	var colors := {}
	for definition in CONTENT.definitions_by_id().values():
		if definition.sprite_tile.x >= 0:
			colors[definition.id] = sprite_fill(definition)
	for markers in loaded_placements.values():
		markers.recolor(colors)
