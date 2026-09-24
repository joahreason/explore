// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha (see _terrain_color()):
// WATER_CODE_ICE..WATER_CODE for water, by how liquid it is (0..1; solid ice
// has no code and stays still), SHALLOW_CODE + 0..7 for shallow open water
// near the coast, FOAM_CODE + shape for open water on the shoreline,
// WASH_CODE + shape for ground beside open water (WASH_GRASS_CODE + shape
// for grass, tinted first), GRASS_CODE for grass ground; anything else is
// opaque 255. A shape is 1 + an index into SHORE_SHAPES (ChunkManager's
// list): a mask of the neighbours across the shoreline - edges 1 -x, 2 +x,
// 4 -y, 8 +y, diagonal corners 16 (-x,-y), 32 (+x,-y), 64 (-x,+y), 128
// (+x,+y) - so bands follow the shore round corners instead of stepping.
// Water gets slow noisy waves whose fronts bend and whose speed drifts from
// place to place and over time, plus a few steady glints - each tile has a
// small random chance of one or two fixed glint pixels - both scaled by how
// liquid it is. Near the coast, wave crests break into whitecaps, more of
// them the shallower it gets. Shoreline water (sea, lake or river) breaks
// into flickering white foam that surges up to the land edge and back; the
// ground beside it is washed by white swash that runs up, thinning to wet
// ground and foam specks at its front, and drains - the first row always
// stays washed, so water and ground meet in white instead of a hard edge.
// Grass ground takes the season's grass tint (Seasons). The output is
// always opaque. Other views bake plain opaque RGB images, which pass
// through unchanged.
shader_type canvas_item;

const float FOAM_CODE = 50.0;
const float WASH_CODE = 100.0;
const float WASH_GRASS_CODE = 150.0;
const float WATER_CODE_ICE = 200.0;
const float WATER_CODE = 220.0;
const float SHALLOW_CODE = 240.0;
const float GRASS_CODE = 253.0;
const int SHORE_SHAPES[46] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 24, 26, 32, 33, 40, 41, 48, 56, 64, 66, 68, 70, 80, 82, 96, 112, 128, 129, 132, 133, 144, 160, 161, 176, 192, 196, 208, 224, 240};
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

// Pixels from the shoreline of shore shape `shape` (1..46): the nearest
// edge in its mask, or the nearest corner point (a quarter circle, meeting
// the neighbouring tiles' edge bands).
float shore_dist(float shape, vec2 in_tile) {
	int mask = SHORE_SHAPES[int(shape) - 1];
	vec2 far = TILE - 1.0 - in_tile;
	float d = TILE;
	if ((mask & 1) != 0) d = min(d, in_tile.x);
	if ((mask & 2) != 0) d = min(d, far.x);
	if ((mask & 4) != 0) d = min(d, in_tile.y);
	if ((mask & 8) != 0) d = min(d, far.y);
	if ((mask & 16) != 0) d = min(d, length(in_tile));
	if ((mask & 32) != 0) d = min(d, length(vec2(far.x, in_tile.y)));
	if ((mask & 64) != 0) d = min(d, length(vec2(in_tile.x, far.y)));
	if ((mask & 128) != 0) d = min(d, length(far));
	return d;
}

// Wave height 0..1 at a pixel. Slow noise shifts the phase: fronts bend,
// and each patch runs a little ahead or behind as the noise drifts; the
// surge makes the whole sea speed up and slacken over time.
float wave_at(vec2 p, float t) {
	float warp = vnoise(p / 60.0 + vec2(t * 0.05, -t * 0.03)) * 4.0;
	float surge = 1.5 * sin(t * 0.13);
	float along = dot(p, wave_dir) / TILE;
	return sin(along * 1.1 - t - surge + warp + p.y * 0.04) * 0.5 + 0.5;
}

vec3 waves(vec3 rgb, vec2 p, float liquid) {
	float t = water_phase * WAVE_SPEED;
	float wave = wave_at(p, t);
	float amp = 0.5 + vnoise(p / 90.0 - t * 0.02);
	float ripple = vnoise(p / 7.0 + vec2(t * 0.15, t * 0.1)) - 0.5;
	return rgb * (1.0 + liquid * ((0.08 * wave - 0.04) * amp + 0.04 * ripple));
}

// Whitecaps where the swell breaks off shore: broken, flickering foam along
// the wave crests, wider and more frequent the shallower it is (0..1).
vec3 whitecaps(vec3 rgb, vec2 p, float shallow) {
	float t = water_phase * WAVE_SPEED;
	float crest = wave_at(p, t);
	float broken = vnoise(p / 9.0 + vec2(t * 0.4, -t * 0.25));
	float flicker = hash(p + floor(water_phase * 3.0) * 1.37);
	if (crest > 0.975 - 0.05 * shallow && broken > 0.7 - 0.2 * shallow && flicker > 0.3)
		rgb = mix(rgb, FOAM, (0.3 + 0.4 * shallow) * mix(0.7, 1.0, flicker));
	return rgb;
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

// Swash on ground beside open water: runs up quickly, drains slowly, each
// stretch of shore on its own cycle. Foam at the waterline stays nearly
// white for most of the run, then thins into wet (darker) ground, with
// foam specks riding the front; the row by the water is always washed.
vec3 swash(vec3 rgb, vec2 p, float d) {
	float t = water_phase;
	float cycle = fract(t * 0.12 + vnoise(p / 40.0) * 2.0);
	float run = cycle < 0.3 ? cycle / 0.3 : 1.0 - (cycle - 0.3) / 0.7;
	float front = 1.0 + 6.5 * run + 1.5 * vnoise(p / 4.0 + 3.1);
	float speck = hash(p + floor(t * 4.0) * 2.71);
	if (d < front) {
		float white = (1.0 - smoothstep(0.35, 1.0, d / front)) * mix(0.8, 1.0, speck);
		rgb = mix(rgb * 0.85, FOAM, white);
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
	} else if (code >= SHALLOW_CODE && code < SHALLOW_CODE + 8.0) {
		float shallow = (code - SHALLOW_CODE + 1.0) / 8.0;
		rgb = whitecaps(glint(waves(rgb, p, 1.0), tile, in_tile, 1.0), p, shallow);
	} else if (code > FOAM_CODE && code <= FOAM_CODE + 46.0) {
		rgb = foam(whitecaps(waves(rgb, p, 1.0), p, 1.0), p, shore_dist(code - FOAM_CODE, in_tile));
	} else if (code > WASH_CODE && code <= WASH_CODE + 46.0) {
		rgb = swash(rgb, p, shore_dist(code - WASH_CODE, in_tile));
	} else if (code > WASH_GRASS_CODE && code <= WASH_GRASS_CODE + 46.0) {
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
		rgb = swash(rgb, p, shore_dist(code - WASH_GRASS_CODE, in_tile));
	} else if (code == GRASS_CODE) {
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
	}
	COLOR = vec4(rgb, 1.0);
}
