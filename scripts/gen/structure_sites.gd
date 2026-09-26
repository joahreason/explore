class_name StructureSites
extends RefCounted

## Landmark layer: rare, discrete sites (StructureDefinition: camps,
## standing stones, ruins) on a coarse world-aligned grid of CELL_SIZE-tile
## cells, at most one site per cell. A site's centre, type, rotation and age
## come from hashes of (seed, cell) - ResourcePlacement's cell hash, seeded
## from world_seed + WorldGen.STRUCTURE_SITE_SEED_OFFSET - and its type from
## the environment at that centre (StructureDefinition suitability over one
## WorldGen.sample(); a structure with water_within then also needs open
## water nearby, else the cell stays empty).
## Every footprint lies wholly inside its own cell (the centre keeps
## `margin` tiles from the cell edge, margin > every radius), so the site
## affecting a tile is found by looking only at the tile's own cell: pure
## (seed, tile) data, chunk-independent and seam-free.
##
## Pure data, like ResourcePlacement: ChunkManager draws parts_in_rect(),
## masks resources with is_masked(), and the inspector reads site_at().
## One instance per WorldGen (sample() fills that WorldGen's water topology
## cache, so an instance is used from one thread at a time); sites are
## cached per cell.

const CELL_SIZE := 64
## The structure types: WorldContent.structures.
const CONTENT: WorldContent = preload("res://resources/world_content.tres")
## Water probe: rays in 8 directions, a sample every this many tiles.
const WATER_PROBE_STEP := 3
const OPEN_WATER := ["ocean", "sea", "lake", "river"]
const CACHE_LIMIT := 20000
## find(): how far to search, and how close to an already visited site (or
## the start) a site is skipped.
const FIND_MAX_RADIUS := 3000
const FIND_AVOID_RADIUS := 16

# Salts for the per-cell rolls (ResourcePlacement._cell_hash).
const _SALT_X := 1
const _SALT_Y := 2
const _SALT_TYPE := 3
const _SALT_ROTATION := 4
const _SALT_AGE := 5
const _SALT_PART_CHANCE := 100  # + part index
const _SALT_PART_DECAY := 1100  # + part index
const _SALT_GROWTH := 2100      # per footprint tile
const _SALT_GROWTH_TILE := 2101

const EnvironmentalStateScript := preload("res://scripts/gen/environmental_state.gd")
const ResourceManagerScript := preload("res://scripts/resources/resource_manager.gd")
const ResourcePlacementScript := preload("res://scripts/resources/resource_placement.gd")

var world_seed: int
var definitions: Array
var margin: int
var _world_gen: WorldGen
var _site_seed: int
var _cache: Dictionary = {}  # Vector2i cell -> site Dictionary ({} = none)


func _init(world_gen: WorldGen, seed_value: int, defs: Array = CONTENT.structures) -> void:
	_world_gen = world_gen
	world_seed = seed_value
	definitions = defs
	_site_seed = ("%d:structures" % (seed_value + WorldGen.STRUCTURE_SITE_SEED_OFFSET)).hash() & 0xFFFFFFFF
	var max_radius := 0
	for def in defs:
		max_radius = maxi(max_radius, def.radius)
	margin = max_radius + 1


static func cell_of(tile: Vector2i) -> Vector2i:
	return Vector2i(floori(tile.x / float(CELL_SIZE)), floori(tile.y / float(CELL_SIZE)))


## The cell's site, or {} if it has none:
##   {"id", "name", "definition", "cell", "center": Vector2i, "rotation"
##    (quarter turns), "age" (0..1), "suitability",
##    "parts": [{"tile": Vector2i, "sheet": Vector2i, "kind", "color"}]}
func site_for_cell(cell: Vector2i) -> Dictionary:
	var site = _cache.get(cell)
	if site == null:
		if _cache.size() >= CACHE_LIMIT:
			_cache.clear()
		site = _build_site(cell)
		_cache[cell] = site
	return site


## The site whose footprint covers `tile`, or {}.
func site_at(tile: Vector2i) -> Dictionary:
	var site := site_for_cell(cell_of(tile))
	if site.is_empty():
		return site
	var d: Vector2i = tile - site["center"]
	var r: int = site["definition"].radius
	return site if d.x * d.x + d.y * d.y <= r * r else {}


## structure_mask: true where a site's footprint covers the tile, so
## resource placement leaves it clear (as it leaves water clear).
func is_masked(tile: Vector2i) -> bool:
	return not site_at(tile).is_empty()


