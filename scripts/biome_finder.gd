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
## within a few rings. Costs ~30 us per sampled cell: typically well under a
## second, MAX_RADIUS bounds the not-found case (~4 s). world_gen must be a
## WorldGen used by nothing else meanwhile (sample() fills its water topology
## cache), so this can run on its own thread.

const STEP := 32
const MAX_RADIUS := 6000
const PATCH_CELLS := 2000
const AVOID_RADIUS := 256


## -> the found tile (Vector2i), or null if none within MAX_RADIUS or
## cancelled (cancel: a Callable returning true to stop early, checked per
## ring).
static func find(world_gen: WorldGen, biome: String, start: Vector2i, avoid: Array = [], cancel: Callable = Callable()) -> Variant:
	var patch := _patch_at(world_gen, biome, start)
	for k in range(1, MAX_RADIUS / STEP + 1):
		if cancel.is_valid() and cancel.call():
			return null
		var best: Variant = null
		var best_dist := INF
		for cell in _ring(k):
			if patch.has(cell):
				continue
			var tile: Vector2i = start + cell * STEP
			var dist := Vector2(cell).length_squared()
			if dist >= best_dist or _near_any(tile, avoid):
				continue
			if _biome_at(world_gen, tile) == biome:
				best = tile
				best_dist = dist
		if best != null:
			return best
	return null


## Lattice cells (relative to start) of the biome's patch containing the
## start - empty if the start isn't that biome.
static func _patch_at(world_gen: WorldGen, biome: String, start: Vector2i) -> Dictionary:
	var patch := {}
	if _biome_at(world_gen, start) != biome:
		return patch
	patch[Vector2i.ZERO] = true
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	var visited := {Vector2i.ZERO: true}
	var qi := 0
	while qi < queue.size() and patch.size() < PATCH_CELLS:
		var cur := queue[qi]
		qi += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if visited.has(n):
				continue
			visited[n] = true
			if _biome_at(world_gen, start + n * STEP) == biome:
				patch[n] = true
				queue.append(n)
	return patch


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
