class_name Seasons
extends RefCounted

## Seasonal colour (polish pass 2): how vegetation looks through the year.
## Each season class is a loop of keyframes over the year fraction (0 =
## Spring 1, 0.25 Summer 1, 0.5 Autumn 1, 0.75 Winter 1), each a target
## colour and how far (alpha, 0..1) to pull the plant's own colour towards
## it, blended linearly between keyframes so colours drift over days rather
## than snapping at a season change. Classes (ResourceDefinition.season_class):
##   deciduous - fresh in spring, green in summer, orange/red in autumn,
##               bare grey-brown in winter (oak, birch, willow, berry bush...)
##   evergreen - darker in winter only (pine, palm, olive, mangrove)
##   grass     - fresh spring, golden late summer, straw autumn, pale winter
##               (grasses, reeds, herbs; also grass ground tiles)
##   flower    - in bloom spring and summer, faded brown in autumn, dull winter

const KEYS := {
	"deciduous": [
		[0.00, Color(0.55, 0.85, 0.35, 0.25)],
		[0.20, Color(0.50, 0.80, 0.30, 0.0)],
		[0.45, Color(0.50, 0.80, 0.30, 0.0)],
		[0.58, Color(0.92, 0.55, 0.15, 0.75)],
		[0.68, Color(0.85, 0.35, 0.12, 0.8)],
		[0.80, Color(0.46, 0.40, 0.33, 0.8)],
		[0.95, Color(0.48, 0.44, 0.36, 0.7)],
	],
	"evergreen": [
		[0.00, Color(0.2, 0.4, 0.3, 0.1)],
		[0.15, Color(0.2, 0.4, 0.3, 0.0)],
		[0.70, Color(0.2, 0.4, 0.3, 0.0)],
		[0.85, Color(0.18, 0.32, 0.30, 0.35)],
	],
	"grass": [
		[0.00, Color(0.55, 0.9, 0.35, 0.2)],
		[0.20, Color(0.55, 0.9, 0.35, 0.0)],
		[0.42, Color(0.85, 0.78, 0.35, 0.35)],
		[0.62, Color(0.75, 0.62, 0.35, 0.5)],
		[0.85, Color(0.62, 0.58, 0.46, 0.55)],
	],
	"flower": [
		[0.05, Color(0.5, 0.4, 0.3, 0.0)],
		[0.45, Color(0.5, 0.4, 0.3, 0.0)],
		[0.62, Color(0.58, 0.42, 0.26, 0.6)],
		[0.85, Color(0.48, 0.45, 0.40, 0.75)],
	],
}


## 0 (Spring 1, 00:00) .. <1 through the year of a GameClock.
static func year_fraction(clock) -> float:
	var days_per_year: float = GameClock.DAYS_PER_SEASON * GameClock.SEASONS.size()
	return fposmod(clock.minutes / GameClock.MINUTES_PER_DAY, days_per_year) / days_per_year


## The tint for a class at a year fraction: rgb = target colour, a = how far
## to pull towards it (0 = unchanged). Unknown / empty class: no tint.
static func tint(season_class: String, fraction: float) -> Color:
	var keys: Array = KEYS.get(season_class, [])
	if keys.is_empty():
		return Color(0, 0, 0, 0)
	var f := fposmod(fraction, 1.0)
	# Find the keyframes around f, wrapping from the last back to the first.
	var n := keys.size()
	for i in n:
		var a: Array = keys[i]
		var b: Array = keys[(i + 1) % n]
		var fa: float = a[0]
		var fb: float = b[0] + (1.0 if i == n - 1 else 0.0)
		var ff := f if f >= fa else f + 1.0
		if ff >= fa and ff <= fb:
			return (a[1] as Color).lerp(b[1], (ff - fa) / maxf(fb - fa, 1e-6))
	return keys[0][1]


## A colour after a season tint (tint.a = strength), alpha kept.
static func apply(color: Color, season_tint: Color) -> Color:
	var c := color.lerp(Color(season_tint.r, season_tint.g, season_tint.b, color.a), season_tint.a)
	c.a = color.a
	return c
