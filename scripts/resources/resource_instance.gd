class_name ResourceInstance
extends RefCounted

## Phase 15 of docs/resource-generation-plan.md: one placed resource as a
## gameplay entity - the generic record later mechanics (harvesting,
## destruction, respawning, growth, persistence) read and change. Pure data:
## rendering stays in resource_marker_chunk.gd, which draws from placement
## output.
##
## Built on demand from a ResourcePlacement instance (ChunkManager.
## get_resource_instance()) - for the instances that are inspected or
## shown in a view that needs them - never stored for every placed object.
## Every field is a pure function of (seed, placement key, tile fields,
## data), so rebuilding one always gives the same record. A record starts
## with full health and harvest_state "available"; the player's changes
## (Phase 16 WorldChanges, keyed by `key` + resource_id) are applied on top
## by ChunkManager.get_resource_instance().

const HARVEST_AVAILABLE := "available"
const HARVESTED := "harvested"

## Stable key: "<guild id>:<cell x>,<cell y>" (the Phase 7 / 8 placement
## key; a single definition placed on its own uses its own id). Unique per
## placed instance, identical across chunks, sessions and load order.
var key: String
var guild_id: String
var cell: Vector2i
var resource_id: String
var world_position: Vector2
## ResourceManager.get_quality(): 0..1, or -1.0 when the resource has no
## quality profile; tier is the profile's name for it ("" without one).
var quality: float = -1.0
var tier: String = ""
## Relative size, 1.0 = typical: definition.base_size x the quality
## profile's size_by_quality range at this quality (base_size without a
## profile). Data only - sprites are not scaled.
var size: float = 1.0
var max_health: float = 100.0
var health: float = 100.0
var harvest_state: String = HARVEST_AVAILABLE


## The record for placement instance `inst` ({id, cell, position, guild?})
## of `definition`, given its quality (ResourceManager.get_quality(), -1 =
## none).
static func create(inst: Dictionary, definition: ResourceDefinition, quality: float):
	var record = load("res://scripts/resources/resource_instance.gd").new()
	record.guild_id = inst.get("guild", inst["id"])
	record.cell = inst["cell"]
	record.key = key_for(record.guild_id, record.cell)
	record.resource_id = inst["id"]
	record.world_position = inst["position"]
	record.quality = quality
	record.size = maxf(definition.base_size, 0.0)
	var profile = definition.quality_profile
	if profile != null and quality >= 0.0:
		record.tier = profile.tier_for(quality)
		record.size *= lerpf(profile.size_by_quality.x, profile.size_by_quality.y, quality)
	record.max_health = maxf(definition.max_health, 0.0) * record.size
	record.health = record.max_health
	return record


static func key_for(guild_id: String, cell: Vector2i) -> String:
	return "%s:%d,%d" % [guild_id, cell.x, cell.y]
