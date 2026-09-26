extends RefCounted

## Main thread: which placed resource is under a point (§4.1 step 8, moved
## out of chunk_manager.gd) - for the inspector (resource_at(), which
## places the stack around the point), and for hovering and harvesting
## (hover_target(), which only looks at what ChunkPresenter shows, so it
## never generates: review W2). In the World view only a sprite's opaque
## pixels count (sprite_drawn(), sprite_image()).

const GameConstants := preload("res://scripts/game_constants.gd")
const GenerationContextScript := preload("res://scripts/world/generation_context.gd")
const ChunkBuilderScript := preload("res://scripts/world/chunk_builder.gd")
const ChunkPresenterScript := preload("res://scripts/world/chunk_presenter.gd")
const ViewModesScript := preload("res://scripts/world/view_modes.gd")
const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")
const CONTENT: WorldContent = preload("res://resources/world_content.tres")
const ViewMode := ViewModesScript.ViewMode

const TILE_SIZE := GameConstants.TILE_SIZE
const CHUNK_SIZE := GenerationContextScript.CHUNK_SIZE

var _ctx: GenerationContextScript
var _builder: ChunkBuilderScript  # the view mode
var _presenter: ChunkPresenterScript  # the shown placements
var _session  # WorldSession: what the player harvested
var _entity_of: Callable  # (inst) -> its ResourceInstance (ChunkManager.get_resource_instance())
var _sprite_images: Dictionary = {}  # sprite_texture -> its Image, for _sprite_covers()


func _init(context: GenerationContextScript, builder: ChunkBuilderScript, presenter: ChunkPresenterScript, session, entity_of: Callable) -> void:
	_ctx = context
	_builder = builder
	_presenter = presenter
	_session = session
	_entity_of = entity_of


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
func resource_at(point: Vector2, include_harvested: bool = true) -> Dictionary:
	var tile := Vector2i(floori(point.x), floori(point.y))
	var stack := _ctx.place_stack(Rect2i(tile - Vector2i(2, 2), Vector2i(5, 5)))
	var candidates := []
	for guild in CONTENT.guilds:
		candidates.append([guild, stack[guild]])
	var best := pick(point, candidates, include_harvested)
	if not best.is_empty():
		best["name"] = String(best["id"]).capitalize()
		best["guild_name"] = String(best["guild"]).capitalize()
		best["entity"] = _entity_of.call(best)
	return best


## The pick rule of resource_at() over `candidates`, [[source (a guild or
## ResourceDefinition), instances], ...]; a copy of the picked instance, or {}.
func pick(point: Vector2, candidates: Array, include_harvested: bool) -> Dictionary:
	var tile := Vector2i(floori(point.x), floori(point.y))
	var best := {}
	var best_dist := INF
	var sprites := _builder.view_mode == ViewMode.RESOURCES
	for layer in candidates:
		var reach := maxf(layer[0].minimum_spacing * 0.35, 0.5)
		for inst in layer[1]:
			if not include_harvested and _session.is_harvested(inst):
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
## resource_at() places), as pick() candidates: what the current view
## draws, nothing where it draws no markers (heatmap and terrain views,
## zoomed out past ChunkBuilder.MAX_PLACEMENT_LOD_STEP). Main thread; no generation.
func _drawn_near(tile: Vector2i) -> Array:
	var rect := Rect2i(tile - Vector2i(2, 2), Vector2i(5, 5))
	var result := []
	var center := Vector2i((Vector2(tile) / CHUNK_SIZE).floor())
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for entry in _presenter.chunk_placements.get(center + Vector2i(dx, dy), []):
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
	var definition: ResourceDefinition = CONTENT.definitions_by_id().get(inst.get("id", ""))
	if definition == null or definition.sprite_tile.x < 0:
		return []
	var sprite := {"tile": definition.sprite_tile, "size": definition.sprite_size, "texture": definition.sprite_texture}
	return ResourceMarkerChunkScript.sprite_draw(sprite, (ResourceMarkerChunkScript.pivot(inst) * TILE_SIZE).round()) + [ChunkPresenterScript.sway_alpha(definition.sway)]


## A sprite texture's pixels (cached), for hit tests and outlines.
func sprite_image(texture: Texture2D) -> Image:
	if not _sprite_images.has(texture):
		_sprite_images[texture] = texture.get_image()
	return _sprite_images[texture]


## Polish (HoverHighlight): the resource a left click at `point` (tile
## units) would harvest, or {}: resource_at()'s pick among what is drawn
## there (_drawn_near()) and not harvested. It never generates or waits on
## the worker, so hovering can't stall a frame; where the view draws no
## markers there's nothing to pick. No "entity" or display names.
func hover_target(point: Vector2) -> Dictionary:
	return pick(point, _drawn_near(Vector2i(point.floor())), false)
