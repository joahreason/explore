extends RefCounted

## Everything generation reads and caches for one seed, behind one lock
## (§4.1 step 5, moved out of chunk_manager.gd): the WorldGen, the landmark
## sites, and the per-seed caches - tile environments, densities, raw guild
## placements, walkability. Pure functions of (seed, tile), so the chunk
## worker, the main thread's inline steps and the UI all share them.
##
## Threading (review C2): every public method takes `mutex` itself (a
## Mutex is recursive, so a caller may hold it across several calls, as a
## chunk job step does); the private ones expect it held. World_gen and
## structures are only used under it too.

const StructureSitesScript := preload("res://scripts/structure_sites.gd")
const ResourceManagerScript := preload("res://scripts/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resource_placement.gd")
const EnvironmentalStateScript := preload("res://scripts/environmental_state.gd")
const BiomeClassifierScript := preload("res://scripts/biome_classifier.gd")
const TerrainSurfaceScript := preload("res://scripts/terrain_surface.gd")
const CONTENT: WorldContent = preload("res://resources/world_content.tres")
const CHUNK_SIZE := 16  # tiles per chunk edge (ChunkManager.CHUNK_SIZE)

## Phase 17: how many chunks of per-tile EnvironmentalState + classify_full()
## results _tile_env() keeps (FIFO). Placing one chunk's guild stack reads
## tiles up to about one chunk around it, and chunks are processed nearest
## first, ring by ring, so a few rings of the loaded area catch nearly every
## reuse. One tile
## costs ~5 KB (state ~3 KB, classification ~2 KB), so the whole ~121-chunk
## footprint of the Resources view (~150 MB) is deliberately not kept.
const ENV_CACHE_CHUNKS := 48
## Tile rows per density-warming step ahead of a guild's chunk placement in
## the no-thread fallback (warm_guild_density()): 4 bands per chunk.
const WARM_DENSITY_ROWS := 4
## Walkability: see _walkable.
const WALKABLE_CHUNKS := 4096  # ~1.5 MB
const WALKABLE := 1
const BLOCKED := 2

var mutex := Mutex.new()
var world_gen: WorldGen
var world_seed: int = 0
## Landmark layer: sites for the current seed (StructureSites, which caches
## them per cell).
var structures: StructureSites
## Chunks in play (the load square) as of the job being generated - bounds
## the caches without reading the scene off the main thread. Set by
## ChunkManager per job step, under the mutex.
var gen_area: int = 81
var _raw_guild_chunks: Dictionary = {} # [guild id, chunk] -> that guild's raw placement in the chunk (see _raw_guild_in_rect)
var _env_chunks: Dictionary = {} # chunk -> [states, classifications], per tile (see _tile_env)
var _density_chunks: Dictionary = {} # guild/resource id -> {chunk -> PackedFloat64Array per tile} (see _density_memo)
## Chunk -> whether the player can stand on each of its tiles (not open
## water; frozen water is walkable): a PackedByteArray of CHUNK_SIZE x
## CHUNK_SIZE, 0 = not known yet, WALKABLE / BLOCKED. Filled for free
## wherever a chunk image is baked tile by tile (set_walkable()), else
## sampled on demand (is_walkable()). At most WALKABLE_CHUNKS chunks,
## oldest dropped first (review W3: a Dictionary entry per tile grew by
## ~200 KB per chunk walked).
var _walkable: Dictionary = {}


func _init(generator: WorldGen = null) -> void:
	world_gen = generator if generator != null else WorldGen.new()


## Switches to `seed_value`: configures the WorldGen (a fresh water-topology
## cache) and drops every per-seed cache.
func configure(seed_value: int) -> void:
	mutex.lock()
	world_seed = seed_value
	world_gen.configure(seed_value)
	clear()
	mutex.unlock()


func tile_env(wx: int, wy: int, sample: Dictionary = {}) -> Array:
	mutex.lock()
	var env := _tile_env(wx, wy, sample)
	mutex.unlock()
	return env


func guild_density(guild: ResourceGuild, wx: int, wy: int, sample: Dictionary = {}) -> float:
	mutex.lock()
	var density := _guild_density(guild, wx, wy, sample)
	mutex.unlock()
	return density


func resource_density(definition: ResourceDefinition, wx: int, wy: int, sample: Dictionary = {}) -> float:
	mutex.lock()
	var density := _resource_density(definition, wx, wy, sample)
	mutex.unlock()
	return density


func species_shares(guild: ResourceGuild, wx: int, wy: int) -> PackedFloat32Array:
	mutex.lock()
	var shares := _species_shares(guild, wx, wy)
	mutex.unlock()
	return shares


func deposit_potentials(sample: Dictionary, wx: int, wy: int) -> Dictionary:
	mutex.lock()
	var potentials := _deposit_potentials(sample, wx, wy)
	mutex.unlock()
	return potentials