## Sites in the cells a tile rect (end-exclusive) overlaps.
func sites_in_rect(rect: Rect2i) -> Array:
	var c0 := cell_of(rect.position)
	var c1 := cell_of(rect.end - Vector2i.ONE)
	var sites := []
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var site := site_for_cell(Vector2i(cx, cy))
			if not site.is_empty():
				sites.append(site)
	return sites


## Stamp parts whose tile lies in the rect, as marker instances for
## resource_marker_chunk.gd: {"id": "structure:<sheet x>,<sheet y>",
## "position" (tile centre), "sheet", "fill", "kind", "site": site id}.
func parts_in_rect(rect: Rect2i) -> Array:
	var result := []
	for site in sites_in_rect(rect):
		for part in site["parts"]:
			var tile: Vector2i = part["tile"]
			if rect.has_point(tile):
				var sheet: Vector2i = part["sheet"]
				result.append({
					"id": "structure:%d,%d" % [sheet.x, sheet.y],
					"position": Vector2(tile) + Vector2(0.5, 0.5),
					"sheet": sheet,
					"fill": part["color"],
					"kind": part["kind"],
					"site": site["id"],
				})
	return result


## "Go to" menu: the centre of the nearest `type_id` site around `start`,
## searched cell ring by cell ring (the ring after the first hit too, since
## ring order is only roughly distance order), skipping sites within
## FIND_AVOID_RADIUS of the start or an `avoid` tile. null if none within
## FIND_MAX_RADIUS or cancelled (cancel: Callable -> true to stop, checked
## about every 20 ms). search() gives the same search in resumable form.
func find(type_id: String, start: Vector2i, avoid: Array = [], cancel: Callable = Callable()) -> Variant:
	var s := search(type_id, start, avoid)
	while not s.step(Time.get_ticks_usec() + 20000):
		if cancel.is_valid() and cancel.call():
			return null
	return s.result


## find() as a resumable Search (review W1): step() it until it returns
## true, then read its result - the web build spreads it over frames.
func search(type_id: String, start: Vector2i, avoid: Array = []) -> Search:
	return Search.new(self, type_id, start, avoid)


class Search:
	extends RefCounted
	var result: Variant = null  # the found centre (Vector2i) or null, once step() returns true
	var _sites
	var _type_id: String
	var _start: Vector2i
	var _avoid: Array
	var _origin: Vector2i
	var _last_ring: int
	var _k := 0
	var _ring_cells: Array[Vector2i] = []
	var _ri := 0
	var _best: Variant = null
	var _best_dist := INF
	var _done := false

	func _init(sites, type_id: String, start: Vector2i, avoid: Array) -> void:
		_sites = sites
		_type_id = type_id
		_start = start
		_avoid = avoid
		_origin = sites.cell_of(start)
		_last_ring = FIND_MAX_RADIUS / CELL_SIZE
		_ring_cells = StructureSites._ring(0)

	## Advances until done or Time.get_ticks_usec() passes deadline_usec
	## (checked between cells); true once done and `result` is set.
	func step(deadline_usec: int) -> bool:
		while not _done and Time.get_ticks_usec() < deadline_usec:
			var site: Dictionary = _sites.site_for_cell(_origin + _ring_cells[_ri])
			_ri += 1
			if not site.is_empty() and site["id"] == _type_id:
				var center: Vector2i = site["center"]
				var dist := Vector2(center - _start).length()
				if dist >= FIND_AVOID_RADIUS and dist < _best_dist and not StructureSites._near_any(center, _avoid):
					_best = center
					_best_dist = dist
			if _ri < _ring_cells.size():
				continue
			if _best != null and _last_ring > _k + 1:
				_last_ring = _k + 1
			_k += 1
			if _k > _last_ring:
				result = _best
				_done = true
			else:
				_ring_cells = StructureSites._ring(_k)
				_ri = 0
		return _done


## Index of the definition a cell's type roll picks from per-definition
## weights (frequency x suitability, 0 = unsuitable), or -1 for none. When
## the weights sum past 1 they're scaled to share the cell.
static func pick_type(weights: PackedFloat32Array, roll: float) -> int:
	var total := 0.0
	for w in weights:
		total += w
	var scale := 1.0 / total if total > 1.0 else 1.0
	var acc := 0.0
	for i in weights.size():
		if weights[i] <= 0.0:
			continue
		acc += weights[i] * scale
		if roll < acc:
			return i
	return -1


