# explore

A procedural 2D top-down world generator built in Godot 4.7, deployed as a web build to [joahreason.github.io/explore](https://joahreason.github.io/explore/).

The world is infinite and deterministic per seed: chunks stream in around the camera as you pan, and every tile's terrain, biome, and history are derived from a set of interacting environmental fields (elevation, temperature, moisture, geology, erosion, disturbance, water topology, and more) rather than painted or hand-authored.

## Controls

- **Pan**: click-and-drag (mouse), one-finger drag (touch)
- **Zoom**: scroll wheel (mouse), pinch (touch)
- **Inspect a tile**: click/tap it (without dragging) to open a panel showing its full generated field data plus classified biome/subtype/modifiers
- **B**: toggle the Base Biome overlay (region outlines + labels)

## UI panel (top-right)

- **Seed field**: shows the seed currently in use; type a seed and press Enter to reload with it
- **Randomize**: generates a fresh random seed and reloads immediately
- **Reload**: forces a fresh page load (useful for standalone/home-screen web app installs that can sit on stale cached files)
- **View mode dropdown**: switches how chunks are rendered (see below)

A plain visit with no `?seed=` in the URL gets a new random seed each time; passing `?seed=<anything>` pins it to a specific world (numeric seeds are used directly, other text is hashed to one deterministically).

## View modes

- **Material** - the default terrain look, a continuous color blend driven by climate/vegetation/geology (no hard biome edges)
- **Subtype**, **Modifiers** - text-label overlays over the Material look, naming each region's biome subtype or independent tags (Cold, Wet, FireProne, etc.)
- **Temperature, Moisture, Temp Variation, Precip Seasonality, Drainage, Disturbance Age, Disturbance Type, Fuel Load, Fire Risk, Cave Potential, Cliff Tendency** - heatmap views, each blended on top of the Material look (not a full replacement) so terrain stays visible as context for how the field affects generation
- **Oak Suitability, Oak Density** - resource-generation debug heatmaps: how much oak would like each tile, and how much should actually grow there (suitability x patch noise)
- **Oak Placement** - the Oak Density heatmap plus a marker for every individually placed oak (deterministic, minimum-spaced; hidden when zoomed far out)
- **Vegetation** - the Material look with every placed natural object: trees (triangles; oak/pine/palm colors), rocks (squares; granite/sandstone/basalt by geology) and berry bushes (circles)
- **Tree Cover, Tree Placement, Rock Placement, Berry Placement** - per-guild debug views: the guild's density heatmap, plus species-colored markers for the placement views

(Base Biome - a region-outline overlay - is available via the `B` key but left out of the dropdown for now in favor of click-to-inspect.)

## Architecture

- **`world_gen.gd`** - the core simulation. `WorldGen.sample(x, y) -> Dictionary` is a (mostly) pure function of tile coordinates that returns ~30 fields: elevation, slope, temperature, moisture, geology/hardness, erosion/deposition, soil fertility, vegetation, disturbance (type/age), drainage, fire risk, cave/cliff potential, water body classification, and more. Every field is deterministic per world seed.
- **`water_topology.gd`** - the one non-O(1) piece of the generator: a bounded, cached flood-fill that gives water bodies real topology (enclosed vs. open, area, connectivity to open ocean) instead of a per-tile noise threshold.
- **`biome_classifier.gd` / `biome_subtype.gd` / `biome_modifiers.gd`** - a 3-stage classifier layered on top of `sample()`'s continuous fields for the debug/inspector views: a scored (not if/elif) base biome, a per-base-biome subtype, and a flat list of independent modifier tags.
- **`chunk_manager.gd`** - infinite chunk streaming (16x16 tiles/chunk). Builds one `Sprite2D` per loaded chunk from whichever color function the current view mode selects, plus an optional text-label overlay for label views. Also handles LOD: at low zoom each chunk samples on a coarser grid (1 sample per 2x2/4x4/8x8 tile block) and the sprite scales back up, since zooming out needs more chunks, not fewer.
- **`camera_rig.gd`** - pan/zoom/pinch, plus filtering so taps/drags over UI panels never get mistaken for map gestures.
- **`debug_colorizer.gd` / `heatmap_colorizer.gd`** - pure `sample() -> Color` functions for the Material look and each heatmap view, respectively.

The art tileset (`tileset.tres`, `urizen_onebit_tileset__v2d0*.png`) is present but not yet wired up - all current rendering is the flat-color debug visualization described above.

## Running locally

Open the project in Godot 4.7+ and run `world.tscn` (the project's main scene). No import/build step needed for the editor; the seed URL-param/reload features are web-export-only and no-op (hidden) elsewhere.

## Deploying

Pushing to `main` triggers `.github/workflows/web-build.yml`, which exports the Web preset with Godot 4.7.2 and deploys it to GitHub Pages automatically. There's no manual export step.
