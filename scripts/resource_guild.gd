class_name ResourceGuild
extends Resource

## Phase 8 amendment of docs/resource-generation-plan.md: a group of
## resources that compete for the same ecological slot (canopy trees,
## shrubs, ...). A species scored in isolation fills every tile no competitor
## wants, so instead:
##   * HOW MUCH of the guild grows at a tile comes from the environment -
##     cover_field (normally WorldGen's `vegetation`) through cover_curve,
##     modulated by the guild's own patch noise - capped by how well the
##     best-suited member could live there (a tile no member tolerates gets
##     nothing, however green it is).
##   * WHICH member it is comes from the members' relative suitability
##     (share_i = s_i^species_sharpness / sum_j s_j^species_sharpness), so
##     adding a species narrows its neighbors' ranges automatically.
##   * PLACEMENT runs once for the whole guild on one shared grid
##     (minimum_spacing), then rolls a species per instance - no two members
##     of a guild can overlap.
## Competition is only within a guild (plan Phase 13 scope limit): guilds
## never read each other. ResourceManager/ResourcePlacement do the math;
## this is data only, same Resource + @export pattern as ResourceDefinition.
##
## id shares one namespace with ResourceDefinition ids (it seeds the guild's
## patch noise and placement rolls the same way), so it must not reuse a
## member's id.

@export var id: String
@export var members: Array[ResourceDefinition] = []:
	set(value):
		members = value
		_reads_shade = null

## Phase 13: whether any member has a shade_curve (built on first use; reset
## when members is reassigned - assign a new array rather than mutating it).
## ResourceManager.get_member_scores() only computes shade for such guilds.
var _reads_shade = null


func reads_shade() -> bool:
	if _reads_shade == null:
		_reads_shade = false
		for member in members:
			if member.shade_curve != null:
				_reads_shade = true
	return _reads_shade

## EnvironmentalState field (by name) the guild's cover is driven by; empty
## = full cover everywhere (ore outcrops: the exposed deposit alone decides).
@export var cover_field: String = "vegetation"
## Maps cover_field (0..1) to cover (0..1). Unset = the field is used as-is.
## Needed for vegetation, whose land values mostly sit around 0.05..0.3.
@export var cover_curve: Curve
## Peak cover (0..1), same role as ResourceDefinition.base_density.
@export_range(0.0, 1.0) var base_density: float = 1.0
## Optional reshaping of the final 0..1 density (the plan's Phase 6
## density_curve) - unset = as-is. Ore outcrops use it to drop trace
## exposures and saturate rich ones, which as raw probabilities would give
## only a handful of outcrops even on ore-rich bare rock.
@export var density_curve: Curve
## Exponent in the species share - higher means the best-suited member takes
## more of the mix (1 = proportional to suitability, large = winner-takes-all).
@export var species_sharpness: float = 4.0

## Same meaning as on ResourceDefinition, but for the guild as a whole: the
## members' own cluster/spacing fields are ignored when placed via a guild.
@export_group("Spatial")
@export var cluster_scale: float = 32.0
@export_range(0.0, 1.0) var cluster_strength: float = 0.0
## Reshapes the raw 0..1 patch noise before cluster_strength applies. Unset =
## as-is (patches fade smoothly into gaps). A steep curve, e.g. 0 below 0.55
## rising to 1 by 0.7, turns patches into distinct thickets with bare ground
## between - the plan's "stronger clustering" for berry bushes.
@export var cluster_curve: Curve
@export var minimum_spacing: float = 1.0
## Phase 14 clustering: cover x the best member's score decides how much of
## the ground lies in STANDS (ResourceManager.get_stand_membership(): the
## patch noise's highest share of tiles) instead of thinning the density
## everywhere - dense clumps with clear gaps between. Density inside a stand
## is base_density. cluster_strength / cluster_curve are unused when on.
@export var cover_sets_area: bool = false
## Half-width (patch-noise units) of a stand's soft edge; ~0.05 fades over a
## tile or two at cluster_scale ~30.
@export var stand_edge: float = 0.05
## Radius (tiles) of one instance's physical footprint, for collisions with
## OTHER guilds (ResourcePlacement.place_stack_in_rect()): two instances of
## different guilds must be at least the sum of their radii apart. Within the
## guild, minimum_spacing already keeps instances apart.
@export var footprint_radius: float = 0.5
## Whether this guild's sprites cast a shadow in the World view (> 0 = yes:
## their silhouette, thrown by the sun or moon - SunShadow). Grass and
## flowers have none, so the ground doesn't speckle.
@export var shadow_size: float = 0.0


## Members' curve-domain warnings plus the guild's own cover_curve check.
func get_curve_domain_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if cover_curve != null and (cover_curve.min_domain > 0.0 or cover_curve.max_domain < 1.0):
		warnings.append("ResourceGuild '%s': cover_curve domain [%s, %s] doesn't cover [0, 1]" % [
			id, cover_curve.min_domain, cover_curve.max_domain
		])
	if density_curve != null and (density_curve.min_domain > 0.0 or density_curve.max_domain < 1.0):
		warnings.append("ResourceGuild '%s': density_curve domain [%s, %s] doesn't cover [0, 1]" % [
			id, density_curve.min_domain, density_curve.max_domain
		])
	if cluster_curve != null and (cluster_curve.min_domain > 0.0 or cluster_curve.max_domain < 1.0):
		warnings.append("ResourceGuild '%s': cluster_curve domain [%s, %s] doesn't cover [0, 1]" % [
			id, cluster_curve.min_domain, cluster_curve.max_domain
		])
	for member in members:
		warnings.append_array(member.get_curve_domain_warnings())
		if member.id == id:
			warnings.append("ResourceGuild '%s': shares its id with a member" % id)
	return warnings
