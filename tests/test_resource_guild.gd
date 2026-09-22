extends SceneTree

## Phase 8 guild invariants: species shares, one shared placement grid per
## guild (spacing holds across species, chunk seams), deterministic species
## rolls, and - with the real guilds on a real world - no instances on water,
## every instance on a tile its species tolerates, pine on colder ground than
## oak, rock type following geology, berry bushes favoring river banks and
## clustering more strongly than trees. Run via tests/run_tests.sh.

const TREES := preload("res://resources/canopy_trees.tres")
const ROCKS := preload("res://resources/surface_rocks.tres")
const SHRUBS := preload("res://resources/shrubs.tres")
const CHUNK := 16

var _fails := 0
var _passes := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS ", msg)
	else:
		_fails += 1
		print("FAIL ", msg)


func const_density(v: float) -> Callable:
	return func(_x: int, _y: int) -> float: return v


func const_shares(v: PackedFloat32Array) -> Callable:
	return func(_x: int, _y: int) -> PackedFloat32Array: return v


func key_set(arr: Array) -> Dictionary:
	var d := {}
	for inst in arr:
		d["%s|%s|%s" % [inst["cell"], inst["position"], inst["id"]]] = true
	return d


func min_pair_dist(arr: Array) -> float:
	var best := INF
	for i in arr.size():
		for j in range(i + 1, arr.size()):
			best = minf(best, (arr[i]["position"] as Vector2).distance_to(arr[j]["position"]))
	return best


