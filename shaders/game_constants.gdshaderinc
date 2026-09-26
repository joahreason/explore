// Game-wide values from scripts/game_constants.gd, set on every material by
// GameConstants.apply_to(). No defaults on purpose: a material that missed
// apply_to() shows it at once instead of drawing with a stale number.

// World pixels per tile (GameConstants.TILE_SIZE).
uniform float tile_px;
// Cast-shadow height encoding (GameConstants.SHADOW_HEIGHT_SCALE).
uniform float shadow_height_scale;
