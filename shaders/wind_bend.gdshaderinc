// Shared wind bend (sway.gdshader, cast_shadow.gdshader): how far, in sprite
// pixels, a sprite's top leans downwind at world position `tile` (tiles) for
// its sway (0..1). Gust waves roll across the world so neighbours move
// together. Uniforms are set every frame from Wind (scripts/wind.gd).
uniform float wind_phase = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength = 0.5;
uniform float max_bend = 3.0;

float wind_bend(float sway, vec2 tile) {
	float along = dot(tile, wind_dir);
	float gust = 0.5 + 0.5 * sin(along * 0.08 - wind_phase * 0.35 + tile.y * 0.05);
	float flutter = 0.5 + 0.5 * sin(along * 0.9 - wind_phase * 2.4 + tile.y * 0.4);
	return sway * wind_strength * max_bend * (0.25 + 0.75 * gust) * (0.4 + 0.6 * flutter);
}

// The sway a draw carries in its colour's alpha (alpha = 1 - sway / 2;
// ChunkManager.sway_alpha()).
float decode_sway(float alpha) {
	return clamp((1.0 - alpha) * 2.0, 0.0, 1.0);
}