func raw_guild_chunk(guild: ResourceGuild, chunk: Vector2i) -> Array:
	mutex.lock()
	var placed := _raw_guild_chunk(guild, chunk)
	mutex.unlock()
	return placed


func warm_guild_density(guild: ResourceGuild, chunk: Vector2i, y0: int) -> void:
	mutex.lock()
	_warm_guild_density(guild, chunk, y0)
	mutex.unlock()


func place_stack(rect: Rect2i, depth: int = CONTENT.guilds.size()) -> Dictionary:
	mutex.lock()
	var placed := _place_stack(rect, depth)
	mutex.unlock()
	return placed


## Phase 8 step 5: the first `depth` guilds of the stack for one chunk,
## after the cross-guild footprint check -> {guild: instances}. A guild's
## instances are the same whatever the depth (only higher guilds affect it),
## so each guild's view shows exactly what the Resources view does.
func place_stack_chunk(base: Vector2i, depth: int = CONTENT.guilds.size()) -> Dictionary:
	return place_stack(Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)), depth)


func place_definition_chunk(definition: ResourceDefinition, base: Vector2i) -> Array:
	mutex.lock()
	var placed := _place_definition_chunk(definition, base)
	mutex.unlock()
	return placed


## Whether the player can stand on a tile: anything but open water (a sea,
## lake or river that isn't frozen solid).
func is_walkable(tile: Vector2i) -> bool:
	mutex.lock()
	var walkable := _is_walkable(tile)
	mutex.unlock()
	return walkable


## is_walkable() for a caller already holding `mutex`: A* asks thousands of
## times per search, and locking on each one made a search ~18% slower.
func is_walkable_held(tile: Vector2i) -> bool:
	return _is_walkable(tile)


func set_walkable(tile: Vector2i, walkable: bool) -> void:
	mutex.lock()
	_set_walkable(tile, walkable)
	mutex.unlock()


static func walkable_sample(sample: Dictionary) -> bool:
	return _walkable_sample(sample)


static func chunk_of_tile(tile: Vector2i) -> Vector2i:
	return _chunk_of_tile(tile)


## Phase 6: same pipeline as _resource_suitability(), then patch noise +
## base_density via ResourceManager.get_density(). `sample` is the tile's
## WorldGen.sample() if the caller already has it (else taken on a cache miss).
func _resource_density(definition: ResourceDefinition, wx: int, wy: int, sample: Dictionary = {}) -> float:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var memo := _density_memo(definition.id, chunk)
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if is_nan(memo[i]):
		if structures.is_masked(Vector2i(wx, wy)):
			memo[i] = 0.0
		else:
			var env := _tile_env(wx, wy, sample)
			memo[i] = ResourceManagerScript.get_density(env[0], definition, world_seed, wx, wy, env[1])
	return memo[i]


## Phase 8 (guilds): the guild's total density, whatever the species mix.
## Phase 13: a guild that reads shade gets it from the canopy guild's memo here
## (the same value ResourceManager.get_shade() would compute), so shade and
## the Tree Cover / Shade heatmaps share one evaluation per tile.
## Landmark layer: 0 inside a structure's footprint (the structure_mask,
## StructureSites.is_masked()), so no guild places anything there - the same
## way zero suitability keeps them off water.
func _guild_density(guild: ResourceGuild, wx: int, wy: int, sample: Dictionary = {}) -> float:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var memo := _density_memo(guild.id, chunk)
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if is_nan(memo[i]):
		if structures.is_masked(Vector2i(wx, wy)):
			memo[i] = 0.0
			return 0.0
		var env := _tile_env(wx, wy, sample)
		if not env[0].shade_known and guild.reads_shade():
			env[0].shade = _guild_density(ResourceManagerScript.SHADE_SOURCE, wx, wy, sample)
			env[0].shade_known = true
		memo[i] = ResourceManagerScript.get_guild_density(env[0], guild, world_seed, wx, wy, env[1])
	return memo[i]


