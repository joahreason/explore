# Generator Architecture (Phase 0 of the resource-generation plan)

This document is the Phase 0 deliverable from `docs/resource-generation-plan.md`: a description of how the existing generator/rendering pipeline actually works today (verified against source, not summarized from memory), plus the identified integration point for the new `ResourceManager` and a flagged gap that later phases will need to address.

## 1. Pipeline overview

```
WorldGen.sample(wx, wy) -> Dictionary   (world_gen.gd)
        ↓
BiomeClassifier.classify_full(sample) -> Dictionary   (biome_classifier.gd + biome_subtype.gd + biome_modifiers.gd)
        ↓
Rendering (chunk_manager.gd)
    - Material / heatmap views -> per-chunk flat-color Image (Sprite2D)
    - Base Biome / Subtype / Modifiers views -> additional drawn-text overlay (Node2D)
```

Both the sampling and classification stages are callable directly, independent of rendering — `chunk_manager.gd`'s `_on_tile_clicked()` calls `_world_gen.sample()` and `BiomeClassifierScript.classify_full()` straight from a click signal, with no Sprite2D/Image involved at all. This confirms generation is queryable without rendering, which the ResourceManager will rely on.

## 2. `WorldGen.sample(wx, wy) -> Dictionary` (`scripts/world_gen.gd`)

Deterministic per `world_seed` (16 independent `FastNoiseLite` fields, each seeded `world_seed + <reserved offset>`, offsets `+1` through `+16`, next free is `+18` - `+17` is reserved as the base for per-resource distribution noise, see §6). Pure per-tile arithmetic **except** the water-body block, which queries `WaterTopology` (§3) — a cached, non-O(1) component.

The returned Dictionary's exact keys, as currently returned (`world_gen.gd:526-558`):

| Key | Type | Notes |
|---|---|---|
| `elevation` | float, ~-1..1 | continent-scale height |
| `slope` | float, ≥0 | magnitude of the elevation gradient |
| `laplacian` | float | signed curvature (concave/convex) |
| `temperature` | float, -1..1 | climate - elevation lapse - sun exposure + micro jitter |
| `moisture` | float, 0..1 | rainfall + orographic + shore + river boost - wind aridity |
| `geology` | int (`Geology` enum: SEDIMENTARY/METAMORPHIC/IGNEOUS/VOLCANIC) | Voronoi rock-type region |
| `hardness` | float, 0..1 | from `GEOLOGY_HARDNESS` |
| `erosion` | float, 0..1 | water+wind erosion, resisted by hardness |
| `deposition` | float, 0..1 | sediment accumulation (concave ground) |
| `soil_fertility` | float, 0..1 | geology fertility bias + moisture + deposition |
| `disturbance` | float, 0..1 | distance-and-age-faded scar intensity |
| `disturbance_type` | String (`"fire"/"flood"/"storm"/"landslide"`) | per-blob, constant across the whole blob |
| `disturbance_age` | float, 0..1 | per-blob, constant across the whole blob |
| `vegetation` | float, 0..1 | temp suitability × moisture × fertility, penalized by exposure/erosion/disturbance |
| `exposure` | float, 0..1 | wind exposure |
| `resource` | float, 0..1 | ridged vein noise × geology resource bias × erosion-exposure gate |
| `water_body` | String (`"none"/"ocean"/"sea"/"lake"/"swamp"/"river"`) | see §3 |
| `water_enclosed` | bool | from `WaterTopology`, only meaningful when `water_body` is `sea`/`lake` |
| `water_area` | int, -1 if not applicable | tile count of the enclosed body |
| `water_compactness` | float | `area / perimeter²`, only meaningful when enclosed |
| `water_connected_to_ocean` | bool | whether an enclosed body found a nearby strait |
| `river` | float, 0..1 | river-line field, gated by elevation band |
| `shore_proximity` | float, 0..1 | 0 unless an actual sub-sea-level tile is nearby |
| `wind_strength` | float, 0..1 | |
| `temp_variation` | float, 0..1 | static annual-amplitude field, no live clock |
| `precip_seasonality` | float, 0..1 | static seasonality field, no live clock |
| `drainage` | float, 0..1 | geology bias + slope - curvature - moisture - shore proximity |
| `fuel_load` | float, 0..1 | vegetation not currently disturbed |
| `fire_risk` | float, 0..1 | dryness × heat × wind × fuel × seasonal-dryness bonus |
| `cave_potential` | float, 0..1 | geology cave bias × moisture |
| `cliff_tendency` | float, 0..1 | hardness × steep slope |

Four geology-keyed constant tables (`GEOLOGY_HARDNESS`, `GEOLOGY_RESOURCE_BIAS`, `GEOLOGY_DRAINAGE_BIAS`, `GEOLOGY_FERTILITY_BIAS`, `GEOLOGY_CAVE_BIAS` — five, not four) drive most of the rock-type-dependent behavior; `resource01` (the `resource` key) already directly encodes `GEOLOGY_RESOURCE_BIAS`, so a `ResourceDefinition`'s `geology_weights` (per the plan's Phase 2) can reuse this field rather than re-deriving it from raw `geology`.

