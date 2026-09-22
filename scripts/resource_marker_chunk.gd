extends Node2D

## One chunk's worth of placed resource instances (Phase 7), drawn as simple
## markers in a single _draw() - one CanvasItem per chunk rather than one
## Node per instance, same reasoning as the per-chunk baked Sprite2D. Pure
## renderer: the instance data comes from ResourcePlacement.place_in_rect()
## (or place_guild_in_rect()) and is never modified here. Positions are in
## tile units, relative to the world origin; this node sits at the chunk's
## pixel origin.

const DEFAULT_FILL := Color(0.10, 0.32, 0.10)
const OUTLINE := Color(0.02, 0.06, 0.02)

var _positions: PackedVector2Array = PackedVector2Array()
var _fills: PackedColorArray = PackedColorArray()
var _radius: float = 3.0


## instances: ResourcePlacement's Dictionaries. origin_tile: this chunk's
## top-left tile, so positions can be drawn chunk-local. colors: instance
## "id" -> fill Color (ResourceDefinition.debug_color).
func setup(instances: Array, origin_tile: Vector2i, tile_size: int, footprint_tiles: float, colors: Dictionary = {}) -> void:
	_positions.clear()
	_fills.clear()
	for inst in instances:
		_positions.append(((inst["position"] as Vector2) - Vector2(origin_tile)) * tile_size)
		_fills.append(colors.get(inst["id"], DEFAULT_FILL))
	# Kept under half the minimum spacing (+ outline), so markers never overlap.
	_radius = maxf(footprint_tiles * tile_size * 0.35, 2.0)
	queue_redraw()


func _draw() -> void:
	for i in _positions.size():
		draw_circle(_positions[i], _radius + 1.0, OUTLINE)
		draw_circle(_positions[i], _radius, _fills[i])
