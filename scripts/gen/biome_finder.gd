class_name BiomeFinder
extends RefCounted

## "Go to biome" search: the nearest tile of a base biome (BiomeClassifier's
## names) around a start tile, on a coarse lattice (STEP tiles) searched ring
## by ring outward. If the start already is that biome, its patch (the
## connected lattice cells of the biome around the start, up to PATCH_CELLS)
## is skipped, so the result is the next patch rather than where you stand;
## `avoid` tiles (places already visited for this biome) are skipped within
## AVOID_RADIUS, so repeated searches hop onward instead of back and forth.
##
## Biomes follow regional climate noise, so they're hundreds to a few thousand
## tiles apart (seed 4242: everything within ~3100 tiles of three sampled
## starts); a 32-tile lattice still catches thin ones like rivers and beaches
## within a few rings. Typically well under a second; MAX_RADIUS bounds the
## not-found case (measured 28 s natively in the 2026-09-26 review). world_gen must be a
## WorldGen used by nothing else meanwhile (sample() fills its water topology
## cache), so this can run on its own thread.

const STEP := 32
const MAX_RADIUS := 6000
const PATCH_CELLS := 2000
const AVOID_RADIUS := 256


## Review W1: the search is resumable - new() then step() until it returns
## true - so the web build, which has no threads, can spread it over frames
## instead of freezing the tab; find() runs one to the end.
var result: Variant = null  # the found tile (Vector2i) or null, once step() returns true
var _world_gen: WorldGen
var _biome: String
var _start: Vector2i
var _avoid: Array
var _patch := {}  # lattice cells (relative to start) of the biome's patch around the start
var _patch_queue: Array[Vector2i] = []
var _patch_visited := {}
var _patch_qi := 0
var _k := 1  # the ring being searched
var _ring_cells: Array[Vector2i] = []
var _ri := 0
var _best: Variant = null
var _best_dist := INF
var _done := false


func _init(world_gen: WorldGen, biome: String, start: Vector2i, avoid: Array = []) -> void:
	_world_gen = world_gen
	_biome = biome
	_start = start
	_avoid = avoid
	if _biome_at(world_gen, start) == biome:
		_patch[Vector2i.ZERO] = true
		_patch_queue.append(Vector2i.ZERO)
		_patch_visited[Vector2i.ZERO] = true
	_ring_cells = _ring(_k)


## Advances the search until it's done or Time.get_ticks_usec() passes
## deadline_usec (checked between lattice cells, ~30 us each); true once
## it's done and `result` is set.
func step(deadline_usec: int) -> bool:
	while not _done and Time.get_ticks_usec() < deadline_usec:
		if _patch_qi < _patch_queue.size() and _patch.size() < PATCH_CELLS:
			_grow_patch()
		else:
			_search_cell()
	return _done


## -> the found tile (Vector2i), or null if none within MAX_RADIUS or
## cancelled (cancel: a Callable returning true to stop early, checked about
## every 20 ms).
static func find(world_gen: WorldGen, biome: String, start: Vector2i, avoid: Array = [], cancel: Callable = Callable()) -> Variant:
	var search := BiomeFinder.new(world_gen, biome, start, avoid)
	while not search.step(Time.get_ticks_usec() + 20000):
		if cancel.is_valid() and cancel.call():
			return null
	return search.result


## One cell of the start's patch (the connected lattice cells of the biome
## around the start, up to PATCH_CELLS; none if the start isn't that biome),
## which is found before the rings are searched.
func _grow_patch() -> void:
	var cur := _patch_queue[_patch_qi]
	_patch_qi += 1
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = cur + d
		if _patch_visited.has(n):
			continue
		_patch_visited[n] = true
		if _biome_at(_world_gen, _start + n * STEP) == _biome:
			_patch[n] = true
			_patch_queue.append(n)


## One lattice cell of the current ring; after the ring's last cell, its
## nearest match (if any) is the result, else the next ring starts.
func _search_cell() -> void:
	var cell := _ring_cells[_ri]
	_ri += 1
	if not _patch.has(cell):
		var tile: Vector2i = _start + cell * STEP
		var dist := Vector2(cell).length_squared()
		if dist < _best_dist and not _near_any(tile, _avoid) and _biome_at(_world_gen, tile) == _biome:
			_best = tile
			_best_dist = dist
	if _ri < _ring_cells.size():
		return
	if _best != null or _k >= MAX_RADIUS / STEP:
		result = _best
		_done = true
		return
	_k += 1
	_ring_cells = _ring(_k)
	_ri = 0


static func _biome_at(world_gen: WorldGen, tile: Vector2i) -> String:
	return BiomeClassifier.classify(world_gen.sample(tile.x, tile.y))


static func _near_any(tile: Vector2i, points: Array) -> bool:
	for p in points:
		if Vector2(tile - p).length() < AVOID_RADIUS:
			return true
	return false


## Lattice cells at Chebyshev distance k from the origin.
static func _ring(k: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for i in range(-k, k + 1):
		cells.append(Vector2i(i, -k))
		cells.append(Vector2i(i, k))
	for i in range(-k + 1, k):
		cells.append(Vector2i(-k, i))
		cells.append(Vector2i(k, i))
	return cells
