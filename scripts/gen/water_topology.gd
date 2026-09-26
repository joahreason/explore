class_name WaterTopology
extends RefCounted

## Real bounded/cached flood-fill for water-body topology (enclosure, size,
## connectivity) - the only non-O(1)-pure-function piece of the generator.
## Everything else in this project is a stateless per-tile function; this
## exists because "is this tile's water body enclosed, and how big/connected
## is it" genuinely cannot be answered without looking at neighboring tiles,
## and a fully unbounded flood-fill isn't affordable for an infinite
## streamed world. See scripts/gen/world_gen.gd's water_body block for how the
## result is used.
##
## Determinism: a body is enclosed exactly when its whole 4-connected water
## component fits within the budget, so a fill from any of its tiles gives
## the same answer, and area/perimeter/compactness/connected_to_ocean are the
## same whichever tile triggered it - verified in tests/test_shores.gd. For a
## body over the budget (open/unbounded, the ocean) a capped fill's shape
## depends on where it started, so only "open" is kept: every water tile the
## capped fill visited is marked open, and a later fill stops as soon as it
## reaches an open tile (connected water belongs to the same, open, body).
## Both rules give the same labels in any query order.

const NEIGHBORS_4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var _cache: Dictionary = {}  # Vector2i tile -> Result, only for fully-enclosed bodies
## Tiles of open bodies, as one bitmap (PackedByteArray, a bit per tile) per
## OPEN_CELL x OPEN_CELL cell: a Dictionary entry per tile would cost ~88 bytes.
var _open: Dictionary = {}  # Vector2i cell -> PackedByteArray
const OPEN_SHIFT := 6
const OPEN_CELL := 1 << OPEN_SHIFT
const OPEN_MASK := OPEN_CELL - 1
var _no_bits := PackedByteArray()  # a default for _open.get() (a const one hangs the 4.7 parser)
const OPEN_RESULT := {
	"enclosed": false, "area": -1, "perimeter": -1,
	"compactness": 0.0, "connected_to_ocean": false,
}


## elevation_fn: Callable(float, float) -> float, i.e. WorldGen.elevation.
func classify(
	wx: int, wy: int, elevation_fn: Callable, sea_level: float,
	fill_budget: int, strait_probe_distance: int
) -> Dictionary:
	var tile := Vector2i(wx, wy)
	if _cache.has(tile):
		return _cache[tile]

	if _is_open(tile):
		return OPEN_RESULT

	var fill := _flood_fill(wx, wy, elevation_fn, sea_level, fill_budget, strait_probe_distance)
	if not fill["enclosed"]:
		_mark_open(fill["members"])
		return OPEN_RESULT

	var result := {
		"enclosed": fill["enclosed"],
		"area": fill["area"],
		"perimeter": fill["perimeter"],
		"compactness": fill["compactness"],
		"connected_to_ocean": fill["connected_to_ocean"],
	}

	# Mark every member tile at once - O(1) lookups for the rest of this
	# lake from here on, instead of re-running the fill per tile.
	for t in fill["members"]:
		_cache[t] = result
	return result


func _flood_fill(
	wx: int, wy: int, elevation_fn: Callable, sea_level: float,
	fill_budget: int, strait_probe_distance: int
) -> Dictionary:
	var start := Vector2i(wx, wy)
	var visited := {start: true}
	var queue: Array[Vector2i] = [start]
	var boundary: Array[Vector2i] = []
	var qi := 0
	var joins_open := false
	var open_fill := {
		"enclosed": false, "area": -1, "perimeter": -1,
		"compactness": 0.0, "connected_to_ocean": false, "members": queue,
	}

	while qi < queue.size():
		var cur: Vector2i = queue[qi]
		qi += 1
		for d in NEIGHBORS_4:
			var n: Vector2i = cur + d
			if visited.has(n):
				continue
			visited[n] = true
			if _is_open(n):
				# Joined to water already known to be open, so this body is
				# open too. Keep filling (up to the budget) so one fill marks
				# a whole region open, not tile by tile along the frontier.
				joins_open = true
				continue
			var e: float = elevation_fn.call(float(n.x), float(n.y))
			if e < sea_level:
				queue.append(n)
				if queue.size() > fill_budget:
					return open_fill
			else:
				boundary.append(n)

	if joins_open:
		return open_fill

	var area := queue.size()
	var perimeter := boundary.size()
	var compactness := float(area) / float(maxi(perimeter * perimeter, 1))
	var connected := _probe_ocean_adjacency(boundary, elevation_fn, sea_level, strait_probe_distance)

	return {
		"enclosed": true, "area": area, "perimeter": perimeter,
		"compactness": compactness, "connected_to_ocean": connected, "members": queue,
	}


func _is_open(t: Vector2i) -> bool:
	# >> floors negative coordinates too, like floori(t / OPEN_CELL).
	var bits: PackedByteArray = _open.get(Vector2i(t.x >> OPEN_SHIFT, t.y >> OPEN_SHIFT), _no_bits)
	if bits.is_empty():
		return false
	var i := ((t.y & OPEN_MASK) << OPEN_SHIFT) | (t.x & OPEN_MASK)
	return (bits[i >> 3] & (1 << (i & 7))) != 0


func _mark_open(tiles: Array[Vector2i]) -> void:
	var cells := {}  # Vector2i -> PackedByteArray, held here while it is written
	for t in tiles:
		var cell := Vector2i(t.x >> OPEN_SHIFT, t.y >> OPEN_SHIFT)
		if not cells.has(cell):
			var bits: PackedByteArray = _open.get(cell, _no_bits)
			_open.erase(cell)  # one owner, so the writes below don't copy it
			if bits.is_empty():
				bits = PackedByteArray()
				bits.resize(OPEN_CELL * OPEN_CELL / 8)
			cells[cell] = bits
		var i := ((t.y & OPEN_MASK) << OPEN_SHIFT) | (t.x & OPEN_MASK)
		cells[cell][i >> 3] |= 1 << (i & 7)
	_open.merge(cells)


## Approximated rather than a second nested flood-fill (which would multiply
## cost further): sample a bounded number of this lake's boundary tiles -
## sorted into a canonical order first so the SAME sample is chosen
## regardless of which tile triggered the fill (traversal order otherwise
## differs by entry point, which would make this non-deterministic) - and
## probe a fixed distance past each in the four cardinal directions, looking
## for open water beyond a narrow land gap (a strait).
func _probe_ocean_adjacency(
	boundary: Array[Vector2i], elevation_fn: Callable, sea_level: float, probe_distance: int
) -> bool:
	if boundary.is_empty():
		return false

	var sorted_boundary := boundary.duplicate()
	sorted_boundary.sort()

	var max_samples := 30
	var step := maxi(1, sorted_boundary.size() / max_samples)
	var i := 0
	while i < sorted_boundary.size():
		var t: Vector2i = sorted_boundary[i]
		for d in NEIGHBORS_4:
			var probe: Vector2i = t + d * probe_distance
			var e: float = elevation_fn.call(float(probe.x), float(probe.y))
			if e < sea_level:
				return true
		i += step

	return false
