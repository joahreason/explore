// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha (see _terrain_color()):
// WATER_CODE_ICE..WATER_CODE for water, by how liquid it is (0..1; solid ice
// has no code and stays still), FOAM_CODE + mask for open water on the
// shoreline, WASH_CODE + mask for sandy ground beside open water (mask bits:
// 1 -x, 2 +x, 4 -y, 8 +y = the neighbours across the shoreline), GRASS_CODE
// for grass ground; anything else is opaque 255.
// Water gets slow noisy waves whose fronts bend and whose speed drifts from
// place to place and over time, plus a few steady glints - each tile has a
// small random chance of one or two fixed glint pixels - both scaled by how
// liquid it is. Shoreline water breaks into flickering white foam that
// surges up to the land edge and back; the sand beside it is washed by
// swash that runs up, leaves foam specks at its front and drains, darkening
// the wet sand. Grass ground takes the season's grass tint (Seasons). The
// output is always opaque. Other views bake plain opaque RGB images, which
// pass through unchanged.
shader_type canvas_item;

const float WATER_CODE_ICE = 200.0;
const float WATER_CODE = 220.0;
const float FOAM_CODE = 224.0;
const float WASH_CODE = 180.0;
const float GRASS_CODE = 253.0;
const float TILE = 12.0;
// Share of water tiles with a glint, and its strength.
const float GLINT_CHANCE = 0.1;
const float GLINT_STRENGTH = 0.3;
// Wave phase per unit of water_phase (real seconds at normal speed).
const float WAVE_SPEED = 0.45;
const vec3 FOAM = vec3(0.93, 0.97, 1.0);

uniform float water_phase = 0.0;
uniform vec4 grass_tint = vec4(0.0);  // rgb target, a = strength
uniform vec2 wave_dir = vec2(1.0, 0.0);

varying vec2 world_px;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Smooth value noise, 0..1.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Pixels from the nearest tile edge named in `mask`.
float edge_dist(int mask, vec2 in_tile) {
	float d = TILE;
	if ((mask & 1) != 0) d = min(d, in_tile.x);
	if ((mask & 2) != 0) d = min(d, TILE - 1.0 - in_tile.x);
	if ((mask & 4) != 0) d = min(d, in_tile.y);
	if ((mask & 8) != 0) d = min(d, TILE - 1.0 - in_tile.y);
	return d;
}

vec3 waves(vec3 rgb, vec2 p, float liquid) {
	float t = water_phase * WAVE_SPEED;
	// Slow noise shifts the phase: fronts bend, and each patch runs a little
	// ahead or behind as the noise drifts; the surge makes the whole sea
	// speed up and slacken over time.
	float warp = vnoise(p / 60.0 + vec2(t * 0.05, -t * 0.03)) * 4.0;
	float surge = 1.5 * sin(t * 0.13);
	float along = dot(p, wave_dir) / TILE;
	float wave = sin(along * 1.1 - t - surge + warp + p.y * 0.04) * 0.5 + 0.5;
	float amp = 0.5 + vnoise(p / 90.0 - t * 0.02);
	float ripple = vnoise(p / 7.0 + vec2(t * 0.15, t * 0.1)) - 0.5;
	return rgb * (1.0 + liquid * ((0.08 * wave - 0.04) * amp + 0.04 * ripple));
}

vec3 glint(vec3 rgb, vec2 tile, vec2 in_tile, float liquid) {
	float h = hash(tile);
	if (h < GLINT_CHANCE) {
		vec2 spot = floor(vec2(hash(tile + 17.3), hash(tile + 41.9)) * (TILE - 1.0));
		float hit = (in_tile == spot || (h < GLINT_CHANCE * 0.4 && in_tile == spot + vec2(1.0, 0.0))) ? 1.0 : 0.0;
		float strength = GLINT_STRENGTH * (0.6 + 0.4 * hash(tile + 5.1));
		rgb = mix(rgb, vec3(0.9, 0.97, 1.0), hit * strength * liquid);
	}
	return rgb;
}

// Surf on water beside land: a band of flickering whites whose reach
// breathes in and out, ragged along the shore, with loose bubbles past it.
vec3 foam(vec3 rgb, vec2 p, float d) {
	float t = water_phase;
	float surf = 0.5 + 0.5 * sin(t * 0.7 + vnoise(p / 30.0) * 6.28);
	float reach = 0.5 + 3.0 * surf + 2.0 * vnoise(p / 4.0 + vec2(t * 0.2, 0.0));
	float flicker = hash(p + floor(t * 3.0) * 1.37);
	if (d < reach) {
		float white = mix(0.8, 1.0, flicker) * (1.0 - 0.2 * d / reach);
		rgb = mix(rgb, FOAM, white);
	} else if (d < reach + 2.5 && flicker > 0.82) {
		rgb = mix(rgb, FOAM, 0.45);
	}
	return rgb;
}

// Swash on sand beside open water: runs up quickly, drains slowly, each
// stretch of beach on its own cycle; wet sand darkens and foam specks ride
// the front up the beach.
vec3 swash(vec3 rgb, vec2 p, float d) {
	float t = water_phase;
	float cycle = fract(t * 0.12 + vnoise(p / 40.0) * 2.0);
	float run = cycle < 0.3 ? cycle / 0.3 : 1.0 - (cycle - 0.3) / 0.7;
	float front = 7.0 * run + 2.0 * vnoise(p / 4.0 + 3.1) - 1.5;
	float speck = hash(p + floor(t * 4.0) * 2.71);
	if (d < front) {
		rgb *= 0.8;
		if (speck > 0.9)
			rgb = mix(rgb, FOAM, 0.55);
	}
	if (abs(d - front) < 1.0 && speck > 0.35)
		rgb = mix(rgb, FOAM, 0.8);
	return rgb;
}

void vertex() {
	world_px = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float code = floor(c.a * 255.0 + 0.5);
	vec3 rgb = c.rgb;
	// Whole-pixel steps (TILE per tile) keep it in the pixel-art grid.
	vec2 p = floor(world_px);
	vec2 tile = floor(p / TILE);
	vec2 in_tile = p - tile * TILE;
	if (code >= WATER_CODE_ICE && code <= WATER_CODE) {
		float liquid = (code - WATER_CODE_ICE) / (WATER_CODE - WATER_CODE_ICE);
		rgb = glint(waves(rgb, p, liquid), tile, in_tile, liquid);
	} else if (code > FOAM_CODE && code < FOAM_CODE + 16.0) {
		rgb = foam(waves(rgb, p, 1.0), p, edge_dist(int(code - FOAM_CODE), in_tile));
	} else if (code > WASH_CODE && code < WASH_CODE + 16.0) {
		rgb = swash(rgb, p, edge_dist(int(code - WASH_CODE), in_tile));
	} else if (code == GRASS_CODE) {
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
	}
	COLOR = vec4(rgb, 1.0);
}
