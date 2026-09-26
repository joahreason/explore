extends Node2D

## The player character: a sprite (assets/sprites/player.png, pivot at its
## bottom middle) that walks freely - not tile by tile - through a list of
## world points (ChunkManager._on_map_tapped(): an A* tile path round water,
## string-pulled, ending at the tapped point). Its position (the node's
## origin, the pivot for the hop and the facing flip) is its feet, the
## sprite's pivot, the sprite drawn above. tile() is the tile its feet are
## on. It hops a little every STEP_TILES of distance walked. Walking runs in
## real time (not the game clock: a paused clock doesn't freeze the player).
## At the end of a walk it calls the walk's `on_arrive` Callable, if any
## (harvesting a tapped resource). Drawn facing its direction of travel,
## with a cast shadow on the ground (the world's shadow material, like the
## plants) that stays put while it hops. Each step lands with a faint
## footstep (assets/sfx/footstep.wav, made by
## tools/generate_sfx.gd), its pitch and volume varied per step - never
## close to the previous step's pitch - so the repetition doesn't grate.

const GameConstants := preload("res://scripts/game_constants.gd")
const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")

const TILE_SIZE := GameConstants.TILE_SIZE
const SPRITE := preload("res://assets/sprites/player.png")
const COLOR := Color(1.0, 0.86, 0.6)
## Hop height (world px) at the middle of each step.
const HOP_PX := 2.0
## Tiles per real second.
@export var walk_speed := 4.0
## Distance (tiles) of one step: one hop, one footstep.
const STEP_TILES := 0.75
const FOOTSTEP := preload("res://assets/sfx/footstep.wav")
const FOOTSTEP_DB := -26.0
## Per-step variation: pitch scale range, the least change from the last
## step's pitch, and volume jitter (dB, either way).
const FOOTSTEP_PITCH := Vector2(0.82, 1.18)
const FOOTSTEP_MIN_PITCH_CHANGE := 0.06
const FOOTSTEP_VOLUME_JITTER := 1.5

## Footsteps played so far, and the last one's pitch (tests read them).
var footsteps := 0
var last_footstep_pitch := 1.0
var _footstep_player: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()

signal arrived

var _path: Array[Vector2] = []  # world points still to reach
var _stride := 0.0  # distance walked (tiles) since the walk started
var _on_arrive := Callable()
var _facing_left := false
var _texture: Texture2D
var _shadow: Node2D


func _ready() -> void:
	_texture = SPRITE
	_footstep_player = AudioStreamPlayer.new()
	_footstep_player.name = "Footstep"
	_footstep_player.stream = FOOTSTEP
	_footstep_player.max_polyphony = 2  # a quick step can overlap the last one's tail
	add_child(_footstep_player)
	_rng.randomize()
	_shadow = _Shadow.new()
	_shadow.player = self
	_shadow.show_behind_parent = true
	add_child(_shadow)


## The world's cast-shadow material (set by ChunkManager), and the layer
## the plants' shadows are drawn in, under every sprite: the player's shadow
## moves there (following the player), so it never darkens the trees the
## player is depth-sorted in front of.
func set_shadow_material(material: Material, layer: Node = null) -> void:
	_shadow.material = material
	if layer != null:
		_shadow.show_behind_parent = false
		_shadow.reparent(layer, false)
		visibility_changed.connect(_redraw)
		tree_exiting.connect(func(): if is_instance_valid(_shadow): _shadow.queue_free())
		_redraw()


func tile() -> Vector2i:
	return Vector2i((position / TILE_SIZE).floor())


static func tile_center(t: Vector2i) -> Vector2:
	return (Vector2(t) + Vector2(0.5, 0.5)) * TILE_SIZE


## Walks straight through `points` (world px, in order; empty = stay), then
## calls `on_arrive`. Replaces any walk in progress (its on_arrive is
## dropped).
func walk(points: Array[Vector2], on_arrive := Callable()) -> void:
	_path = points.duplicate()
	_on_arrive = on_arrive
	_stride = 0.0
	if _path.is_empty():
		_finish()


## Stands at `world_pos` at once, walk cancelled.
func teleport(world_pos: Vector2) -> void:
	_path.clear()
	_on_arrive = Callable()
	position = world_pos
	_redraw()


func is_walking() -> bool:
	return not _path.is_empty()


## The tile the current walk ends on (tile() when standing).
func destination() -> Vector2i:
	return Vector2i((_path[-1] / TILE_SIZE).floor()) if not _path.is_empty() else tile()


func _process(delta: float) -> void:
	if _path.is_empty():
		return
	var budget := walk_speed * TILE_SIZE * delta
	var steps_before := floori(_stride / STEP_TILES)
	while budget > 0.0 and not _path.is_empty():
		var to := _path[0] - position
		if absf(to.x) > 0.5:
			_facing_left = to.x < 0.0
		var moved := minf(to.length(), budget)
		position += to.normalized() * moved if to.length() > 0.0 else Vector2.ZERO
		_stride += moved / TILE_SIZE
		budget -= moved
		if to.length() <= moved:
			position = _path.pop_front()
	if floori(_stride / STEP_TILES) > steps_before:
		_play_footstep()
	if _path.is_empty():
		_finish()
	_redraw()


## A landing step's sound: random pitch in FOOTSTEP_PITCH, at least
## FOOTSTEP_MIN_PITCH_CHANGE from the last one, and a little volume jitter.
func _play_footstep() -> void:
	var pitch := _rng.randf_range(FOOTSTEP_PITCH.x, FOOTSTEP_PITCH.y)
	for attempt in 8:
		if absf(pitch - last_footstep_pitch) >= FOOTSTEP_MIN_PITCH_CHANGE:
			break
		pitch = _rng.randf_range(FOOTSTEP_PITCH.x, FOOTSTEP_PITCH.y)
	last_footstep_pitch = pitch
	_footstep_player.pitch_scale = pitch
	_footstep_player.volume_db = FOOTSTEP_DB + _rng.randf_range(-FOOTSTEP_VOLUME_JITTER, FOOTSTEP_VOLUME_JITTER)
	_footstep_player.play()
	footsteps += 1


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
		if _shadow.get_parent() != self:
			_shadow.global_position = global_position.round()
			_shadow.visible = is_visible_in_tree()
		_shadow.queue_redraw()


## Current hop height (world px, whole pixels): an arc over each step.
func hop() -> float:
	return roundf(HOP_PX * sin(PI * fposmod(_stride / STEP_TILES, 1.0))) if is_walking() else 0.0


func _draw() -> void:
	# Drawn on whole pixels, wherever between them the walk is.
	draw_set_transform(position.round() - position + Vector2(0, -hop()), 0.0, Vector2(-1, 1) if _facing_left else Vector2.ONE)
	draw_texture_rect(_texture, sprite_rect(), false, COLOR)
	draw_set_transform(Vector2.ZERO)


## The sprite's rect, its pivot on the player's position (its feet), as
## the placed resources' sprites stand on theirs.
func sprite_rect() -> Rect2:
	return ResourceMarkerChunkScript.pivot_rect(Vector2.ZERO, _texture.get_size())


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
		draw_texture_rect(player.texture(), player.sprite_rect(), false, ResourceMarkerChunkScript.shadow_color(player.sprite_rect().size.y, 1.0))
		draw_set_transform(Vector2.ZERO)
