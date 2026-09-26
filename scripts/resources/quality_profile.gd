class_name QualityProfile
extends "res://scripts/resources/resource_definition.gd"

## Phase 14: how GOOD one placed instance of a resource is (tree age, ore
## richness, berry yield) - a separate layer after placement (plan Rule 4):
## it never changes density, patches or which instances exist, it only
## rates the instances that do. A ResourceDefinition points at one of these
## through quality_profile; several definitions can share one (every mature
## tree species uses the same tree-age profile).
##
## The drivers are the inherited suitability data - curves, required curves,
## categorical weights - evaluated by the same ResourceManager.get_suitability()
## as placement (plan Rules 2 and 6), so "old growth" or "abundant" comes
## from fields such as succession, soil fertility, moisture and Phase 13
## shade, never from the biome label (Rule 3). ResourceManager.get_quality()
## combines them with the fields below.

## Deposits (Phase 9 ores, clay, salt): multiply by how much of the deposit
## exists at the tile (ResourceManager.get_deposit_potential() / base_density,
## i.e. geology x vein x district), so outcrops on a seam's centre line in a
## rich district are rich. Ignored for a definition that isn't a deposit.
@export var richness_from_deposit: bool = false
## Per-instance variation (+-, from a hash of the instance's stable key), so
## neighbours in the same conditions still differ a little.
@export_range(0.0, 0.5) var jitter: float = 0.1
## Tier names from worst to best, and the quality values (ascending, one
## fewer than names) at which each next tier starts: names ["poor", "normal",
## "rich"] with thresholds [0.3, 0.7] = poor below 0.3, rich from 0.7.
@export var tier_names: PackedStringArray = []
@export var tier_thresholds: PackedFloat32Array = []
## Phase 15: size multiplier at quality 0 (x) and 1 (y), linear between -
## a young tree is small, old growth large (ResourceInstance.size).
@export var size_by_quality: Vector2 = Vector2(1.0, 1.0)


## The tier name for a quality value (0..1), "" when no tiers are set.
func tier_for(quality: float) -> String:
	if tier_names.is_empty():
		return ""
	var tier := 0
	for threshold in tier_thresholds:
		if quality >= threshold:
			tier += 1
	return tier_names[mini(tier, tier_names.size() - 1)]


## The inherited curve-domain checks, plus the tier table's shape.
func get_curve_domain_warnings() -> PackedStringArray:
	var warnings := super()
	if not tier_names.is_empty() and tier_thresholds.size() != tier_names.size() - 1:
		warnings.append("QualityProfile '%s': %d tier names need %d thresholds, not %d" % [
			id, tier_names.size(), tier_names.size() - 1, tier_thresholds.size()
		])
	for i in range(1, tier_thresholds.size()):
		if tier_thresholds[i] <= tier_thresholds[i - 1]:
			warnings.append("QualityProfile '%s': tier_thresholds must ascend" % id)
	return warnings
