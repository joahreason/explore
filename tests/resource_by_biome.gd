extends SceneTree

## Diagnostic (not pass/fail): where a resource actually gets placed, per
## base biome, over several seeds - the check that exposed oak being densest
## in Tundra. Prints instances/100 tiles per biome, highest first, plus any
## curve-domain warnings. Defaults to the canopy-tree guild, with one column
## per species; override with RESOURCE=res://...tres (a ResourceDefinition or
## a ResourceGuild). Run via: tests/run_tests.sh --by-biome

const SEEDS := [4242, 1337, 7, 99]
const HALF_EXTENT := 300  # tiles each side of the origin, per seed
const BIOME_STRIDE := 3   # biome area is estimated on this sample grid


func _init() -> void:
	var path := OS.get_environment("RESOURCE")
	var res: Resource = load(path if path != "" else "res://resources/canopy_trees.tres")
	for warning in res.get_curve_domain_warnings():
		print("WARN ", warning)
	var guild := res as ResourceGuild
	var ids: Array = [res.id]
	if guild != null:
		ids = guild.members.map(func(m): return m.id)

	var area := {}
	var placed := {}  # biome -> {id -> count}
	var total_area := 0
	for seed in SEEDS:
		var wg := WorldGen.new()
		wg.configure(seed)
		for y in range(-HALF_EXTENT, HALF_EXTENT, BIOME_STRIDE):
			for x in range(-HALF_EXTENT, HALF_EXTENT, BIOME_STRIDE):
				var b: String = BiomeClassifier.classify(wg.sample(x, y))
				area[b] = area.get(b, 0) + BIOME_STRIDE * BIOME_STRIDE
				total_area += BIOME_STRIDE * BIOME_STRIDE
		var rect := Rect2i(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2, HALF_EXTENT * 2)
		var instances: Array
		if guild != null:
			var density_fn := func(x: int, y: int) -> float:
				var s := wg.sample(x, y)
				return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), guild, seed, x, y, BiomeClassifier.classify_full(s))
			var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
				var s := wg.sample(x, y)
				return ResourceManager.get_species_shares(ResourceManager.get_member_suitabilities(EnvironmentalState.from_sample(s), guild, BiomeClassifier.classify_full(s)), guild.species_sharpness)
			instances = ResourcePlacement.place_guild_in_rect(guild, seed, rect, density_fn, shares_fn)
		else:
			var density_fn := func(x: int, y: int) -> float:
				var s := wg.sample(x, y)
				return ResourceManager.get_density(EnvironmentalState.from_sample(s), res, seed, x, y, BiomeClassifier.classify_full(s))
			instances = ResourcePlacement.place_in_rect(res, seed, rect, density_fn)
		for inst in instances:
			var p: Vector2 = inst["position"]
			var b: String = BiomeClassifier.classify(wg.sample(floori(p.x), floori(p.y)))
			if not placed.has(b):
				placed[b] = {}
			placed[b][inst["id"]] = placed[b].get(inst["id"], 0) + 1

	var count := func(b: String) -> int:
		var n := 0
		for id in placed.get(b, {}):
			n += placed[b][id]
		return n
	var biomes := area.keys()
	biomes.sort_custom(func(a, b): return float(count.call(a)) / area[a] > float(count.call(b)) / area[b])
	print("'%s' per base biome, %d seeds x %dx%d tiles, per 100 tiles (total | %s):" % [
		res.id, SEEDS.size(), HALF_EXTENT * 2, HALF_EXTENT * 2, " ".join(ids)
	])
	for b in biomes:
		var line := "  %-12s area %5.1f%%  %5.2f |" % [b, 100.0 * area[b] / total_area, 100.0 * count.call(b) / area[b]]
		for id in ids:
			line += " %5.2f" % (100.0 * placed.get(b, {}).get(id, 0) / area[b])
		print(line + "  (n=%d)" % count.call(b))
	quit()
