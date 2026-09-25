extends Node2D

## The player character: a sprite from the Urizen sheet that moves tile by
## tile along a path (ChunkManager.find_path(), started by a tap / left
## click - see ChunkManager._on_map_tapped()), diagonals included. Its
## position (the node's origin, the pivot for the hop and the facing flip)
## is its feet: the bottom centre of the tile it stands on (feet_point()),
## the sprite drawn above. Each step glides to the next tile's feet point
## with a small hop. tile() is the tile it stands on - or, mid-step, the one it
## is stepping onto (a new walk starts from there once the step is done).
## Walking runs in real time (not the game clock: a paused clock doesn't
## freeze the player). At the end of a path it calls the walk's `on_arrive`
## Callable, if any (harvesting a tapped resource). Drawn facing its
## direction of travel, with a cast shadow on the ground (the world's
## shadow material, like the plants) that stays put while it hops.

const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")

const TILE_SIZE := 12
const SPRITE_TILE := Vector2i(104, 0)
const COLOR := Color(1.0, 0.86, 0.6)
## Hop height (world px) at the middle of each step.
const HOP_PX := 2.0
## Tiles per real second (a diagonal step takes as long as a straight one).
@export var walk_speed := 4.0

signal arrived

var _tile := Vector2i.ZERO
var _queue: Array[Vector2i] = []  # tiles still to step onto, after the current step
var _stepping := false
var _step_from := Vector2i.ZERO
var _step_t := 0.0  # 0..1 through the current step
var _on_arrive := Callable()
var _facing_left := false
var _texture: Texture2D
var _shadow: Node2D


func _ready() -> void:
	_texture = ResourceMarkerChunkScript.sprite_texture(SPRITE_TILE)
	_shadow = _Shadow.new()
	_shadow.player = self
	_shadow.show_behind_parent = true
	add_child(_shadow)


## The world's cast-shadow material (set by ChunkManager).
func set_shadow_material(material: Material) -> void:
	_shadow.material = material


func tile() -> Vector2i:
	return _tile


static func tile_center(t: Vector2i) -> Vector2:
	return (Vector2(t) + Vector2(0.5, 0.5)) * TILE_SIZE


## Where the player's feet (its position) are when standing on tile `t`:
## the tile's bottom centre.
static func feet_point(t: Vector2i) -> Vector2:
	return (Vector2(t) + Vector2(0.5, 1.0)) * TILE_SIZE


## Steps through `tiles` (each a neighbour of the one before, starting next
## to tile(); empty = stay), then calls `on_arrive`. Replaces any walk in
## progress (its on_arrive is dropped); a step already under way finishes
## first.
func walk(tiles: Array[Vector2i], on_arrive := Callable()) -> void:
	_queue = tiles.duplicate()
	_on_arrive = on_arrive
	if not _stepping:
		_next_step()


## Stands on the tile holding `world_pos` at once (feet at its bottom
## centre), walk cancelled.
func teleport(world_pos: Vector2) -> void:
	_queue.clear()
	_on_arrive = Callable()
	_stepping = false
	_tile = Vector2i((world_pos / TILE_SIZE).floor())
	position = feet_point(_tile)
	_redraw()


func is_walking() -> bool:
	return _stepping or not _queue.is_empty()


## The tile the current walk ends on (tile() when standing).
func destination() -> Vector2i:
	return _queue[-1] if not _queue.is_empty() else _tile


func _next_step() -> void:
	if _queue.is_empty():
		_stepping = false
		_finish()
		return
	_step_from = _tile
	_tile = _queue.pop_front()
	_step_t = 0.0
	_stepping = true
	if _tile.x != _step_from.x:
		_facing_left = _tile.x < _step_from.x


func _process(delta: float) -> void:
	if not _stepping:
		return
	_step_t += delta * walk_speed
	if _step_t >= 1.0:
		position = feet_point(_tile)
		_next_step()
	if _stepping:
		position = feet_point(_step_from).lerp(feet_point(_tile), _step_t).round()
	_redraw()


func _finish() -> void:
	var callback := _on_arrive
	_on_arrive = Callable()
	_redraw()
	arrived.emit()
	if callback.is_valid():
		callback.call()


func _redraw() -> void:
	queue_redraw()
	if _shadow != null:
		_shadow.queue_redraw()


## Current hop height (world px, whole pixels): an arc over each step.
func hop() -> float:
	return roundf(HOP_PX * sin(PI * clampf(_step_t, 0.0, 1.0))) if _stepping else 0.0


func _draw() -> void:
	draw_set_transform(Vector2(0, -hop()), 0.0, Vector2(-1, 1) if _facing_left else Vector2.ONE)
	draw_texture_rect(_texture, sprite_rect(), false, COLOR)
	draw_set_transform(Vector2.ZERO)


## The sprite's rect, standing on the player's position (its feet): the
## same framing as the placed resources' sprites, one tile up from the tile
## centre framing by half a tile.
func sprite_rect() -> Rect2:
	return ResourceMarkerChunkScript.sprite_rect(Vector2(0, -TILE_SIZE * 0.5), float(TILE_SIZE))


func texture() -> Texture2D:
	return _texture


func is_facing_left() -> bool:
	return _facing_left


## The player's silhouette through the cast-shadow material (alpha 1 = no
## sway), behind the sprite and on the ground (no hop).
class _Shadow extends Node2D:
	var player: Node2D

	func _draw() -> void:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1) if player.is_facing_left() else Vector2.ONE)
		draw_texture_rect(player.texture(), player.sprite_rect(), false, Color(0, 0, 0, 1))
		draw_set_transform(Vector2.ZERO)
