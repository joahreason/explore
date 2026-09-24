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
## drawn in one call, snapped to whole sprite pixels.

enum Shape { CIRCLE, TRIANGLE, SQUARE, DIAMOND, HEXAGON, SPRITE }

const SPRITE_SHEET := preload("res://urizen_onebit_tileset__v2d0.png")
## Sheet layout, as in tileset.tres: 12 px tiles, 1 px margin and separation.
const SPRITE_SIZE := 12
## Pixels of outline ring around the 12 px art in outlined_image().
const OUTLINE_PAD := 1
const SPRITE_STRIDE := 13

const DEFAULT_FILL := Color(0.10, 0.32, 0.10)
const OUTLINE := Color(0.02, 0.06, 0.02)

var _positions: PackedVector2Array = PackedVector2Array()
var _fills: PackedColorArray = PackedColorArray()
var _radii: PackedFloat32Array = PackedFloat32Array()
var _shapes: PackedInt32Array = PackedInt32Array()
var _textures: Array[Texture2D] = []  # per instance; null unless drawn as a sprite
var _sprite_sizes: PackedFloat32Array = PackedFloat32Array()  # per instance, pixels

static var _sheet: Image
static var _sprite_cache: Dictionary = {}  # Vector2i tile -> ImageTexture


## Appends one layer. instances: ResourcePlacement's Dictionaries.
## origin_tile: this chunk's top-left tile, so positions can be drawn
## chunk-local. colors: instance "id" -> fill Color
## (ResourceDefinition.debug_color). shape: TRIANGLE reads as a tree,
## SQUARE as a rock, DIAMOND as a wetland plant, HEXAGON as an ore outcrop,
## CIRCLE is the plain marker. SPRITE draws sprites[id] = {"tile": sheet
## tile (Vector2i), "size": width in tiles}; an id without an entry is
## drawn as `fallback` instead. An instance's own "fill" Color, if it has
## one (Phase 14 Quality view), overrides colors.
func add_instances(instances: Array, origin_tile: Vector2i, tile_size: int, footprint_tiles: float, colors: Dictionary = {}, shape: Shape = Shape.CIRCLE, sprites: Dictionary = {}, fallback: Shape = Shape.TRIANGLE) -> void:
	# Kept under half the minimum spacing (+ outline), so markers of one
	# layer never overlap.
	var radius := maxf(footprint_tiles * tile_size * 0.35, 2.0)
	for inst in instances:
		var texture: Texture2D = null
		var sprite_px := 0.0
		var inst_shape := shape
		if shape == Shape.SPRITE:
			if sprites.has(inst["id"]):
				texture = sprite_texture(sprites[inst["id"]]["tile"])
				sprite_px = float(sprites[inst["id"]]["size"]) * tile_size
			else:
				inst_shape = fallback
		var pos: Vector2 = inst["position"]
		if texture != null:
			# Sprites sit centred in the tile their instance falls in, on the
			# terrain grid (the exact position stays in the data).
			pos = Vector2(pos.floor()) + Vector2(0.5, 0.5)
		_positions.append((pos - Vector2(origin_tile)) * tile_size)
		_fills.append(inst["fill"] if inst.has("fill") else colors.get(inst["id"], DEFAULT_FILL))
		_radii.append(radius)
		_shapes.append(inst_shape)
		_textures.append(texture)
		_sprite_sizes.append(sprite_px)
	queue_redraw()


## Soft ground shadows under sprites (a first-pass polish): ellipses at the
## base of each instance's tile, drawn by a child node behind this one
## (show_behind_parent) that has no material, so they neither sway with the
## sprites nor carry the sway encoding. shadow_size scales the ellipse (1 =
## a tree); positions as in add_instances().
const SHADOW_COLOR := Color(0, 0, 0, 0.28)


func add_shadows(instances: Array, origin_tile: Vector2i, tile_size: int, shadow_size: float) -> void:
	if shadow_size <= 0.0 or instances.is_empty():
		return
	if _shadows == null:
		_shadows = _ShadowLayer.new()
		_shadows.name = "Shadows"
		_shadows.show_behind_parent = true
		add_child(_shadows)
	var radii := Vector2(0.42, 0.15) * shadow_size * tile_size
	for inst in instances:
		var tile_center := Vector2((inst["position"] as Vector2).floor()) + Vector2(0.5, 0.5)
		var center := (tile_center - Vector2(origin_tile)) * tile_size + Vector2(0.08, 0.36) * tile_size
		_shadows.ellipses.append(Rect2(center - radii, radii * 2.0))
	_shadows.queue_redraw()


var _shadows: _ShadowLayer = null


class _ShadowLayer extends Node2D:
	var ellipses: Array[Rect2] = []

	func _draw() -> void:
		for r in ellipses:
			var poly := PackedVector2Array()
			for k in 12:
				poly.append(r.get_center() + Vector2.from_angle(TAU * k / 12.0) * r.size * 0.5)
			draw_colored_polygon(poly, SHADOW_COLOR)


func shadow_count() -> int:
	return 0 if _shadows == null else _shadows.ellipses.size()


func _draw() -> void:
	for i in _positions.size():
		if _shapes[i] == Shape.SPRITE:
			# The outlined texture is the 12 px art plus a 1 px ring (OUTLINE_PAD);
			# the art stays size x size, snapped to its own pixel grid so every
			# sprite pixel renders the same width at any zoom. The tint only
			# darkens the baked outline further.
			var size := _sprite_sizes[i]
			var px := size / SPRITE_SIZE
			var top_left := ((_positions[i] - Vector2.ONE * size * 0.5) / px).round() * px
			draw_texture_rect(_textures[i], Rect2(top_left, Vector2.ONE * size).grow(px * OUTLINE_PAD), false, _fills[i])
		elif _shapes[i] == Shape.CIRCLE:
			draw_circle(_positions[i], _radii[i] + 1.0, OUTLINE)
			draw_circle(_positions[i], _radii[i], _fills[i])
		else:
			draw_colored_polygon(shape_polygon(_shapes[i], _positions[i], _radii[i] + 1.5), OUTLINE)
			draw_colored_polygon(shape_polygon(_shapes[i], _positions[i], _radii[i]), _fills[i])


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
