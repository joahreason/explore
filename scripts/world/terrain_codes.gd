extends RefCounted

## Tile codes of the gameplay views' chunk images, read by
## shaders/terrain.gdshader, and the shore shapes they carry (§4.1 step 1,
## moved out of chunk_manager.gd). Constants and one pure function; any
## thread.

## Polish pass 2: tile codes in the gameplay views' chunk images (alpha,
## out of 255) that shaders/terrain.gdshader reads - water shimmers, grass
## ground takes the season's tint - and the ground materials that count as
## grass. Water codes run WATER_CODE_ICE..WATER_CODE for how liquid it is
## (0..1); solid ice carries no code and stays still. Surf is for the coast
## only (ocean and sea, not lakes or rivers): shallow open sea near the
## coast carries SHALLOW_CODE + 0..7 (shallower = higher) for whitecaps,
## open sea on the shoreline FOAM_CODE + a shore shape, and any ground on a
## sea shore WASH_CODE (WASH_GRASS_CODE for grass, which also takes the
## season's tint) + a shore shape - surf foam and swash. A shape (shore_shape()) is 1 + the index in
## SHORE_SHAPES of the mask of neighbours across the shoreline: edges 1 -x,
## 2 +x, 4 -y, 8 +y and diagonal corners 16 (-x,-y), 32 (+x,-y), 64 (-x,+y),
## 128 (+x,+y), a corner only when neither edge beside it is set (it would
## be covered) - 46 shapes, mirrored in shaders/terrain_codes.gdshaderinc
## (test_terrain checks both sides agree).
const FOAM_CODE := 50
const WASH_CODE := 100
const WASH_GRASS_CODE := 150
const WATER_CODE_ICE := 200
const WATER_CODE := 220
const SHALLOW_CODE := 240
const GRASS_CODE := 253
const SHORE_SHAPES := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 24, 26, 32, 33, 40, 41, 48, 56, 64, 66, 68, 70, 80, 82, 96, 112, 128, 129, 132, 133, 144, 160, 161, 176, 192, 196, 208, 224, 240]
## Neighbour steps for the mask bits, and the edge bits beside each corner.
const SHORE_STEPS := [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
const CORNER_EDGES := [1 | 4, 2 | 4, 1 | 8, 2 | 8]
## Only tiles this close to sea level can border the shoreline (elevation
## changes by under 0.01 per tile) - a cheap gate before shore_shape().
## Sea shallower than SHALLOW_DEPTH gets whitecaps.
const SHORE_ELEVATION_MARGIN := 0.03
const SEA_BODIES := ["ocean", "sea"]
const SHALLOW_DEPTH := 0.008
const GRASS_GROUND := ["grass", "dry_grass"]


## The shore shape of a tile (see SHORE_SHAPES), 0 off the shoreline: which
## neighbours lie across the shoreline from it - ground around a water tile
## (`water`), water around a ground tile. Elevation against sea level
## decides it, so it is exact across chunk borders.
static func shore_shape(world_gen: WorldGen, wx: int, wy: int, water: bool) -> int:
	var mask := 0
	for i in SHORE_STEPS.size():
		if i >= 4 and mask & CORNER_EDGES[i - 4]:
			continue
		var n: Vector2i = SHORE_STEPS[i]
		if (world_gen.elevation(wx + n.x, wy + n.y) < world_gen.sea_level) != water:
			mask |= 1 << i
	return SHORE_SHAPES.find(mask) + 1
