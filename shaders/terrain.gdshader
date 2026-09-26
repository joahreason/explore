// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha (see _terrain_color()):
// WATER_CODE_ICE..WATER_CODE for water, by how liquid it is (0..1; solid ice
// has no code and stays still), SHALLOW_CODE + 0..7 for shallow open sea
// near the coast, FOAM_CODE + shape for open sea on the shoreline,
// WASH_CODE + shape for ground on a sea shore (WASH_GRASS_CODE + shape
// for grass, tinted first), GRASS_CODE for grass ground; anything else is
// opaque 255. A shape is 1 + an index into SHORE_SHAPES (TerrainCodes'
// list): a mask of the neighbours across the shoreline - edges 1 -x, 2 +x,
// 4 -y, 8 +y, diagonal corners 16 (-x,-y), 32 (+x,-y), 64 (-x,+y), 128
// (+x,+y) - so bands follow the shore round corners instead of stepping.
// Water gets slow noisy waves whose fronts bend and whose speed drifts from
// place to place and over time, plus a few steady glints - each tile has a
// small random chance of one or two fixed glint pixels - both scaled by how
// liquid it is. Near the coast, wave crests break into whitecaps, more of
// them the shallower it gets. Shoreline sea (not lakes or rivers) breaks
// into flickering white foam that surges up to the land edge and back; the
// ground beside it is washed by white swash that runs up, thinning to wet
// ground and foam specks at its front, and drains - the first row always
// stays washed, so water and ground meet in white instead of a hard edge.
// Grass ground takes the season's grass tint (Seasons). With ground_detail
// (the gameplay views) ground (and swashed ground) gets a subtle grain and
// mottle. Every tile edge bumps in or out a little (EDGE_PX), so the tiles
// form one wobbly grid - every pixel belongs to
// exactly one tile and shows its ground (invisible between tiles of one
// ground) - outer corners of a ground are rounded (CORNER_PX), decided
// from the four tiles round the corner so all of them agree, and now and
// then a small splotch sits just off a border (edge_blob()). Land never
// takes a water tile's colour. What happens on top (swash, waves, foam)
// stays each pixel's own tile's. The output is always opaque. Other
// views bake plain opaque RGB images, which pass through unchanged.
shader_type canvas_item;

#include "res://shaders/game_constants.gdshaderinc"

const float FOAM_CODE = 50.0;
const float WASH_CODE = 100.0;
const float WASH_GRASS_CODE = 150.0;
const float WATER_CODE_ICE = 200.0;
const float WATER_CODE = 220.0;
const float SHALLOW_CODE = 240.0;
const float GRASS_CODE = 253.0;
const int SHORE_SHAPES[46] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 24, 26, 32, 33, 40, 41, 48, 56, 64, 66, 68, 70, 80, 82, 96, 112, 128, 129, 132, 133, 144, 160, 161, 176, 192, 196, 208, 224, 240};
// Share of water tiles with a glint, and its strength.
const float GLINT_CHANCE = 0.1;
const float GLINT_STRENGTH = 0.3;
// Wave phase per unit of water_phase (real seconds at normal speed).
const float WAVE_SPEED = 0.45;
const vec3 FOAM = vec3(0.93, 0.97, 1.0);

uniform float water_phase = 0.0;
uniform vec4 grass_tint = vec4(0.0);  // rgb target, a = strength
uniform vec2 wave_dir = vec2(1.0, 0.0);
uniform bool ground_detail = false;
// Ground borders: each tile edge bumps up to EDGE_PX in or out (whole
// pixels); outer corners cut along a quarter circle of CORNER_PX (at most
// half a tile).
const float EDGE_PX = 2.0;
const float CORNER_PX = 8.0;
// Splotches: each tile edge between two different grounds has this chance
// of one small round splotch near its middle, just off the border on a
// random side, showing the ground across it; radius range in pixels.
const float BLOB_CHANCE = 0.35;
const vec2 BLOB_RADIUS = vec2(1.9, 2.2);  // bump + gap + 2 radii stays under half a tile
// Different ground (ground_differs()): a hue gap (colour proportions) or a
// brightness ratio beyond what one material's per-tile jitter gives.
const float GROUND_HUE = 0.025;
const float GROUND_BRIGHTNESS = 1.15;
varying vec2 world_px;

