extends RefCounted

## Game-wide values used by several scripts and shaders - the one place to
## change them. Scripts preload this file; shaders include
## shaders/game_constants.gdshaderinc, whose uniforms apply_to() sets on
## every material that uses them (they have no defaults, so a material that
## missed apply_to() shows it at once instead of using a stale number).

## World pixels per tile: the terrain grid, walking, picking and art scale
## (1 art pixel = 1 world pixel).
const TILE_SIZE := 16
## Cast shadows get their sprite's drawn height (px) through the red channel
## of their draw colour, divided by this (ResourceMarkerChunk.shadow_color(),
## shaders/cast_shadow.gdshader); the tallest sprite must stay below it.
const SHADOW_HEIGHT_SCALE := 64.0


## Sets the shader side of these values (game_constants.gdshaderinc) on
## `material`.
static func apply_to(material: ShaderMaterial) -> void:
	material.set_shader_parameter("tile_px", float(TILE_SIZE))
	material.set_shader_parameter("shadow_height_scale", SHADOW_HEIGHT_SCALE)
