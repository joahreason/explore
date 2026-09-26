extends Node2D

## One chunk's worth of placed resource instances (Phase 7), drawn as simple
## markers in a single _draw() - one CanvasItem per chunk rather than one
## Node per instance, same reasoning as the per-chunk baked Sprite2D. Pure
## renderer: the instance data comes from ResourcePlacement.place_in_rect()
## (or place_guild_in_rect()) and is never modified here. Positions are in
## tile units, relative to the world origin; this node sits at the chunk's
## pixel origin. Several layers (e.g. rocks, shrubs, trees in the Resources
## view) can be added to one node; they draw in the order added.
##
## Shape.SPRITE draws each instance's tile from the one-bit Urizen sheet
## (Phase 8 step 6): its white pixels, tinted by the instance's color, so
## coloring stays in data (ResourceDefinition.sprite_color), with a 1 px dark
## outline and dark interior detail baked into one texture (outlined_image()),
## drawn in one call, snapped to whole sprite pixels. The sheet art stays at
## its native 12 px (1 art pixel = 1 world pixel) inside the 16 px tiles,
## its bottom middle as its pivot like the pivoted art.
##
## Art-style test (16 px tiles): an entry can instead carry its own
## "texture" (ResourceDefinition.sprite_texture) - art with its outline
## already drawn and its pivot at the bottom middle, drawn 1:1
## (pivot_rect()), so tall art (trees) reaches up into the tiles above.
## A sprite's pivot is its tile centre offset by up to PIVOT_SPREAD / 2 of a
## tile each way, from where in the tile the instance was placed (pivot()),
## so it is deterministic; an instance's own "pivot" (tile units -
## structure parts, kept on the grid) overrides it.
##
## Depth: the drawing is split into child nodes (_Row), one per pivot y
## (whole pixels), at that y. This node y-sorts them, and as it sits in the
## y-sorted Resources node (with the Player) each sorts with the player and
## the other chunks' sprites: whatever stands further south draws in front.

enum Shape { CIRCLE, TRIANGLE, SQUARE, DIAMOND, HEXAGON, SPRITE }

const GameConstants := preload("res://scripts/game_constants.gd")
const SPRITE_SHEET := preload("res://urizen_onebit_tileset__v2d0.png")
## Sheet layout, as in tileset.tres: 12 px tiles, 1 px margin and separation.
const SPRITE_SIZE := 12
## Pixels of outline ring around the 12 px art in outlined_image().
const OUTLINE_PAD := 1
const SPRITE_STRIDE := 13

const DEFAULT_FILL := Color(0.10, 0.32, 0.10)
const OUTLINE := Color(0.02, 0.06, 0.02)
## How far (share of a tile, in all) a sprite's pivot may sit from its tile
## centre: 0.75 = up to 6 px each way in a 16 px tile.
const PIVOT_SPREAD := 0.75

var _positions: PackedVector2Array = PackedVector2Array()
var _fills: PackedColorArray = PackedColorArray()
var _radii: PackedFloat32Array = PackedFloat32Array()
var _shapes: PackedInt32Array = PackedInt32Array()
var _textures: Array[Texture2D] = []  # per instance; null unless drawn as a sprite
var _rects: Array[Rect2] = []  # per instance: where its sprite is drawn (unused for shapes)
var _rows: Dictionary = {}  # pivot y (whole px, chunk-local) -> _Row
var _tiles: Array[Vector2i] = []  # per instance: the tile it was placed in (world tiles)

static var _sheet: Image
static var _sprite_cache: Dictionary = {}  # Vector2i tile -> ImageTexture


## Appends one layer. instances: ResourcePlacement's Dictionaries.
## origin_tile: this chunk's top-left tile, so positions can be drawn
## chunk-local. colors: instance "id" -> fill Color
## (ResourceDefinition.debug_color). shape: TRIANGLE reads as a tree,
## SQUARE as a rock, DIAMOND as a wetland plant, HEXAGON as an ore outcrop,
## CIRCLE is the plain marker. SPRITE draws sprites[id] = {"tile": sheet
## tile (Vector2i), "size": width in tiles, optional "texture": pivoted art
## drawn instead of the sheet tile}; an id without an entry is
## drawn as `fallback` instead. An instance's own "fill" Color, if it has
## one (Phase 14 Quality view), overrides colors.
func add_instances(instances: Array, origin_tile: Vector2i, tile_size: int, footprint_tiles: float, colors: Dictionary = {}, shape: Shape = Shape.CIRCLE, sprites: Dictionary = {}, fallback: Shape = Shape.TRIANGLE) -> void:
	# Kept under half the minimum spacing (+ outline), so markers of one
	# layer never overlap.
	var radius := maxf(footprint_tiles * tile_size * 0.35, 2.0)
	var first := _positions.size()
	for inst in instances:
		var texture: Texture2D = null
		var sprite: Dictionary = sprites.get(inst["id"], {})
		var inst_shape := shape
		if shape == Shape.SPRITE and sprite.is_empty():
			inst_shape = fallback
		elif shape == Shape.SPRITE:
			texture = sprite["texture"] if sprite.get("texture") != null else sprite_texture(sprite["tile"])
		var pos: Vector2 = inst["position"]
		_tiles.append(Vector2i(pos.floor()))
		if texture != null:
			pos = pivot(inst)
		var p := (pos - Vector2(origin_tile)) * tile_size
		if texture != null:
			p = p.round()
		_positions.append(p)
		_fills.append(inst["fill"] if inst.has("fill") else colors.get(inst["id"], DEFAULT_FILL))
		_radii.append(radius)
		_shapes.append(inst_shape)
		_textures.append(texture)
		_rects.append(sprite_draw(sprite, p)[1] if texture != null else Rect2())
	y_sort_enabled = true
	for i in range(first, _positions.size()):
		var y := roundi(_positions[i].y)
		if not _rows.has(y):
			var node := _Row.new()
			node.chunk = self
			node.use_parent_material = true  # the sway shader
			node.position = Vector2(0, y)
			add_child(node)
			_rows[y] = node
		_rows[y].indices.append(i)
		_rows[y].queue_redraw()


