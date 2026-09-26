// Cast shadows under resource sprites (ResourceMarkerChunk's Shadows
// layer): each shadow is the sprite's own silhouette, flattened onto the
// ground from the sprite's base and thrown away from the sun or moon -
// SunShadow (scripts/sun_shadow.gd) sets `cast_dir` (shadow offset per pixel of
// height: x sideways, y towards the viewer) and `darkness` from the in-game
// time. It sways with the plant it belongs to (the same wind bend, via the
// same colour-alpha sway encoding as sway.gdshader). Offsets snap to whole
// pixels so the pixel art stays crisp.
shader_type canvas_item;

#include "res://shaders/game_constants.gdshaderinc"
#include "res://shaders/wind_bend.gdshaderinc"

uniform vec2 cast_dir = vec2(0.0, 0.3);
uniform float darkness = 0.3;
// Drawn sprite height in pixels (12 px sheet art + the 1 px outline ring
// each side), unless the draw colour's red channel carries it
// (ResourceMarkerChunk.shadow_color(): height / shadow_height_scale).
uniform float sprite_px = 14.0;

void vertex() {
	float sway = decode_sway(COLOR.a);
	float px = COLOR.r > 0.0 ? COLOR.r * shadow_height_scale : sprite_px;
	// Height of this vertex above the sprite's base: 0 at the bottom edge.
	float h = (1.0 - UV.y) * px;
	vec2 tile = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy / tile_px;
	// Flatten onto the ground from the base (top ends up furthest away),
	// then lean with the wind like the sprite does.
	vec2 base = VERTEX + vec2(0.0, h);
	vec2 p = base + cast_dir * h;
	if (sway > 0.0 && h > 0.0) {
		p += wind_dir * wind_bend(sway, tile) * (h / px);
	}
	VERTEX = round(p);
	COLOR = vec4(0.0, 0.0, 0.0, 1.0);
}

void fragment() {
	COLOR = vec4(0.0, 0.0, 0.0, texture(TEXTURE, UV).a * darkness);
}
