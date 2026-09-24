extends SceneTree

## Phase 13 (correlated ecosystems): resources influence each other only
## through shared environmental causes. Canopy shade is ONE derived value
## (ResourceManager.get_shade() = the canopy-tree guild's density), and the
## understory responds to it through shade_curve data: shade-loving species
## sit under more canopy than vegetated land in general, sun-loving ones
## under less; open ground (shade 0) is unchanged for every species that
## merely avoids or tolerates shade; values are deterministic and the chunk
## path (memo) agrees with the direct one. The floodplain chain (river +
## deposition + flat -> denser vegetation -> different mix) emerges from
## the existing river/deposition/fertility fields and is checked here too.
## Run via tests/run_tests.sh.

const CANOPY := preload("res://resources/canopy_trees.tres")
const GROUND_COVER := preload("res://resources/ground_cover.tres")
const DEADWOOD := preload("res://resources/deadwood.tres")
const SHRUBS := preload("res://resources/shrubs.tres")
const WETLAND := preload("res://resources/wetland_plants.tres")
const SEED := 4242
const REGIONS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000), Vector2i(8000, -12000)]
const HALF := 160
## Species whose shade_curve is below 1 on open ground on purpose: they
## depend on shade (mushrooms replaced their Forest/Rainforest biome weights,
## a label proxy for shade, with it).
const SHADE_DEPENDENT := ["mushrooms"]

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
	for guild in [CANOPY, GROUND_COVER, DEADWOOD, SHRUBS]:
		check(guild.get_curve_domain_warnings().is_empty(), "%s: no curve-domain warnings %s" % [guild.id, guild.get_curve_domain_warnings()])
	check(ResourceManager.SHADE_SOURCE == CANOPY, "shade source is the canopy-tree guild")
	var source_clean := not CANOPY.reads_shade()
	for member in CANOPY.members:
		source_clean = source_clean and member.shade_curve == null
	check(source_clean, "no canopy member reads shade (shade can't depend on itself)")
	check(GROUND_COVER.reads_shade() and DEADWOOD.reads_shade() and SHRUBS.reads_shade() and not WETLAND.reads_shade(),
		"ground cover, deadwood and shrubs read shade; wetland plants don't")

	var shade_readers: Array[ResourceDefinition] = []
	var no_shade := {}  # id -> duplicate without its shade curve
	for guild in [GROUND_COVER, DEADWOOD, SHRUBS]:
		for member in guild.members:
			if member.shade_curve == null:
				continue
			shade_readers.append(member)
			var dup: ResourceDefinition = member.duplicate()
			dup.shade_curve = null
			var req := PackedStringArray()
			for r in member.required_curves:
				if r != "shade_curve":
					req.append(r)
			dup.required_curves = req
			no_shade[member.id] = dup
	var open_neutral := true
	for member in shade_readers:
		if not SHADE_DEPENDENT.has(member.id):
			open_neutral = open_neutral and member.shade_curve.sample(0.0) == 1.0
	check(open_neutral, "every shade curve is 1 at shade 0 except the shade-dependent %s" % [SHADE_DEPENDENT])

	# Field checks over a sample grid.
	var wg := WorldGen.new()
	wg.configure(SEED)
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var range_ok := true
	var matches_density := true
	var same := true
	var cached := true
	var neutral_ok := true
	var zero_tiles := 0
	var neutral_tested := 0
	var veg_sum := 0.0
	var veg_n := 0
	for c in REGIONS:
		for y in range(c.y - HALF, c.y + HALF, 4):
			for x in range(c.x - HALF, c.x + HALF, 4):
				var s := wg.sample(x, y)
				var st: EnvironmentalState = EnvironmentalState.from_sample(s)
				var cl := BiomeClassifier.classify_full(s)
				var shade := ResourceManager.get_shade(st, SEED, x, y, cl)
				range_ok = range_ok and shade >= 0.0 and shade <= 1.0
				var fresh: EnvironmentalState = EnvironmentalState.from_sample(s)
				matches_density = matches_density and shade == ResourceManager.get_guild_density(fresh, CANOPY, SEED, x, y, cl)
				cached = cached and st.shade_known and ResourceManager.get_shade(st, SEED, x, y, cl) == shade
				var s2 := wg2.sample(x, y)
				same = same and shade == ResourceManager.get_shade(EnvironmentalState.from_sample(s2), SEED, x, y, BiomeClassifier.classify_full(s2))
				if s["water_body"] == "none" and float(s["vegetation_potential"]) >= 0.15:
					veg_sum += shade
					veg_n += 1
				if shade == 0.0:
					zero_tiles += 1
					for member in shade_readers:
						if SHADE_DEPENDENT.has(member.id):
							continue
						var a := ResourceManager.get_suitability(st, member, cl)
						var b := ResourceManager.get_suitability(st, no_shade[member.id], cl)
						neutral_tested += int(a > 0.0)
						neutral_ok = neutral_ok and a == b
	check(range_ok, "shade in [0, 1]")
	check(matches_density, "shade == the canopy guild's density at the tile")
	check(cached, "shade computed once and kept on the state")
	check(same, "shade identical from a fresh WorldGen")
	check(neutral_ok and zero_tiles > 100 and neutral_tested > 100,
		"open ground (shade 0, %d tiles): suitability identical to the same species without a shade curve (%d nonzero cases)" % [zero_tiles, neutral_tested])

	# Placement: where each understory species ends up relative to the canopy.
	var background := veg_sum / maxf(veg_n, 1.0)
	var stats := _place_stats(wg, [GROUND_COVER, DEADWOOD, SHRUBS])
	var mean := func(id: String) -> float:
		var e: Array = stats.get(id, [0, 0.0])
		return e[1] / maxf(e[0], 1.0)
	var summary := PackedStringArray()
	for id in stats:
		summary.append("%s %d @ %.3f" % [id, stats[id][0], mean.call(id)])
	print("INFO mean shade at placed instances (vegetated land %.3f): %s" % [background, ", ".join(summary)])
	var enough := true
	for id in ["mushrooms", "wild_herbs", "meadow_grass", "wildflowers", "berry_bush"]:
		enough = enough and stats.has(id) and stats[id][0] >= 100
	check(enough, "each understory species placed >= 100 times")
	check(mean.call("mushrooms") > background * 1.3 and mean.call("wild_herbs") > background * 1.3,
		"shade lovers under more canopy: mushrooms %.3f, wild herbs %.3f vs vegetated land %.3f" % [mean.call("mushrooms"), mean.call("wild_herbs"), background])
	check(mean.call("meadow_grass") < background and mean.call("wildflowers") < background,
		"sun lovers under less canopy: meadow grass %.3f, wildflowers %.3f vs %.3f" % [mean.call("meadow_grass"), mean.call("wildflowers"), background])
	check(mean.call("wildflowers") < mean.call("berry_bush") and mean.call("berry_bush") < mean.call("wild_herbs"),
		"berries in between (tolerate partial shade): flowers %.3f < berries %.3f < herbs %.3f" % [mean.call("wildflowers"), mean.call("berry_bush"), mean.call("wild_herbs")])

	# Determinism of the correlated placement itself.
	var a := _place(wg, GROUND_COVER, REGIONS[0])
	var b := _place(wg2, GROUND_COVER, REGIONS[0])
	check(a.size() > 50 and str(a) == str(b), "ground cover placement identical from a fresh WorldGen (%d instances)" % a.size())

	_check_floodplain(wg)

	# The chunk path: shade attached from the canopy memo in chunk_manager.gd
	# must be what ResourceManager computes directly.
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.set_view_mode(world.get_script().ViewMode.RESOURCES)
	world.flush_chunk_work()
	var chunk_ok := true
	var compared := 0
	for chunk in world._env_chunks:
		var entry: Array = world._env_chunks[chunk]
		for i in entry[0].size():
			var st = entry[0][i]
			if st == null or not st.shade_known:
				continue
			var x: int = chunk.x * world.CHUNK_SIZE + i % world.CHUNK_SIZE
			var y: int = chunk.y * world.CHUNK_SIZE + i / world.CHUNK_SIZE
			var s: Dictionary = world._world_gen.sample(x, y)
			chunk_ok = chunk_ok and st.shade == ResourceManager.get_shade(EnvironmentalState.from_sample(s), SEED, x, y, BiomeClassifier.classify_full(s))
			compared += 1
	check(chunk_ok and compared > 500, "chunk path shade == direct get_shade() (%d tiles)" % compared)

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