## Where an instance's sprite stands (its pivot, world tile units): its own
## "pivot" if it has one, else its tile centre offset by where in the tile
## it was placed, scaled by PIVOT_SPREAD.
static func pivot(inst: Dictionary) -> Vector2:
	if inst.has("pivot"):
		return inst["pivot"]
	var pos: Vector2 = inst["position"]
	var tile := pos.floor()
	return tile + Vector2(0.5, 0.5) + (pos - tile - Vector2(0.5, 0.5)) * PIVOT_SPREAD


## A sprite entry ({"tile", "size", optional "texture"}, as add_instances()
## takes) with its pivot at `pivot_px`: [the drawn texture, its rect].
static func sprite_draw(sprite: Dictionary, pivot_px: Vector2) -> Array:
	if sprite.get("texture") != null:
		var texture: Texture2D = sprite["texture"]
		return [texture, pivot_rect(pivot_px, texture.get_size())]
	var art_px := float(sprite["size"]) * SPRITE_SIZE
	return [sprite_texture(sprite["tile"]), sprite_rect(pivot_px - Vector2(0, art_px * 0.5), art_px)]


## Cast shadows (polish): the sprites of the instances added from index
## `from` on whose `casts` entry (one per instance, in order) is true get a
## shadow - their own silhouette, drawn with `material`
## (shaders/cast_shadow.gdshader), which flattens it onto the ground away
## from the sun or moon (SunShadow) and sways it with the plant (the draw
## colour's alpha carries the same sway as the sprite's). Only sprite
## instances cast one. The shadows are a separate node (shadow_layer())
## that the caller parents under every chunk's sprites - a shadow reaching
## into the next chunk must not cover that chunk's trees; it is freed with
## this node.
func add_shadows(from: int, material: Material, casts: Array[bool]) -> void:
	if _shadows == null:
		_shadows = _ShadowLayer.new()
		_shadows.name = "Shadows"
		_shadows.material = material
		tree_exiting.connect(func(): if is_instance_valid(_shadows): _shadows.queue_free())
	for i in range(from, _positions.size()):
		if _shapes[i] != Shape.SPRITE or not casts[i - from]:
			continue
		_shadows.textures.append(_textures[i])
		_shadows.rects.append(_rects[i])
		_shadows.colors.append(shadow_color(_rects[i].size.y, _fills[i].a))
	_shadows.queue_redraw()


## The sprites of this chunk whose pivot is at one y, placed at that y so
## y-sorting puts them in depth order; draws its instances (indices into the
## chunk's arrays, in the order added) with draw_instance().
class _Row extends Node2D:
	var chunk: Node2D
	var indices: PackedInt32Array = PackedInt32Array()

	func _draw() -> void:
		draw_set_transform(-position)
		for i in indices:
			chunk.draw_instance(self, i)


## Instances added so far (the next add_instances() starts here).
func instance_count() -> int:
	return _positions.size()


var _shadows: _ShadowLayer = null


class _ShadowLayer extends Node2D:
	var textures: Array[Texture2D] = []
	var rects: Array[Rect2] = []
	var colors: Array[Color] = []

	func _draw() -> void:
		for i in textures.size():
			draw_texture_rect(textures[i], rects[i], false, colors[i])


func shadow_count() -> int:
	return 0 if _shadows == null else _shadows.textures.size()


## The node drawing this chunk's shadows (null if none): parent it under
## all sprites, at this node's position.
func shadow_layer() -> Node2D:
	return _shadows


## Where a sprite of `size` px centred at `center` is drawn: its art snapped
## to whole sprite pixels, grown by the baked outline ring.
static func sprite_rect(center: Vector2, size: float) -> Rect2:
	var px := size / SPRITE_SIZE
	var top_left := ((center - Vector2.ONE * size * 0.5) / px).round() * px
	return Rect2(top_left, Vector2.ONE * size).grow(px * OUTLINE_PAD)


## Where art of `size` px with its pivot at the bottom middle is drawn, its
## pivot at `pivot`, snapped to whole pixels.
static func pivot_rect(pivot: Vector2, size: Vector2) -> Rect2:
	return Rect2((pivot - Vector2(size.x * 0.5, size.y)).round(), size)


