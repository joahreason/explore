class_name BiomeSubtype
extends RefCounted

## Stage 2 of the classifier: given a base_biome (from BiomeClassifier) and
## the same environmental sample, pick a smaller, PER-BIOME-SCOPED subtype.
## Each dispatch function only ever competes 3-5 candidates against each
## other - never a single global list across all biomes - which is what
## keeps this from becoming an unmaintainable conditional tree as more
## subtypes get added later.
##
## Deliberately a starting vocabulary (~6 base biomes covered), not
## exhaustive coverage of every biome - more get added the same way,
## one small scoped dispatch at a time.

static func classify(s: Dictionary, base_biome: String) -> String:
	match base_biome:
		"Forest":
			return _argmax(_score_forest(s))
		"Grassland":
			return _argmax(_score_grassland(s))
		"Desert":
			return _argmax(_score_desert(s))
		"Wetland", "Swamp":
			return _argmax(_score_wetland(s))
		"Beach":
			return _argmax(_score_coastal(s))
	return ""


static func _score_forest(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var elev01 := clampf((float(s["elevation"]) + 1.0) * 0.5, 0.0, 1.0)
	return {
		"Montane": smoothstep(0.5, 0.72, elev01),
		"Boreal": smoothstep(0.05, 0.35, -temperature),
		"Tropical": smoothstep(0.1, 0.25, temperature) * smoothstep(0.45, 0.6, moisture),
		"Dry Woodland": smoothstep(0.05, 0.2, temperature) * (1.0 - smoothstep(0.4, 0.55, moisture)),
		"Temperate": 0.15,
	}


static func _score_grassland(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var elev01 := clampf((float(s["elevation"]) + 1.0) * 0.5, 0.0, 1.0)
	return {
		"Alpine Meadow": smoothstep(0.45, 0.65, elev01),
		"Steppe": smoothstep(0.0, 0.25, -temperature) * (1.0 - smoothstep(0.25, 0.4, moisture)),
		"Prairie": 0.15,
	}


static func _score_desert(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var erosion: float = s["erosion"]
	return {
		"Rocky": smoothstep(0.15, 0.35, erosion),
		"Cold": smoothstep(0.0, 0.3, -temperature),
		"Hot": smoothstep(0.0, 0.2, temperature),
	}


static func _score_wetland(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var drainage: float = s["drainage"]
	return {
		"Bog": smoothstep(0.0, 0.25, -temperature) * (1.0 - smoothstep(0.3, 0.5, drainage)),
		"Fen": smoothstep(0.35, 0.55, drainage),
		"Marsh": 0.15,
	}


static func _score_coastal(s: Dictionary) -> Dictionary:
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var erosion: float = s["erosion"]
	return {
		"Rocky Shore": smoothstep(0.2, 0.4, erosion),
		"Mangrove": smoothstep(0.1, 0.25, temperature) * smoothstep(0.4, 0.6, moisture),
		"Dunes": 0.15,
	}


static func _argmax(scores: Dictionary) -> String:
	var best_name := ""
	var best_score := -INF
	for name in scores.keys():
		var v: float = scores[name]
		if v > best_score:
			best_score = v
			best_name = name
	return best_name
