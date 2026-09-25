extends Node2D

## The player character: a sprite from the Urizen sheet that walks along a
## tile path (ChunkManager.find_path(), started by a tap / left click - see
## ChunkManager._on_map_tapped()). Position is in world px; the tile it
## stands on is tile(). Walking runs in real time (not the game clock: a
## paused clock doesn't freeze the player). At the end of a path it calls
## the walk's `on_arrive` Callable, if any (harvesting a tapped resource).
## Drawn with a two-frame walk cycle, facing its direction of travel, with
## a cast shadow (the world's shadow material, like the plants) and a small
## marker on the tile it is walking to.

const ResourceMarkerChunkScript := preload("res://scripts/resource_marker_chunk.gd")

const TILE_SIZE := 12
## Sheet tiles: standing / second walk frame.
const FRAMES: Array[Vector2i] = [Vector2i(104, 0), Vector2i(104, 1)]
const COLOR := Color(1.0, 0.86, 0.6)
## Tiles per real second.
@export var walk_speed := 4.0
## Seconds per walk frame.
const STEP_SEC := 0.18

signal arrived

var _path: Array[Vector2] = []  # world px points still to reach
var _on_arrive := Callable()
var _step_time := 0.0
var _frame := 0
var _facing_left := false
var _textures: Array[Texture2D] = []
var _shadow: Node2D


func _ready() -> void:
	for tile in FRAMES:
		_textures.append(ResourceMarkerChunkScript.sprite_texture(tile))
	_shadow = _Shadow.new()
	_shadow.player = self
	_shadow.show_behind_parent = true
	add_child(_shadow)


## The world's cast-shadow material (set by ChunkManager).
func set_shadow_material(material: Material) -> void:
	_shadow.material = material


func tile() -> Vector2i:
	return Vector2i((position / TILE_SIZE).floor())


## Follows `tiles` (tile coordinates, the first step first; empty = stay),
## then calls `on_arrive`. Replaces any walk in progress (its on_arrive is
## dropped).
func walk(tiles: Array[Vector2i], on_arrive := Callable()) -> void:
	_path.clear()
	for t in tiles:
		_path.append((Vector2(t) + Vector2(0.5, 0.5)) * TILE_SIZE)
	_on_arrive = on_arrive
	queue_redraw()
	if _path.is_empty():
		_finish()


## Stands at `world_pos` at once, walk cancelled.
func teleport(world_pos: Vector2) -> void:
	_path.clear()
	_on_arrive = Callable()
	position = world_pos
	queue_redraw()


func is_walking() -> bool:
	return not _path.is_empty()


## The tile the current walk ends on (tile() when standing).
func destination() -> Vector2i:
	return Vector2i((_path[-1] / TILE_SIZE).floor()) if not _path.is_empty() else tile()


func _process(delta: float) -> void:
	if _path.is_empty():
		return
	var budget := walk_speed * TILE_SIZE * delta
	while budget > 0.0 and not _path.is_empty():
		var to := _path[0] - position
		if absf(to.x) > 0.01:
			_facing_left = to.x < 0.0
		if to.length() <= budget:
			position = _path.pop_front()
			budget -= to.length()
		else:
			position += to.normalized() * budget
			budget = 0.0
	_step_time += delta
	if _step_time >= STEP_SEC:
		_step_time = 0.0
		_frame = 1 - _frame
	if _path.is_empty():
		_frame = 0
		_finish()
	queue_redraw()
	_shadow.queue_redraw()


func _finish() -> void:
	var callback := _on_arrive
	_on_arrive = Callable()
	arrived.emit()
	if callback.is_valid():
		callback.call()


func _draw() -> void:
	if not _path.is_empty():
		# Destination marker: a small ring of four specks on the target tile.
		var at := _path[-1] - position
		for d in [Vector2(-3, 0), Vector2(3, 0), Vector2(0, -3), Vector2(0, 3)]:
			draw_rect(Rect2((at + d).floor(), Vector2(1, 1)), Color(1, 1, 1, 0.8))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1) if _facing_left else Vector2.ONE)
	draw_texture_rect(_textures[_frame], _sprite_rect(), false, COLOR)
	draw_set_transform(Vector2.ZERO)


## The sprite's rect around the player's position (same framing as the
## placed resources' sprites).
func _sprite_rect() -> Rect2:
	return ResourceMarkerChunkScript.sprite_rect(Vector2.ZERO, float(TILE_SIZE))


func frame_texture() -> Texture2D:
	return _textures[_frame]


func is_facing_left() -> bool:
	return _facing_left


## The player's silhouette through the cast-shadow material (alpha 1 = no
## sway), behind the sprite.
class _Shadow extends Node2D:
	var player: Node2D

	func _draw() -> void:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1) if player.is_facing_left() else Vector2.ONE)
		draw_texture_rect(player.frame_texture(), player._sprite_rect(), false, Color(0, 0, 0, 1))
		draw_set_transform(Vector2.ZERO)