## Floodplain chain (plan Phase 13's second example): flat river-side ground
## with sediment grows denser, different vegetation - through the shared
## river/deposition/fertility fields, no floodplain rule anywhere.
func _check_floodplain(wg: WorldGen) -> void:
	var regions := [Vector2i(18000, 8820), Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(8000, -12000)]
	var counts := {}  # guild id -> [on, off]
	var species := {}  # id -> [on, off]
	var area := [0, 0]
	for c in regions:
		for y in range(c.y - HALF, c.y + HALF):
			for x in range(c.x - HALF, c.x + HALF):
				var s := wg.sample(x, y)
				if s["water_body"] == "none":
					area[0 if _floodplain(s) else 1] += 1
		for guild in [CANOPY, WETLAND]:
			for inst in _place(wg, guild, c):
				var p: Vector2 = inst["position"]
				var k := 0 if _floodplain(wg.sample(floori(p.x), floori(p.y))) else 1
				var g: Array = counts.get(guild.id, [0, 0])
				g[k] += 1
				counts[guild.id] = g
				var e: Array = species.get(inst["id"], [0, 0])
				e[k] += 1
				species[inst["id"]] = e
	var tree_on: float = 100.0 * counts[CANOPY.id][0] / maxf(area[0], 1)
	var tree_off: float = 100.0 * counts[CANOPY.id][1] / maxf(area[1], 1)
	var share := func(id: String, guild: ResourceGuild, k: int) -> float:
		return float(species.get(id, [0, 0])[k]) / maxf(counts[guild.id][k], 1)
	print("INFO floodplain %.2f%% of land: trees %.2f vs %.2f per 100 tiles; willow %.0f%% vs %.0f%% of trees; reed %.0f%% vs %.0f%% of wetland plants" % [
		100.0 * area[0] / (area[0] + area[1]), tree_on, tree_off,
		100.0 * share.call("willow", CANOPY, 0), 100.0 * share.call("willow", CANOPY, 1),
		100.0 * share.call("reed", WETLAND, 0), 100.0 * share.call("reed", WETLAND, 1)])
	check(area[0] > 200, "floodplain tiles found (%d)" % area[0])
	check(tree_on > tree_off * 1.3, "floodplains carry denser trees (%.2f vs %.2f per 100 tiles)" % [tree_on, tree_off])
	check(share.call("willow", CANOPY, 0) > 5.0 * share.call("willow", CANOPY, 1) and share.call("reed", WETLAND, 0) > 5.0 * share.call("reed", WETLAND, 1),
		"floodplain composition differs: willow and reed shares > 5x elsewhere")


