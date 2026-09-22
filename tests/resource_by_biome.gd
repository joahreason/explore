extends SceneTree

## Diagnostic (not pass/fail): where a resource actually gets placed, per
## base biome, over several seeds - the check that exposed oak being densest
## in Tundra. Prints oaks/100 tiles per biome, highest first, plus any
## curve-domain warnings. Override the resource with RESOURCE=res://...tres.
## Run via: tests/run_tests.sh --by-biome

const SEEDS := [4242, 1337, 7, 99]
const HALF_EXTENT := 300  # tiles each side of the origin, per seed
const BIOME_STRIDE := 3   # biome area is estimated on this sample grid


func _init() -> void:
	var path := OS.get_environment("RESOURCE")
	var definition: ResourceDefinition = load(path if path != "" else "res://resources/oak.tres")
	for warning in definition.get_curve_domain_warnings():
		print("WARN ", warning)

	var area := {}
	var placed := {}
	var total_area := 0
	for seed in SEEDS:
		var wg := WorldGen.new()
		wg.configure(seed)
		for y in range(-HALF_EXTENT, HALF_EXTENT, BIOME_STRIDE):
			for x in range(-HALF_EXTENT, HALF_EXTENT, BIOME_STRIDE):
				var b: String = BiomeClassifier.classify(wg.sample(x, y))
				area[b] = area.get(b, 0) + BIOME_STRIDE * BIOME_STRIDE
				total_area += BIOME_STRIDE * BIOME_STRIDE
		var density_fn := func(x: int, y: int) -> float:
			var s := wg.sample(x, y)
			return ResourceManager.get_density(EnvironmentalState.from_sample(s), definition, seed, x, y, BiomeClassifier.classify_full(s))
		var rect := Rect2i(-HALF_EXTENT, -HALF_EXTENT, HALF_EXTENT * 2, HALF_EXTENT * 2)
		for inst in ResourcePlacement.place_in_rect(definition, seed, rect, density_fn):
			var p: Vector2 = inst["position"]
			var b: String = BiomeClassifier.classify(wg.sample(floori(p.x), floori(p.y)))
			placed[b] = placed.get(b, 0) + 1

	var biomes := area.keys()
	biomes.sort_custom(func(a, b): return float(placed.get(a, 0)) / area[a] > float(placed.get(b, 0)) / area[b])
	print("'%s' per base biome, %d seeds x %dx%d tiles:" % [definition.id, SEEDS.size(), HALF_EXTENT * 2, HALF_EXTENT * 2])
	for b in biomes:
		print("  %-12s area %5.1f%%  per 100 tiles %5.2f  (n=%d)" % [
			b, 100.0 * area[b] / total_area, 100.0 * placed.get(b, 0) / area[b], placed.get(b, 0)
		])
	quit()
