extends Node2D

## One chunk's worth of placed resource instances (Phase 7), drawn as simple
## markers in a single _draw() - one CanvasItem per chunk rather than one
## Node per instance, same reasoning as the per-chunk baked Sprite2D. Pure
## renderer: the instance data comes from ResourcePlacement.place_in_rect()
## (or place_guild_in_rect()) and is never modified here. Positions are in
## tile units, relative to the world origin; this node sits at the chunk's
## pixel origin. Several layers (e.g. rocks, shrubs, trees in the Resources
## view) can be added to one node; they draw in the order added.

enum Shape { CIRCLE, TRIANGLE, SQUARE, DIAMOND }

const DEFAULT_FILL := Color(0.10, 0.32, 0.10)
const OUTLINE := Color(0.02, 0.06, 0.02)

var _positions: PackedVector2Array = PackedVector2Array()
var _fills: PackedColorArray = PackedColorArray()
var _radii: PackedFloat32Array = PackedFloat32Array()
var _shapes: PackedInt32Array = PackedInt32Array()


## Appends one layer. instances: ResourcePlacement's Dictionaries.
## origin_tile: this chunk's top-left tile, so positions can be drawn
## chunk-local. colors: instance "id" -> fill Color
## (ResourceDefinition.debug_color). shape: TRIANGLE reads as a tree,
## SQUARE as a rock, DIAMOND as a wetland plant, CIRCLE is the plain marker.
func add_instances(instances: Array, origin_tile: Vector2i, tile_size: int, footprint_tiles: float, colors: Dictionary = {}, shape: Shape = Shape.CIRCLE) -> void:
	# Kept under half the minimum spacing (+ outline), so markers of one
	# layer never overlap.
	var radius := maxf(footprint_tiles * tile_size * 0.35, 2.0)
	for inst in instances:
		_positions.append(((inst["position"] as Vector2) - Vector2(origin_tile)) * tile_size)
		_fills.append(colors.get(inst["id"], DEFAULT_FILL))
		_radii.append(radius)
		_shapes.append(shape)
	queue_redraw()


func _draw() -> void:
	for i in _positions.size():
		if _shapes[i] == Shape.CIRCLE:
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
		_:
			var poly := PackedVector2Array()
			for k in 12:
				poly.append(p + Vector2.from_angle(TAU * k / 12.0) * r)
			return poly
