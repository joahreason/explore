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
## between instances of the SAME resource - or, via place_guild_in_rect(),
## of the same guild. Collision between different guilds (e.g. a rock and a
## tree) is place_stack_in_rect()'s job.
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
const _SALT_SPECIES := 5


## Returns every instance of `definition` whose position falls inside
## `tile_rect` (tile coordinates, end-exclusive), as Dictionaries:
##   {"id": String, "cell": Vector2i, "position": Vector2 (tile units)}
## `density_fn` is a Callable(wx: int, wy: int) -> float in 0..1 - normally
## ResourceManager.get_density() for that tile; injected so this layer never
## depends on how density is computed (and can be tested with synthetic
## fields). Density is sampled at the tile containing each candidate.
## `density_bound` (Phase 17) is a value density_fn never exceeds, e.g.
## ResourceManager.get_density_bound(): a candidate whose acceptance roll is
## at or above it is rejected without calling density_fn - the same result,
## since roll < density would be false anyway. 1.0 = no bound known.
static func place_in_rect(
	definition: ResourceDefinition, world_seed: int, tile_rect: Rect2i, density_fn: Callable, density_bound: float = 1.0
) -> Array[Dictionary]:
	return _place(definition.id, definition.minimum_spacing, world_seed, tile_rect, density_fn, density_bound)


## Phase 8 amendment: places a whole ResourceGuild on ONE shared grid
## (guild.minimum_spacing, seeded by guild.id), so members can never overlap,
## then gives each instance a species by a per-cell hash roll against
## `shares_fn` - Callable(wx: int, wy: int) -> PackedFloat32Array, one share
## per guild.members entry, normally ResourceManager.get_species_shares().
## Instances are {"id": member id, "guild": guild id, "cell", "position"};
## (guild id, cell) is the stable key. An instance whose shares are all zero
## is dropped (density_fn should already be zero there). `density_bound` as
## for place_in_rect() (ResourceManager.get_guild_density_bound()).
static func place_guild_in_rect(
	guild: ResourceGuild, world_seed: int, tile_rect: Rect2i, density_fn: Callable, shares_fn: Callable, density_bound: float = 1.0
) -> Array[Dictionary]:
	var guild_seed := _resource_seed(guild.id, world_seed)
	var result: Array[Dictionary] = []
	for inst in _place(guild.id, guild.minimum_spacing, world_seed, tile_rect, density_fn, density_bound):
		var pos: Vector2 = inst["position"]
		var shares: PackedFloat32Array = shares_fn.call(floori(pos.x), floori(pos.y))
		var member := _pick(shares, _cell_unit(guild_seed, inst["cell"], _SALT_SPECIES))
		if member < 0:
			continue
		inst["guild"] = guild.id
		inst["id"] = guild.members[member].id
		result.append(inst)
	return result


## Phase 8 step 5: several guilds sharing the ground, e.g. [rocks, trees,
## shrubs], in PRIORITY order. Each guild is placed with
## place_guild_in_rect() on its own grid as usual, then an instance is
## dropped if a surviving instance of any higher-priority guild lies closer
## than the sum of the two guilds' footprint_radius. Returns one instance
## Array per guild, in the same order. density_fns/shares_fns are per guild,
## as for place_guild_in_rect().
##
## Chunk-safe like the rest of this file: to filter guild i inside the rect,
## the higher guilds' survivors are needed out to i's collision reach, so
## each guild is placed (once) in the rect grown by the reach of every guild
## below it, and filtered only against instances inside that grown rect.
## Every decision therefore still depends only on world coordinates.
static func place_stack_in_rect(
	guilds: Array, world_seed: int, tile_rect: Rect2i, density_fns: Array, shares_fns: Array
) -> Array:
	var raw_fn := func(i: int, rect: Rect2i) -> Array:
		return place_guild_in_rect(guilds[i], world_seed, rect, density_fns[i], shares_fns[i])
	return place_stack_with(guilds, tile_rect, raw_fn)


