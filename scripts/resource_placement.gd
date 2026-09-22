class_name ResourcePlacement
extends RefCounted

## Phase 7 of docs/resource-generation-plan.md: turns a resource's continuous
## density field (ResourceManager.get_density()) into discrete, individually
## positioned instances - a separate layer from density (plan Rule 4), pure
## data with no rendering (ChunkManager draws the result).
##
## Algorithm - a deterministic, chunk-independent Poisson-disc-style process
## (Matern "type II" hard-core thinning over a jittered grid):
##   1. The world is divided into square cells of side minimum_spacing
##      (tiles), aligned to WORLD coordinates. Each cell has exactly one
##      candidate point, jittered inside it by a hash of (world_seed,
##      resource id, cell) - never by global random state (plan Rule 1).
##   2. A candidate survives the density test if a second per-cell hash roll
##      is below the density at the tile it lands on - so density is the
##      per-cell acceptance probability, and zero density places nothing.
##   3. Minimum-spacing filter: a surviving candidate is dropped if any other
##      surviving candidate closer than minimum_spacing has a higher
##      (hash-derived) priority. Because cells are exactly minimum_spacing
##      wide, any such neighbor lies in the surrounding 3x3 cells.
## Every instance's fate therefore depends only on data within one cell of
## it, never on which chunk asked first or in what order - so a chunk can be
## placed on its own, and neighboring chunks agree exactly on who owns an
## instance near their shared edge (each instance belongs to the rect its
## position falls in). No duplicates, no seams, no missing trees.
##
## Trade-off: hard-core thinning never packs as tightly as a sequential
## (dart-throwing) Poisson disc - peak density saturates around one instance
## per ~3 cells (~0.3 / minimum_spacing^2 per tile) - in exchange for being
## order-independent, which is what makes it chunk-safe.
##
## minimum_spacing is also the resource's footprint for collision avoidance
## between instances of the SAME resource. Cross-resource collision (e.g. a
## rock and a tree) needs a second resource type to exist first - Phase 8.
##
## Each instance is identified by (resource id, cell) - stable across
## sessions and chunk loads, which later phases (gameplay entities,
## persistence) can use as its key.

const _MASK32 := 0xFFFFFFFF

# Salts so each per-cell hash roll is independent of the others.
const _SALT_JITTER_X := 1
const _SALT_JITTER_Y := 2
const _SALT_ACCEPT := 3
const _SALT_PRIORITY := 4


## Returns every instance of `definition` whose position falls inside
## `tile_rect` (tile coordinates, end-exclusive), as Dictionaries:
##   {"id": String, "cell": Vector2i, "position": Vector2 (tile units)}
## `density_fn` is a Callable(wx: int, wy: int) -> float in 0..1 - normally
## ResourceManager.get_density() for that tile; injected so this layer never
## depends on how density is computed (and can be tested with synthetic
## fields). Density is sampled at the tile containing each candidate.
static func place_in_rect(
	definition: ResourceDefinition, world_seed: int, tile_rect: Rect2i, density_fn: Callable
) -> Array[Dictionary]:
	var spacing := maxf(definition.minimum_spacing, 0.5)
	var resource_seed := _resource_seed(definition, world_seed)

	var c0 := Vector2i(floori(tile_rect.position.x / spacing), floori(tile_rect.position.y / spacing))
	var c1 := Vector2i(floori(tile_rect.end.x / spacing), floori(tile_rect.end.y / spacing))

	# Candidates for every cell the rect touches plus a one-cell ring (the
	# spacing filter's neighborhood), each density-tested once.
	var survivors := {}  # Vector2i cell -> Dictionary candidate
	for cy in range(c0.y - 1, c1.y + 2):
		for cx in range(c0.x - 1, c1.x + 2):
			var candidate := _candidate(resource_seed, spacing, Vector2i(cx, cy))
			var pos: Vector2 = candidate["position"]
			var density: float = density_fn.call(floori(pos.x), floori(pos.y))
			if candidate["accept"] < density:
				survivors[candidate["cell"]] = candidate

	var result: Array[Dictionary] = []
	var min_dist_sq := spacing * spacing
	for cell in survivors:
		var candidate: Dictionary = survivors[cell]
		var pos: Vector2 = candidate["position"]
		if not tile_rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
			continue
		if _is_suppressed(candidate, survivors, min_dist_sq):
			continue
		result.append({"id": definition.id, "cell": cell, "position": pos})
	return result


static func _is_suppressed(candidate: Dictionary, survivors: Dictionary, min_dist_sq: float) -> bool:
	var cell: Vector2i = candidate["cell"]
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var other_cell := cell + Vector2i(dx, dy)
			if not survivors.has(other_cell):
				continue
			var other: Dictionary = survivors[other_cell]
			if (other["position"] as Vector2).distance_squared_to(candidate["position"]) >= min_dist_sq:
				continue
			if _outranks(other, candidate):
				return true
	return false


## Strict total order, so exactly one of two conflicting candidates wins.
static func _outranks(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] > b["priority"]
	var ca: Vector2i = a["cell"]
	var cb: Vector2i = b["cell"]
	return ca.x > cb.x if ca.x != cb.x else ca.y > cb.y


static func _candidate(resource_seed: int, spacing: float, cell: Vector2i) -> Dictionary:
	var jitter := Vector2(
		_cell_unit(resource_seed, cell, _SALT_JITTER_X), _cell_unit(resource_seed, cell, _SALT_JITTER_Y)
	)
	return {
		"cell": cell,
		"position": (Vector2(cell) + jitter) * spacing,
		"accept": _cell_unit(resource_seed, cell, _SALT_ACCEPT),
		"priority": _cell_hash(resource_seed, cell, _SALT_PRIORITY),
	}


## Same derivation style as ResourceManager's patch noise (world_seed +
## reserved offset, mixed with the unique resource id), but its own offset
## so placement rolls are decorrelated from the patch field.
static func _resource_seed(definition: ResourceDefinition, world_seed: int) -> int:
	return ("%d:%s" % [world_seed + WorldGen.RESOURCE_PLACEMENT_SEED_OFFSET, definition.id]).hash() & _MASK32


## 0..1 (exclusive of 1) from the low 24 bits of the cell hash.
static func _cell_unit(resource_seed: int, cell: Vector2i, salt: int) -> float:
	return float(_cell_hash(resource_seed, cell, salt) & 0xFFFFFF) / 16777216.0


static func _cell_hash(resource_seed: int, cell: Vector2i, salt: int) -> int:
	var h := _hash32(salt)
	h = _hash32(h ^ (cell.y & _MASK32))
	h = _hash32(h ^ (cell.x & _MASK32))
	return _hash32(h ^ resource_seed)


## Integer finalizer (xor-shift-multiply). Kept strictly in 32 bits with a
## sub-2^31 multiplier so no intermediate product overflows GDScript's
## signed 64-bit int - identical results on every platform, web included.
static func _hash32(x: int) -> int:
	x &= _MASK32
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & _MASK32
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & _MASK32
	return x ^ (x >> 16)
