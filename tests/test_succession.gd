extends SceneTree

## Phase 11 (disturbance and succession): WorldGen's `succession` is 1 exactly
## where no scar reaches (so per-blob type/age never leak into undisturbed
## land) and deterministic; `vegetation_potential` is `vegetation` before the
## scar penalty; disturbance_type_weights are neutral outside scars; placed
## species follow bare -> pioneer grass/herbs -> shrubs -> young trees ->
## mature trees, with deadwood on young scars. Run via tests/run_tests.sh.

const CANOPY := preload("res://resources/canopy_trees.tres")
const SHRUBS := preload("res://resources/shrubs.tres")
const DEADWOOD := preload("res://resources/deadwood.tres")
const PIONEERS := preload("res://resources/pioneer_plants.tres")
const DEAD_TREE := preload("res://resources/dead_tree.tres")
const SEED := 4242
const REGIONS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000)]

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
	for guild in [CANOPY, SHRUBS, DEADWOOD, PIONEERS]:
		check(guild.get_curve_domain_warnings().is_empty(), "%s: no curve-domain warnings %s" % [guild.id, guild.get_curve_domain_warnings()])

	var wg := WorldGen.new()
	wg.configure(SEED)
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var untyped := DEAD_TREE.duplicate()
	untyped.disturbance_type_weights = {}
	var range_ok := true
	var outside_ok := true
	var potential_ok := true
	var same := true
	var gate_ok := true
	var scarred := 0
	var land := 0
	for c in REGIONS:
		for y in range(c.y - 200, c.y + 200, 3):
			for x in range(c.x - 200, c.x + 200, 3):
				var s := wg.sample(x, y)
				var succ: float = s["succession"]
				range_ok = range_ok and succ >= 0.0 and succ <= 1.0
				if s["disturbance"] == 0.0:
					outside_ok = outside_ok and succ == 1.0
				potential_ok = potential_ok and s["vegetation_potential"] >= s["vegetation"] \
					and (s["disturbance"] > 0.0 or s["vegetation_potential"] == s["vegetation"])
				var s2 := wg2.sample(x, y)
				same = same and succ == s2["succession"] and s["vegetation_potential"] == s2["vegetation_potential"]
				if succ == 1.0:
					var state: EnvironmentalState = EnvironmentalState.from_sample(s)
					gate_ok = gate_ok and ResourceManager.get_suitability(state, DEAD_TREE) == ResourceManager.get_suitability(state, untyped)
				if s["water_body"] == "none":
					land += 1
					if succ < 0.9:
						scarred += 1
	check(range_ok, "succession in [0, 1]")
	check(outside_ok, "succession is exactly 1 wherever disturbance is 0 (no type/age leak)")
	check(potential_ok, "vegetation_potential >= vegetation, equal outside scars")
	check(same, "succession / vegetation_potential identical from a fresh WorldGen")
	check(gate_ok, "disturbance_type_weights neutral where succession is 1")
	var share := float(scarred) / land
	check(share > 0.05 and share < 0.5, "recovering land (succession < 0.9): %.1f%%" % (100.0 * share))

	# Placement per guild (no cross-guild collisions): where each species ends up.
	var stats := {}  # id -> [count, succession sum, count on undisturbed land]
	for guild in [CANOPY, SHRUBS, DEADWOOD, PIONEERS]:
		var density_fn := func(x: int, y: int) -> float:
			var s := wg.sample(x, y)
			return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), guild, SEED, x, y, BiomeClassifier.classify_full(s))
		var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
			var s := wg.sample(x, y)
			var scores := ResourceManager.get_member_scores(EnvironmentalState.from_sample(s), guild, SEED, x, y, BiomeClassifier.classify_full(s))
			return ResourceManager.get_species_shares(scores, guild.species_sharpness)
		for c in REGIONS:
			for inst in ResourcePlacement.place_guild_in_rect(guild, SEED, Rect2i(c - Vector2i(200, 200), Vector2i(400, 400)), density_fn, shares_fn):
				var p: Vector2 = inst["position"]
				var succ: float = wg.sample(floori(p.x), floori(p.y))["succession"]
				var st: Array = stats.get(inst["id"], [0, 0.0, 0])
				st[0] += 1
				st[1] += succ
				if succ == 1.0:
					st[2] += 1
				stats[inst["id"]] = st
	var mean := func(id: String) -> float:
		var st: Array = stats.get(id, [0, 0.0, 0])
		return st[1] / maxf(st[0], 1.0)
	var summary := PackedStringArray()
	for id in stats:
		summary.append("%s %d @ %.2f" % [id, stats[id][0], mean.call(id)])
	print("INFO species: count @ mean succession: ", ", ".join(summary))
	var scar_only := true
	for id in ["dead_tree", "fallen_log", "pioneer_grass", "fireweed", "young_tree"]:
		scar_only = scar_only and stats.has(id) and stats[id][0] >= 10 and stats[id][2] == 0
	check(scar_only, "dead trees, logs, pioneers and young trees: >= 10 each, none on undisturbed land (mushrooms also grow on the forest floor since Phase 12)")
	var pioneer: float = (mean.call("pioneer_grass") + mean.call("fireweed")) * 0.5
	check(mean.call("dead_tree") < pioneer and pioneer < mean.call("berry_bush") and pioneer < mean.call("young_tree")
		and mean.call("young_tree") < mean.call("oak") and mean.call("young_tree") < mean.call("pine"),
		"stage order: dead trees %.2f < pioneers %.2f < young trees %.2f < oak %.2f / pine %.2f (berries %.2f)" % [
			mean.call("dead_tree"), pioneer, mean.call("young_tree"), mean.call("oak"), mean.call("pine"), mean.call("berry_bush")])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