## place_stack_in_rect() with the per-guild placement injected:
## raw_fn(guild index, rect) must return exactly what place_guild_in_rect()
## would for that guild and rect - e.g. assembled from cached per-chunk
## placements, which is valid because placement is chunk-independent.
static func place_stack_with(guilds: Array, tile_rect: Rect2i, raw_fn: Callable) -> Array:
	var n := guilds.size()
	# reach[i]: how far a guild-i instance can be blocked by a higher guild.
	var reach := []
	for i in n:
		var r := 0.0
		for j in i:
			r = maxf(r, guilds[i].footprint_radius + guilds[j].footprint_radius)
		reach.append(r)
	# Tile margin each guild must be placed with, around tile_rect.
	var margin := []
	margin.resize(n)
	margin.fill(0)
	for i in range(n - 1, -1, -1):
		for j in i:
			margin[j] = maxi(margin[j], margin[i] + ceili(reach[i]))

	var placed := []  # per guild, survivors inside tile_rect.grow(margin[i])
	for i in n:
		var rect := tile_rect.grow(margin[i])
		var kept: Array[Dictionary] = []
		for inst in raw_fn.call(i, rect):
			if not _is_blocked(inst, i, guilds, placed):
				kept.append(inst)
		placed.append(kept)

	var result := []
	for i in n:
		var inside: Array[Dictionary] = []
		for inst in placed[i]:
			var pos: Vector2 = inst["position"]
			if tile_rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
				inside.append(inst)
		result.append(inside)
	return result


static func _is_blocked(inst: Dictionary, level: int, guilds: Array, placed: Array) -> bool:
	var pos: Vector2 = inst["position"]
	for j in level:
		var min_dist: float = guilds[level].footprint_radius + guilds[j].footprint_radius
		for other in placed[j]:
			if pos.distance_squared_to(other["position"]) < min_dist * min_dist:
				return true
	return false


## Index whose cumulative share first exceeds roll (0..1); -1 if all zero.
static func _pick(shares: PackedFloat32Array, roll: float) -> int:
	var total := 0.0
	for s in shares:
		total += maxf(s, 0.0)
	if total <= 0.0:
		return -1
	var acc := 0.0
	var last := -1
	for i in shares.size():
		if shares[i] <= 0.0:
			continue
		acc += shares[i] / total
		last = i
		if roll < acc:
			return i
	return last


static func _place(
	id: String, minimum_spacing: float, world_seed: int, tile_rect: Rect2i, density_fn: Callable, density_bound: float = 1.0
) -> Array[Dictionary]:
	var spacing := maxf(minimum_spacing, 0.5)
	var resource_seed := _resource_seed(id, world_seed)

	var c0 := Vector2i(floori(tile_rect.position.x / spacing), floori(tile_rect.position.y / spacing))
	var c1 := Vector2i(floori(tile_rect.end.x / spacing), floori(tile_rect.end.y / spacing))

	# Candidates for every cell the rect touches plus a one-cell ring (the
	# spacing filter's neighborhood), each density-tested once.
	var survivors := {}  # Vector2i cell -> Dictionary candidate
	for cy in range(c0.y - 1, c1.y + 2):
		for cx in range(c0.x - 1, c1.x + 2):
			# Accept roll first: jitter and priority are only hashed for
			# candidates that can still pass.
			var cell := Vector2i(cx, cy)
			var accept := _cell_unit(resource_seed, cell, _SALT_ACCEPT)
			if accept >= density_bound:
				continue  # can't pass: density_fn never exceeds density_bound
			var pos := _jittered(resource_seed, spacing, cell)
			var density: float = density_fn.call(floori(pos.x), floori(pos.y))
			if accept < density:
				survivors[cell] = {
					"cell": cell,
					"position": pos,
					"priority": _cell_hash(resource_seed, cell, _SALT_PRIORITY),
				}

	var result: Array[Dictionary] = []
	var min_dist_sq := spacing * spacing
	for cell in survivors:
		var candidate: Dictionary = survivors[cell]
		var pos: Vector2 = candidate["position"]
		if not tile_rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
			continue
		if _is_suppressed(candidate, survivors, min_dist_sq):
			continue
		result.append({"id": id, "cell": cell, "position": pos})
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


## The cell's one candidate position, jittered inside it (tile units).
static func _jittered(resource_seed: int, spacing: float, cell: Vector2i) -> Vector2:
	var jitter := Vector2(
		_cell_unit(resource_seed, cell, _SALT_JITTER_X), _cell_unit(resource_seed, cell, _SALT_JITTER_Y)
	)
	return (Vector2(cell) + jitter) * spacing


## Same derivation style as ResourceManager's patch noise (world_seed +
## reserved offset, mixed with the unique resource id), but its own offset
## so placement rolls are decorrelated from the patch field.
static func _resource_seed(id: String, world_seed: int) -> int:
	return ("%d:%s" % [world_seed + WorldGen.RESOURCE_PLACEMENT_SEED_OFFSET, id]).hash() & _MASK32


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
