class_name HeatmapColorizer
extends RefCounted

## Debug render-method views: each function maps one WorldGen sample() field
## to a flat color via a simple ramp (same lerp technique as
## DebugColorizer._water_color). ChunkManager blends this on top of the
## Material look (see ChunkManager._color_for/HEATMAP_OVERLAY_STRENGTH)
## rather than swapping it out entirely, so terrain stays visible as context
## for how the field affects generation - still just one Sprite2D per chunk,
## no extra node/layer needed.

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

const NOT_SUITABLE := Color(0.12, 0.1, 0.14)
const HIGHLY_SUITABLE := Color(0.25, 0.85, 0.35)

# Deliberately a different hue from suitability's green, so the two views
# can't be mistaken for each other when flipping between them.
const NO_DENSITY := Color(0.1, 0.1, 0.12)
const HIGH_DENSITY := Color(0.95, 0.7, 0.15)

const BURIED_ROCK := Color(0.2, 0.17, 0.12)
const BARE_ROCK := Color(0.9, 0.88, 0.85)

const NO_DEPOSIT := Color(0.45, 0.45, 0.45)

const SUNLIT := Color(0.95, 0.9, 0.55)
const DEEP_SHADE := Color(0.05, 0.2, 0.15)


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


## Phase 11 succession stage: fresh scar (YOUNG_SCAR) .. mature/undisturbed
## (OLD_SCAR) - unlike disturbance_age, gated by the scar's footprint.
static func succession(s: Dictionary) -> Color:
	return YOUNG_SCAR.lerp(OLD_SCAR, clampf(float(s["succession"]), 0.0, 1.0))


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


## Takes a raw 0..1 value directly (not a sample Dictionary) since
## suitability isn't a WorldGen field - it's computed externally by
## ResourceManager.get_suitability(), which already clamps to [0,1].
static func resource_suitability(value: float) -> Color:
	return NOT_SUITABLE.lerp(HIGHLY_SUITABLE, clampf(value, 0.0, 1.0))


## Same raw-0..1 contract as resource_suitability(), for
## ResourceManager.get_density() (Phase 6).
static func resource_density(value: float) -> Color:
	return NO_DENSITY.lerp(HIGH_DENSITY, clampf(value, 0.0, 1.0))


## Phase 13 canopy shade (ResourceManager.get_shade()), raw 0..1: sunlit
## open ground .. deep shade under dense canopy.
static func shade(value: float) -> Color:
	return SUNLIT.lerp(DEEP_SHADE, clampf(value, 0.0, 1.0))


static func rock_exposure(s: Dictionary) -> Color:
	return BURIED_ROCK.lerp(BARE_ROCK, clampf(float(s["rock_exposure"]), 0.0, 1.0))


## Phase 9 Deposits view: one ore's potential (how much exists) in its
## debug color, dimmed where it's buried and full brightness where the
## deposit's exposure (ResourceManager.get_exposure(): rock_exposure for
## ores, river banks for clay) shows it at the surface, so hidden and visible
## deposits read apart at a glance.
static func deposit(ore_color: Color, potential: float, rock_exposure: float) -> Color:
	var hidden := ore_color.darkened(0.55)
	var exposed := ore_color.lightened(0.25)
	var shade := hidden.lerp(exposed, clampf(rock_exposure, 0.0, 1.0))
	return NO_DEPOSIT.lerp(shade, clampf(potential * 1.5, 0.0, 1.0))
