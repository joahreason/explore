class_name WorldContent
extends Resource

## What the world is made of, as data: resources/world_content.tres lists the
## guilds in stack order, how the World view draws them, the ore deposits,
## farmland, the ground materials and the landmark structures. New content is
## a .tres edit, not code. Read-only once prepare() has run, so any thread may
## read it.

## Guilds sharing the ground, in collision priority order (Phase 8 step 5):
## ore outcrops and rocks are geology and were there first, then trees,
## then wetland plants (Phase 10) that own the wet margins, then shore
## features (shells, beach grass, mud flats), then deadwood left by the
## disturbance (Phase 11), the shrubs that fill in around all of them, then
## cacti on dry ground, and last the pioneer plants and ground cover (Phase
## 12) on what open ground remains.
@export var guilds: Array[ResourceGuild] = []
## The World view's layers, in draw order (later ones on top).
@export var world_view_layers: Array[WorldLayer] = []
## Phase 9 ore deposits (and Phase 10 clay): per-tile fields (exists /
## exposed) - see ResourceManager.get_deposit_potential(); the ore outcrop
## guild places the exposed part.
@export var deposits: Array[ResourceDefinition] = []
## Phase 10 floodplains: a suitability field only (Farming Potential view,
## inspector), nothing placed.
@export var farmland: ResourceDefinition
## The single-resource Oak views' definition (Phase 7).
@export var oak: ResourceDefinition
## Ground materials (TerrainSurface), in priority order for exact ties
## (practically never); `terrain_fallback` is used when nothing scores.
@export var terrain_materials: Array[SurfaceMaterial] = []
@export var terrain_fallback: SurfaceMaterial
## Landmark structures (StructureSites).
@export var structures: Array[StructureDefinition] = []

var _definitions := {}  # instance id -> ResourceDefinition
var _guild_of_member := {}  # member id -> ResourceGuild


## Builds the lookups and every curve plan now (review C5): they are read
## from the chunk worker and the "Go to" thread, so nothing may fill them
## lazily later. Each world calls it before its threads start; it only
## fills what is missing, so another world's running threads are safe.
## `rebuild` (after the data changed, F5 reload, other threads stopped or
## locked out) drops the old lookups and plans first.
func prepare(rebuild := false) -> void:
	if rebuild or _definitions.is_empty():
		var definitions := {oak.id: oak}
		_guild_of_member = {}
		for guild in guilds:
			if rebuild:
				guild.members = guild.members  # resets its cached reads_shade()
			for member in guild.members:
				definitions[member.id] = member
				_guild_of_member[member.id] = guild
		_definitions = definitions
	if rebuild:
		for definition in generation_definitions():
			definition.curve_plan = null
			if definition.quality_profile != null:
				definition.quality_profile.curve_plan = null
	ResourceManager.build_curve_plans(generation_definitions())


## Instance id -> ResourceDefinition for every guild member (and oak).
func definitions_by_id() -> Dictionary:
	return _definitions


## The guild a member is placed with.
func guild_of(member: ResourceDefinition) -> ResourceGuild:
	return _guild_of_member.get(member.id)


## Every definition generation reads (its curve plans are built by prepare()).
func generation_definitions() -> Array:
	return _definitions.values() + deposits + [farmland] + terrain_materials + structures


## The World view's placement layers ([guild, shape(, fallback)]).
func world_view_placement_layers() -> Array:
	return world_view_layers.map(func(layer: WorldLayer) -> Array: return layer.to_layer())


## Curve-domain warnings of the guilds (their members' included), the
## deposits and farmland.
func curve_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	for source in guilds + deposits + [farmland]:
		warnings.append_array(source.get_curve_domain_warnings())
	return warnings
