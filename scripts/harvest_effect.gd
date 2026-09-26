extends Node2D

## One-shot harvest feedback (polish): the harvested object's sprite grows a
## little and fades out while a few specks in its colour burst out and fall,
## then the node frees itself (DURATION). Spawned by
## ChunkManager._on_harvest_clicked() at the object's base (its tile's
## bottom middle), growing up from there; pure
## visuals, no game state. The specks' directions come from the object's key
## so each harvest looks a little different but deterministic.

const DURATION := 0.35
const SPECKS := 8
const GRAVITY := 90.0

var _texture: Texture2D
var _color := Color.WHITE
var _size := 12.0
var _pivoted := false
var _age := 0.0
var _velocities: Array[Vector2] = []


## texture: the object's drawn sprite (null = specks only); color: its tint;
## size: drawn size in pixels; key: its stable key (seeds the specks);
## pivoted: texture is pivoted art (ResourceDefinition.sprite_texture),
## drawn at its own size on its pivot and growing from there.
func setup(texture: Texture2D, color: Color, size: float, key: String, pivoted := false) -> void:
	_texture = texture
	_pivoted = pivoted
	_color = Color(color.r, color.g, color.b, 1.0)
	_size = size
	var rng := RandomNumberGenerator.new()
	rng.seed = key.hash()
	for i in SPECKS:
		var angle := -PI * 0.5 + rng.randf_range(-1.2, 1.2)
		_velocities.append(Vector2.from_angle(angle) * rng.randf_range(18.0, 42.0))


func progress() -> float:
	return clampf(_age / DURATION, 0.0, 1.0)


func _process(delta: float) -> void:
	_age += delta
	if _age >= DURATION:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := progress()
	var fade := Color(1, 1, 1, 1.0 - t)
	if _texture != null:
		var grow := 1.0 + 0.35 * t
		if _pivoted:
			var art := _texture.get_size() * grow
			draw_texture_rect(_texture, Rect2(-Vector2(art.x * 0.5, art.y), art), false, _color * fade)
		else:
			var s := _size * grow
			draw_texture_rect(_texture, Rect2(-Vector2(s * 0.5, s), Vector2.ONE * s).grow(s / 12.0), false, _color * fade)
	var elapsed := t * DURATION
	for v in _velocities:
		var p := v * elapsed + Vector2(0, 0.5 * GRAVITY * elapsed * elapsed)
		draw_rect(Rect2(p - Vector2.ONE, Vector2(2, 2)), _color * fade)
