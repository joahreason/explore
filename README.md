# explore

A procedural 2D top-down world generator built in Godot 4.7, deployed as a web build to [joahreason.github.io/explore](https://joahreason.github.io/explore/).

The world is infinite and deterministic per seed: chunks stream in around the camera as you explore, and every tile's terrain, biome, and history are derived from a set of interacting environmental fields (elevation, temperature, moisture, geology, erosion, disturbance, water topology, and more) rather than painted or hand-authored.

## Controls

- **Move**: left-click / tap the ground - the player walks there, around water (frozen water can be crossed); a spot that can't be reached walks to the closest point. The camera follows loosely: the player can move around the middle of the screen before it scrolls along. Dragging doesn't pan
- **Zoom**: scroll wheel (mouse, eased), pinch (touch)
- **Hover** (mouse only): the object a left click would walk to and harvest gets a thin outline
- **Harvest**: left-click / tap a placed resource - the player walks up to it and harvests it (another tap on the way cancels). It disappears and stays gone: harvests, the player's position and the time are saved automatically per world seed (`user://world_changes/<seed>.json`; browser storage on web)
- **Inspect a tile**: right-click / long-press it to open a panel showing the placed resource under the click (e.g. "Oak (Canopy Trees)"), its full generated field data plus classified biome/subtype/modifiers
- **B**: toggle the Base Biome overlay (region outlines + labels)

## UI panel (top-right)

- **Seed field**: shows the seed currently in use; type a seed and press Enter to switch to it (web: reloads the page with it; desktop: regenerates the world in place). On mobile web, tapping it opens the on-screen keyboard; submitting, Randomize, Reload or a tap on the map closes it
- **Randomize**: generates a fresh random seed and switches to it immediately (reload on web, in-place regenerate on desktop)
- **Reload** (web only): forces a fresh page load (useful for standalone/home-screen web app installs that can sit on stale cached files)
- **View mode dropdown**: switches how chunks are rendered (see below)
- **Clock** (bottom-left): in-game date and time, e.g. "Spring 3, Year 1 · 14:05". A day lasts 24 real minutes (1 in-game minute per second); four seasons of 30 days. The World and Terrain Only views are tinted by the time of day (blue night, warm dawn/dusk, untinted midday); data views stay untinted. The time is saved per seed with your harvests
- **Seasons**: deciduous trees and berry bushes turn orange in autumn and bare in winter, conifers and palms stay green, grass goes golden in late summer and pale in winter (sprites and grass ground), drifting over days
- **Ambience** (World / Terrain Only views): water shimmers; particles appear where and when the world supports them - fireflies on warm damp nights, pollen and butterflies over sunny meadows, falling leaves under autumn canopy, blowing sand in dry windy country, snow in cold places and in winter
- **Wind**: plants sway in a drifting wind - grass and flowers most, shrubs less, trees a little, rocks / ore / logs not at all; gusts roll across the ground. The wind runs on the in-game clock (paused = still)
- **Time controls** (above the clock): `<<` rewind and `>>` fast-forward - each press steps through x4, x16, x64 (then back to x4); the middle button pauses / resumes, or returns to normal speed. The clock shows the current mode ("Paused", ">> x16"). Rewinding only turns the clock back (harvests stay), and stops at Spring 1, Year 1, 00:00
- **Position readout** (bottom-left): the tile at the screen center, its chunk, and the zoom - always shown
- **Debug resource** (only in the Debug views): the resource the Debug views show, e.g. "Oak (Canopy Trees)"
- **Go to biome**: pick a biome to move the camera to the nearest place of it; if you are already in that biome, it takes you to the next patch of it instead (repeat to keep hopping onward). Searches up to ~6000 tiles out; says "No <biome> nearby" if none is found

A plain visit with no `?seed=` in the URL gets a new random seed each time; passing `?seed=<anything>` pins it to a specific world (numeric seeds are used directly, other text is hashed to one deterministically).

## View modes

**Debug views** (balancing, Phase 18): *Debug: Suitability / Density / Patch Noise / Placement* show the resource picked in the Debug resource dropdown - its score, its expected density (the guild's density x its species share), its guild's patch or stand value, and its placed instances. Right-clicking a tile in one of them adds a factor-by-factor breakdown to the info panel (every curve with the field value and its factor, required ones marked, the geometric mean, biome/subtype modifiers, affinities, then guild cover, patch/stand value, best member, species share and density).

- **World** (default) - the live game view: the terrain ground (below) with every placed natural object on it (see "What World places" below)
- **Terrain Only** - just the ground: every land tile is one surface material (grass, dry grass, dirt, forest floor, mud, marsh, sand, beach sand, gravel, rock, snow, burnt ground) chosen from its environment and mixed in organic patches, so a grassland has dirt spots and mud by the water and a swamp mixes marsh, mud and grass; colours vary with moisture, cold, geology and so on. Water bodies keep their depth colouring
- **Subtype**, **Modifiers** - text-label overlays over the terrain, naming each region's biome subtype or independent tags (Cold, Wet, FireProne, etc.)
- **Temperature, Moisture, Temp Variation, Precip Seasonality, Drainage, Disturbance Age, Disturbance Type, Fuel Load, Fire Risk, Cave Potential, Cliff Tendency** - heatmap views, each blended on top of the terrain (not a full replacement) so terrain stays visible as context for how the field affects generation
- **What World places** - trees as sprites from the one-bit tileset (oak, olive, willow, pine, palm; tinted by each species' `sprite_color`), ore outcrops (iron, copper, coal) and rocks (granite, sandstone, basalt - by bedrock) as tileset sprites too, as are berry bushes, reeds and cattails; as are clay and salt outcrops and, on coasts, shells, river-mouth mud, beach grass, salt marsh and mangroves. Hidden when zoomed far out.
- **Deposits** - where iron, copper, coal, clay and salt exist underground (dim) vs. show at the surface (bright), with placed outcrops as hexagons.
- **Farming Potential** - how good each tile is for farming: flat, fertile, moist ground, best on river floodplains.

(Base Biome - a region-outline overlay - is available via the `B` key but left out of the dropdown for now in favor of click-to-inspect. The per-resource debug views - Oak Suitability/Density/Placement, Tree Cover, Tree/Rock/Berry Placement - still exist in `chunk_manager.gd` but are left out of the dropdown; re-add them in `view_mode_dropdown.gd` when tuning a resource.)

## Architecture

- **`world_gen.gd`** - the core simulation. `WorldGen.sample(x, y) -> Dictionary` is a (mostly) pure function of tile coordinates that returns ~30 fields: elevation, slope, temperature, moisture, geology/hardness, erosion/deposition, soil fertility, vegetation, disturbance (type/age), drainage, fire risk, cave/cliff potential, water body classification, and more. Every field is deterministic per world seed.
- **`water_topology.gd`** - the one non-O(1) piece of the generator: a bounded, cached flood-fill that gives water bodies real topology (enclosed vs. open, area, connectivity to open ocean) instead of a per-tile noise threshold.
- **`biome_classifier.gd` / `biome_subtype.gd` / `biome_modifiers.gd`** - a 3-stage classifier layered on top of `sample()`'s continuous fields for the debug/inspector views: a scored (not if/elif) base biome, a per-base-biome subtype, and a flat list of independent modifier tags.
- **`chunk_manager.gd`** - infinite chunk streaming (16x16 tiles/chunk). Builds one `Sprite2D` per loaded chunk from whichever color function the current view mode selects, plus an optional text-label overlay for label views. Also handles LOD: at low zoom each chunk samples on a coarser grid (1 sample per 2x2/4x4/8x8 tile block) and the sprite scales back up, since zooming out needs more chunks, not fewer.
- **`camera_rig.gd`** - zoom/pinch, map taps (`map_tapped`) and info (`info_clicked`), following the player loosely (`FOLLOW_ZONE`: still while they are inside it, eased back to its edge past it; `snap_to_player()`), plus filtering so taps over UI panels never get mistaken for map gestures.
- **`player.gd`** - the player: steps tile by tile along a path (`walk()`, `walk_speed` tiles per real second, diagonals included) - its position (the node's pivot) is its feet, the bottom centre of its tile (`feet_point()`), the sprite drawn above; each step glides to the next tile's feet point with a small hop (`HOP_PX`; the cast shadow stays on the ground); `tile()` is the tile it stands on or is stepping onto. `ChunkManager._on_map_tapped()` plans the path (`find_path()`: A* over `is_walkable()` tiles, 8 directions, no corner cutting, `MAX_PATH_NODES`, else the closest tile found; walkability is recorded as chunk images bake at LOD 1, else sampled) and harvests a tapped resource on arrival; `teleport_player()` (biome travel, tests) lands on the nearest dry tile. The position is saved per seed with the changes and time.
- **`terrain_surface.gd` / `resources/terrain/*.tres`** - the ground layer: one data-driven `SurfaceMaterial` per land tile (suitability curves like resources, patch noise, field-driven tints) and water colours.
- **`heatmap_colorizer.gd`** - pure `sample() -> Color` functions for each heatmap view.

The art tileset (`tileset.tres`, `urizen_onebit_tileset__v2d0*.png`) is present but not yet wired up - all current rendering is the flat-color debug visualization described above.

## Running locally

Open the project in Godot 4.7+ and run `world.tscn` (the project's main scene). No import/build step needed for the editor. The seed field and Randomize regenerate the world in place (starting from the `world_seed` exported on the World node); the `?seed=` URL param and the Reload button are web-export-only.

## Deploying

Pushing to `main` triggers `.github/workflows/web-build.yml`, which exports the Web preset with Godot 4.7.2 and deploys it to GitHub Pages automatically. There's no manual export step.
