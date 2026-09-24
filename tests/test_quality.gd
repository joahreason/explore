extends SceneTree

## Phase 14 (resource quality): every placed instance of a resource with a
## QualityProfile gets a 0..1 quality and a tier (tree age, berry yield, ore
## richness) from its tile's fields plus a small per-instance jitter - a
## layer AFTER placement that never changes which instances exist (the
## placement snapshot guards that). Checks: profile data, the math, value
## range, determinism and order independence, the chunk path == the direct
## call, every tier occurs, and quality follows its drivers (old growth in
## dense, fertile, undisturbed stands; abundant berries on fertile, moist,
## sunny ground; rich ore on deposit-rich seams). Run via tests/run_tests.sh.

const CANOPY := preload("res://resources/canopy_trees.tres")
const SHRUBS := preload("res://resources/shrubs.tres")
const ORE_OUTCROPS := preload("res://resources/ore_outcrops.tres")
const TREE_AGE := preload("res://resources/quality/tree_age.tres")
const BERRY_YIELD := preload("res://resources/quality/berry_yield.tres")
const ORE_RICHNESS := preload("res://resources/quality/ore_richness.tres")
const SEED := 4242
const REGIONS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000), Vector2i(8000, -12000)]
const HALF := 96
## Members without a quality on purpose: young_tree is itself the sapling
## stage of recovering scars (Phase 11), so it has no age tiers.
const NO_QUALITY := ["young_tree"]

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
	# Data.
	for profile in [TREE_AGE, BERRY_YIELD, ORE_RICHNESS]:
		check(profile.get_curve_domain_warnings().is_empty(), "%s: no warnings %s" % [profile.id, profile.get_curve_domain_warnings()])
	var wired := true
	for guild in [CANOPY, SHRUBS, ORE_OUTCROPS]:
		check(guild.get_curve_domain_warnings().is_empty(), "%s: no warnings (profiles included)" % guild.id)
		for member in guild.members:
			var expected: Resource = null if NO_QUALITY.has(member.id) else {CANOPY: TREE_AGE, SHRUBS: BERRY_YIELD, ORE_OUTCROPS: ORE_RICHNESS}[guild]
			wired = wired and member.quality_profile == expected
	check(wired, "every tree (but young_tree), berry bush and ore outcrop member has its profile")
	check(TREE_AGE.tier_for(0.0) == "young" and TREE_AGE.tier_for(TREE_AGE.tier_thresholds[0]) == "mature"
		and TREE_AGE.tier_for(TREE_AGE.tier_thresholds[1]) == "old growth" and TREE_AGE.tier_for(1.0) == "old growth",
		"tier_for: thresholds start the next tier")

	# The math on one state: jitter bounds, roll 0.5 = no jitter, no profile = -1.
	var wg := WorldGen.new()
	wg.configure(SEED)
	var math_ok := true
	var tested := 0
	var oak: ResourceDefinition = CANOPY.members[0]
	var young: ResourceDefinition = CANOPY.members.filter(func(m): return m.id == "young_tree")[0]
	for y in range(-200, 200, 8):
		for x in range(-200, 200, 8):
			var s := wg.sample(x, y)
			var st: EnvironmentalState = EnvironmentalState.from_sample(s)
			var cl := BiomeClassifier.classify_full(s)
			ResourceManager.get_shade(st, SEED, x, y, cl)
			var base := ResourceManager.get_quality(st, oak, SEED, x, y, 0.5, cl)
			var lo := ResourceManager.get_quality(st, oak, SEED, x, y, 0.0, cl)
			var hi := ResourceManager.get_quality(st, oak, SEED, x, y, 0.999, cl)
			math_ok = math_ok and is_equal_approx(base, ResourceManager.get_suitability(st, TREE_AGE, cl))
			math_ok = math_ok and lo <= base and hi >= base and base - lo <= TREE_AGE.jitter + 1e-6 and hi - base <= TREE_AGE.jitter + 1e-6
			math_ok = math_ok and ResourceManager.get_quality(st, young, SEED, x, y, 0.5, cl) == -1.0
			tested += 1
	check(math_ok and tested > 1000, "quality = drivers' suitability + jitter within +-jitter; no profile -> -1 (%d tiles)" % tested)

	# Placed instances, through the real world scene (the Resources stack).
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var samples := {"tree_age": [], "berry_yield": [], "ore_richness": []}  # profile id -> [[quality, drivers Dictionary]]
	var range_ok := true
	var direct_ok := true
	var unprofiled_ok := true
	var counted := 0
	for c in REGIONS:
		var rect := Rect2i(c - Vector2i(HALF, HALF), Vector2i(2 * HALF, 2 * HALF))
		var stack: Dictionary = world._place_stack(rect, 7)
		for guild in [CANOPY, SHRUBS, ORE_OUTCROPS]:
			for inst in stack[guild]:
				var q: float = world._instance_quality(inst)
				var definition: ResourceDefinition = world._definitions_by_id()[inst["id"]]
				if definition.quality_profile == null:
					unprofiled_ok = unprofiled_ok and q == -1.0
					continue
				counted += 1
				range_ok = range_ok and q >= 0.0 and q <= 1.0
				# Direct, from a fresh WorldGen and state: same value.
				var p: Vector2 = inst["position"]
				var x := floori(p.x)
				var y := floori(p.y)
				var s := wg2.sample(x, y)
				var st: EnvironmentalState = EnvironmentalState.from_sample(s)
				var cl := BiomeClassifier.classify_full(s)
				var direct := ResourceManager.get_quality(st, definition, SEED, x, y, ResourcePlacement.instance_roll(inst, SEED), cl)
				direct_ok = direct_ok and direct == q
				ResourceManager.get_shade(st, SEED, x, y, cl)
				samples[definition.quality_profile.id].append([q, {
					"succession": st.succession, "fertility": st.soil_fertility, "moisture": st.moisture, "shade": st.shade,
					"deposit": ResourceManager.get_deposit_potential(st, definition, SEED, x, y, cl),
					"vein": ResourceManager.get_vein_value(definition, SEED, x, y),
				}])
	check(range_ok and counted > 500, "quality in [0, 1] for every profiled instance (%d)" % counted)
	check(unprofiled_ok, "instances without a profile report -1 (no quality)")
	check(direct_ok, "chunk path (cached tile state) == direct get_quality() from a fresh WorldGen")

	# Order independence: the same instances, placed via a different rect
	# and evaluated after clearing every cache, keep their quality.
	var rect0 := Rect2i(REGIONS[0] - Vector2i(24, 24), Vector2i(48, 48))
	var before := {}
	for inst in world._place_stack(rect0, 3)[CANOPY]:
		before[inst["cell"]] = world._instance_quality(inst)
	world.clear_generation_caches()
	var order_ok := before.size() > 20
	var shifted: Array = world._place_stack(rect0.grow(16), 3)[CANOPY]
	shifted.reverse()
	var seen := 0
	for inst in shifted:
		if before.has(inst["cell"]):
			seen += 1
			order_ok = order_ok and world._instance_quality(inst) == before[inst["cell"]]
	check(order_ok and seen == before.size(), "quality independent of placement rect, cache state and evaluation order (%d trees)" % seen)

	# Tiers and drivers.
	for profile in [TREE_AGE, BERRY_YIELD, ORE_RICHNESS]:
		var rows: Array = samples[profile.id]
		var counts := {}
		for row in rows:
			var tier: String = profile.tier_for(row[0])
			counts[tier] = counts.get(tier, 0) + 1
		var shares := PackedStringArray()
		var every_tier := rows.size() >= 40
		for tier in profile.tier_names:
			var share := float(counts.get(tier, 0)) / maxf(rows.size(), 1.0)
			shares.append("%s %.0f%%" % [tier, share * 100.0])
			every_tier = every_tier and share >= 0.05
		print("INFO %s: %d instances, %s, mean %.3f; r(quality, field): %s" % [profile.id, rows.size(), ", ".join(shares), _mean(rows), _correlations(rows)])
		check(every_tier, "%s: every tier holds >= 5%% of %d instances (%s)" % [profile.id, rows.size(), ", ".join(shares)])

	var trees: Array = samples["tree_age"]
	check(_r(trees, "shade") > 0.3 and _r(trees, "fertility") > 0.2, "tree age rises with canopy density and fertility (r %.2f, %.2f)" % [_r(trees, "shade"), _r(trees, "fertility")])
	var scarred := trees.filter(func(row): return row[1]["succession"] < 0.8)
	var intact := trees.filter(func(row): return row[1]["succession"] >= 0.999)
	check(scarred.size() >= 20 and _mean(scarred) < _mean(intact) - 0.1,
		"trees on recovering scars are younger: mean %.3f (%d) vs %.3f undisturbed" % [_mean(scarred), scarred.size(), _mean(intact)])
	var berries: Array = samples["berry_yield"]
	check(_r(berries, "fertility") > 0.2 and _r(berries, "moisture") > 0.2 and _r(berries, "shade") < -0.1,
		"berry yield rises with fertility and moisture, falls with shade (r %.2f, %.2f, %.2f)" % [_r(berries, "fertility"), _r(berries, "moisture"), _r(berries, "shade")])
	var ores: Array = samples["ore_richness"]
	check(_r(ores, "deposit") > 0.8 and _r(ores, "vein") > 0.3, "ore richness follows the deposit potential and its seams (r %.2f, %.2f)" % [_r(ores, "deposit"), _r(ores, "vein")])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _mean(rows: Array) -> float:
	var total := 0.0
	for row in rows:
		total += row[0]
	return total / maxf(rows.size(), 1.0)


## Pearson correlation of quality with one driver field.
func _r(rows: Array, field: String) -> float:
	var n := float(rows.size())
	if n < 2.0:
		return 0.0
	var mq := 0.0
	var mf := 0.0
	for row in rows:
		mq += row[0]
		mf += row[1][field]
	mq /= n
	mf /= n
	var cov := 0.0
	var vq := 0.0
	var vf := 0.0
	for row in rows:
		var dq: float = row[0] - mq
		var df: float = row[1][field] - mf
		cov += dq * df
		vq += dq * dq
		vf += df * df
	return cov / sqrt(vq * vf) if vq > 0.0 and vf > 0.0 else 0.0


func _correlations(rows: Array) -> String:
	var parts := PackedStringArray()
	for field in ["succession", "fertility", "moisture", "shade", "deposit", "vein"]:
		parts.append("%s %.2f" % [field, _r(rows, field)])
	return ", ".join(parts)
