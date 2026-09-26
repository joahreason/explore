// Wind sway for resource sprites (ResourceMarkerChunk). Bends the TOP of
// each sprite downwind - its base stays planted - by an amount that comes in
// through the draw colour's alpha (ChunkManager._marker_colors():
// alpha = 1 - sway * 0.5, so opaque draws - rocks, markers - never move);
// the alpha is restored to 1 here. The offset is rounded to whole sprite
// pixels so the pixel art stays crisp. Wind (scripts/wind.gd) drives the
// uniforms from the in-game clock.
shader_type canvas_item;

#include "res://shaders/game_constants.gdshaderinc"
#include "res://shaders/wind_bend.gdshaderinc"

void vertex() {
	float sway = decode_sway(COLOR.a);
	COLOR.a = 1.0;
	if (sway > 0.0 && UV.y < 0.5) {
		vec2 tile = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy / tile_px;
		VERTEX += wind_dir * round(wind_bend(sway, tile));
	}
}
