// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha (see _terrain_color()):
// WATER_CODE_ICE..WATER_CODE for water, by how liquid it is (0..1; solid ice
// has no code and stays still), GRASS_CODE for grass ground; anything else
// is opaque 255. Water gets soft moving waves and a few steady glints - each
// tile has a small random chance of one or two fixed glint pixels at a
// random spot and brightness - both scaled by how liquid it is. Grass ground
// takes the season's grass tint (Seasons). The output is always opaque.
// Other views bake plain opaque RGB images, which pass through unchanged.
shader_type canvas_item;

const float WATER_CODE_ICE = 200.0;
const float WATER_CODE = 220.0;
const float GRASS_CODE = 253.0;
// Share of water tiles with a glint, and its strength.
const float GLINT_CHANCE = 0.1;
const float GLINT_STRENGTH = 0.3;

uniform float water_phase = 0.0;
uniform vec4 grass_tint = vec4(0.0);  // rgb target, a = strength
uniform vec2 wave_dir = vec2(1.0, 0.0);

varying vec2 world_px;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	world_px = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float code = floor(c.a * 255.0 + 0.5);
	vec3 rgb = c.rgb;
	if (code >= WATER_CODE_ICE && code <= WATER_CODE) {
		float liquid = (code - WATER_CODE_ICE) / (WATER_CODE - WATER_CODE_ICE);
		// Whole-pixel steps (12 per tile) keep it in the pixel-art grid.
		vec2 p = floor(world_px);
		float along = dot(p, wave_dir) / 12.0;
		float wave = sin(along * 1.3 - water_phase * 1.1 + p.y * 0.06) * 0.5 + 0.5;
		rgb *= 1.0 + liquid * (0.08 * wave - 0.04);
		// Steady glints: a few tiles each hold one or two fixed bright pixels.
		vec2 tile = floor(p / 12.0);
		vec2 in_tile = p - tile * 12.0;
		float h = hash(tile);
		if (h < GLINT_CHANCE) {
			vec2 spot = floor(vec2(hash(tile + 17.3), hash(tile + 41.9)) * 11.0);
			float hit = (in_tile == spot || (h < GLINT_CHANCE * 0.4 && in_tile == spot + vec2(1.0, 0.0))) ? 1.0 : 0.0;
			float strength = GLINT_STRENGTH * (0.6 + 0.4 * hash(tile + 5.1));
			rgb = mix(rgb, vec3(0.9, 0.97, 1.0), hit * strength * liquid);
		}
	} else if (code == GRASS_CODE) {
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
	}
	COLOR = vec4(rgb, 1.0);
}
