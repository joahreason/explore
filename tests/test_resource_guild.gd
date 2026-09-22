extends SceneTree

## Phase 8 guild invariants: species shares, one shared placement grid per
## guild (spacing holds across species, chunk seams), deterministic species
## rolls, and - with the real canopy-tree guild on a real world - no trees on
## water, every tree on a tile its species tolerates, and pine on colder
## ground than oak. Run via tests/run_tests.sh.

const TREES := preload("res://resources/canopy_trees.tres")
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

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
