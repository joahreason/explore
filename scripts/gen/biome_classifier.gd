class_name BiomeClassifier
extends RefCounted

## Discrete biome labeling derived from WorldGen's continuous fields, purely
## for the debug overlay (naming/outlining regions for a human to read).
## The actual generation/rendering never uses this - it stays continuous.
##
## Water/Beach are unambiguous categorical facts already decided upstream
## (WorldGen's water_body topology, shore_proximity) - no competition
## needed. Land biomes are decided by SCORING every candidate (a weighted
## style, like the terrain surface materials in terrain_surface.gd)
## and taking the argmax, rather than an ordered if/elif chain - this is
## what lets Forest/Rainforest and Grassland/Savanna naturally divide by
## whichever's extra conditions are actually met, instead of one hiding
## behind the other in a fixed check order.

const BiomeSubtypeScript := preload("res://scripts/gen/biome_subtype.gd")
const BiomeModifiersScript := preload("res://scripts/gen/biome_modifiers.gd")

## Tundra's score ramps from 0 at temperature -TUNDRA_COLD_START to 1 at
## -TUNDRA_COLD_FULL. It used to start at -0.1, so merely cool land beat the
## Plains floor (0.2) by -0.16 and Tundra covered ~a third of the world;
## -0.5 leaves the cool band to boreal forest/grassland.
const TUNDRA_COLD_START := 0.5
const TUNDRA_COLD_FULL := 0.75
## Vegetation ramps (start, full) for the wooded (Forest/Rainforest) and
## grassy (Grassland/Savanna) scores. Tuned together with WorldGen's
## vegetation formula for a roughly even land-biome spread (wide sample,
## 4 seeds: no land biome above ~22%).
const FOREST_VEG := Vector2(0.27, 0.37)
const GRASS_VEG := Vector2(0.2, 0.3)
## Temperature ramp (start, full) from Barrens to Desert. Cacti need
## >= 0.05 (cactus.tres); Desert only wins from about -0.1 up.
const BARRENS_TEMP := Vector2(-0.2, 0.05)

const BIOME_COLORS := {
	"Ocean": Color(0.15, 0.35, 0.75, 0.55),
	"Frozen Sea": Color(0.7, 0.85, 0.95, 0.55),
	"Sea": Color(0.2, 0.45, 0.65, 0.55),
	"Lake": Color(0.25, 0.6, 0.65, 0.55),
	"Swamp": Color(0.3, 0.34, 0.2, 0.55),
	"River": Color(0.3, 0.58, 0.75, 0.55),
	"Beach": Color(0.85, 0.75, 0.45, 0.55),
	"Alpine Snow": Color(0.95, 0.95, 1.0, 0.55),
	"Tundra": Color(0.7, 0.78, 0.72, 0.55),
	"Badlands": Color(0.55, 0.42, 0.3, 0.55),
	"Desert": Color(0.9, 0.8, 0.4, 0.55),
	"Barrens": Color(0.68, 0.66, 0.58, 0.55),
	"Wetland": Color(0.25, 0.32, 0.2, 0.55),
	"Rainforest": Color(0.05, 0.45, 0.15, 0.55),
	"Forest": Color(0.15, 0.5, 0.2, 0.55),
	"Savanna": Color(0.75, 0.65, 0.25, 0.55),
	"Grassland": Color(0.45, 0.7, 0.3, 0.55),
	"Plains": Color(0.6, 0.62, 0.4, 0.55),
}


## Thin wrapper kept for existing callers (chunk_manager.gd's overlay) -
## behavior unchanged, just now backed by classify_detailed().
static func classify(s: Dictionary) -> String:
	return classify_detailed(s)["base_biome"]


## {base_biome, subtype, modifiers, confidence, scores} - the real
## "DerivedBiome" result.
static func classify_full(s: Dictionary) -> Dictionary:
	var d := classify_detailed(s)
	d["subtype"] = BiomeSubtypeScript.classify(s, d["base_biome"])
	d["modifiers"] = BiomeModifiersScript.compute(s)
	return d


