extends Node2D

## Desktop polish: a thin outline around the resource a left click would
## harvest (ChunkManager.hover_target(): the same pick as harvesting). Only
## for a real mouse - after any touch it hides until the mouse moves again
## (touch screens have no hover, and the emulated mouse would leave it on
## the last tapped spot). Hidden over UI. Looks up the object only when the
## pointer enters another tile.

const OUTLINE_COLOR := Color(1, 1, 0.85, 0.9)

var _mouse_mode := false
var _tile := Vector2i(1 << 30, 0)
var _target_tile := Vector2i.ZERO
var _has_target := false

@onready var _world := get_parent()
@onready var _rig := get_node("../CameraRig")


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_mouse_mode = false
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		_mouse_mode = true


func _process(_delta: float) -> void:
	var mouse_screen := get_viewport().get_mouse_position()
	if not _mouse_mode or _rig._is_over_ui(mouse_screen):
		_set_target(false, Vector2i.ZERO)
		_tile = Vector2i(1 << 30, 0)
		return
	var point: Vector2 = get_global_mouse_position() / _world.TILE_SIZE
	var tile := Vector2i(point.floor())
	if tile == _tile:
		return
	_tile = tile
	var inst: Dictionary = _world.hover_target(point)
	_set_target(not inst.is_empty(), Vector2i((inst.get("position", Vector2.ZERO) as Vector2).floor()))


func _set_target(has: bool, tile: Vector2i) -> void:
	if has == _has_target and tile == _target_tile:
		return
	_has_target = has
	_target_tile = tile
	queue_redraw()


func has_target() -> bool:
	return _has_target


func target_tile() -> Vector2i:
	return _target_tile


func _draw() -> void:
	if not _has_target:
		return
	var s: float = _world.TILE_SIZE
	draw_rect(Rect2(Vector2(_target_tile) * s, Vector2.ONE * s).grow(1.0), OUTLINE_COLOR, false, 1.0)
