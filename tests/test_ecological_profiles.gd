extends SceneTree

## Phase 12 (ecological resource profiles): every category the plan lists
## exists as a data-driven definition, and the new ones land where their
## environment says - ground cover on established ground (grass in open
## country, herbs in woodland), birch only where it is cool, mushrooms on the
## forest floor too, limestone/shale/sandstone only on sedimentary rock,
## exposed stone only on bare bedrock, gravel only on eroded ground or river
## banks, and none of it on open water. Also: cacti only in (warm) Desert,
## and cool dry land is Barrens. Run via tests/run_tests.sh.

const GROUND_COVER := preload("res://resources/ground_cover.tres")
const CANOPY := preload("res://resources/canopy_trees.tres")
const DEADWOOD := preload("res://resources/deadwood.tres")
const ROCKS := preload("res://resources/surface_rocks.tres")
const DESERT_PLANTS := preload("res://resources/desert_plants.tres")
## Plan Phase 12's list -> the ids that cover it ("shrubs" = berry_bush,
## "grass" = meadow_grass/pioneer_grass, "fallen trees" = fallen_log).
const PLAN_IDS := [
	"oak", "pine", "birch", "berry_bush", "meadow_grass", "wildflowers", "wild_herbs", "mushrooms", "reed", "cattail",
	"granite", "limestone", "shale", "basalt", "clay", "coal", "iron", "copper",
	"dead_tree", "fallen_log", "gravel", "mud", "exposed_stone",
]
const OPEN := ["Grassland", "Plains", "Savanna"]
const WOODED := ["Forest", "Rainforest"]
## Seed/center pairs that between them hold every geology (geology cells
## are larger than a region; the last two are sedimentary).
const REGIONS := [[4242, Vector2i(0, 0)], [4242, Vector2i(12000, -7000)], [1337, Vector2i(-9000, 15000)], [7, Vector2i(20000, 20000)], [4242, Vector2i(8000, -12000)], [4242, Vector2i(-16000, -8000)]]

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
	var missing := []
	for id in PLAN_IDS:
		if not ResourceLoader.exists("res://resources/%s.tres" % id) or load("res://resources/%s.tres" % id).id != id:
			missing.append(id)
	check(missing.is_empty(), "every plan Phase 12 category has a definition (missing: %s)" % [missing])
	for guild in [GROUND_COVER, CANOPY, DEADWOOD, ROCKS]:
		check(guild.get_curve_domain_warnings().is_empty(), "%s: no curve-domain warnings %s" % [guild.id, guild.get_curve_domain_warnings()])

	var counts := {}  # id -> {biome -> n}
	var bad := {}     # rule -> offending count
	for rule in ["water", "ground_cover_on_scar", "birch_warm", "sedimentary", "exposed_stone", "gravel"]:
		bad[rule] = 0
	var forest_floor_mushrooms := 0
	for region in REGIONS:
		var seed: int = region[0]
		var c: Vector2i = region[1]
		var wg := WorldGen.new()
		wg.configure(seed)
		for guild in [GROUND_COVER, CANOPY, DEADWOOD, ROCKS]:
			var density_fn := func(x: int, y: int) -> float:
				var s := wg.sample(x, y)
				return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), guild, seed, x, y, BiomeClassifier.classify_full(s))
			var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
				var s := wg.sample(x, y)
				var scores := ResourceManager.get_member_scores(EnvironmentalState.from_sample(s), guild, seed, x, y, BiomeClassifier.classify_full(s))
				return ResourceManager.get_species_shares(scores, guild.species_sharpness)
			for inst in ResourcePlacement.place_guild_in_rect(guild, seed, Rect2i(c - Vector2i(150, 150), Vector2i(300, 300)), density_fn, shares_fn):
				var p: Vector2 = inst["position"]
				var s := wg.sample(floori(p.x), floori(p.y))
				var id: String = inst["id"]
				var biome: String = BiomeClassifier.classify(s)
				var per: Dictionary = counts.get(id, {})
				per[biome] = per.get(biome, 0) + 1
				counts[id] = per
				if s["water_body"] in ["ocean", "sea", "lake", "river"]:
					bad["water"] += 1
				if guild == GROUND_COVER and s["succession"] < 0.45:
					bad["ground_cover_on_scar"] += 1
				if id == "birch" and s["temperature"] > 0.1:
					bad["birch_warm"] += 1
				if id in ["limestone", "shale", "sandstone"] and s["geology"] != WorldGen.Geology.SEDIMENTARY:
					bad["sedimentary"] += 1
				if id == "exposed_stone" and s["rock_exposure"] < 0.5:
					bad["exposed_stone"] += 1
				# Gravel keeps a 0.1 floor off eroded ground (so a river bank
				# can add to it), so a few land elsewhere.
				if id == "gravel" and s["erosion"] < 0.15 and s["river"] <= 0.0:
					bad["gravel"] += 1
				if id == "mushrooms" and s["succession"] == 1.0 and biome in WOODED:
					forest_floor_mushrooms += 1

	var total := func(id: String, biomes: Array = []) -> int:
		var n := 0
		var per: Dictionary = counts.get(id, {})
		for b in per:
			if biomes.is_empty() or b in biomes:
				n += per[b]
		return n
	var summary := PackedStringArray()
	for id in counts:
		summary.append("%s %d" % [id, total.call(id)])
	print("INFO placed: ", ", ".join(summary))
	check(bad["water"] == 0, "nothing on open water (%d)" % bad["water"])
	var present := true
	for id in ["meadow_grass", "wild_herbs", "wildflowers", "birch", "limestone", "shale", "gravel", "exposed_stone"]:
		present = present and total.call(id) >= 10
	check(present, "each new Phase 12 species placed >= 10 times")
	check(bad["ground_cover_on_scar"] == 0, "ground cover only on established ground, succession >= 0.45 (%d off)" % bad["ground_cover_on_scar"])
	# Share of each species that falls in open vs wooded biomes.
	var grass_open: float = float(total.call("meadow_grass", OPEN)) / maxf(total.call("meadow_grass", OPEN + WOODED), 1)
	var herbs_wood: float = float(total.call("wild_herbs", WOODED)) / maxf(total.call("wild_herbs", OPEN + WOODED), 1)
	check(grass_open > 0.8 and herbs_wood > 0.6, "meadow grass mostly in open country (%.0f%%), herbs mostly in woodland (%.0f%%)" % [100 * grass_open, 100 * herbs_wood])
	check(bad["birch_warm"] == 0, "birch only where temperature <= 0.1 (%d off)" % bad["birch_warm"])
	check(forest_floor_mushrooms >= 10, "mushrooms on the undisturbed forest floor: %d" % forest_floor_mushrooms)
	check(bad["sedimentary"] == 0, "limestone, shale and sandstone only on sedimentary rock (%d off)" % bad["sedimentary"])
	check(bad["exposed_stone"] == 0, "exposed stone only where rock_exposure >= 0.5 (%d off)" % bad["exposed_stone"])
	var gravel_off: float = float(bad["gravel"]) / maxf(total.call("gravel"), 1)
	check(gravel_off < 0.15, "gravel mostly on eroded ground (erosion >= 0.15) or river banks: %.0f%% elsewhere" % (100 * gravel_off))

	# Cacti: hot deserts only, sagebrush: Barrens only - both strict_biomes,
	# so none past their biome's edge (seed 1337's hot, dry country around
	# (1900, -2980) and cold, dry country around (1250, -2250)).
	var cwg := WorldGen.new()
	cwg.configure(1337)
	var desert_density := func(x: int, y: int) -> float:
		var s := cwg.sample(x, y)
		return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), DESERT_PLANTS, 1337, x, y, BiomeClassifier.classify_full(s))
	var desert_shares := func(x: int, y: int) -> PackedFloat32Array:
		var s := cwg.sample(x, y)
		return ResourceManager.get_species_shares(ResourceManager.get_member_scores(EnvironmentalState.from_sample(s), DESERT_PLANTS, 1337, x, y, BiomeClassifier.classify_full(s)), DESERT_PLANTS.species_sharpness)
	var placed := {"cactus": 0, "sagebrush": 0}
	var off := {"cactus": 0, "sagebrush": 0}
	for rect in [Rect2i(Vector2i(1750, -3130), Vector2i(300, 300)), Rect2i(Vector2i(1100, -2400), Vector2i(300, 300))]:
		for inst in ResourcePlacement.place_guild_in_rect(DESERT_PLANTS, 1337, rect, desert_density, desert_shares):
			var p: Vector2 = inst["position"]
			var s := cwg.sample(floori(p.x), floori(p.y))
			var id: String = inst["id"]
			var biome := BiomeClassifier.classify(s)
			placed[id] += 1
			if (id == "cactus" and (biome != "Desert" or s["temperature"] < 0.05)) or (id == "sagebrush" and biome != "Barrens"):
				off[id] += 1
	check(DESERT_PLANTS.get_curve_domain_warnings().is_empty() and placed["cactus"] >= 50 and off["cactus"] == 0,
		"cacti only in hot deserts: %d placed, %d elsewhere" % [placed["cactus"], off["cactus"]])
	check(placed["sagebrush"] >= 50 and off["sagebrush"] == 0,
		"sagebrush only in Barrens: %d placed, %d elsewhere" % [placed["sagebrush"], off["sagebrush"]])

	# Dry, bare land splits by warmth: Desert is warm (cactus country),
	# Barrens takes the frozen/cool rest (wide lattice, 2 seeds).
	var desert_temps := []
	var cold_temps := []
	for seed in [4242, 1337]:
		var dwg := WorldGen.new()
		dwg.configure(seed)
		for iy in range(-30, 30):
			for ix in range(-30, 30):
				var s := dwg.sample(ix * 750, iy * 750)
				match BiomeClassifier.classify(s):
					"Desert":
						desert_temps.append(s["temperature"])
					"Barrens":
						cold_temps.append(s["temperature"])
	desert_temps.sort()
	cold_temps.sort()
	check(desert_temps.size() >= 50 and cold_temps.size() >= 20 and desert_temps[0] >= -0.2 and cold_temps[-1] <= 0.05
		and desert_temps[desert_temps.size() / 10] >= 0.05,
		"Desert warm (min %.2f, p10 %.2f, %d tiles), Barrens cool (max %.2f, %d tiles)" % [desert_temps[0], desert_temps[desert_temps.size() / 10], desert_temps.size(), cold_temps[-1], cold_temps.size()])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