## Returns {base_biome, scores, confidence}. confidence is the gap between
## the winning score and the runner-up (small gap = ambiguous/transition
## tile, large gap = confidently one biome) - 1.0 for the categorical
## water/beach cases, which aren't scored/competed at all.
static func classify_detailed(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var water_body: String = s["water_body"]
	var shore_proximity: float = s["shore_proximity"]

	match water_body:
		"ocean":
			var name := "Frozen Sea" if temperature < -0.4 else "Ocean"
			return {"base_biome": name, "scores": {}, "confidence": 1.0}
		"sea":
			return {"base_biome": "Sea", "scores": {}, "confidence": 1.0}
		"lake":
			return {"base_biome": "Lake", "scores": {}, "confidence": 1.0}
		"swamp":
			return {"base_biome": "Swamp", "scores": {}, "confidence": 1.0}
		"river":
			return {"base_biome": "River", "scores": {}, "confidence": 1.0}

	if shore_proximity > 0.5:
		return {"base_biome": "Beach", "scores": {}, "confidence": 1.0}

	var scores := _score_land_biomes(s)
	var best_name := ""
	var best_score := -INF
	var second_score := -INF
	for name in scores.keys():
		var v: float = scores[name]
		if v > best_score:
			second_score = best_score
			best_score = v
			best_name = name
		elif v > second_score:
			second_score = v

	var confidence := clampf(best_score - second_score, 0.0, 1.0)
	return {"base_biome": best_name, "scores": scores, "confidence": confidence}


static func _score_land_biomes(s: Dictionary) -> Dictionary:
	var elevation: float = s["elevation"]
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var vegetation: float = s["vegetation"]
	var erosion: float = s["erosion"]
	var slope: float = s["slope"]
	var elev01 := clampf((elevation + 1.0) * 0.5, 0.0, 1.0)
	var drainage: float = s["drainage"]
	var wooded := smoothstep(FOREST_VEG.x, FOREST_VEG.y, vegetation)
	var grassy := smoothstep(GRASS_VEG.x, GRASS_VEG.y, vegetation)
	var hot_wet := smoothstep(0.05, 0.2, temperature) * smoothstep(0.4, 0.55, moisture)
	var hot_dry := smoothstep(0.1, 0.25, temperature) * (1.0 - smoothstep(0.35, 0.5, moisture))
	# Wetland = wet AND poorly drained ground, not "wet but sparse": under
	# the current vegetation formula wet ground is always lush, so a
	# vegetation cap left Wetland at <1%. Waterlogging also halves the
	# wooded/grassy biomes so Wetland wins where it's full.
	var waterlogged := smoothstep(0.5, 0.65, moisture) * (1.0 - smoothstep(0.42, 0.55, drainage))
	var not_wet := 1.0 - 0.5 * waterlogged
	# Dry, bare ground splits by warmth: a third of it used to be frozen or
	# too cool for cacti yet was labeled Desert (cold ground is sparse
	# anyway, and high ground is both cold and wind-dried).
	var arid := (1.0 - smoothstep(0.15, 0.3, moisture)) * (1.0 - smoothstep(0.1, 0.2, vegetation))
	var warm := smoothstep(BARRENS_TEMP.x, BARRENS_TEMP.y, temperature)
	var tundra := smoothstep(TUNDRA_COLD_START, TUNDRA_COLD_FULL, -temperature)

	return {
		# Needs cold as well as height - by elevation alone, hot highlands
		# (median temperature +0.22) were labeled snow.
		"Alpine Snow": smoothstep(0.55, 0.85, elev01) * (1.0 - smoothstep(0.0, 0.3, temperature)),
		"Tundra": tundra,
		"Badlands": maxf(smoothstep(0.15, 0.45, erosion), smoothstep(0.004, 0.009, slope)),
		"Desert": arid * warm,
		# Halved where Tundra is full so the deep cold goes to Tundra rather
		# than being decided by dictionary order.
		"Barrens": arid * (1.0 - warm) * (1.0 - 0.5 * tundra),
		"Wetland": waterlogged,
		# The hot variants split their generic biome by climate instead of
		# multiplying it down - as a bare product (forest * hot * wet) they
		# could never outscore the generic biome, so Rainforest/Savanna
		# never won anywhere.
		"Rainforest": wooded * hot_wet * not_wet,
		"Forest": wooded * (1.0 - hot_wet) * not_wet,
		"Savanna": grassy * hot_dry,
		# Halved under woodland so Forest wins where both are full (before,
		# it only won that tie by dictionary order).
		"Grassland": grassy * (1.0 - hot_dry) * (1.0 - 0.5 * wooded) * not_wet,
		# Constant floor so something always wins in "boring middle ground"
		# tiles where nothing else clears its threshold - matches the old
		# code's final "else: return Plains" fallback.
		"Plains": 0.2,
	}