## 3. Water topology (`scripts/water_topology.gd`)

The one genuinely stateful/non-O(1) piece of the generator: a bounded, cached BFS flood-fill (`_flood_fill`, capped at `flood_fill_budget`, default 3500 tiles) that determines whether a wet tile's body is enclosed, and if so its real `area`/`perimeter`/`compactness`, plus a secondary bounded probe (`_probe_ocean_adjacency`, `strait_probe_distance` tiles, 4 cardinal directions from ~30 canonically-sorted boundary samples) to decide Sea (strait-connected) vs. Lake (not). A fill that exceeds the budget is "open/unbounded" and falls back to a separate low-frequency noise field for Ocean-vs-Sea flavor, since a capped fill's shape depends on entry point.

Caching: enclosed bodies memoize every member tile at once (`_cache: Dictionary[Vector2i, Result]`); open/capped bodies memoize by a coarse 64-tile cell (`_coarse_cache`). `WorldGen` holds one `WaterTopology` instance per `configure(seed)` call, recreated whenever the seed changes.

## 4. Biome classification (`biome_classifier.gd`, `biome_subtype.gd`, `biome_modifiers.gd`)

A 3-stage layer purely for debug/inspector labeling — nothing in `WorldGen.sample()` or the render path depends on its output except the label-view overlays and the click-to-inspect panel.

1. **`BiomeClassifier.classify_detailed(sample) -> {base_biome, scores, confidence}`**: water/beach are categorical (from `water_body`/`shore_proximity` directly, no scoring). Land biomes (`Alpine Snow`, `Tundra`, `Badlands`, `Desert`, `Wetland`, `Rainforest`, `Forest`, `Savanna`, `Grassland`, `Plains`) are each scored by a `smoothstep`-based formula over `elevation`/`temperature`/`moisture`/`vegetation`/`erosion`/`slope`, and the highest wins (`Plains` has a constant `0.2` floor so something always wins). `confidence` is the gap between the top two scores.
2. **`BiomeSubtype.classify(sample, base_biome) -> String`**: dispatches to a small (3-5 candidate) scoring function scoped to that specific base biome — Forest, Grassland, Desert, Wetland/Swamp, Beach are currently covered; anything else returns `""`.
3. **`BiomeModifiers.compute(sample) -> Array[String]`**: ~14 independent one-line threshold tests (Cold/Hot, Wet/Dry, Windy, Rocky, Fertile/Poor, Young/Recovering/OldGrowth, FireProne, WellDrained/Flooded), each blind to the others and to the base biome.

`BiomeClassifier.classify_full(sample) -> {base_biome, subtype, modifiers, confidence, scores}` is the combined entry point.

## 5. Rendering & chunk streaming (`scripts/chunk_manager.gd`)

