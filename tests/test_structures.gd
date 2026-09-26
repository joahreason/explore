extends SceneTree

## Landmark layer (camps, standing stones, ruins): StructureSites places at
## most one site per CELL_SIZE cell from hashes of (seed, cell); the type
## comes from the environment at the centre; every footprint lies inside its
## cell. Checks: the data is valid; sites are deterministic and seed-
## dependent; footprints stay inside their cell; every site suits its type
## (and has water nearby when it asks for it); stamps give 5-9 standing
## stones and a campfire with 1-2 tents; ruins grow more plants where
## vegetation is higher; the mask matches the footprint whatever the query
## order; rarity stays near its targets; and in the real scene no resource
## is placed on a footprint, the World view draws the parts, the inspector
## names the site and the Go to menu finds sites. Run via tests/run_tests.sh.

const StructureSitesScript := preload("res://scripts/structure_sites.gd")
const SEED := 4242
const CELL := StructureSites.CELL_SIZE

var _fails := 0
var _passes := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS ", msg)
	else:
		_fails += 1
		print("FAIL ", msg)


func _init() -> void:
	for def in StructureSitesScript.CONTENT.structures:
		check(def.get_curve_domain_warnings().is_empty(), "%s: data valid %s" % [def.id, def.get_curve_domain_warnings()])
		check(def.radius < StructureSitesScript.new(WorldGen.new(), SEED).margin, "%s: radius %d fits inside the cell margin" % [def.id, def.radius])

	var wg := WorldGen.new()
	wg.configure(SEED)
	var sites := StructureSitesScript.new(wg, SEED)

	# Scan a spread of cells once; everything below reads these.
	var cells: Array[Vector2i] = []
	for cy in range(-12, 12):
		for cx in range(-12, 12):
			cells.append(Vector2i(cx * 3, cy * 3))
	var found := []
	var land := 0
	for cell in cells:
		var center := cell * CELL + Vector2i(CELL / 2, CELL / 2)
		if wg.sample(center.x, center.y)["water_body"] == "none":
			land += 1
		var site := sites.site_for_cell(cell)
		if not site.is_empty():
			found.append(site)
	var by_type := {}
	for site in found:
		by_type[site["id"]] = by_type.get(site["id"], 0) + 1
	print("INFO %d cells (%d with a land centre): %s" % [cells.size(), land, by_type])
	check(by_type.size() == 3, "all three structures occur in the sampled area")

	# 1. Determinism and seed dependence.
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var again := StructureSitesScript.new(wg2, SEED)
	var reversed := cells.duplicate()
	reversed.reverse()
	var same := true
	for cell in reversed:
		same = same and _signature(again.site_for_cell(cell)) == _signature(sites.site_for_cell(cell))
	check(same, "same seed, fresh WorldGen, reverse order: identical sites")
	var wg3 := WorldGen.new()
	wg3.configure(SEED + 1)
	var other := StructureSitesScript.new(wg3, SEED + 1)
	var differ := 0
	for cell in cells:
		if _signature(other.site_for_cell(cell)) != _signature(sites.site_for_cell(cell)):
			differ += 1
	check(differ > found.size() / 2, "another seed gives other sites (%d cells differ)" % differ)

	# 2. Footprints inside their cell; plausibility at the centre.
	var inside := true
	var suits := true
	var water_ok := true
	var ages_ok := true
	for site in found:
		var def: StructureDefinition = site["definition"]
		var cell_rect := Rect2i(site["cell"] * CELL, Vector2i(CELL, CELL))
		var c: Vector2i = site["center"]
		inside = inside and cell_rect.has_point(c - Vector2i(def.radius, def.radius)) and cell_rect.has_point(c + Vector2i(def.radius, def.radius))
		for part in site["parts"]:
			var d: Vector2i = part["tile"] - c
			inside = inside and d.x * d.x + d.y * d.y <= def.radius * def.radius and cell_rect.has_point(part["tile"])
		var s := wg.sample(c.x, c.y)
		var suit: float = ResourceManager.get_suitability(EnvironmentalState.from_sample(s), def)
		suits = suits and s["water_body"] == "none" and suit >= def.min_suitability and is_equal_approx(suit, site["suitability"])
		if def.water_within > 0:
			water_ok = water_ok and sites._water_near(c, def.water_within)
		ages_ok = ages_ok and site["age"] >= def.age_range.x and site["age"] <= def.age_range.y
	check(inside, "every footprint and part lies inside its own cell")
	check(suits, "every site stands on dry land that suits its type")
	check(water_ok, "camps and ruins have open water within their water_within")
	check(ages_ok, "every age lies in its structure's age_range")

	# 3. Stamps.
	var stones_ok := true
	var camp_ok := true
	var camp_kinds := []
	for site in found:
		var kinds := {}
		for part in site["parts"]:
			kinds[part["kind"]] = kinds.get(part["kind"], 0) + 1
		if site["id"] == "standing_stones":
			stones_ok = stones_ok and kinds.get("standing stone", 0) >= 5 and kinds.get("standing stone", 0) <= 9
		elif site["id"] == "camp":
			camp_ok = camp_ok and kinds.get("campfire", 0) == 1 and kinds.get("tent", 0) >= 1 and kinds.get("tent", 0) <= 2
			camp_kinds.append(kinds)
	check(stones_ok, "standing stones: 5-9 stones in every ring")
	check(camp_ok, "camps: a campfire and one or two tents %s" % ("" if camp_ok else str(camp_kinds)))
	var ruins: StructureDefinition = StructureSitesScript.CONTENT.structures[2]
	var growth := Vector2i.ZERO  # (low vegetation, high vegetation) plant counts
	var walls_young := 0
	var walls_old := 0
	for i in 200:
		var cell := Vector2i(i, 7)
		var center := cell * CELL + Vector2i(32, 32)
		growth.x += _count(sites._stamp(ruins, cell, center, 0, 1.0, 0.1), "overgrowth")
		growth.y += _count(sites._stamp(ruins, cell, center, 0, 1.0, 0.9), "overgrowth")
		walls_young += _count(sites._stamp(ruins, cell, center, 0, 0.0, 0.5), "wall")
		walls_old += _count(sites._stamp(ruins, cell, center, 0, 1.0, 0.5), "wall")
	check(growth.y > growth.x * 3, "ruins: more plants grow through at high vegetation (%d vs %d)" % [growth.y, growth.x])
	check(walls_old < walls_young / 2, "ruins: old sites keep fewer walls (%d vs %d)" % [walls_old, walls_young])

	# 4. The mask is exactly the footprint, whichever order tiles are asked in.
	var mask_ok := true
	var masked := 0
	for site in found.slice(0, 12):
		var c: Vector2i = site["center"]
		var r: int = site["definition"].radius
		for dy in range(-r - 2, r + 3):
			for dx in range(-r - 2, r + 3):
				var t := c + Vector2i(dx, dy)
				var want := dx * dx + dy * dy <= r * r
				mask_ok = mask_ok and sites.is_masked(t) == want and again.is_masked(t) == want
				if want:
					masked += 1
	check(mask_ok and masked > 0, "structure_mask covers exactly the footprint (%d tiles checked)" % masked)

	# 5. Rarity: share of land cells with each type, near the targets
	# (camp ~6%, standing stones ~3%, ruins ~1.5% measured on 3 seeds).
	var rates := {}
	for id in ["camp", "standing_stones", "ruins"]:
		rates[id] = float(by_type.get(id, 0)) / maxi(land, 1)
	print("INFO rates per land cell: %s" % rates)
	check(rates["camp"] > 0.025 and rates["camp"] < 0.12, "camp rate %.3f in 0.025..0.12" % rates["camp"])
	check(rates["standing_stones"] > 0.01 and rates["standing_stones"] < 0.07, "standing stones rate %.3f in 0.01..0.07" % rates["standing_stones"])
	check(rates["ruins"] > 0.002 and rates["ruins"] < 0.05, "ruins rate %.3f in 0.002..0.05" % rates["ruins"])
	check(rates["camp"] > rates["standing_stones"] and rates["standing_stones"] > rates["ruins"], "camps commonest, ruins rarest")

	await _check_scene(found)

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _check_scene(found: Array) -> void:
	# Curve plans are built when the world starts, not lazily by whichever
	# thread asks first: the "Go to" thread reads these same definitions
	# (review C5).
	await process_frame  # the tree is running, so add_child() runs _ready() at once
	var lazy: Array = StructureSitesScript.CONTENT.structures + TerrainSurface.CONTENT.terrain_materials
	for def in lazy:
		def.curve_plan = null
	var eager: Node2D = load("res://world.tscn").instantiate()
	eager.world_seed = SEED
	eager.changes_dir = ""
	eager.threaded_generation = false
	root.add_child(eager)  # runs _ready(); no frame, so no chunk work yet
	var unbuilt: Array = lazy.filter(func(def): return def.curve_plan == null).map(func(def): return def.id)
	eager.queue_free()
	await process_frame
	check(unbuilt.is_empty(), "every structure and terrain curve plan is built at startup (not yet: %s)" % [unbuilt])

	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	world.changes_dir = ""
	root.add_child(world)
	await process_frame
	await process_frame
	world.flush_chunk_work()

	# No resource on any footprint (the whole guild stack around each site).
	var clear := true
	var near := 0
	for site in found.slice(0, 10):
		var c: Vector2i = site["center"]
		var r: int = site["definition"].radius
		var stack: Dictionary = world._ctx.place_stack(Rect2i(c - Vector2i(r + 3, r + 3), Vector2i(2 * r + 7, 2 * r + 7)))
		for guild in stack:
			for inst in stack[guild]:
				var t := Vector2i((inst["position"] as Vector2).floor())
				if world._ctx.structures.is_masked(t):
					clear = false
				else:
					near += 1
	check(clear and near > 0, "no resource placed on a footprint (%d placed just around them)" % near)

	# The World view draws a site's parts in its chunk's marker data.
	var site: Dictionary = found[0]
	var part_tile: Vector2i = site["parts"][0]["tile"]
	var chunk := Vector2i(floori(part_tile.x / 16.0), floori(part_tile.y / 16.0))
	world._ctx.mutex.lock()
	var layers: Array = world._builder.placement_chunk(chunk)
	world._ctx.mutex.unlock()
	var drawn := false
	for entry in layers:
		if entry[0][0] == null:
			for inst in entry[1]:
				drawn = drawn or Vector2i((inst["position"] as Vector2).floor()) == part_tile
	check(drawn, "World view: the chunk's marker data holds the site's parts")
	var node: Node2D = world._presenter.marker_node(chunk * 16, layers)
	check(node.instance_count() >= layers[0][1].size(), "marker node draws %d structure sprites" % layers[0][1].size())
	node.free()

	# Inspector.
	world._on_tile_clicked((Vector2(site["center"]) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var text: String = world._inspector_panel.label.text
	check(text.contains("Structure:[/b] %s" % site["name"]), "inspector names the structure on its centre tile")

	# Go to: finds sites directly, and hops on from one already visited.
	var start := Vector2i(0, 0)
	world._travel._finder_gen = WorldGen.new()
	world._travel._finder_gen.configure(SEED)
	world._travel._finder_seed = SEED
	var t0 := Time.get_ticks_msec()
	world._travel._run_search(world._travel._new_search("Ruins", start, []))
	var first = world._travel._finder_result
	check(first != null and world._ctx.structures.site_at(first).get("id", "") == "ruins", "Go to Ruins lands on a ruins centre (%s, %d ms)" % [first, Time.get_ticks_msec() - t0])
	if first != null:
		world._travel._run_search(world._travel._new_search("Ruins", start, [first]))
		var second = world._travel._finder_result
		check(second != null and second != first and world._ctx.structures.site_at(second).get("id", "") == "ruins", "Go to Ruins again hops to another site (%s)" % [second])
	world._travel._run_search(world._travel._new_search("Grassland", start, []))
	check(world._travel._finder_result != null, "biomes still travel through BiomeFinder")
	world.queue_free()
	await process_frame


func _signature(site: Dictionary) -> String:
	if site.is_empty():
		return ""
	var tiles := []
	for part in site["parts"]:
		tiles.append("%s%s" % [part["tile"], part["sheet"]])
	return "%s|%s|%d|%.5f|%s" % [site["id"], site["center"], site["rotation"], site["age"], ",".join(tiles)]


func _count(parts: Array, kind: String) -> int:
	var n := 0
	for part in parts:
		if part["kind"] == kind:
			n += 1
	return n