## Phase 17: [EnvironmentalState, classify_full() result] for a tile, cached
## per chunk (ENV_CACHE_CHUNKS, oldest chunk dropped first). Placement asks
## for the same tile once per guild with a candidate there and again from
## the neighboring chunk's one-cell ring, and the density heatmaps for every
## tile - ~5 full evaluations per tile in the Resources view before this.
## Both values are pure functions of (seed, tile) and are only read, never
## mutated, so sharing them changes no result. `sample` = the tile's
## WorldGen.sample() if the caller has it, {} = sample on a miss.
func _tile_env(wx: int, wy: int, sample: Dictionary = {}) -> Array:
	var chunk := Vector2i(floori(wx / float(CHUNK_SIZE)), floori(wy / float(CHUNK_SIZE)))
	var entry: Array = _env_chunks.get(chunk, [])
	if entry.is_empty():
		if _env_chunks.size() >= ENV_CACHE_CHUNKS:
			_env_chunks.erase(_env_chunks.keys()[0])
		var states := []
		var classifications := []
		states.resize(CHUNK_SIZE * CHUNK_SIZE)
		classifications.resize(CHUNK_SIZE * CHUNK_SIZE)
		entry = [states, classifications]
		_env_chunks[chunk] = entry
	var i := (wy - chunk.y * CHUNK_SIZE) * CHUNK_SIZE + (wx - chunk.x * CHUNK_SIZE)
	if entry[0][i] == null:
		var s := sample if not sample.is_empty() else world_gen.sample(wx, wy)
		entry[0][i] = EnvironmentalStateScript.from_sample(s)
		entry[1][i] = BiomeClassifierScript.classify_full(s)
	return [entry[0][i], entry[1][i]]


## Drops every per-seed cache (placements, densities, tile environments,
## walkability) and the landmark sites: on a seed change, an F5 data
## reload, and for cold-cache timings in tests.
func clear() -> void:
	mutex.lock()
	_raw_guild_chunks.clear()
	_density_chunks.clear()
	_env_chunks.clear()
	_walkable.clear()
	structures = StructureSitesScript.new(world_gen, world_seed)
	mutex.unlock()


## Phase 17: the density memo of one guild (or single resource) for one
## chunk - a PackedFloat64Array per tile, NAN = not computed yet - shared by
## the placement callbacks (a chunk's one-cell ring is its neighbor's
## interior) and the density heatmaps. Written through by the caller. Valid
## for the seed like _raw_guild_chunks; an id's chunks are dropped once they
## grow well past the loaded area (gen_area; ~2 KB each).
func _density_memo(id: String, chunk: Vector2i) -> PackedFloat64Array:
	var by_chunk: Dictionary = _density_chunks.get(id, {})
	if not _density_chunks.has(id):
		_density_chunks[id] = by_chunk
	var densities: PackedFloat64Array = by_chunk.get(chunk, PackedFloat64Array())
	if densities.is_empty():
		if by_chunk.size() > 8 * gen_area:
			by_chunk.clear()
		densities.resize(CHUNK_SIZE * CHUNK_SIZE)
		densities.fill(NAN)
		by_chunk[chunk] = densities
	return densities


## Phase 9: every deposit (WorldContent.deposits)'s potential at a tile -> {definition: potential}
## (zero entries left out).
func _deposit_potentials(sample: Dictionary, wx: int, wy: int) -> Dictionary:
	var state = EnvironmentalStateScript.from_sample(sample)
	var result := {}
	for ore in CONTENT.deposits:
		var potential: float = ResourceManagerScript.get_deposit_potential(state, ore, world_seed, wx, wy)
		if potential > 0.0:
			result[ore] = potential
	return result


func _species_shares(guild: ResourceGuild, wx: int, wy: int) -> PackedFloat32Array:
	var env := _tile_env(wx, wy)
	var scores: PackedFloat32Array = ResourceManagerScript.get_member_scores(env[0], guild, world_seed, wx, wy, env[1])
	return ResourceManagerScript.get_species_shares(scores, guild.species_sharpness)


## Phase 8 step 5: the first `depth` guilds of the stack placed in a tile
## rect (see place_stack_chunk()).
func _place_stack(rect: Rect2i, depth: int = CONTENT.guilds.size()) -> Dictionary:
	var guilds := CONTENT.guilds.slice(0, depth)
	var raw_fn := func(i: int, r: Rect2i) -> Array:
		return _raw_guild_in_rect(guilds[i], r)
	var placed: Array = ResourcePlacementScript.place_stack_with(guilds, rect, raw_fn)
	var result := {}
	for i in guilds.size():
		result[guilds[i]] = placed[i]
	return result


## place_guild_in_rect() for any rect, assembled from per-chunk placements
## cached in _raw_guild_chunks - exact, since placement is chunk-independent.
## The stack filter needs every guild but the lowest in a rect grown past the
## chunk, so without the cache each chunk would re-place its neighbors' edges
## (tree placement cost ~1.6x, rocks ~2.3x). Placement depends only on seed
## and guild data, so entries stay valid across view changes; the cache is
## just dropped when it grows well past the loaded area.
func _raw_guild_in_rect(guild: ResourceGuild, rect: Rect2i) -> Array:
	var result := []
	for c in chunks_in_rect(rect):
		for inst in _raw_guild_chunk(guild, c):
			var pos: Vector2 = inst["position"]
			if rect.has_point(Vector2i(floori(pos.x), floori(pos.y))):
				result.append(inst)
	return result


