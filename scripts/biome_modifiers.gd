class_name BiomeModifiers
extends RefCounted

## Stage 3 of the classifier: independent, orthogonal tags. Each is a
## one-line threshold test against the environmental sample - none of them
## inspect each other or the base biome. This is deliberate: it's what
## keeps this list from becoming a combinatorial/nested mess as more tags
## get added later - appending a new one-liner never has to account for
## interactions with the existing ones.
##
## Deliberately a starting vocabulary (~10 tags), not exhaustive - more get
## added the same way, by appending another independent check.

const COLD_THRESHOLD := -0.3
const HOT_THRESHOLD := 0.25
const WET_THRESHOLD := 0.65
const DRY_THRESHOLD := 0.25
const WINDY_THRESHOLD := 0.7
const ROCKY_THRESHOLD := 0.4
const FERTILE_THRESHOLD := 0.75
const POOR_THRESHOLD := 0.45
const FIRE_PRONE_THRESHOLD := 0.03
const WELL_DRAINED_THRESHOLD := 0.7
const FLOODED_THRESHOLD := 0.3
# Below this, disturbance_age isn't locally meaningful - it's a per-blob
# value defined everywhere, but only relevant where a disturbance blob's
# influence (disturbance, the distance-gated intensity) actually reaches.
const DISTURBANCE_RELEVANCE_THRESHOLD := 0.05


static func compute(s: Dictionary) -> Array[String]:
	var tags: Array[String] = []

	var temperature: float = s["temperature"]
	if temperature < COLD_THRESHOLD:
		tags.append("Cold")
	if temperature > HOT_THRESHOLD:
		tags.append("Hot")

	var moisture: float = s["moisture"]
	if moisture > WET_THRESHOLD:
		tags.append("Wet")
	if moisture < DRY_THRESHOLD:
		tags.append("Dry")

	if float(s["wind_strength"]) > WINDY_THRESHOLD:
		tags.append("Windy")

	if float(s["erosion"]) > ROCKY_THRESHOLD:
		tags.append("Rocky")

	var fertility: float = s["soil_fertility"]
	if fertility > FERTILE_THRESHOLD:
		tags.append("Fertile")
	if fertility < POOR_THRESHOLD:
		tags.append("Poor")

	if float(s["disturbance"]) > DISTURBANCE_RELEVANCE_THRESHOLD:
		var age: float = s["disturbance_age"]
		if age < 0.33:
			tags.append("Young")
		elif age < 0.66:
			tags.append("Recovering")
		else:
			tags.append("OldGrowth")

	if float(s["fire_risk"]) > FIRE_PRONE_THRESHOLD:
		tags.append("FireProne")

	var drainage: float = s["drainage"]
	if drainage > WELL_DRAINED_THRESHOLD:
		tags.append("WellDrained")
	if drainage < FLOODED_THRESHOLD:
		tags.append("Flooded")

	return tags
