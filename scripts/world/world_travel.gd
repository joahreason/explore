extends RefCounted

## The "Go to" menu's searches (§4.1 step 8, moved out of chunk_manager.gd):
## the nearest tile of a biome (BiomeFinder) or the nearest landmark of a
## type (StructureSites), away from where the player stands and from the
## places already traveled to. A search can take seconds, so it runs on its
## own thread with its own WorldGen copy - sharing nothing with chunk
## generation - or, without threads, a slice per frame from poll() (review
## W1). ChunkManager starts searches and moves the player to the result.

const BiomeFinderScript := preload("res://scripts/biome_finder.gd")
const StructureSitesScript := preload("res://scripts/structure_sites.gd")

## Review W1: main-thread time per frame for a search without threads.
const TRAVEL_BUDGET_USEC := 4000

var _finder_gen: WorldGen
var _finder_thread: Thread
var _finder_biome: String = ""
var _finder_seed: int = 0
var _finder_result: Variant = null  # written by the search thread, read after it finishes
var _finder_search: RefCounted  # a search stepped from poll() where there's no thread (web)
var _finder_cancel: bool = false
var _finder_sites: StructureSites  # the search thread's own sites (on _finder_gen), kept while the seed stays
var _travel_visited: Dictionary = {}  # biome -> tiles already traveled to (BiomeFinder's avoid list)


## Starts a search for `biome` (a BiomeClassifier base biome name or a
## structure's display name) from `start` in the world of `world_seed`
## (`params`: the scene's WorldGen preset, or null). Ignored while a search
## runs.
func start(biome: String, start_tile: Vector2i, params: WorldGen, world_seed: int, threaded: bool) -> void:
	if is_finding():
		return
	if _finder_gen == null:
		_finder_gen = params.duplicate() if params != null else WorldGen.new()
	_finder_gen.configure(world_seed)
	_finder_biome = biome
	_finder_seed = world_seed
	_finder_cancel = false
	var avoid: Array = _travel_visited.get(biome, []).duplicate()
	_finder_result = null
	var search := _new_search(biome, start_tile, avoid)
	if threaded:
		_finder_thread = Thread.new()
		_finder_thread.start(_run_search.bind(search))
	else:
		_finder_search = search


func is_finding() -> bool:
	return _finder_thread != null or _finder_search != null


## Stops a running search; its outcome then reports it cancelled.
func cancel() -> void:
	if is_finding():
		_finder_cancel = true


## A new seed: a running search is looking at the old world, and the
## places traveled to belong to it.
func reset() -> void:
	_finder_cancel = true
	_travel_visited.clear()


## Before content is reloaded (review X3): stops the search thread, which
## reads structure definitions, and forgets its sites. Returns whether a
## thread was stopped - its outcome (cancelled) is then ready for finish().
func stop_for_reload() -> bool:
	_finder_cancel = true
	var stopped := false
	if _finder_thread != null:
		_finder_thread.wait_to_finish()
		_finder_thread = null
		stopped = true
	_finder_sites = null
	return stopped


## Leaving the tree: stops the search thread.
func stop() -> void:
	if _finder_thread != null:
		_finder_cancel = true
		_finder_thread.wait_to_finish()
		_finder_thread = null


## Main thread, once a frame: steps a search without a thread by
## TRAVEL_BUDGET_USEC. Returns true when a search is over, its outcome
## ready for finish().
func poll() -> bool:
	var done := false
	if _finder_thread != null and not _finder_thread.is_alive():
		_finder_thread.wait_to_finish()
		_finder_thread = null
		done = true
	if _finder_search != null and (_finder_cancel or _finder_search.step(Time.get_ticks_usec() + TRAVEL_BUDGET_USEC)):
		if not _finder_cancel:
			_finder_result = _finder_search.result
		_finder_search = null
		done = true
	return done


## The outcome of the search just over, for a world now at `world_seed`:
## {"biome", "found", "cancelled", "tile"}. A found tile is remembered, so
## the next trip to the same biome hops onward (the last 8 are avoided).
func finish(world_seed: int) -> Dictionary:
	var cancelled := _finder_cancel or _finder_seed != world_seed
	var found := not cancelled and _finder_result != null
	var outcome := {"biome": _finder_biome, "found": found, "cancelled": cancelled, "tile": _finder_result if found else null}
	if found:
		var visited: Array = _travel_visited.get(_finder_biome, [])
		visited.append(_finder_result)
		_travel_visited[_finder_biome] = visited.slice(-8)
	return outcome


## The search for a travel target, not yet run: BiomeFinder, or for a
## structure's display name (WorldContent.structures) a StructureSites
## search - the nearest site of that type other than one at the start or
## already visited - instead of scanning tiles. Both step() until done.
func _new_search(biome: String, start_tile: Vector2i, avoid: Array) -> RefCounted:
	for def in StructureSitesScript.CONTENT.structures:
		if def.display_name == biome:
			if _finder_sites == null or _finder_sites.world_seed != _finder_seed:
				_finder_sites = StructureSitesScript.new(_finder_gen, _finder_seed)
			return _finder_sites.search(def.id, start_tile, avoid)
	return BiomeFinderScript.new(_finder_gen, biome, start_tile, avoid)


## The search thread: runs `search` to the end unless cancelled.
func _run_search(search: RefCounted) -> void:
	while not search.step(Time.get_ticks_usec() + 20000):
		if _finder_cancel:
			return
	_finder_result = search.result