## Phase 14 (no-thread fallback): evaluates a guild's density at the
## placement candidates of rows y0..y0+WARM_DENSITY_ROWS of a chunk ahead of
## _raw_guild_chunk(), which then reads it from the memo - the same values,
## in smaller steps (a dense canopy chunk is ~20 ms of density work in one
## go). Nothing to do once the chunk's placement is cached.
func _warm_guild_density(guild: ResourceGuild, chunk: Vector2i, y0: int) -> void:
	if _raw_guild_chunks.has([guild.id, chunk]):
		return
	var band := Rect2i(chunk * CHUNK_SIZE + Vector2i(0, y0), Vector2i(CHUNK_SIZE, WARM_DENSITY_ROWS))
	for tile in ResourcePlacementScript.candidate_tiles(guild.id, guild.minimum_spacing, world_seed, band, ResourceManagerScript.get_guild_density_bound(guild)):
		_guild_density(guild, tile.x, tile.y)


## One guild's raw placement in one chunk, from _raw_guild_chunks or placed
## and cached now.
func _raw_guild_chunk(guild: ResourceGuild, chunk: Vector2i) -> Array:
	var key := [guild.id, chunk]
	if not _raw_guild_chunks.has(key):
		if _raw_guild_chunks.size() > 8 * CONTENT.guilds.size() * gen_area:
			_raw_guild_chunks.clear()
		var density_fn := func(wx: int, wy: int) -> float:
			return _guild_density(guild, wx, wy)
		var shares_fn := func(wx: int, wy: int) -> PackedFloat32Array:
			return _species_shares(guild, wx, wy)
		var chunk_rect := Rect2i(chunk * CHUNK_SIZE, Vector2i(CHUNK_SIZE, CHUNK_SIZE))
		_raw_guild_chunks[key] = ResourcePlacementScript.place_guild_in_rect(guild, world_seed, chunk_rect, density_fn, shares_fn, ResourceManagerScript.get_guild_density_bound(guild))
	return _raw_guild_chunks[key]


## Chunks a tile rect overlaps, row by row.
static func chunks_in_rect(rect: Rect2i) -> Array[Vector2i]:
	var c0 := Vector2i(floori(rect.position.x / float(CHUNK_SIZE)), floori(rect.position.y / float(CHUNK_SIZE)))
	var c1 := Vector2i(floori((rect.end.x - 1) / float(CHUNK_SIZE)), floori((rect.end.y - 1) / float(CHUNK_SIZE)))
	var chunks: Array[Vector2i] = []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			chunks.append(Vector2i(cx, cy))
	return chunks


## A single ResourceDefinition placed on its own (Oak Placement).
func _place_definition_chunk(definition: ResourceDefinition, base: Vector2i) -> Array:
	var density_fn := func(wx: int, wy: int) -> float:
		return _resource_density(definition, wx, wy)
	return ResourcePlacementScript.place_in_rect(definition, world_seed, Rect2i(base, Vector2i(CHUNK_SIZE, CHUNK_SIZE)), density_fn, ResourceManagerScript.get_density_bound(definition))


## Whether the player can stand on a tile: anything but open water (a sea,
## lake or river that isn't frozen solid).
func _is_walkable(tile: Vector2i) -> bool:
	var cells: PackedByteArray = _walkable.get(_chunk_of_tile(tile), PackedByteArray())
	if not cells.is_empty():
		var known := cells[_walkable_index(tile)]
		if known != 0:
			return known == WALKABLE
	var walkable := _walkable_sample(world_gen.sample(tile.x, tile.y))
	_set_walkable(tile, walkable)
	return walkable


func _set_walkable(tile: Vector2i, walkable: bool) -> void:
	var chunk := _chunk_of_tile(tile)
	var cells: PackedByteArray = _walkable.get(chunk, PackedByteArray())
	_walkable.erase(chunk)  # one owner while it's written; re-added as newest
	if cells.is_empty():
		cells.resize(CHUNK_SIZE * CHUNK_SIZE)
		if _walkable.size() >= WALKABLE_CHUNKS:
			_walkable.erase(_walkable.keys()[0])  # the oldest (insertion order)
	cells[_walkable_index(tile)] = WALKABLE if walkable else BLOCKED
	_walkable[chunk] = cells


static func _chunk_of_tile(tile: Vector2i) -> Vector2i:
	return Vector2i(floori(float(tile.x) / CHUNK_SIZE), floori(float(tile.y) / CHUNK_SIZE))


static func _walkable_index(tile: Vector2i) -> int:
	return posmod(tile.y, CHUNK_SIZE) * CHUNK_SIZE + posmod(tile.x, CHUNK_SIZE)


static func _walkable_sample(sample: Dictionary) -> bool:
	return TerrainSurfaceScript.water_liquid(sample) <= 0.0
