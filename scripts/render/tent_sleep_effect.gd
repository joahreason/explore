extends Node2D

## A camp tent with the player asleep inside (ChunkManager.enter_tent()):
## the tent's sprite slowly bounces - stretching up and squashing down on
## its base - while little pixel Zs drift up out of its top, sway and fade.
## ChunkManager hides the tent's own marker while this node stands in for
## it at the tent's tile centre; on waking (wake()) its Zs fade out and it
## frees itself. Runs in real time
## (the sped-up game clock would make it frantic); pure visuals.

## Seconds per bounce, and how far the tent stretches (share of its height).
const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")

const BOUNCE_PERIOD := 1.6
const BOUNCE_STRETCH := 0.08
## A new Z every Z_INTERVAL seconds, each living Z_LIFE seconds while it
## rises Z_RISE px, sways Z_SWAY px side to side and grows from 3 to 5 px.
const Z_INTERVAL := 0.7
const Z_LIFE := 2.4
const Z_RISE := 16.0
const Z_SWAY := 3.0
const Z_COLOR := Color(0.95, 0.95, 1.0)
const Z_SHADOW := Color(0.05, 0.05, 0.12)
## Seconds the Zs left in the air take to fade out after waking.
const WAKE_FADE := 0.8

var _texture: Texture2D
var _color := Color.WHITE
var _size := 12.0
var _age := 0.0
var _wake_age := -1.0  # _age when wake() was called; -1 while asleep


## texture: the tent's sprite (outlined, as the markers draw it); color:
## its tint; size: its drawn size in pixels.
func setup(texture: Texture2D, color: Color, size: float) -> void:
	_texture = texture
	_color = color
	_size = size


## The player woke (ChunkManager._leave_tent()): the tent's own marker is
## back, so this stops drawing the tent and making Zs; the Zs in the air
## keep drifting and fade out over WAKE_FADE seconds, then it frees itself.
func wake() -> void:
	if not is_waking():
		_wake_age = _age


func is_waking() -> bool:
	return _wake_age >= 0.0


func _process(delta: float) -> void:
	_age += delta
	if is_waking() and _age - _wake_age >= WAKE_FADE:
		queue_free()
	queue_redraw()


## Vertical scale of the tent now: 1 +- BOUNCE_STRETCH.
func stretch() -> float:
	return 1.0 + BOUNCE_STRETCH * sin(TAU * _age / BOUNCE_PERIOD)


## The Zs in the air now, as [offset from the tent's top, size px, alpha].
func zs() -> Array:
	var result := []
	var newest := floori((_wake_age if is_waking() else _age) / Z_INTERVAL)
	var fade := clampf(1.0 - (_age - _wake_age) / WAKE_FADE, 0.0, 1.0) if is_waking() else 1.0
	for i in range(newest, -1, -1):
		var t := (_age - i * Z_INTERVAL) / Z_LIFE
		if t >= 1.0:
			break
		var offset := Vector2(2.0 + Z_SWAY * sin(t * TAU + i), -Z_RISE * t)
		result.append([offset, 3 + roundi(2.0 * t), (1.0 - t * t) * fade])
	return result


func _draw() -> void:
	if _texture == null:
		return
	# Scale about the base of the tent (half a tile below its centre). Once
	# waking, the tent's marker stands at rest in its place.
	var sy := 1.0 if is_waking() else stretch()
	if not is_waking():
		draw_set_transform(Vector2(0, _size * 0.5), 0.0, Vector2(2.0 - sy, sy))
		draw_texture_rect(_texture, Rect2(Vector2(-_size * 0.5, -_size), Vector2.ONE * _size).grow(_size / ResourceMarkerChunkScript.SPRITE_SIZE), false, _color)
		draw_set_transform(Vector2.ZERO)
	var top := Vector2(0, _size * 0.5 - _size * sy)
	for z in zs():
		var p: Vector2 = (top + z[0]).round()
		_draw_z(p + Vector2.ONE, z[1], Color(Z_SHADOW, z[2]))
		_draw_z(p, z[1], Color(Z_COLOR, z[2]))


## A pixel "Z" `s` px square with its top-left at `p`.
func _draw_z(p: Vector2, s: int, color: Color) -> void:
	draw_rect(Rect2(p, Vector2(s, 1)), color)
	draw_rect(Rect2(p + Vector2(0, s - 1), Vector2(s, 1)), color)
	for i in range(1, s - 1):
		draw_rect(Rect2(p + Vector2(s - 1 - i, i), Vector2.ONE), color)
