extends SceneTree

## Phase 8 guild invariants: species shares, one shared placement grid per
## guild (spacing holds across species, chunk seams), deterministic species
## rolls, and - with the real guilds on a real world - no instances on water,
## every instance on a tile its species tolerates, pine on colder ground than
## oak, rock type following geology, berry bushes favoring river banks and
## clustering more strongly than trees, no footprint overlap between guilds
## (per-chunk safe), and the Phase 10 water-edge species: reeds and willows
## only on river banks, cattails only on flat, wet ground, mostly in marshes. Run via tests/run_tests.sh.

const TREES := preload("res://resources/guilds/canopy_trees.tres")
const ROCKS := preload("res://resources/guilds/surface_rocks.tres")
const SHRUBS := preload("res://resources/guilds/shrubs.tres")
const WETLAND := preload("res://resources/guilds/wetland_plants.tres")
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
	# Phase 12: limestone/shale split sedimentary ground with sandstone;
	# gravel and exposed stone follow erosion/exposure, not geology.
	var any_geology := [WorldGen.Geology.SEDIMENTARY, WorldGen.Geology.METAMORPHIC, WorldGen.Geology.IGNEOUS, WorldGen.Geology.VOLCANIC]
	var sedimentary := [WorldGen.Geology.SEDIMENTARY]
	var rock_geology := {"granite": [WorldGen.Geology.METAMORPHIC, WorldGen.Geology.IGNEOUS], "sandstone": sedimentary, "limestone": sedimentary, "shale": sedimentary,
		"basalt": [WorldGen.Geology.VOLCANIC], "gravel": any_geology, "exposed_stone": any_geology}
	var wrong_rock := 0
	var rock_ids := {}
	for inst in rocks:
		var p: Vector2 = inst["position"]
		rock_ids[inst["id"]] = rock_ids.get(inst["id"], 0) + 1
		if not wg.sample(floori(p.x), floori(p.y))["geology"] in rock_geology[inst["id"]]:
			wrong_rock += 1
	var bad := violations(ROCKS, wg, rocks)
	check(bad == [0, 0], "real rocks: %d instances, 0 on water (%d), 0 where their type scores 0 (%d)" % [rocks.size(), bad[0], bad[1]])
	var sedimentary_rocks: int = rock_ids.get("sandstone", 0) + rock_ids.get("limestone", 0) + rock_ids.get("shale", 0)
	check(wrong_rock == 0 and rock_ids.has("granite") and rock_ids.has("basalt") and sedimentary_rocks > 0, "rock type follows geology: %s, %d on the wrong rock" % [rock_ids, wrong_rock])

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

	# 5. Cross-guild footprints (Phase 8 step 5): synthetic stack at full
	# density, then the real rocks > trees > shrubs stack.
	var top := ResourceGuild.new()
	top.id = "top"
	top.members = [a]
	top.minimum_spacing = 2.0
	top.footprint_radius = 0.9
	var low := ResourceGuild.new()
	low.id = "low"
	low.members = [b]
	low.minimum_spacing = 1.5
	low.footprint_radius = 0.6
	var syn := [top, low]
	var full := [const_density(1.0), const_density(1.0)]
	var one_share := [const_shares(PackedFloat32Array([1.0])), const_shares(PackedFloat32Array([1.0]))]
	var syn_rect := Rect2i(0, 0, 96, 96)
	var stacked := ResourcePlacement.place_stack_in_rect(syn, 42, syn_rect, full, one_share)
	var unfiltered_low := ResourcePlacement.place_guild_in_rect(low, 42, syn_rect, full[1], one_share[1])
	check(key_set(stacked[0]) == key_set(ResourcePlacement.place_guild_in_rect(top, 42, syn_rect, full[0], one_share[0])),
		"stack: top guild unchanged (%d)" % stacked[0].size())
	check(cross_min_dist(stacked[0], stacked[1]) >= 1.5 and stacked[1].size() < unfiltered_low.size() and not stacked[1].is_empty(),
		"stack: lower guild kept >= 1.5 from the top (min %.3f), %d of %d kept" % [cross_min_dist(stacked[0], stacked[1]), stacked[1].size(), unfiltered_low.size()])
	var chunk_union := [[], []]
	for cy in range(0, 6):
		for cx in range(0, 6):
			var part := ResourcePlacement.place_stack_in_rect(syn, 42, Rect2i(cx * CHUNK, cy * CHUNK, CHUNK, CHUNK), full, one_share)
			for i in 2:
				chunk_union[i].append_array(part[i])
	check(key_set(chunk_union[0]) == key_set(stacked[0]) and key_set(chunk_union[1]) == key_set(stacked[1])
		and chunk_union[1].size() == stacked[1].size(),
		"stack: per-chunk union == whole-rect for every guild (%d + %d)" % [chunk_union[0].size(), chunk_union[1].size()])

	var real_stack := [ROCKS, TREES, WETLAND, SHRUBS]
	var d_fns := []
	var s_fns := []
	for g in real_stack:
		d_fns.append(func(x: int, y: int) -> float:
			var s := wg.sample(x, y)
			return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), g, seed, x, y, BiomeClassifier.classify_full(s)))
		s_fns.append(func(x: int, y: int) -> PackedFloat32Array:
			var s := wg.sample(x, y)
			return ResourceManager.get_species_shares(ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), g, BiomeClassifier.classify_full(s)), g.species_sharpness))
	var world_rect := Rect2i(area.position, Vector2i(160, 160))
	t0 = Time.get_ticks_usec()
	var real := ResourcePlacement.place_stack_in_rect(real_stack, seed, world_rect, d_fns, s_fns)
	var stack_ms := (Time.get_ticks_usec() - t0) / 1000.0 / 100.0
	var closest := INF
	for i in real_stack.size():
		for j in range(i + 1, real_stack.size()):
			closest = minf(closest, cross_min_dist(real[i], real[j]) - real_stack[i].footprint_radius - real_stack[j].footprint_radius)
	var kept_line := ""
	for i in real_stack.size():
		var raw := ResourcePlacement.place_guild_in_rect(real_stack[i], seed, world_rect, d_fns[i], s_fns[i])
		kept_line += " %s %d/%d" % [real_stack[i].id, real[i].size(), raw.size()]
	check(closest >= 0.0 and not real[2].is_empty() and not real[3].is_empty(), "real stack: no rock/tree/wetland/shrub footprints overlap (closest gap %.3f tiles)" % closest)
	print("INFO real stack kept:%s; %.2f ms/chunk for all four guilds" % [kept_line, stack_ms])

	# 6. Phase 10 water-edge inputs and species.
	var river_only := ResourceDefinition.new()
	river_only.id = "river_only"
	river_only.river_curve = Curve.new()
	river_only.river_curve.add_point(Vector2(0.0, 0.0))
	river_only.river_curve.add_point(Vector2(0.3, 1.0))
	river_only.required_curves = PackedStringArray(["river_curve"])
	var st := EnvironmentalState.new()
	st.water_body = "none"
	var dry_s := ResourceManager.get_suitability(st, river_only)
	st.river = 0.3
	var bank_s := ResourceManager.get_suitability(st, river_only)
	check(dry_s == 0.0 and is_equal_approx(bank_s, 1.0) and ResourceManager.get_suitability(st, a) == 1.0,
		"river_curve as a requirement: %.2f away from a river, %.2f on a bank; unset shore/deposition curves stay neutral" % [dry_s, bank_s])

	check(WETLAND.get_curve_domain_warnings().is_empty(), "wetland_plants + members: no curve-domain warnings %s" % WETLAND.get_curve_domain_warnings())
	var wet := place_real(WETLAND, wg, seed, area)
	bad = violations(WETLAND, wg, wet)
	var ids := {}
	var reed_off_bank := 0
	var cattail_bad := 0
	for inst in wet:
		var p: Vector2 = inst["position"]
		var s := wg.sample(floori(p.x), floori(p.y))
		ids[inst["id"]] = ids.get(inst["id"], 0) + 1
		if inst["id"] == "reed" and s["river"] <= 0.05:
			reed_off_bank += 1
		if inst["id"] == "cattail" and (s["moisture"] < 0.45 or s["slope"] > 0.006):
			cattail_bad += 1
	check(bad == [0, 0] and ids.get("reed", 0) > 30 and ids.get("cattail", 0) > 30,
		"real wetland plants: %s, 0 on open water (%d), 0 where their species scores 0 (%d)" % [ids, bad[0], bad[1]])
	check(reed_off_bank == 0 and cattail_bad == 0,
		"reeds only on river banks (%d off), cattails only on flat wet ground (%d off)" % [reed_off_bank, cattail_bad])
	var willows := 0
	var willow_off_bank := 0
	var bank_trees := 0
	var bank_willows := 0
	for inst in place_real(TREES, wg, seed, area):
		var p: Vector2 = inst["position"]
		var river: float = wg.sample(floori(p.x), floori(p.y))["river"]
		if inst["id"] == "willow":
			willows += 1
			if river <= 0.03:
				willow_off_bank += 1
		if river > 0.1:
			bank_trees += 1
			if inst["id"] == "willow":
				bank_willows += 1
	check(willows > 20 and willow_off_bank == 0 and bank_willows > bank_trees / 3,
		"willows only by rivers: %d willows, %d off the banks; %d of %d bank trees are willows" % [willows, willow_off_bank, bank_willows, bank_trees])

	# 7. Phase 17: get_suitability() caches each definition's curve list;
	# reassigning a curve or required_curves after first use must show.
	var flat_curve := func(y: float) -> Curve:
		var c := Curve.new()
		c.add_point(Vector2(0.0, y))
		c.add_point(Vector2(1.0, y))
		return c
	var tuned := ResourceDefinition.new()
	tuned.id = "tuned"
	tuned.temperature_curve = flat_curve.call(1.0)
	tuned.moisture_curve = flat_curve.call(0.25)
	var blank := EnvironmentalState.new()
	var before := ResourceManager.get_suitability(blank, tuned)  # mean(1, 0.25) = 0.5
	tuned.required_curves = PackedStringArray(["moisture_curve"])
	var required := ResourceManager.get_suitability(blank, tuned)  # 0.25 x mean(1)
	tuned.moisture_curve = flat_curve.call(1.0)
	var reassigned := ResourceManager.get_suitability(blank, tuned)
	check(is_equal_approx(before, 0.5) and is_equal_approx(required, 0.25) and is_equal_approx(reassigned, 1.0),
		"suitability follows curve / required_curves reassignment after first use (%.3f, %.3f, %.3f)" % [before, required, reassigned])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func cross_min_dist(a: Array, b: Array) -> float:
	var best := INF
	for p in a:
		for q in b:
			best = minf(best, (p["position"] as Vector2).distance_to(q["position"]))
	return best


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
