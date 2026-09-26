// Chunk terrain images (one pixel per tile, scaled up). In the gameplay
// views ChunkManager marks tiles in the image's alpha (see _terrain_color()):
// WATER_CODE_ICE..WATER_CODE for water, by how liquid it is (0..1; solid ice
// has no code and stays still), SHALLOW_CODE + 0..7 for shallow open sea
// near the coast, FOAM_CODE + shape for open sea on the shoreline,
// WASH_CODE + shape for ground on a sea shore (WASH_GRASS_CODE + shape
// for grass, tinted first), GRASS_CODE for grass ground; anything else is
// opaque 255. A shape is 1 + an index into SHORE_SHAPES (ChunkManager's
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
// (the gameplay views), ground (plain - grass and GRASS_CODE-less ground,
// 253 / 255 - or sea-washed) meets a different neighbouring ground tile
// along a hard but wavy edge: every tile edge line bends into a smooth
// curve up to EDGE_PX
// off the grid (edge_curve(), the same for the tiles on both sides), and a
// pixel past the curve takes the neighbour's ground - one clean border,
// no dithering, islands or notches; outer corners are rounded off
// (CORNER_PX) - and ground (and swashed
// ground) gets a subtle grain and mottle. The chunk image has a 1-texel
// border holding the neighbouring chunks' edge tiles
// (ChunkManager._share_borders()), so edges cross chunk borders. The output is always opaque. Other views bake plain opaque RGB images, which pass
// through unchanged.
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
// How far (pixels) ground edges wander from the tile grid (under half a
// tile, so only direct neighbours meet), and the length (pixels) of one
// wiggle along an edge.
const float EDGE_PX = 2.0;
const float EDGE_WAVE = 26.0;
// Radius (pixels) of the rounded outer corners of ground areas (at most
// half a tile).
const float CORNER_PX = 8.0;
// Different ground (ground_differs()): a hue gap (colour proportions) or a
// brightness ratio beyond what one material's per-tile jitter gives.
const float GROUND_HUE = 0.025;
const float GROUND_BRIGHTNESS = 1.15;
// Splotches along ground borders (edge_pick()): one per BLOB_SLOT px of
// edge at most, with this chance; radius range (px); and how far from the
// edge line they can reach (EDGE_PX + largest radius + gap), which must
// stay under half a tile.
const float BLOB_SLOT = 7.0;
const float BLOB_CHANCE = 0.15;
const vec2 BLOB_RADIUS = vec2(1.2, 2.0);
const float BLOB_REACH = EDGE_PX + 3.0 + BLOB_RADIUS.y;

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
// shape) - what ground borders bend between.
bool is_ground(float code) {
	return plain_ground(code) || (code > WASH_CODE && code <= WASH_GRASS_CODE + 46.0);
}

// Ground that takes the season's grass tint.
bool is_grass(float code) {
	return code == GRASS_CODE || (code > WASH_GRASS_CODE && code <= WASH_GRASS_CODE + 46.0);
}

// Whether two ground tiles are different ground (a border between them),
// not the same material's per-tile variation: grass on one side only, a
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

// How far (pixels, either way) the ground border along the tile edge line
// at world coordinate `line` sits off it, `along` pixels along the line: a
// sine whose phase drifts with slow noise, so it always wiggles (never
// runs straight on the grid) without repeating, smooth enough to step in
// clean runs of whole pixels (no single-pixel nubs). Depends only on the
// line, so the tiles on both sides draw the same border.
float edge_curve(float line, float along) {
	float drift = vnoise(vec2(along / (EDGE_WAVE * 2.5), line * 0.173 + 11.0));
	return round(EDGE_PX * sin(along * 6.2832 / EDGE_WAVE + drift * 9.0 + line * 0.71));
}

// Which side of the tile edge line at world coordinate `line` (`key` tells
// x and y lines apart) a pixel centre `across` / `along` it takes its
// ground from: +1 the tile past the line, -1 the one before. Past the
// border curve (edge_curve()) is +1 - except inside a splotch: now and then
// (BLOB_CHANCE per BLOB_SLOT px of edge) a small round blob sits just off
// the curve on one side and shows the other side's ground. Everything
// depends only on the line, so the tiles on both sides agree.
float edge_pick(float line, float key, float across, float along, bool blobs) {
	float pick = across > line + edge_curve(key, along) ? 1.0 : -1.0;
	if (!blobs || abs(across - line) > BLOB_REACH)
		return pick;
	float slot = floor(along / BLOB_SLOT);
	for (float k = -1.0; k <= 1.0; k += 1.0) {
		vec2 id = vec2(key * 0.37 + 3.3, slot + k);
		if (hash(id) >= BLOB_CHANCE)
			continue;
		float r = mix(BLOB_RADIUS.x, BLOB_RADIUS.y, hash(id + 1.7));
		float b_along = (slot + k + hash(id + 2.9)) * BLOB_SLOT;
		float dir = hash(id + 4.1) < 0.5 ? -1.0 : 1.0;
		float b_across = line + edge_curve(key, b_along) + dir * (r + 1.0 + 2.0 * hash(id + 6.3));
		// A little longer along the edge than across it.
		vec2 d = vec2(across - b_across, (along - b_along) / 1.3);
		if (dot(d, d) <= r * r)
			pick = -dir;
	}
	return pick;
}

