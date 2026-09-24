// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha: WATER_CODE for a
// water body, GRASS_CODE for grass ground (see _terrain_color()); anything
// else is opaque 255. Water shimmers - soft moving waves plus small glints
// that come and go - and grass ground takes the season's grass tint
// (Seasons, "grass" class). The output is always opaque. Other views bake
// plain opaque RGB images, which pass through unchanged.
shader_type canvas_item;

const float WATER_CODE = 254.0;
const float GRASS_CODE = 253.0;

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
	if (code == WATER_CODE) {
		// Whole-pixel steps (12 per tile) keep it in the pixel-art grid.
		vec2 p = floor(world_px);
		float along = dot(p, wave_dir) / 12.0;
		float wave = sin(along * 1.3 - water_phase * 1.1 + p.y * 0.06) * 0.5 + 0.5;
		rgb *= 0.93 + 0.1 * wave;
		// Glints: a sparse set of pixels, each flashing on its own cycle.
		vec2 cell = floor(p / 3.0);
		float h = hash(cell);
		float cycle = fract(water_phase * 0.25 + h * 7.0);
		float glint = step(0.93, h) * smoothstep(0.0, 0.08, cycle) * (1.0 - smoothstep(0.08, 0.2, cycle));
		rgb = mix(rgb, vec3(0.9, 0.97, 1.0), glint * 0.7);
	} else if (code == GRASS_CODE) {
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
	}
	COLOR = vec4(rgb, 1.0);
}
