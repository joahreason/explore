class_name WorldLayer
extends Resource

## One guild as the World (Resources) view draws it: sprites, and the
## marker shape for a member without art (review A3). See WorldContent.

const ResourceMarkerChunkScript := preload("res://scripts/render/resource_marker_chunk.gd")

@export var guild: ResourceGuild
@export var shape: ResourceMarkerChunkScript.Shape = ResourceMarkerChunkScript.Shape.SPRITE
## Shape for a member without a sprite; unset (-1) = the default triangle.
@export var fallback: int = -1


## [guild, shape] or [guild, shape, fallback] - a placement layer.
func to_layer() -> Array:
	return [guild, shape] if fallback < 0 else [guild, shape, fallback]