func _init() -> void:
	# 1. Species shares.
	var sh := ResourceManager.get_species_shares(PackedFloat32Array([0.8, 0.4, 0.0]), 4.0)
	check(is_equal_approx(sh[0] + sh[1] + sh[2], 1.0) and sh[2] == 0.0 and sh[0] > 0.9,
		"shares sum to 1, zero stays zero, sharpness favors the best (%s)" % sh)
	var flat := ResourceManager.get_species_shares(PackedFloat32Array([0.8, 0.4]), 1.0)
	check(is_equal_approx(flat[0], 2.0 / 3.0), "sharpness 1 -> proportional (%.3f)" % flat[0])
	var none := ResourceManager.get_species_shares(PackedFloat32Array([0.0, 0.0]), 4.0)
	check(none[0] == 0.0 and none[1] == 0.0, "no suitable member -> all shares zero")

	# 2. Synthetic guild placement.
	var a := ResourceDefinition.new()
	a.id = "a"
	var b := ResourceDefinition.new()
	b.id = "b"
	var guild := ResourceGuild.new()
	guild.id = "g"
	guild.members = [a, b]
	guild.minimum_spacing = 2.0
	var rect := Rect2i(-48, -48, 96, 96)
	var only_a := ResourcePlacement.place_guild_in_rect(guild, 42, rect, const_density(1.0), const_shares(PackedFloat32Array([1.0, 0.0])))
	var all_a := not only_a.is_empty()
	for inst in only_a:
		all_a = all_a and inst["id"] == "a" and inst["guild"] == "g"
	check(all_a, "shares [1,0] -> every instance is 'a', tagged with the guild (%d)" % only_a.size())
	var dead := ResourcePlacement.place_guild_in_rect(guild, 42, rect, const_density(1.0), const_shares(PackedFloat32Array([0.0, 0.0])))
	check(dead.is_empty(), "all-zero shares -> nothing placed")

	var mixed_fn := const_shares(PackedFloat32Array([0.3, 0.7]))
	var mixed := ResourcePlacement.place_guild_in_rect(guild, 42, Rect2i(0, 0, 200, 200), const_density(1.0), mixed_fn)
	var n_b := 0
	for inst in mixed:
		if inst["id"] == "b":
			n_b += 1
	var frac_b := float(n_b) / mixed.size()
	check(absf(frac_b - 0.7) < 0.03, "shares [0.3,0.7] -> %.3f of %d instances are 'b'" % [frac_b, mixed.size()])

	var again := ResourcePlacement.place_guild_in_rect(guild, 42, Rect2i(0, 0, 200, 200), const_density(1.0), mixed_fn)
	check(key_set(again) == key_set(mixed), "same inputs -> identical positions and species")
	var union := []
	for cy in range(-3, 3):
		for cx in range(-3, 3):
			union.append_array(ResourcePlacement.place_guild_in_rect(guild, 42, Rect2i(cx * CHUNK, cy * CHUNK, CHUNK, CHUNK), const_density(1.0), mixed_fn))
	var whole := ResourcePlacement.place_guild_in_rect(guild, 42, rect, const_density(1.0), mixed_fn)
	check(key_set(union) == key_set(whole) and union.size() == whole.size(), "per-chunk union == whole-rect, species included (%d)" % whole.size())
	check(min_pair_dist(union) >= guild.minimum_spacing, "one shared grid: min distance across species %.3f >= %.1f" % [min_pair_dist(union), guild.minimum_spacing])

	# 3. Real canopy-tree guild on a real world.
	check(TREES.get_curve_domain_warnings().is_empty(), "canopy_trees + members: no curve-domain warnings %s" % TREES.get_curve_domain_warnings())
	var seed := 4242
	var wg := WorldGen.new()
	wg.configure(seed)
	var density_fn := func(x: int, y: int) -> float:
		var s := wg.sample(x, y)
		return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), TREES, seed, x, y, BiomeClassifier.classify_full(s))
	var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
		var s := wg.sample(x, y)
		var suit := ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), TREES, BiomeClassifier.classify_full(s))
		return ResourceManager.get_species_shares(suit, TREES.species_sharpness)
	var t0 := Time.get_ticks_usec()
	var trees := ResourcePlacement.place_guild_in_rect(TREES, seed, Rect2i(-160, -160, 320, 320), density_fn, shares_fn)
	var per_chunk_ms := (Time.get_ticks_usec() - t0) / 1000.0 / 400.0
	var on_water := 0
	var intolerant := 0
	var temp_sum := {}
	var count := {}
	var member_index := {}
	for i in TREES.members.size():
		member_index[TREES.members[i].id] = i
	for inst in trees:
		var p: Vector2 = inst["position"]
		var s := wg.sample(floori(p.x), floori(p.y))
		if s["water_body"] in ["ocean", "sea", "lake", "river"]:
			on_water += 1
		var suit := ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), TREES, BiomeClassifier.classify_full(s))
		if suit[member_index[inst["id"]]] <= 0.0:
			intolerant += 1
		temp_sum[inst["id"]] = temp_sum.get(inst["id"], 0.0) + float(s["temperature"])
		count[inst["id"]] = count.get(inst["id"], 0) + 1
	check(on_water == 0 and intolerant == 0, "real trees: %d instances, 0 on water (%d), 0 where their species scores 0 (%d)" % [trees.size(), on_water, intolerant])
	var oak_n: int = count.get("oak", 0)
	var pine_n: int = count.get("pine", 0)
	var ok := oak_n > 50 and pine_n > 50
	var oak_t: float = temp_sum.get("oak", 0.0) / maxi(oak_n, 1)
	var pine_t: float = temp_sum.get("pine", 0.0) / maxi(pine_n, 1)
	check(ok and pine_t < oak_t - 0.1, "pine on colder ground than oak: pine %d @ %.2f, oak %d @ %.2f mean temperature" % [pine_n, pine_t, oak_n, oak_t])
	print("INFO real canopy-tree placement cost: %.2f ms/chunk" % per_chunk_ms)

	# 4. Rocks and berry bushes (Phase 8 step 4) on the same real world, in a
	# region with sedimentary, metamorphic and volcanic ground (all three rock
	# types), shrub habitat and rivers - the origin has no sedimentary rock.
	var area := Rect2i(17840, 8840, 320, 320)
	for g in [ROCKS, SHRUBS]:
		check(g.get_curve_domain_warnings().is_empty(), "%s + members: no curve-domain warnings %s" % [g.id, g.get_curve_domain_warnings()])
	var rocks := place_real(ROCKS, wg, seed, area)
	var rock_geology := {"granite": [WorldGen.Geology.METAMORPHIC, WorldGen.Geology.IGNEOUS], "sandstone": [WorldGen.Geology.SEDIMENTARY], "basalt": [WorldGen.Geology.VOLCANIC]}
	var wrong_rock := 0
	var rock_ids := {}
	for inst in rocks:
		var p: Vector2 = inst["position"]
		rock_ids[inst["id"]] = rock_ids.get(inst["id"], 0) + 1
		if not wg.sample(floori(p.x), floori(p.y))["geology"] in rock_geology[inst["id"]]:
			wrong_rock += 1
	var bad := violations(ROCKS, wg, rocks)
	check(bad == [0, 0], "real rocks: %d instances, 0 on water (%d), 0 where their type scores 0 (%d)" % [rocks.size(), bad[0], bad[1]])
	check(wrong_rock == 0 and rock_ids.size() == 3, "rock type follows geology: %s, %d on the wrong rock" % [rock_ids, wrong_rock])

	var berries := place_real(SHRUBS, wg, seed, area)
	bad = violations(SHRUBS, wg, berries)
	check(bad == [0, 0] and berries.size() > 50, "real berry bushes: %d instances, 0 on water (%d), 0 where they score 0 (%d)" % [berries.size(), bad[0], bad[1]])

	# River proximity: berries per tile on river-bank land vs. other land
	# where shrubs grow at all.
	var bank_tiles := 0
	var other_tiles := 0
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var s := wg.sample(x, y)
			if s["water_body"] != "none" or s["vegetation"] < 0.15:
				continue
			if s["river"] > 0.1:
				bank_tiles += 1
			else:
				other_tiles += 1
	var on_bank := 0
	for inst in berries:
		var p: Vector2 = inst["position"]
		var s := wg.sample(floori(p.x), floori(p.y))
		if s["river"] > 0.1:
			on_bank += 1
	var bank_rate := float(on_bank) / maxi(bank_tiles, 1)
	var other_rate := float(berries.size() - on_bank) / maxi(other_tiles, 1)
	check(bank_tiles > 200 and bank_rate > other_rate * 1.3, "berries favor river banks: %.2f vs %.2f per 100 tiles (%d bank tiles)" % [100 * bank_rate, 100 * other_rate, bank_tiles])

	# Clustering: place each guild on its own patch noise alone (uniform
	# environment), then compare how clumped the counts are in 16x16 blocks
	# (variance / mean; higher = patchier).
	var trees_d := dispersion(TREES, seed)
	var berries_d := dispersion(SHRUBS, seed)
	check(berries_d > trees_d * 1.5, "berries cluster more strongly than trees: dispersion %.2f vs %.2f" % [berries_d, trees_d])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func place_real(guild: ResourceGuild, wg: WorldGen, seed: int, rect: Rect2i) -> Array[Dictionary]:
	var density_fn := func(x: int, y: int) -> float:
		var s := wg.sample(x, y)
		return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), guild, seed, x, y, BiomeClassifier.classify_full(s))
	var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
		var s := wg.sample(x, y)
		var suit := ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), guild, BiomeClassifier.classify_full(s))
		return ResourceManager.get_species_shares(suit, guild.species_sharpness)
	return ResourcePlacement.place_guild_in_rect(guild, seed, rect, density_fn, shares_fn)


