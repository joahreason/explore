class_name HeatmapColorizer
extends RefCounted

## Debug render-method views: each function maps one WorldGen sample() field
## to a flat color via a simple ramp (same lerp technique as
## DebugColorizer._water_color). These REPLACE a chunk's base image color
## (see ChunkManager.ViewMode) rather than drawing as an overlay - swapping
## Sprite2D.texture is enough, no extra node/layer needed.

const COLD := Color(0.15, 0.35, 0.85)
const NEUTRAL := Color(0.85, 0.85, 0.85)
const HOT := Color(0.9, 0.25, 0.15)

const DRY := Color(0.75, 0.55, 0.25)
const WET := Color(0.15, 0.45, 0.85)

const LOW := Color(0.1, 0.1, 0.15)
const HIGH := Color(0.95, 0.9, 0.4)

const POOR_DRAINAGE := Color(0.25, 0.2, 0.35)
const GOOD_DRAINAGE := Color(0.85, 0.7, 0.35)


static func temperature(s: Dictionary) -> Color:
	var t01 := clampf((float(s["temperature"]) + 1.0) * 0.5, 0.0, 1.0)
	if t01 < 0.5:
		return COLD.lerp(NEUTRAL, t01 * 2.0)
	return NEUTRAL.lerp(HOT, (t01 - 0.5) * 2.0)


static func moisture(s: Dictionary) -> Color:
	return DRY.lerp(WET, clampf(float(s["moisture"]), 0.0, 1.0))


static func temp_variation(s: Dictionary) -> Color:
	return LOW.lerp(HIGH, clampf(float(s["temp_variation"]), 0.0, 1.0))


static func precip_seasonality(s: Dictionary) -> Color:
	return LOW.lerp(HIGH, clampf(float(s["precip_seasonality"]), 0.0, 1.0))


static func drainage(s: Dictionary) -> Color:
	return POOR_DRAINAGE.lerp(GOOD_DRAINAGE, clampf(float(s["drainage"]), 0.0, 1.0))