func _build_site(cell: Vector2i) -> Dictionary:
	var span := CELL_SIZE - 2 * margin
	var center := cell * CELL_SIZE + Vector2i(
		margin + mini(int(_unit(cell, _SALT_X) * span), span - 1),
		margin + mini(int(_unit(cell, _SALT_Y) * span), span - 1)
	)
	var sample := _world_gen.sample(center.x, center.y)
	var state = EnvironmentalStateScript.from_sample(sample)
	var weights := PackedFloat32Array()
	var suitabilities := PackedFloat32Array()
	for def in definitions:
		var s: float = ResourceManagerScript.get_suitability(state, def)
		if s < def.min_suitability:
			s = 0.0
		suitabilities.append(s)
		weights.append(def.frequency * s)
	var index := pick_type(weights, _unit(cell, _SALT_TYPE))
	if index < 0:
		return {}
	var def: StructureDefinition = definitions[index]
	# The water requirement vetoes the picked type rather than entering its
	# weight: the probe (up to ~80 samples) then runs only for cells that
	# picked a structure needing water, not for every suitable cell.
	if def.water_within > 0 and not _water_near(center, def.water_within):
		return {}
	var rotation := mini(int(_unit(cell, _SALT_ROTATION) * 4.0), 3)
	var age := lerpf(def.age_range.x, def.age_range.y, _unit(cell, _SALT_AGE))
	return {
		"id": def.id,
		"name": def.display_name,
		"definition": def,
		"cell": cell,
		"center": center,
		"rotation": rotation,
		"age": age,
		"suitability": suitabilities[index],
		"parts": _stamp(def, cell, center, rotation, age, float(sample["vegetation"])),
	}


## The stamp's surviving parts, rotated, plus the plants growing through.
func _stamp(def: StructureDefinition, cell: Vector2i, center: Vector2i, rotation: int, age: float, vegetation: float) -> Array:
	var parts := []
	var occupied := {}
	for i in def.parts.size():
		var part: Dictionary = def.parts[i]
		if _unit(cell, _SALT_PART_CHANCE + i) >= float(part.get("chance", 1.0)):
			continue
		if _unit(cell, _SALT_PART_DECAY + i) < age * float(part.get("decay", 0.0)):
			continue
		var tile := center + _rotated(part.get("at", Vector2i.ZERO), rotation)
		if occupied.has(tile):
			continue
		occupied[tile] = true
		var kind: String = part.get("kind", "")
		parts.append({"tile": tile, "sheet": part["tile"], "kind": kind, "color": def.kind_colors.get(kind, Color.WHITE)})

	var growth := def.overgrowth * age * lerpf(1.0, vegetation, def.overgrowth_vegetation_weight)
	if growth <= 0.0 or def.overgrowth_tiles.is_empty():
		return parts
	var r := def.radius
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var tile := center + Vector2i(dx, dy)
			if dx * dx + dy * dy > r * r or occupied.has(tile):
				continue
			if _unit(tile, _SALT_GROWTH) >= growth:
				continue
			var n := def.overgrowth_tiles.size()
			var sheet: Vector2i = def.overgrowth_tiles[mini(int(_unit(tile, _SALT_GROWTH_TILE) * n), n - 1)]
			parts.append({"tile": tile, "sheet": sheet, "kind": "overgrowth", "color": def.overgrowth_color})
	return parts


## Open water within `distance` tiles: samples along 8 rays every
## WATER_PROBE_STEP tiles, nearest first.
func _water_near(center: Vector2i, distance: int) -> bool:
	for d in range(WATER_PROBE_STEP, distance + 1, WATER_PROBE_STEP):
		for i in 8:
			var dir := Vector2.RIGHT.rotated(i * PI / 4.0)
			var p := center + Vector2i((dir * d).round())
			if OPEN_WATER.has(_world_gen.sample(p.x, p.y)["water_body"]):
				return true
	return false


static func _rotated(at: Vector2i, quarter_turns: int) -> Vector2i:
	var v := at
	for i in quarter_turns:
		v = Vector2i(-v.y, v.x)
	return v


func _unit(cell: Vector2i, salt: int) -> float:
	return ResourcePlacementScript.cell_unit(_site_seed, cell, salt)


static func _near_any(tile: Vector2i, points: Array) -> bool:
	for p in points:
		if Vector2(tile - p).length() < FIND_AVOID_RADIUS:
			return true
	return false


## Cells at Chebyshev distance k from the origin (k = 0: the origin).
static func _ring(k: int) -> Array[Vector2i]:
	if k == 0:
		return [Vector2i.ZERO]
	var cells: Array[Vector2i] = []
	for i in range(-k, k + 1):
		cells.append(Vector2i(i, -k))
		cells.append(Vector2i(i, k))
	for i in range(-k + 1, k):
		cells.append(Vector2i(-k, i))
		cells.append(Vector2i(k, i))
	return cells
