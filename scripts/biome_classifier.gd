class_name BiomeClassifier
extends RefCounted

## Discrete biome labeling derived from WorldGen's continuous fields, purely
## for the debug overlay (naming/outlining regions for a human to read).
## The actual generation/rendering never uses this - it stays continuous.

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
	"Wetland": Color(0.25, 0.32, 0.2, 0.55),
	"Rainforest": Color(0.05, 0.45, 0.15, 0.55),
	"Forest": Color(0.15, 0.5, 0.2, 0.55),
	"Savanna": Color(0.75, 0.65, 0.25, 0.55),
	"Grassland": Color(0.45, 0.7, 0.3, 0.55),
	"Plains": Color(0.6, 0.62, 0.4, 0.55),
}


static func classify(s: Dictionary) -> String:
	var elevation: float = s["elevation"]
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var vegetation: float = s["vegetation"]
	var erosion: float = s["erosion"]
	var slope: float = s["slope"]
	var water_body: String = s["water_body"]
	var shore_proximity: float = s["shore_proximity"]

	match water_body:
		"ocean":
			return "Frozen Sea" if temperature < -0.4 else "Ocean"
		"sea":
			return "Sea"
		"lake":
			return "Lake"
		"swamp":
			return "Swamp"
		"river":
			return "River"

	if shore_proximity > 0.5:
		return "Beach"

	var elev01 := clampf((elevation + 1.0) * 0.5, 0.0, 1.0)
	if elev01 > 0.75:
		return "Alpine Snow"
	if temperature < -0.35:
		return "Tundra"
	if erosion > 0.4 or slope > 0.008:
		return "Badlands"
	if moisture < 0.25 and vegetation < 0.15:
		return "Desert"
	if moisture > 0.6 and vegetation < 0.2:
		return "Wetland"
	if vegetation > 0.35:
		return "Rainforest" if (temperature > 0.15 and moisture > 0.5) else "Forest"
	if vegetation > 0.18:
		return "Savanna" if (temperature > 0.2 and moisture < 0.45) else "Grassland"
	return "Plains"