## [instances on water, instances whose own species scores 0 at their tile]
func violations(guild: ResourceGuild, wg: WorldGen, instances: Array) -> Array:
	var member_index := {}
	for i in guild.members.size():
		member_index[guild.members[i].id] = i
	var on_water := 0
	var intolerant := 0
	for inst in instances:
		var p: Vector2 = inst["position"]
		var s := wg.sample(floori(p.x), floori(p.y))
		if s["water_body"] in ["ocean", "sea", "lake", "river"]:
			on_water += 1
		var suit := ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), guild, BiomeClassifier.classify_full(s))
		if suit[member_index[inst["id"]]] <= 0.0:
			intolerant += 1
	return [on_water, intolerant]


## Variance/mean of instance counts per 16x16 block when a guild is placed on
## its patch noise alone (density = patch value), 512x512 tiles.
func dispersion(guild: ResourceGuild, seed: int) -> float:
	var proxy := ResourceDefinition.new()
	proxy.id = "proxy"
	var density_fn := func(x: int, y: int) -> float:
		return ResourceManager.get_guild_patch_modifier(guild, seed, x, y)
	var shares_fn := const_shares(PackedFloat32Array([1.0]))
	var one := ResourceGuild.new()
	one.id = guild.id
	one.members = [proxy]
	one.minimum_spacing = guild.minimum_spacing
	var counts := {}
	for inst in ResourcePlacement.place_guild_in_rect(one, seed, Rect2i(0, 0, 512, 512), density_fn, shares_fn):
		var p: Vector2 = inst["position"]
		var k := Vector2i(floori(p.x / 16.0), floori(p.y / 16.0))
		counts[k] = counts.get(k, 0) + 1
	var n := 32 * 32
	var mean := 0.0
	for k in counts:
		mean += counts[k]
	mean /= n
	var variance := 0.0
	for by in 32:
		for bx in 32:
			variance += pow(counts.get(Vector2i(bx, by), 0) - mean, 2)
	variance /= n
	return variance / maxf(mean, 0.001)
