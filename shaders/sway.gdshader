// Wind sway for resource sprites (ResourceMarkerChunk). Bends the TOP of
// each sprite downwind - its base stays planted - by an amount that comes in
// through the draw colour's alpha (ChunkManager._marker_colors():
// alpha = 1 - sway * 0.5, so opaque draws - rocks, markers - never move);
// the alpha is restored to 1 here. The offset is rounded to whole sprite
// pixels so the 12 px art stays crisp. Wind (scripts/wind.gd) drives the
// uniforms from the in-game clock.
shader_type canvas_item;

uniform float wind_phase = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength = 0.5;
// Top offset in sprite pixels at sway 1, full wind and a full gust.
uniform float max_bend = 3.0;

void vertex() {
	float sway = clamp((1.0 - COLOR.a) * 2.0, 0.0, 1.0);
	COLOR.a = 1.0;
	if (sway > 0.0 && UV.y < 0.5) {
		// World position in tiles (12 px each) sets the gust waves' phase,
		// so neighbours move together and gusts roll across the ground.
		vec2 tile = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy / 12.0;
		float along = dot(tile, wind_dir);
		float gust = 0.5 + 0.5 * sin(along * 0.08 - wind_phase * 0.35 + tile.y * 0.05);
		float flutter = 0.5 + 0.5 * sin(along * 0.9 - wind_phase * 2.4 + tile.y * 0.4);
		float bend = sway * wind_strength * max_bend * (0.25 + 0.75 * gust) * (0.4 + 0.6 * flutter);
		VERTEX += wind_dir * round(bend);
	}
}