// Which tile's ground pixel `p` shows, relative to its own (-1..1 each
// axis), by the wavy seams (edge_pick()) of its tile's edges to a ground
// neighbour of another colour (`seam`: -x, +x, -y, +y) - the rest are
// skipped. Only borders to a different ground (`active`, ground_differs())
// get splotches and rounded corners; seams within one ground just wave, so
// its per-tile colour jitter doesn't line up on the grid.
vec2 edge_side(vec2 p, bvec4 seam, bvec4 active) {
	vec2 c = p + 0.5;  // pixel centre
	vec2 lo = floor(p / tile_px) * tile_px;  // this tile's top-left edge lines
	vec2 hi = lo + tile_px;
	vec2 side = vec2(0.0);
	if (seam.x && edge_pick(lo.x, lo.x, c.x, c.y, active.x) < 0.0) side.x = -1.0;
	else if (seam.y && edge_pick(hi.x, hi.x, c.x, c.y, active.y) > 0.0) side.x = 1.0;
	if (seam.z && edge_pick(lo.y, lo.y + 0.5, c.y, c.x, active.z) < 0.0) side.y = -1.0;
	else if (seam.w && edge_pick(hi.y, hi.y + 0.5, c.y, c.x, active.w) > 0.0) side.y = 1.0;
	// Rounded corners: where both edges at this pixel's nearest tile corner
	// are borders (an outer corner of this ground), the corner is cut along
	// a quarter circle of CORNER_PX and the cut goes to the ground across
	// it. Inner corners round themselves - they are the diagonal tile's
	// outer corners, cut the same way from its side.
	vec2 q = vec2(c.x - lo.x < tile_px * 0.5 ? -1.0 : 1.0, c.y - lo.y < tile_px * 0.5 ? -1.0 : 1.0);
	if ((q.x < 0.0 ? active.x : active.y) && (q.y < 0.0 ? active.z : active.w)) {
		vec2 corner = vec2(q.x < 0.0 ? lo.x : hi.x, q.y < 0.0 ? lo.y : hi.y);
		vec2 inward = (corner - c) * q;  // pixels in from the corner, per axis
		if (inward.x < CORNER_PX && inward.y < CORNER_PX && length(vec2(CORNER_PX) - inward) > CORNER_PX)
			side = q;
	}
	return side;
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
	// The ground this pixel shows (colour, grass tint, grain): past a wavy
	// border it is the neighbour's - washed shore ground included. What
	// happens on top (swash, waves, foam) stays its own tile's, so the surf
	// follows the real shoreline.
	vec4 g = c;
	if (ground_detail && is_ground(code)) {
		// Take the ground neighbour the pixel's border puts it in (TEXTURE
		// can only be sampled here, not in a helper); diagonal first, else
		// along one axis. Only edges to a different ground have a border.
		vec2 px = TEXTURE_PIXEL_SIZE;
		vec4 w = texture(TEXTURE, UV - vec2(px.x, 0.0));
		vec4 e = texture(TEXTURE, UV + vec2(px.x, 0.0));
		vec4 n = texture(TEXTURE, UV - vec2(0.0, px.y));
		vec4 s = texture(TEXTURE, UV + vec2(0.0, px.y));
		bvec4 seam = bvec4(is_ground(code_of(w)) && w != c, is_ground(code_of(e)) && e != c,
			is_ground(code_of(n)) && n != c, is_ground(code_of(s)) && s != c);
		bvec4 active = bvec4(seam.x && ground_differs(w, c), seam.y && ground_differs(e, c),
			seam.z && ground_differs(n, c), seam.w && ground_differs(s, c));
		vec2 side = any(seam) ? edge_side(p, seam, active) : vec2(0.0);
		if (side != vec2(0.0)) {
			vec4 nd = texture(TEXTURE, UV + side * TEXTURE_PIXEL_SIZE);
			vec4 nx = texture(TEXTURE, UV + vec2(side.x, 0.0) * TEXTURE_PIXEL_SIZE);
			vec4 ny = texture(TEXTURE, UV + vec2(0.0, side.y) * TEXTURE_PIXEL_SIZE);
			if (is_ground(code_of(nd)))
				g = nd;
			else if (side.x != 0.0 && is_ground(code_of(nx)))
				g = nx;
			else if (side.y != 0.0 && is_ground(code_of(ny)))
				g = ny;
		}
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
