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
## coloring stays in data (ResourceDefinition.sprite_color).

enum Shape { CIRCLE, TRIANGLE, SQUARE, DIAMOND, HEXAGON, SPRITE }

const SPRITE_SHEET := preload("res://urizen_onebit_tileset__v2d0.png")
## Sheet layout, as in tileset.tres: 12 px tiles, 1 px margin and separation.
const SPRITE_SIZE := 12
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
## drawn as `fallback` instead.
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
		_positions.append(((inst["position"] as Vector2) - Vector2(origin_tile)) * tile_size)
		_fills.append(colors.get(inst["id"], DEFAULT_FILL))
		_radii.append(radius)
		_shapes.append(inst_shape)
		_textures.append(texture)
		_sprite_sizes.append(sprite_px)
	queue_redraw()


func _draw() -> void:
	for i in _positions.size():
		if _shapes[i] == Shape.SPRITE:
			# 1 px dark outline (four offset copies), then the tinted sprite.
			var size := _sprite_sizes[i]
			var rect := Rect2(_positions[i] - Vector2.ONE * size * 0.5, Vector2.ONE * size)
			var px := size / SPRITE_SIZE
			for offset in [Vector2(px, 0), Vector2(-px, 0), Vector2(0, px), Vector2(0, -px)]:
				draw_texture_rect(_textures[i], Rect2(rect.position + offset, rect.size), false, OUTLINE)
			draw_texture_rect(_textures[i], rect, false, _fills[i])
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


static func sprite_texture(tile: Vector2i) -> Texture2D:
	if not _sprite_cache.has(tile):
		_sprite_cache[tile] = ImageTexture.create_from_image(sprite_image(tile))
	return _sprite_cache[tile]
