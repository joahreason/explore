extends Node2D

## Infinite chunk-based procedural world, deterministic per world_seed.
## Rendering here is a debug visualization only (flat colored tiles per
## WorldGen field sample) - the art tileset is intentionally not used yet;
## see scripts/world_gen.gd and scripts/debug_colorizer.gd for the actual
## generation/coloring logic. This file just handles chunk streaming.

const DebugColorizerScript := preload("res://scripts/debug_colorizer.gd")
const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")
const BiomeOverlayChunkScript := preload("res://scripts/biome_overlay_chunk.gd")

const TILE_SIZE := 12          # screen pixels per tile
const CHUNK_SIZE := 16         # tiles per chunk edge
const MIN_LOAD_RADIUS := 4     # floor on load radius even when zoomed in
const UNLOAD_BUFFER := 2       # extra chunks beyond load radius before freeing (hysteresis)

## Assign a saved WorldGen.tres preset here to tune generation in the
## Inspector; if left empty a default-tuned WorldGen is created at runtime.
@export var world_gen_params: WorldGen
@export var world_seed: int = 1337
@export var target_path: NodePath

@onready var chunks_root: Node2D = $Chunks
@onready var overlay_root: Node2D = $Overlay

var _target: Node2D
var _world_gen: WorldGen
var _loaded_chunks: Dictionary = {}   # Vector2i chunk -> Sprite2D
var _loaded_overlays: Dictionary = {} # Vector2i chunk -> Node2D (biome overlay), only while enabled
var _overlay_enabled: bool = false
var _last_center: Vector2i = Vector2i(1 << 30, 1 << 30)  # force first update
var _last_load_radius: int = -1


func _ready() -> void:
	world_seed = _resolve_world_seed()
	_world_gen = world_gen_params if world_gen_params != null else WorldGen.new()
	_world_gen.configure(world_seed)

	if target_path != NodePath():
		_target = get_node(target_path)

	_update_chunks(_chunk_of(_target.global_position if _target else Vector2.ZERO), _current_load_radius())


## Web only: a "?seed=" query param overrides the exported world_seed - set
## by ReloadButton from whatever was typed into the seed field. A purely
## numeric seed is used directly (matches the exported int seed behavior
## everywhere else in this project); anything else (letters/spaces) is
## hashed to a deterministic int, so the same text always regenerates the
## same world.
func _resolve_world_seed() -> int:
	if not OS.has_feature("web"):
		return world_seed

	var raw = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('seed') || ''", true
	)
	var raw_str := str(raw) if raw != null else ""
	if raw_str == "":
		return world_seed
	if raw_str.is_valid_int():
		return int(raw_str)
	return raw_str.hash()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		toggle_biome_overlay()


## Public so both the "B" key and the on-screen button can trigger it.
func toggle_biome_overlay() -> void:
	_overlay_enabled = not _overlay_enabled
	if _overlay_enabled:
		for chunk_coord in _loaded_chunks.keys():
			_generate_overlay_chunk(chunk_coord)
	else:
		for overlay in _loaded_overlays.values():
			overlay.queue_free()
		_loaded_overlays.clear()


func _process(_delta: float) -> void:
	if _target == null:
		return
	var center := _chunk_of(_target.global_position)
	var load_radius := _current_load_radius()
	if center == _last_center and load_radius == _last_load_radius:
		return
	_last_center = center
	_last_load_radius = load_radius
	_update_chunks(center, load_radius)


## Enough chunks to cover the current camera view (whatever its zoom), plus
## a floor so a fully zoomed-in camera still has a comfortable buffer.
func _current_load_radius() -> int:
	var cam := get_viewport().get_camera_2d()
	var zoom: float = cam.zoom.x if cam else 4.0
	var viewport_size := get_viewport().get_visible_rect().size
	var half_extent_px := (viewport_size / zoom) * 0.5
	var half_diagonal_px := half_extent_px.length()
	var chunk_px := CHUNK_SIZE * TILE_SIZE
	var needed := ceili(half_diagonal_px / chunk_px) + 1
	return maxi(MIN_LOAD_RADIUS, needed)


func _chunk_of(world_pos: Vector2) -> Vector2i:
	var tile := Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))
	return Vector2i(floori(float(tile.x) / CHUNK_SIZE), floori(float(tile.y) / CHUNK_SIZE))


func _update_chunks(center: Vector2i, load_radius: int) -> void:
	for cy in range(center.y - load_radius, center.y + load_radius + 1):
		for cx in range(center.x - load_radius, center.x + load_radius + 1):
			var c := Vector2i(cx, cy)
			if not _loaded_chunks.has(c):
				_generate_chunk(c)

	var unload_radius := load_radius + UNLOAD_BUFFER
	for c in _loaded_chunks.keys():
		if Vector2(c - center).length() > unload_radius:
			_unload_chunk(c)


func _generate_chunk(chunk_coord: Vector2i) -> void:
	var base := chunk_coord * CHUNK_SIZE
	var img := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RGB8)

	for ly in range(CHUNK_SIZE):
		for lx in range(CHUNK_SIZE):
			var wx := base.x + lx
			var wy := base.y + ly
			var sample := _world_gen.sample(wx, wy)
			img.set_pixel(lx, ly, DebugColorizerScript.color_for(sample))

	var texture := ImageTexture.create_from_image(img)
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	sprite.scale = Vector2(TILE_SIZE, TILE_SIZE)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	chunks_root.add_child(sprite)

	_loaded_chunks[chunk_coord] = sprite

	if _overlay_enabled:
		_generate_overlay_chunk(chunk_coord)


## Biome labels are derived from the same WorldGen fields but sampled on a
## (chunk_size+1)^2 grid so boundary outlines line up with tiles one step
## into the neighboring chunk, without that chunk needing to be loaded.
func _generate_overlay_chunk(chunk_coord: Vector2i) -> void:
	var base := chunk_coord * CHUNK_SIZE
	var stride := CHUNK_SIZE + 1
	var biome_grid := []
	biome_grid.resize(stride * stride)

	for ly in range(stride):
		for lx in range(stride):
			var sample := _world_gen.sample(base.x + lx, base.y + ly)
			biome_grid[ly * stride + lx] = BiomeClassifierScript.classify(sample)

	var overlay := BiomeOverlayChunkScript.new()
	overlay.setup(biome_grid, CHUNK_SIZE, TILE_SIZE)
	overlay.position = Vector2(base.x * TILE_SIZE, base.y * TILE_SIZE)
	overlay_root.add_child(overlay)
	_loaded_overlays[chunk_coord] = overlay


func _unload_chunk(chunk_coord: Vector2i) -> void:
	var sprite: Sprite2D = _loaded_chunks[chunk_coord]
	sprite.queue_free()
	_loaded_chunks.erase(chunk_coord)

	if _loaded_overlays.has(chunk_coord):
		_loaded_overlays[chunk_coord].queue_free()
		_loaded_overlays.erase(chunk_coord)
