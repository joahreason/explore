extends SceneTree

## Phase 17 guard: performance work must not change what gets generated.
## Places the full GUILD_STACK (every guild's instances: guild, species id,
## cell, position), Oak Placement, and bakes a few views' chunk images for a
## fixed seed and a fixed set of areas through the real chunk_manager.gd code
## paths, then compares a per-layer count + hash against
## tests/placement_snapshot.txt. Also checks the density bounds placement
## relies on to skip candidates (ResourceManager.get_*density_bound()).
##
##   SNAPSHOT_WRITE=1   rewrite the golden file (only for an agreed change)
##   SNAPSHOT_DUMP=path write every instance line, for diffing a mismatch
##
## Areas cover the origin (mixed forest), a river (18000,8820), a storm scar
## (-540,-2060), a fire scar (1760,-870), sedimentary wetland
## (8000,-12000) and a sea coast (19946,20042, from test_shores.gd's areas).
##
## Order pass (review T2): a second, fresh world without a worker rebuilds
## the same chunks in reverse order and must match chunk for chunk, so a
## result that depends on what was generated first fails here. ORDER_AREAS
## adds a coast with an enclosed sea next to open ocean (not in the golden
## file). Reversing chunk order didn't expose the water-label bug of review
## D1 there, so test_shores.gd checks that one directly.

const SEED := 4242
const GOLDEN := "res://tests/placement_snapshot.txt"
## Tile centers; each area is AREA_CHUNKS x AREA_CHUNKS chunks around it.
const AREAS := [Vector2i(0, 0), Vector2i(18000, 8820), Vector2i(-540, -2060), Vector2i(1760, -870), Vector2i(8000, -12000), Vector2i(19946, 20042), Vector2i(-1920, -2280)]
const AREA_CHUNKS := 3
const ORDER_AREAS := [Vector2i(-1052, -1212)]

