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

const YOUNG_SCAR := Color(0.15, 0.1, 0.08)
const OLD_SCAR := Color(0.6, 0.75, 0.4)

const TYPE_FIRE := Color(0.9, 0.3, 0.1)
const TYPE_FLOOD := Color(0.2, 0.4, 0.9)
const TYPE_STORM := Color(0.6, 0.6, 0.75)
const TYPE_LANDSLIDE := Color(0.55, 0.4, 0.25)
const TYPE_UNKNOWN := Color(0.8, 0.2, 0.8)

const NO_FUEL := Color(0.12, 0.14, 0.1)
const HIGH_FUEL := Color(0.75, 0.7, 0.2)

const NO_RISK := Color(0.1, 0.15, 0.2)
const HIGH_RISK := Color(0.95, 0.15, 0.05)

const NO_CAVE := Color(0.15, 0.15, 0.18)
const HIGH_CAVE := Color(0.55, 0.4, 0.75)

const NO_CLIFF := Color(0.15, 0.15, 0.18)
const HIGH_CLIFF := Color(0.9, 0.85, 0.8)


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


## Raw per-blob age across the whole Voronoi cell (not gated by disturbance
## intensity) - deliberately shows full region extent, useful for verifying
## neighboring blobs get decorrelated ages.
static func disturbance_age(s: Dictionary) -> Color:
	return YOUNG_SCAR.lerp(OLD_SCAR, clampf(float(s["disturbance_age"]), 0.0, 1.0))


static func disturbance_type(s: Dictionary) -> Color:
	match String(s["disturbance_type"]):
		"fire":
			return TYPE_FIRE
		"flood":
			return TYPE_FLOOD
		"storm":
			return TYPE_STORM
		"landslide":
			return TYPE_LANDSLIDE
	return TYPE_UNKNOWN


static func fuel_load(s: Dictionary) -> Color:
	return NO_FUEL.lerp(HIGH_FUEL, clampf(float(s["fuel_load"]), 0.0, 1.0))


## fire_risk's real range rarely exceeds ~0.1 (dryness and fuel accumulation
## are in natural tension - you can't have max dryness AND max fuel at once,
## confirmed via diagnostic + per-biome breakdown, not a bug). Display-only
## gain+gamma so the view is legible; the underlying data stays unscaled for
## anything that thresholds against it later (e.g. a future FireProne tag).
static func fire_risk(s: Dictionary) -> Color:
	var v := clampf(pow(float(s["fire_risk"]) * 8.0, 0.6), 0.0, 1.0)
	return NO_RISK.lerp(HIGH_RISK, v)


static func cave_potential(s: Dictionary) -> Color:
	return NO_CAVE.lerp(HIGH_CAVE, clampf(float(s["cave_potential"]), 0.0, 1.0))


## cliff_tendency is sparse by nature (only steep+hard tiles, mean ~0.02) -
## same display-only gain treatment as fire_risk, real data left unscaled.
static func cliff_tendency(s: Dictionary) -> Color:
	var v := clampf(pow(float(s["cliff_tendency"]) * 4.0, 0.5), 0.0, 1.0)
	return NO_CLIFF.lerp(HIGH_CLIFF, v)