- **Tiling**: `TILE_SIZE = 12` screen px/tile, `CHUNK_SIZE = 16` tiles/chunk edge. World position → tile via `floor(pos / TILE_SIZE)`; tile → chunk via `floor(tile / CHUNK_SIZE)` (`_chunk_of`).
- **Streaming**: `_update_chunks(center, load_radius)` loads any chunk within `load_radius` of the camera-target's chunk and unloads any loaded chunk beyond `load_radius + UNLOAD_BUFFER` (hysteresis). `load_radius` is derived from current zoom + viewport size, floored at `MIN_LOAD_RADIUS = 4`.
- **Per-chunk render, current state (critical for resource-object planning): one `Sprite2D` per chunk, built from one baked `Image`.** `_build_chunk_image()` samples every tile in the chunk (or, at low zoom, a coarser LOD grid — see below) and writes one pixel per tile via `_color_for(sample, wx, wy)` (the world coordinates were added in resource-generation Phase 6, for position-dependent views like resource density's patch noise; `WorldGen.sample()` itself is unchanged). **There are no per-tile `Node` instances anywhere in the current render path** — not even for the tileset (`tileset.tres` + `urizen_onebit_tileset__v2d0*.png` exist in the repo but are unused; see §7).
- **View modes** (`ViewMode` enum, kept in sync with `view_mode_dropdown.gd`): `MATERIAL` (default, continuous color blend, no hard edges), heatmap views (`TEMPERATURE`, `MOISTURE`, `TEMP_VARIATION`, `PRECIP_SEASONALITY`, `DRAINAGE`, `DISTURBANCE_AGE`, `DISTURBANCE_TYPE`, `FUEL_LOAD`, `FIRE_RISK`, `CAVE_POTENTIAL`, `CLIFF_TENDENCY` — each blended 65% onto the Material look via `_color_for`'s lerp, not a full replacement), and label views (`BASE_BIOME`, `SUBTYPE`, `MODIFIERS` — Material-colored base image plus a drawn-text `Node2D` overlay from `_generate_overlay_chunk`, since text can't be baked into a flat pixel image).
- **LOD**: at low zoom, `_current_lod_step()` (from `LOD_THRESHOLDS`) picks a coarser sampling grid (1 sample per 2×2/4×4/8×8 tile block instead of per-tile); the `Sprite2D`'s scale is inflated to compensate so its world-space footprint is unchanged.
- **Click-to-inspect**: `CameraRig`'s `clicked` signal (`world_pos: Vector2`) → `_on_tile_clicked()` → single fresh `sample()` + `classify_full()` call → `TileInspectorPanel.show_info()` (`scripts/tile_inspector_panel.gd`). This is the existing precedent for "query generation data for one tile, on demand, without touching the chunk-image render path" — the same pattern the `ResourceManager` should follow.

## 6. Determinism & seed model

`world_seed` is resolved once in `chunk_manager.gd:_ready()` (`_resolve_world_seed()`): a fixed exported int in the editor, or on web, a `?seed=` URL param (numeric used directly, other text hashed via `String.hash()`), or a fresh `randi()` if no param — see `README.md` for the user-facing seed UI (Randomize/Reload/Enter-to-submit). `WorldGen.configure(world_seed)` seeds all 16 noise fields off of it once per session. Per Rule 1 of the resource-generation plan, new noise follows the same pattern: `world_seed + <a newly reserved offset>`, next free `+18`. Per-resource distribution/patch noise (Phase 5) reserves `+17` (`WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET`) but lives in `ResourceManager.get_patch_modifier()`, not WorldGen: each `ResourceDefinition` gets its own `FastNoiseLite` seeded by `("<world_seed + 17>:<definition.id>").hash()`, so resources are decorrelated from each other and `definition.id` must be unique. These noise objects are cached in a static Dictionary keyed by seed/id/scale - pure derived data, never serialized.

## 7. Flagged gap: no per-tile object rendering exists yet

Everything in `chunk_manager.gd` today renders a chunk as **one flat-color baked Image** — there is no mechanism anywhere in the project for placing/instancing individual `Node`/`Sprite2D` objects at specific tile positions within a chunk, not even for the tileset art, which is present in the repo (`tileset.tres`, `urizen_onebit_tileset__v2d0*.png`) but explicitly not wired up (per `README.md`).

This matters for the resource plan starting at **Phase 7 (Spatial Object Placement)** and **Phase 8 (First Playable Resources: trees/rocks/berries)** — those phases require actually instancing individual objects (a tree sprite at a specific world position), which is a new rendering concept for this project, not an extension of the existing per-chunk image bake. It's not a blocker for Phases 1-6 (suitability/density/patch-noise are pure data, following the same `sample() -> Dictionary`-style pattern as everything else), but it should be treated as its own design decision when Phase 7 starts — likely a new `Node2D` container (parallel to `overlay_root`, e.g. `resources_root`) holding one child node per placed instance per loaded chunk, added/removed alongside chunk load/unload exactly like `_loaded_overlays` is today — rather than assumed to just fall out of the existing `_build_chunk_image` path.

## 8. Identified integration point for `ResourceManager`

A new `scripts/resource_manager.gd` (stub created this phase, see below), following the exact same shape as `BiomeClassifier`: a `RefCounted` with `class_name ResourceManager` and static, stateless functions that take an already-computed `sample: Dictionary` (and, once Stage 2/3 exist, the `classify_full()` result for biome/subtype/modifier weighting) and return a suitability/density value — never recomputing anything `WorldGen.sample()` already provides (Rule 2 of the plan).

Consumers, by phase:
- **Phase 3-4 (suitability + debug views)**: `chunk_manager.gd` gains new `ViewMode` entries (e.g. `RESOURCE_SUITABILITY_OAK`) that call into `ResourceManagerScript` from `_heatmap_color_for()`, exactly like the existing heatmap views call `HeatmapColorizerScript` — no new render path needed, since suitability is just another scalar field to color-map.
- **Phase 5-6 (patch noise + density)**: additional pure functions on the same script/class, still consumed the same way for debug heatmaps. `get_density(state, definition, world_seed, wx, wy, classified)` = `clamp(suitability * clamp(base_density, 0, 1) * get_patch_modifier(), 0, 1)`, surfaced as the `RESOURCE_DENSITY_OAK` ("Oak Density") view with its own amber palette so it can't be confused with suitability's green. Density is always <= suitability.
- **Phase 7+ (spatial placement/instancing)**: this is where a *new* consumer appears — not `_build_chunk_image` (which only ever produces one pixel per tile), but a new per-chunk step (see §7) that queries `ResourceManagerScript` for candidate placements and instances actual nodes. This is later work, flagged here so it isn't a surprise when Phase 7 starts.

`scripts/resource_manager.gd` has been created as an empty stub (class declaration + doc comment only, no logic) to mark this integration point concretely for Phase 1+ to build into.