var _fails := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond:
		_fails += 1


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	# The startup chunks stream in on a worker thread; finish them so it is
	# idle while this calls the generation functions directly.
	world.flush_chunk_work()

	var CM = world.get_script()
	var lines := {}  # layer name -> Array of lines
	var t0 := Time.get_ticks_msec()
	for area in AREAS:
		var center: Vector2i = world._chunk_of(Vector2(area) * world.TILE_SIZE)
		for dy in AREA_CHUNKS:
			for dx in AREA_CHUNKS:
				var chunk := center + Vector2i(dx - AREA_CHUNKS / 2, dy - AREA_CHUNKS / 2)
				var base: Vector2i = chunk * world.CHUNK_SIZE
				var stack: Dictionary = world._place_stack_chunk(base)
				for guild in world.GUILD_STACK:
					_add(lines, guild.id, stack[guild])
				_add(lines, "oak_placement", world._place_definition_chunk(world.OAK_RESOURCE, base))
	var t_place := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	for mode in [CM.ViewMode.MATERIAL, CM.ViewMode.RESOURCE_PLACEMENT_OAK, CM.ViewMode.TREE_PLACEMENT, CM.ViewMode.DEPOSITS, CM.ViewMode.SUCCESSION]:
		world._view_mode = mode
		var key: String = "image_" + CM.ViewMode.keys()[mode].to_lower()
		for area in AREAS:
			var chunk: Vector2i = world._chunk_of(Vector2(area) * world.TILE_SIZE)
			for lod_step in [1, 2]:
				var img: Image = world._build_chunk_image(chunk, lod_step)
				_append(lines, key, "%s|%d|%s" % [chunk, lod_step, img.get_data().hex_encode().md5_text()])
	var t_images := Time.get_ticks_msec() - t0
	print("INFO snapshot: placement %d ms, images %d ms" % [t_place, t_images])

	# ResourcePlacement skips candidates whose roll is at or above the density
	# bound, which is only exact if no tile's density ever exceeds it.
	var bound_ok := true
	var bound_tiles := 0
	for area in AREAS:
		for y in range(area.y - 24, area.y + 24, 3):
			for x in range(area.x - 24, area.x + 24, 3):
				var s: Dictionary = world._world_gen.sample(x, y)
				var st = EnvironmentalState.from_sample(s)
				var cl: Dictionary = BiomeClassifier.classify_full(s)
				bound_tiles += 1
				for guild in world.GUILD_STACK:
					bound_ok = bound_ok and ResourceManager.get_guild_density(st, guild, SEED, x, y, cl) <= ResourceManager.get_guild_density_bound(guild)
				bound_ok = bound_ok and ResourceManager.get_density(st, world.OAK_RESOURCE, SEED, x, y, cl) <= ResourceManager.get_density_bound(world.OAK_RESOURCE)
	check(bound_ok, "density never exceeds its placement bound (%d tiles x %d guilds + oak)" % [bound_tiles, world.GUILD_STACK.size()])

	# Order pass: the golden areas and ORDER_AREAS, chunk by chunk, here and
	# in reverse order from a fresh world with no worker.
	var order_chunks: Array[Vector2i] = []
	for area in AREAS + ORDER_AREAS:
		var center: Vector2i = world._chunk_of(Vector2(area) * world.TILE_SIZE)
		for dy in AREA_CHUNKS:
			for dx in AREA_CHUNKS:
				order_chunks.append(center + Vector2i(dx - AREA_CHUNKS / 2, dy - AREA_CHUNKS / 2))
	t0 = Time.get_ticks_msec()
	var forward := {}
	for chunk in order_chunks:
		forward[chunk] = _chunk_results(world, chunk)
	var fresh: Node2D = load("res://world.tscn").instantiate()
	fresh.world_seed = SEED
	fresh.threaded_generation = false
	root.add_child(fresh)
	await process_frame
	fresh.flush_chunk_work()
	var differ: Array[Vector2i] = []
	for i in range(order_chunks.size() - 1, -1, -1):
		var chunk: Vector2i = order_chunks[i]
		if _chunk_results(fresh, chunk) != forward[chunk]:
			differ.append(chunk)
	fresh.queue_free()
	check(differ.is_empty(), "%d chunks identical rebuilt in reverse order by a fresh world without a worker (%d ms)%s" % [
		order_chunks.size(), Time.get_ticks_msec() - t0, "" if differ.is_empty() else ", differ: %s" % [differ]])

	var summary := PackedStringArray()
	var dump := PackedStringArray()
	var names := lines.keys()
	names.sort()
	for name in names:
		var body := "\n".join(PackedStringArray(lines[name]))
		summary.append("%s %d %s" % [name, lines[name].size(), body.md5_text()])
		dump.append_array(PackedStringArray(lines[name]))

	var dump_path := OS.get_environment("SNAPSHOT_DUMP")
	if dump_path != "":
		var f := FileAccess.open(dump_path, FileAccess.WRITE)
		f.store_string("\n".join(dump) + "\n")
		print("INFO wrote %d instance lines to %s" % [dump.size(), dump_path])

	if OS.get_environment("SNAPSHOT_WRITE") == "1":
		var f := FileAccess.open(GOLDEN, FileAccess.WRITE)
		f.store_string("\n".join(summary) + "\n")
		print("INFO wrote %s" % GOLDEN)

	var golden := FileAccess.get_file_as_string(GOLDEN).strip_edges().split("\n")
	check(golden.size() == summary.size(), "snapshot has %d layers (golden %d)" % [summary.size(), golden.size()])
	var total := 0
	for i in summary.size():
		var parts := summary[i].split(" ")
		total += int(parts[1])
		var want: String = golden[i] if i < golden.size() else "(missing)"
		check(summary[i] == want, "%s: %s instances/images identical to golden" % [parts[0], parts[1]] if summary[i] == want else "%s: got '%s', golden '%s'" % [parts[0], summary[i], want])
	check(total > 1000, "snapshot covers %d instances/images" % total)

	print("RESULT %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(1 if _fails > 0 else 0)


## Positions are written as integer micro-tiles, not "%.6f": far from the
## origin a float32 position has only ~8-9 fractional bits, so many print as
## exact decimal ties, and the C runtime rounds those differently (MSVC half
## away from zero, glibc half to even) - the golden then only matched on the
## platform it was recorded on. roundi() of the double product is plain IEEE
## arithmetic, identical everywhere.
func _add(lines: Dictionary, name: String, instances: Array) -> void:
	for inst in instances:
		var pos: Vector2 = inst["position"]
		_append(lines, name, "%s|%s|%s|%d,%d" % [inst.get("guild", ""), inst["id"], inst["cell"], roundi(pos.x * 1e6), roundi(pos.y * 1e6)])


## Every guild's, Oak Placement's and the Material view's image for one
## chunk, as layer name -> hash.
func _chunk_results(world: Node2D, chunk: Vector2i) -> Dictionary:
	var lines := {}
	var base: Vector2i = chunk * world.CHUNK_SIZE
	var stack: Dictionary = world._place_stack_chunk(base)
	for guild in world.GUILD_STACK:
		_add(lines, guild.id, stack[guild])
	_add(lines, "oak_placement", world._place_definition_chunk(world.OAK_RESOURCE, base))
	var view: int = world._view_mode
	world._view_mode = world.get_script().ViewMode.MATERIAL
	_append(lines, "image_material", world._build_chunk_image(chunk, 1).get_data().hex_encode())
	world._view_mode = view
	var result := {}
	for name in lines:
		result[name] = "\n".join(PackedStringArray(lines[name])).md5_text()
	return result


func _append(lines: Dictionary, name: String, line: String) -> void:
	if not lines.has(name):
		lines[name] = []
	lines[name].append(line)
