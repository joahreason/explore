extends Node2D

## Desktop polish: a thin outline around the sprite of the resource a left
## click would harvest (ChunkManager.hover_target(): the same pick as
## harvesting), or of the camp tent it would sleep in
## (ChunkManager.tent_drawn()) - traced round the sprite's silhouette
## (outline_texture()), not its tile, and swaying with it in the wind (the
## world's sway material, with the sprite's own sway in the draw alpha). Only for a real mouse - after any
## touch it hides until the mouse moves again (touch screens have no hover,
## and the emulated mouse would leave it on the last tapped spot). Hidden
## over UI. Looks up the object only when the pointer enters another world
## pixel.

const OUTLINE_COLOR := Color(1, 1, 0.85)

var _mouse_mode := false
var _pixel := Vector2i(1 << 30, 0)
var _target_tile := Vector2i.ZERO
var _has_target := false
var _drawn: Array = []  # [texture, rect, sway alpha] of the outlined sprite; [] = none drawn
var _outlines: Dictionary = {}  # sprite texture -> its outline texture

@onready var _world := get_parent()
@onready var _rig := get_node("../CameraRig")


func _ready() -> void:
	material = _world.sway_material


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_mouse_mode = false
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		_mouse_mode = true


func _process(_delta: float) -> void:
	var mouse_screen := get_viewport().get_mouse_position()
	if not _mouse_mode or _rig._is_over_ui(mouse_screen):
		_set_target(false, Vector2i.ZERO, [])
		_pixel = Vector2i(1 << 30, 0)
		return
	var mouse := get_global_mouse_position()
	var pixel := Vector2i(mouse.floor())
	if pixel == _pixel:
		return
	_pixel = pixel
	var point: Vector2 = mouse / _world.TILE_SIZE
	var tile := Vector2i(point.floor())
	if _world.is_tent(tile):
		_set_target(true, tile, _world.tent_drawn(tile))
		return
	var inst: Dictionary = _world.hover_target(point)
	_set_target(not inst.is_empty(), Vector2i((inst.get("position", Vector2.ZERO) as Vector2).floor()), _world.sprite_drawn(inst) if not inst.is_empty() else [])


func _set_target(has: bool, tile: Vector2i, drawn: Array) -> void:
	if has == _has_target and tile == _target_tile and drawn == _drawn:
		return
	_has_target = has
	_target_tile = tile
	_drawn = drawn
	queue_redraw()


func has_target() -> bool:
	return _has_target


func target_tile() -> Vector2i:
	return _target_tile


## The outlined sprite: [texture, rect in world px, sway alpha], or [] if none (no
## target, or a target without a sprite, which gets its tile outlined).
func drawn() -> Array:
	return _drawn


func _draw() -> void:
	if not _has_target:
		return
	if _drawn.is_empty():
		var s: float = _world.TILE_SIZE
		draw_rect(Rect2(Vector2(_target_tile) * s, Vector2.ONE * s).grow(1.0), Color(OUTLINE_COLOR, 1.0), false, 1.0)  # alpha 1: no sway
		return
	var rect: Rect2 = _drawn[1]
	# The sway shader reads the sway from the alpha and draws opaque.
	draw_texture_rect(outline_texture(_drawn[0]), rect.grow(rect.size.x / (_drawn[0] as Texture2D).get_width()), false, Color(OUTLINE_COLOR, _drawn[2]))


## A ring one pixel wide round `texture`'s opaque pixels (8 directions),
## on a canvas one pixel bigger each side; white, tinted when drawn. Cached.
func outline_texture(texture: Texture2D) -> Texture2D:
	if not _outlines.has(texture):
		var art: Image = _world.sprite_image(texture)
		var w := art.get_width()
		var h := art.get_height()
		var opaque := func(x: int, y: int) -> bool:
			return x >= 0 and y >= 0 and x < w and y < h and art.get_pixel(x, y).a > 0.5
		var ring := Image.create(w + 2, h + 2, false, Image.FORMAT_RGBA8)
		for y in h + 2:
			for x in w + 2:
				if opaque.call(x - 1, y - 1):
					continue
				for d in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
					if opaque.call(x - 1 + d.x, y - 1 + d.y):
						ring.set_pixel(x, y, Color.WHITE)
						break
		_outlines[texture] = ImageTexture.create_from_image(ring)
	return _outlines[texture]
