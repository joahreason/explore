// The tile codes chunk images carry in their alpha, and the shore shapes,
// shared with scripts/world/terrain_codes.gd (TerrainCodes), which bakes
// them. test_terrain parses this file and checks both sides agree (review
// Q2): a mismatch would silently mis-render coasts.
const float FOAM_CODE = 50.0;
const float WASH_CODE = 100.0;
const float WASH_GRASS_CODE = 150.0;
const float WATER_CODE_ICE = 200.0;
const float WATER_CODE = 220.0;
const float SHALLOW_CODE = 240.0;
const float GRASS_CODE = 253.0;
const int SHORE_SHAPES[46] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 24, 26, 32, 33, 40, 41, 48, 56, 64, 66, 68, 70, 80, 82, 96, 112, 128, 129, 132, 133, 144, 160, 161, 176, 192, 196, 208, 224, 240};
