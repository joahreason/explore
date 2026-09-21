class_name DebugColorizer
extends RefCounted

## Converts a WorldGen sample() Dictionary into a flat debug color.
## Pure visualization aid - kept separate from WorldGen so the art/rendering
## layer can be swapped later without touching the generation data itself.
## Colors are blended continuously from field weights, not switched by
## hard biome lookup, so regions transition smoothly.

const WATER_SHALLOW := Color(0.2, 0.45, 0.8)
const WATER_DEEP := Color(0.05, 0.12, 0.45)
const ICE := Color(0.75, 0.85, 0.95)
const SNOW := Color(0.95, 0.95, 1.0)
const ROCK := Color(0.5, 0.5, 0.55)
const SAND := Color(0.85, 0.75, 0.45)
const MUD := Color(0.3, 0.22, 0.15)
const SOIL := Color(0.45, 0.3, 0.18)
const GRASS := Color(0.35, 0.65, 0.25)
const FOREST := Color(0.1, 0.35, 0.15)
const RESOURCE := Color(1.0, 0.1, 0.8)
const DISTURBED := Color(0.35, 0.32, 0.28)


static func color_for(s: Dictionary) -> Color:
	var elevation: float = s["elevation"]
	var temperature: float = s["temperature"]
	var moisture: float = s["moisture"]
	var slope: float = s["slope"]
	var vegetation: float = s["vegetation"]
	var erosion: float = s["erosion"]
	var disturbance: float = s["disturbance"]
	var resource: float = s["resource"]

	var sea_level := -0.1

	if elevation < sea_level:
		var depth_t := clampf(inverse_lerp(sea_level, sea_level - 0.6, elevation), 0.0, 1.0)
		var water_color := WATER_SHALLOW.lerp(WATER_DEEP, depth_t)
		var frozen_t := clampf(smoothstep(-0.15, -0.55, temperature), 0.0, 1.0)
		return water_color.lerp(ICE, frozen_t)

	var elev01 := clampf((elevation + 1.0) * 0.5, 0.0, 1.0)
	var warm_trigger := smoothstep(-0.2, 0.3, temperature)
	var flat_trigger := 1.0 - smoothstep(0.0013, 0.0065, slope)

	var w_snow := maxf(smoothstep(0.15, 0.55, -temperature), smoothstep(0.55, 0.85, elev01))
	var w_rock := clampf(erosion * 1.3 + smoothstep(0.0045, 0.012, slope) * 0.7, 0.0, 1.0)
	var w_sand := clampf((1.0 - moisture) * warm_trigger, 0.0, 1.0)
	var w_mud := clampf(moisture * (1.0 - vegetation) * flat_trigger, 0.0, 1.0)
	var w_soil := clampf((1.0 - vegetation) * (1.0 - w_mud) * 0.6, 0.0, 1.0)
	var w_grass := clampf(vegetation * (1.0 - smoothstep(0.6, 1.0, vegetation)), 0.0, 1.0)
	var w_forest := clampf(vegetation * smoothstep(0.55, 1.0, vegetation), 0.0, 1.0)

	var total := w_snow + w_rock + w_sand + w_mud + w_soil + w_grass + w_forest + 0.001
	var color := (
		SNOW * w_snow
		+ ROCK * w_rock
		+ SAND * w_sand
		+ MUD * w_mud
		+ SOIL * w_soil
		+ GRASS * w_grass
		+ FOREST * w_forest
	) / total

	color = color.lerp(DISTURBED, disturbance * 0.5)

	if resource > 0.65:
		color = color.lerp(RESOURCE, clampf((resource - 0.65) / 0.35, 0.0, 1.0) * 0.85)

	return color