func _floodplain(s: Dictionary) -> bool:
	return s["water_body"] == "none" and s["river"] > 0.03 and s["deposition"] > 0.05 and s["slope"] < 0.004


func _place(wg: WorldGen, guild: ResourceGuild, c: Vector2i) -> Array:
	var density_fn := func(x: int, y: int) -> float:
		var s := wg.sample(x, y)
		return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), guild, SEED, x, y, BiomeClassifier.classify_full(s))
	var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
		var s := wg.sample(x, y)
		return ResourceManager.get_species_shares(ResourceManager.get_member_scores(EnvironmentalState.from_sample(s), guild, SEED, x, y, BiomeClassifier.classify_full(s)), guild.species_sharpness)
	return ResourcePlacement.place_guild_in_rect(guild, SEED, Rect2i(c - Vector2i(HALF, HALF), Vector2i(2 * HALF, 2 * HALF)), density_fn, shares_fn)


## id -> [count, shade sum] over every region, per guild placed on its own.
func _place_stats(wg: WorldGen, guilds: Array) -> Dictionary:
	var stats := {}
	for guild in guilds:
		for c in REGIONS:
			for inst in _place(wg, guild, c):
				var p: Vector2 = inst["position"]
				var x := floori(p.x)
				var y := floori(p.y)
				var s := wg.sample(x, y)
				var shade := ResourceManager.get_shade(EnvironmentalState.from_sample(s), SEED, x, y, BiomeClassifier.classify_full(s))
				var e: Array = stats.get(inst["id"], [0, 0.0])
				e[0] += 1
				e[1] += shade
				stats[inst["id"]] = e
	return stats