## The draw colour of a cast shadow for a sprite `height` px tall, whose
## sprite's draw alpha (its sway) is `alpha`.
static func shadow_color(height: float, alpha: float) -> Color:
	return Color(height / GameConstants.SHADOW_HEIGHT_SCALE, 0, 0, alpha)


## Draws instance i on `canvas` (its _Row, transformed to chunk-local).
func draw_instance(canvas: CanvasItem, i: int) -> void:
	if _shapes[i] == Shape.SPRITE:
		# The outlined sheet texture is the 12 px art plus a 1 px ring
		# (OUTLINE_PAD), snapped to its own pixel grid so every sprite
		# pixel renders the same width at any zoom. The tint only darkens
		# the outline further.
		canvas.draw_texture_rect(_textures[i], _rects[i], false, _fills[i])
	elif _shapes[i] == Shape.CIRCLE:
		canvas.draw_circle(_positions[i], _radii[i] + 1.0, OUTLINE)
		canvas.draw_circle(_positions[i], _radii[i], _fills[i])
	else:
		canvas.draw_colored_polygon(shape_polygon(_shapes[i], _positions[i], _radii[i] + 1.5), OUTLINE)
		canvas.draw_colored_polygon(shape_polygon(_shapes[i], _positions[i], _radii[i]), _fills[i])


## Outline of a marker centered on p, fitting a circle of radius r (a
## 12-gon for CIRCLE, for rasterizing it outside _draw()).
static func shape_polygon(shape: Shape, p: Vector2, r: float) -> PackedVector2Array:
	match shape:
		Shape.TRIANGLE:
			return PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.87, r * 0.5), p + Vector2(-r * 0.87, r * 0.5)])
		Shape.SQUARE:
			var h := r * 0.75
			return PackedVector2Array([p + Vector2(-h, -h), p + Vector2(h, -h), p + Vector2(h, h), p + Vector2(-h, h)])
		Shape.DIAMOND:
			return PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.6, 0), p + Vector2(0, r), p + Vector2(-r * 0.6, 0)])
		Shape.HEXAGON:
			var hex := PackedVector2Array()
			for k in 6:
				hex.append(p + Vector2.from_angle(TAU * k / 6.0) * r)
			return hex
		_:
			var poly := PackedVector2Array()
			for k in 12:
				poly.append(p + Vector2.from_angle(TAU * k / 12.0) * r)
			return poly


## One sheet tile as white-on-transparent (the one-bit sheet is white on
## opaque black), so a modulate color tints just the drawing. Cached; only
## the tiles actually used are converted.
static func sprite_image(tile: Vector2i) -> Image:
	if _sheet == null:
		_sheet = SPRITE_SHEET.get_image()
		_sheet.convert(Image.FORMAT_RGBA8)
	var img := _sheet.get_region(Rect2i(Vector2i.ONE + tile * SPRITE_STRIDE, Vector2i(SPRITE_SIZE, SPRITE_SIZE)))
	for y in SPRITE_SIZE:
		for x in SPRITE_SIZE:
			var v := img.get_pixel(x, y).v
			img.set_pixel(x, y, Color(1, 1, 1, v))
	return img


## The drawn sprite: sprite_image() on a (12 + 2 x OUTLINE_PAD) px canvas
## with its art white (to be tinted) and OUTLINE where the tile's own black
## pixels are part of the drawing - anything enclosed by the art (detail
## lines, dithering, holes) - plus a ring of OUTLINE around the silhouette
## (8 directions, so corners close). Before, the outline was four offset
## copies: open at diagonal corners, and the ground showed through the
## art's black detail wherever no copy happened to cover it.
static func outlined_image(tile: Vector2i) -> Image:
	var art := sprite_image(tile)
	var n := SPRITE_SIZE + 2 * OUTLINE_PAD
	var opaque := func(x: int, y: int) -> bool:
		var ax := x - OUTLINE_PAD
		var ay := y - OUTLINE_PAD
		return ax >= 0 and ay >= 0 and ax < SPRITE_SIZE and ay < SPRITE_SIZE and art.get_pixel(ax, ay).a >= 0.5
	# Background = transparent pixels reachable from the canvas edge.
	var outside := {Vector2i.ZERO: true}
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	var qi := 0
	while qi < queue.size():
		var p := queue[qi]
		qi += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if q.x < 0 or q.y < 0 or q.x >= n or q.y >= n or outside.has(q) or opaque.call(q.x, q.y):
				continue
			outside[q] = true
			queue.append(q)
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			if opaque.call(x, y):
				img.set_pixel(x, y, Color.WHITE)
			elif not outside.has(Vector2i(x, y)):
				img.set_pixel(x, y, OUTLINE)
			else:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if opaque.call(x + dx, y + dy):
							img.set_pixel(x, y, OUTLINE)
	return img


static func sprite_texture(tile: Vector2i) -> Texture2D:
	if not _sprite_cache.has(tile):
		_sprite_cache[tile] = ImageTexture.create_from_image(outlined_image(tile))
	return _sprite_cache[tile]