// Pseudo-random 0..1 per point. No sin(): the usual fract(sin(x) * 43758)
// hash falls apart on 32-bit GPU floats at large world coordinates (far
// from the origin its values clump into streaks). Wrapped to a 4096 px
// period first to keep full precision - repeats far too rarely to notice,
// and exactly periodic, so value noise lattices stay seamless.
float hash(vec2 p) {
	vec3 p3 = fract(vec3(mod(p, 4096.0).xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
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
	vec2 far = tile_px - 1.0 - in_tile;
	float d = tile_px;
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
	float along = dot(p, wave_dir) / tile_px;
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
		vec2 spot = floor(vec2(hash(tile + 17.3), hash(tile + 41.9)) * (tile_px - 1.0));
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

float code_of(vec4 c) {
	return floor(c.a * 255.0 + 0.5);
}

// Plain ground: grass (GRASS_CODE) or other ground (no code, 255).
bool plain_ground(float code) {
	return code >= GRASS_CODE;
}

// Any ground: plain, or washed by the sea (WASH_CODE / WASH_GRASS_CODE +
// shape) - what borders bend between and gets the grain.
bool is_ground(float code) {
	return plain_ground(code) || (code > WASH_CODE && code <= WASH_GRASS_CODE + 46.0);
}

// Ground that takes the season's grass tint.
bool is_grass(float code) {
	return code == GRASS_CODE || (code > WASH_GRASS_CODE && code <= WASH_GRASS_CODE + 46.0);
}

// Whether two ground tiles are different ground (a border between them),
// not one material's per-tile variation: grass on one side only, a
// different hue (colour proportions - the brightness jitter,
// SurfaceMaterial.jitter up to 6%, leaves them alone), or a brightness gap
// beyond GROUND_BRIGHTNESS.
bool ground_differs(vec4 a, vec4 b) {
	if (is_grass(code_of(a)) != is_grass(code_of(b)))
		return true;
	float sa = a.r + a.g + a.b + 0.0001;
	float sb = b.r + b.g + b.b + 0.0001;
	float ratio = sa / sb;
	return distance(a.rgb / sa, b.rgb / sb) > GROUND_HUE || ratio > GROUND_BRIGHTNESS || ratio < 1.0 / GROUND_BRIGHTNESS;
}

// How far (whole pixels, either way) the tile edge line `key` wobbles off
// the grid, `along` pixels along it: one smooth bump per tile edge, in or
// out at random, fading to nothing at the tile corners - so corners stay
// on the grid and their rounding (CORNER_PX up to half a tile) always fits.
// Depends only on the line, so the tiles on both sides draw the same edge.
float edge_offset(float key, float along) {
	float segment = floor(along / tile_px);
	float bump = sin(3.14159 * (along / tile_px - segment));
	return round(EDGE_PX * bump * (hash(vec2(key, segment + 5.1)) < 0.5 ? 1.0 : -1.0));
}

// The splotch on the tile edge segment `segment` of edge line `key` (see
// BLOB_CHANCE), if any, and whether pixel centre `across` / `along` is in
// it: 0 = not, else the side of the line (-1 / +1, `across` growing) the
// splotch sits on - it shows the ground from the other side. Keyed to the
// edge alone, so the tiles on both sides draw it the same.
float edge_blob(float line, float key, float segment, float across, float along) {
	vec2 id = vec2(key, segment + 91.7);
	if (hash(id) >= BLOB_CHANCE)
		return 0.0;
	float r = mix(BLOB_RADIUS.x, BLOB_RADIUS.y, hash(id + 1.3));
	float b_along = (segment + 0.5 + (hash(id + 2.9) - 0.5) * 0.3) * tile_px;
	float dir = hash(id + 4.1) < 0.5 ? -1.0 : 1.0;
	float b_across = line + edge_offset(key, b_along) + dir * (r + 1.0);
	vec2 d = vec2(across - b_across, (along - b_along) / 1.2);  // a little longer along the edge
	return dot(d, d) <= r * r ? dir : 0.0;
}

// Subtle ground texture: per-pixel grain and a soft mottle.
vec3 ground_noise(vec3 rgb, vec2 p) {
	float grain = hash(p + 21.3) - 0.5;
	float mottle = vnoise(p / 5.0 + 7.7) - 0.5;
	return rgb * (1.0 + 0.07 * grain + 0.08 * mottle);
}

void vertex() {
	world_px = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Whole-pixel steps (tile_px per tile) keep it in the pixel-art grid.
	vec2 p = floor(world_px);
	vec4 c = texture(TEXTURE, UV);
	float code = code_of(c);
	// The ground this pixel shows (colour, grass tint, grain) may be a
	// neighbouring tile's, across a wobbling edge; what happens on top
	// (swash, waves, foam) stays its own tile's, so the surf follows the
	// shoreline.
	vec4 g = c;
	if (ground_detail && is_ground(code)) {
		// The corner of this pixel's tile it is nearest (direction q), and
		// the four tiles round it: [own, across x, across y, diagonal].
		// TEXTURE can only be sampled here, not in a helper.
		vec2 px = TEXTURE_PIXEL_SIZE;
		vec2 cp = p + 0.5;  // pixel centre
		vec2 lo = floor(p / tile_px) * tile_px;
		vec2 q = vec2(cp.x - lo.x < tile_px * 0.5 ? -1.0 : 1.0, cp.y - lo.y < tile_px * 0.5 ? -1.0 : 1.0);
		vec2 corner = lo + max(q, vec2(0.0)) * tile_px;
		vec4 quad[4] = vec4[4](c, texture(TEXTURE, UV + vec2(q.x, 0.0) * px),
			texture(TEXTURE, UV + vec2(0.0, q.y) * px), texture(TEXTURE, UV + q * px));
		// Which of them owns this pixel: the side of each wobbling edge
		// line through the corner it is on (1 = across, towards q).
		// Distance past each wobbling line, towards q (the lines where they
		// pass this pixel's row / column).
		vec2 past = vec2(cp.x - corner.x - edge_offset(corner.x, cp.y), cp.y - corner.y - edge_offset(corner.y + 0.5, cp.x)) * q;
		int ox = past.x > 0.0 ? 1 : 0;
		int oy = past.y > 0.0 ? 1 : 0;
		vec4 owner = quad[ox + 2 * oy];
		// Rounded corner: if the owner's ground differs from both tiles
		// beside it round this corner, its corner is cut along a quarter
		// circle, measured from the wobbling lines themselves (so the curve
		// meets them cleanly). The cut shows the ground round the corner:
		// the beside tile matching the other one or the diagonal. Where two
		// tiles of one ground touch only at the corner (a saddle), only the
		// darker pair is cut, so it parts cleanly and the other stays whole.
		vec4 beside_x = quad[(1 - ox) + 2 * oy];
		vec4 beside_y = quad[ox + 2 * (1 - oy)];
		vec4 diagonal = quad[(1 - ox) + 2 * (1 - oy)];
		bool saddle = !ground_differs(owner, diagonal) && !ground_differs(beside_x, beside_y);
		if (ground_differs(owner, beside_x) && ground_differs(owner, beside_y)
				&& (!saddle || dot(owner.rgb, vec3(0.3, 0.59, 0.11)) < dot(beside_x.rgb, vec3(0.3, 0.59, 0.11)))) {
			// Pixels in from each line, into the owner's quarter.
			vec2 inward = vec2(ox == 1 ? past.x : -past.x, oy == 1 ? past.y : -past.y);
			if (inward.x < CORNER_PX && inward.y < CORNER_PX && length(vec2(CORNER_PX) - inward) > CORNER_PX) {
				vec4 cut = (!ground_differs(beside_x, beside_y) || !ground_differs(beside_x, diagonal)) ? beside_x
					: (!ground_differs(beside_y, diagonal) ? beside_y : beside_x);
				if (is_ground(code_of(cut)))
					owner = cut;
			}
		}
		// Splotches on the two edge lines through this corner, each on this
		// pixel's own tile row / column, between two different grounds.
		// A splotch on the far (q) side shows this side's tile, and back.
		vec4 row_near = quad[0];
		vec4 row_far = quad[1];
		if (ground_differs(row_near, row_far) && is_ground(code_of(row_far))) {
			float b = edge_blob(corner.x, corner.x, floor(cp.y / tile_px), cp.x, cp.y);
			if (b != 0.0)
				owner = b * q.x > 0.0 ? row_near : row_far;
		}
		vec4 col_far = quad[2];
		if (ground_differs(row_near, col_far) && is_ground(code_of(col_far))) {
			float b = edge_blob(corner.y, corner.y + 0.5, floor(cp.x / tile_px), cp.y, cp.x);
			if (b != 0.0)
				owner = b * q.y > 0.0 ? row_near : col_far;
		}
		// Land never takes a water tile's colour.
		if (is_ground(code_of(owner)))
			g = owner;
	}
	float ground = code_of(g);
	vec3 rgb = g.rgb;
	if (ground_detail && is_ground(ground))
		rgb = ground_noise(rgb, p);
	if (is_grass(ground))
		rgb = mix(rgb, grass_tint.rgb, grass_tint.a);
	vec2 tile = floor(p / tile_px);
	vec2 in_tile = p - tile * tile_px;
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
		rgb = swash(rgb, p, shore_dist(code - WASH_GRASS_CODE, in_tile));
	}
	COLOR = vec4(rgb, 1.0);
}
