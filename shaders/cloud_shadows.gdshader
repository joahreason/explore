// Drifting cloud shadows over the world (CloudShadows, cloud_shadows.gd):
// soft dark patches from value-noise fbm over WORLD position (so they stay
// put on the map and only move by `offset`, which the wind advances).
shader_type canvas_item;

uniform vec2 offset = vec2(0.0);     // tiles the cloud field has drifted
uniform float scale = 28.0;          // tiles per noise unit (cloud size)
uniform float coverage = 0.42;       // share of the sky covered
uniform float darkness = 0.32;       // shadow alpha under a cloud
uniform vec3 shadow_color = vec3(0.02, 0.03, 0.08);

varying vec2 world_tiles;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.55;
	for (int k = 0; k < 4; k++) {
		v += a * value_noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v / 1.0625;
}

void vertex() {
	world_tiles = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy / 16.0;
}

void fragment() {
	float n = fbm((world_tiles - offset) / scale);
	// fbm here is roughly normal around 0.484 (measured quantiles: 25% of
	// the field is above ~0.58, 10% above ~0.66), so this edge makes about
	// `coverage` of the sky cloudy.
	float edge = 0.484 + (0.5 - coverage) * 0.4;
	float cloud = smoothstep(edge - 0.07, edge + 0.07, n);
	COLOR = vec4(shadow_color, cloud * darkness);
}
