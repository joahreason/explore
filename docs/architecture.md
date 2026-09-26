# Architecture

How the world generator, the resource layer and the world scene work today,
checked against the source. Why things are this way: `docs/decisions.md`.
How they got here: `CHANGELOG_DEV.md`. Numbers: `docs/tuning-log.md`.

## 1. Pipeline overview

```
WorldGen.sample(wx, wy) -> Dictionary          (scripts/gen/world_gen.gd)
        ↓                                        EnvironmentalState.from_sample(): typed view
BiomeClassifier.classify_full(sample)          (biome_classifier.gd + biome_subtype.gd + biome_modifiers.gd)
        ↓
ResourceManager: suitability, density, deposits, shade, quality   (scripts/resources/)
ResourcePlacement: instances from a density field
TerrainSurface: one ground material per land tile                  (scripts/gen/terrain_surface.gd)
        ↓
World scene (scripts/world/): ChunkStreamer -> ChunkBuilder -> ChunkPresenter
    - a baked Image per chunk (terrain or a heatmap), shaded by terrain.gdshader
    - one marker node per chunk for placed resources and landmark parts
    - a drawn-text overlay for the label views
```

Every stage is callable on its own, without rendering: the inspector
(`ChunkManager._on_tile_clicked()`, on `CameraRig`'s `info_clicked`) takes
the generation lock, samples one tile, classifies it, asks the resource layer
for deposits, farming potential, shade, ground and the resource under the
click (`ResourcePicker.resource_at()`), and hands it all to
the inspector panel's `show_info()` (`scripts/ui/tile_inspector_panel.gd`).
Any new on-demand query follows the same pattern.

Folders (review O1): `scripts/gen/` samples and classifies the world (WorldGen, biomes, water, terrain surfaces, landmark sites); `scripts/resources/` holds the resource model (definitions, guilds, suitability, placement, quality); `scripts/world/` is the world scene (ChunkManager and its modules, the player, camera, clock, session and saves); `scripts/render/` draws (chunk overlays and markers, heatmap colours, day/night, shadows, wind, seasons, effects); `scripts/ui/` holds the controls; `scripts/game_constants.gd` stays at the top as the one shared constants file. Data: `resources/species/` (guild members), `resources/guilds/`, `resources/deposits/`, `resources/terrain/`, `resources/quality/`, `resources/structures/`, with `world_content.tres` and `farmland.tres` at the top.

The world scene's modules (review §4.1), all in `scripts/world/`:

| Module | Job |
|---|---|
| `chunk_manager.gd` (`ChunkManager`, the World node) | Facade: seed, view mode, input, player and tent, harvest, debug resource, content reload; owns the modules below |
| `generation_context.gd` (`GenerationContext`) | The WorldGen, landmark sites and per-seed generation caches, behind one mutex |
| `chunk_builder.gd` (`ChunkBuilder`) | One chunk's content as data: image, label grids, placements; in small steps |
| `chunk_streamer.gd` (`ChunkStreamer`) | Which chunks the camera needs, LOD, the job queue, the worker thread |
| `chunk_presenter.gd` (`ChunkPresenter`) | Main thread: turns finished jobs into sprites, overlays and marker nodes |
| `resource_picker.gd` (`ResourcePicker`) | What placed resource is under a point (inspector, hover, harvest) |
| `world_travel.gd` (`WorldTravel`) | "Go to" searches for biomes and landmarks |
| `world_session.gd` (`WorldSession`) | The clock, saved changes and the tent for the current seed |
| `view_modes.gd` (`ViewModes`) | Every view in one table (`VIEWS`): label, colouring, layers, flags |
| `world_content.gd` (`WorldContent`), `world_layer.gd` | What the world is made of, as data (`resources/world_content.tres`) |
| `terrain_codes.gd` (`TerrainCodes`) | Tile codes the terrain shader reads, shore shapes |
| `navigation.gd` (`Navigation`) | Pure A*, path smoothing, nearest walkable tile |
| `world_changes.gd`, `game_clock.gd`, `player.gd`, `camera_rig.gd` | Saves, in-game time, the player, the camera |

The scene (`world.tscn`, draw order top to bottom): `World` (ChunkManager) >
`Chunks` (terrain sprites), `ShadowLayer` (cast shadows), `Resources`
(y-sorted marker nodes and `Player`), `CloudShadows`, `AmbientParticles`,
`HoverHighlight`, `Overlay` (label views), `DayNight`, `CameraRig`, and the
`UI` CanvasLayer (seed field, dropdowns, `TimeControls`, `ClockLabel`,
`PositionLabel`, `PerfOverlay`, `TileInspector`).

## 2. `WorldGen.sample(wx, wy) -> Dictionary` (`scripts/gen/world_gen.gd`)

Deterministic per `world_seed` (noise seeds: §6). Pure per-tile arithmetic
**except** the water-body block, which queries `WaterTopology` (§3), a
cached, non-O(1) component.

The returned Dictionary's keys (the `return {` at the end of `sample()`):

| Key | Type | Notes |
|---|---|---|
| `elevation` | float, ~-1..1 | continent-scale height: a large base (oceans and landmasses thousands of tiles across, ~85% land) plus ridges - full mountains on high ground, hills only (raise, never dip below `lowland_ridge_level`) in the lowlands, faded out just below the coast so oceans are open water; plus scattered lake basins (`_lake` noise above `lake_threshold`, sunk to just under sea level, ~0.1% of the world) |
| `slope` | float, ≥0 | magnitude of the elevation gradient |
| `laplacian` | float | signed curvature (concave/convex) |
| `temperature` | float, -1..1 | climate - elevation lapse - sun exposure + micro jitter (+-0.06) |
| `moisture` | float, 0..1 | rainfall + orographic + shore + river boost - wind aridity |
| `geology` | int (`Geology` enum: SEDIMENTARY/METAMORPHIC/IGNEOUS/VOLCANIC) | Voronoi rock-type region |
| `hardness` | float, 0..1 | from `GEOLOGY_HARDNESS` |
| `erosion` | float, 0..1 | water+wind erosion, resisted by hardness |
| `deposition` | float, 0..1 | sediment accumulation (concave ground) |
| `soil_fertility` | float, 0..1 | geology fertility bias + moisture + deposition |
| `disturbance` | float, 0..1 | distance-and-age-faded scar intensity |
| `disturbance_type` | String (`"fire"/"flood"/"storm"/"landslide"`) | per-blob, constant across the whole blob |
| `disturbance_age` | float, 0..1 | per-blob, constant across the whole blob |
| `succession` | float, 0..1 | recovery stage: 1 − footprint × (1 − `disturbance_age`), footprint = the scar's distance falloff before the age fade. 0 = fresh scar center, the blob's age where it hit fully, exactly 1 outside any scar (so type/age never leak into undisturbed land) |
| `vegetation` | float, 0..1 | cold limit × (1 − heat × dryness) × (moisture × fertility)^`vegetation_water_exponent` (0.5), penalized by exposure/erosion/disturbance - heat only hurts where it is dry |
| `vegetation_potential` | float, 0..1 | `vegetation` before the (1 − `disturbance`) scar penalty - what grows here undisturbed. Vegetation guilds take cover from it; members' `succession_curve` decides what grows on a scar |
| `exposure` | float, 0..1 | wind exposure |
| `resource` | float, 0..1 | ridged vein noise × geology resource bias × erosion-exposure gate |
| `water_body` | String (`"none"/"ocean"/"sea"/"lake"/"swamp"/"river"`) | see §3 |
| `water_enclosed` | bool | from `WaterTopology`, only meaningful when `water_body` is `sea`/`lake` |
| `water_area` | int, -1 if not applicable | tile count of the enclosed body |
| `water_compactness` | float | `area / perimeter²`, only meaningful when enclosed |
| `water_connected_to_ocean` | bool | whether an enclosed body found a nearby strait |
| `river` | float, 0..1 | river-line field, gated by elevation band; >= 0.5 is the river itself, land banks ~0.05-0.5 |
| `shore_proximity` | float, 0..1 | 0 unless an actual sub-sea-level tile is nearby |
| `shore_salinity` | float, 0..1 | share of the shore probes' water that is sea/ocean (open or strait-connected per `WaterTopology`) rather than an enclosed lake; 0 away from any shore |
| `wind_strength` | float, 0..1 | |
| `temp_variation` | float, 0..1 | static annual-amplitude field, no live clock |
| `precip_seasonality` | float, 0..1 | static seasonality field, no live clock |
| `drainage` | float, 0..1 | geology bias + slope - curvature - moisture - shore proximity |
| `fuel_load` | float, 0..1 | vegetation not currently disturbed |
| `fire_risk` | float, 0..1 | dryness × heat × wind × fuel × seasonal-dryness bonus |
| `cave_potential` | float, 0..1 | geology cave bias × moisture |
| `cliff_tendency` | float, 0..1 | hardness × steep slope |
| `rock_exposure` | float, 0..1 | how much bedrock shows: max(erosion-exposure gate, smoothstep on `cliff_tendency` from `resource_cliff_exposure_requirement`); 0 on water. Decides whether a deposit is visible (`ResourceManager.get_exposed_deposit()`) |

Five geology-keyed constant tables (`GEOLOGY_HARDNESS`,
`GEOLOGY_RESOURCE_BIAS`, `GEOLOGY_DRAINAGE_BIAS`, `GEOLOGY_FERTILITY_BIAS`,
`GEOLOGY_CAVE_BIAS`) drive most rock-type-dependent behaviour; `resource`
already encodes `GEOLOGY_RESOURCE_BIAS`.

The key names are the real ones; the plan doc's conceptual names differ in
places (`laplacian`, not `curvature`; `exposure`, not `wind_exposure`).

`EnvironmentalState` (`scripts/gen/environmental_state.gd`) is a typed,
transient view of one sample for the resource layer, built by
`from_sample()` next to the Dictionary (which stays the return type). It
also carries canopy `shade` / `shade_known`, attached lazily by the resource
layer (§7) - shade is not a `sample()` key because it depends on resource
data.

## 3. Water topology (`scripts/gen/water_topology.gd`)

The one stateful, non-O(1) piece of the generator: a bounded BFS flood fill
(`_flood_fill`, capped at `flood_fill_budget`, 3500 tiles) that decides
whether a wet tile's body is enclosed and, if so, its real area, perimeter
and compactness, plus a bounded probe (`_probe_ocean_adjacency`,
`strait_probe_distance` tiles, the four cardinal directions from up to ~30
sorted boundary samples) to decide Sea (strait-connected) vs. Lake. A body
over the budget is open (unbounded) and is Ocean; Sea is only an enclosed
body with a strait to open water, so it is rare.

Determinism (review D1): a body is enclosed exactly when its whole
4-connected component fits the budget, so a fill from any of its tiles gives
the same answer; enclosed bodies memoize every member tile (`_cache`). For
an open body only "open" is kept: every water tile a capped fill visited is
marked in a bitmap per 64x64-tile cell (`_open`), and a later fill stops as
soon as it reaches an open tile. Both rules give the same labels in any
query order. `WorldGen` makes a fresh `WaterTopology` in each
`configure(seed)`. First touch of a large open region costs ~15-40 ms.

## 4. Biome classification (`biome_classifier.gd`, `biome_subtype.gd`, `biome_modifiers.gd`)

A 3-stage layer over the continuous fields. `sample()` never reads it. Its
labels drive the label views, the inspector, the "Go to biome" menu and
ambient particles; its normalized scores are the biome *membership* that
resources' `biome_weights` read (§7).

1. **`BiomeClassifier.classify_detailed(sample) -> {base_biome, scores, confidence}`**: water and beach are categorical (from `water_body` / `shore_proximity`, no scoring). Land biomes (`Alpine Snow`, `Tundra`, `Badlands`, `Desert`, `Barrens`, `Wetland`, `Rainforest`, `Forest`, `Savanna`, `Grassland`, `Plains`) are each scored by a `smoothstep`-based formula over `elevation` / `temperature` / `moisture` / `vegetation` / `erosion` / `slope` / `drainage`, and the highest wins (`Plains` has a constant `0.2` floor so something always wins). Dry, bare land splits by warmth (`BARRENS_TEMP`) into Desert and Barrens. `confidence` is the gap between the top two scores.
2. **`BiomeSubtype.classify(sample, base_biome) -> String`**: a small (3-5 candidate) scoring function per base biome - Forest, Grassland, Desert, Wetland/Swamp, Beach; anything else returns `""`.
3. **`BiomeModifiers.compute(sample) -> Array[String]`**: ~14 independent one-line threshold tests (Cold/Hot, Wet/Dry, Windy, Rocky, Fertile/Poor, Young/Recovering/OldGrowth, FireProne, WellDrained/Flooded), each blind to the others and to the base biome.

`BiomeClassifier.classify_full(sample) -> {base_biome, subtype, modifiers, confidence, scores}` is the combined entry point.

## 5. Chunks: building, streaming, showing

- **Tiling**: `GameConstants.TILE_SIZE = 16` world px per tile (`scripts/game_constants.gd`, the one definition; `ChunkManager.TILE_SIZE` and `Player.TILE_SIZE` alias it, and shaders get it as a uniform from `shaders/game_constants.gdshaderinc`, set by `GameConstants.apply_to()`). `CHUNK_SIZE = 16` tiles per chunk edge. Tile = `floor(pos / TILE_SIZE)`; chunk = `floor(tile / CHUNK_SIZE)`.
- **Streaming**: `ChunkStreamer._update_chunks(center, load_radius)` queues a job for every chunk within `load_radius` of the camera target's chunk that is missing or stale, and unloads chunks beyond `load_radius + UNLOAD_BUFFER` (hysteresis). `load_radius` comes from the zoom and viewport size, floored at `MIN_LOAD_RADIUS = 4` (9x9 = 81 chunks, the benchmarks' default).
- **Chunk jobs**: nothing is generated inside `_update_chunks()`. A job (`ChunkStreamer._run_next_job()`, its steps from `ChunkBuilder.job_steps()`) builds one chunk's content as plain data (image, placement instances per marker layer, label grids), nearest chunk first; the main thread's `ChunkStreamer._apply_results()` hands finished jobs to `ChunkPresenter.show_chunk()` within `APPLY_BUDGET_USEC` per frame. On desktop the jobs run on one worker thread (`ChunkStreamer._worker_loop()`). Without threads (the web export has `thread_support=false`, and GitHub Pages can't send the cross-origin-isolation headers threaded web builds need) they run on the main thread within `INLINE_BUDGET_USEC` per frame, one small step at a time: the image in `IMAGE_BAND_ROWS`-row bands, a label-grid step, `_tile_env()` warm-up bands for the chunks the stack filter reads, `warm_guild_density()` bands before each dense guild placement, one step per (guild, chunk) raw placement, then the assembly - so a ~42 ms Resources chunk spreads over many frames. The worker runs the same steps, minus the warm-ups, back to back. `threaded_generation = false` forces the fallback. View and LOD changes bump `ChunkStreamer._epoch`: every loaded chunk is then stale, keeps showing its old content, and is rebuilt through the same queue; results built for an older epoch are dropped. Tests call `flush_chunk_work()` to finish all queued work synchronously; the worker is idle afterwards, so they can call generation functions directly.
- **Threading rule**: everything generation touches - the WorldGen and its `WaterTopology` cache, the landmark sites, the per-seed caches in `GenerationContext` (`_tile_env()`, `_density_memo()`, `_raw_guild_chunks`, walkability), the view mode and debug resource, `ResourceManager`'s static noise caches - is only used while holding `GenerationContext.mutex` (recursive). `GenerationContext`'s public methods take it themselves; private ones expect it held. The worker holds it per job step; on the main thread `_on_tile_clicked()`, `set_view_mode()`, `regenerate()` and the other generation queries take it (a UI action can wait up to ~130 ms for a running Resources job). `ResourceDefinition.curve_plan`s are built by `WorldContent.prepare()` in `_ready()`, before any thread starts. `ChunkStreamer`'s own queue fields are guarded by `_queue_mutex`. The scene tree is only touched on the main thread (`ChunkPresenter`, `ChunkManager`). One worker, not a pool, because those caches aren't thread-safe. A new generation path on the main thread must take the mutex too.
- **Per-chunk image**: `ChunkBuilder.build_chunk_image()` samples every tile in the chunk (or, at low zoom, a coarser LOD grid) and writes one pixel per tile via `ChunkBuilder.color_for(sample, wx, wy)`. The chunk shows as one `Sprite2D` with `shaders/terrain.gdshader`; there are no per-tile nodes.
- **Terrain surface**: the base colour of every view is `ChunkBuilder.terrain_color()`: water bodies (ocean/sea/lake/river) keep their depth/ice colouring, and every land or swamp tile shows ONE ground material from `TerrainSurface.material_at()` (`scripts/gen/terrain_surface.gd`, data in `resources/terrain/*.tres`, `SurfaceMaterial` extends `ResourceDefinition`): each material's suitability (`ResourceManager.get_suitability()`, curves over EnvironmentalState incl. `vegetation_curve` and `shade`) x its prevalence (`base_density`) x its own patch noise (`cluster_scale` / `cluster_strength`, seed offset +20); highest wins. Colour = base (per geology where given) + two field-driven tints + per-tile brightness jitter. Shade is exact only on a 4-tile lattice (`SHADE_LATTICE`) and bilinearly blended between (`lattice_shade()`, corners via `_tile_env()`); the state used for ground is a fresh one, so interpolated shade never leaks into placement's cached states. Cost ~50-55 us per tile. `ChunkBuilder.surface_at()` gives the material (inspector "Ground" line).
- **Terrain shader** (`shaders/terrain.gdshader`): in the gameplay views (World, Terrain Only) chunk images are RGBA8 with tile codes in alpha (`TerrainCodes`): water `WATER_CODE_ICE`..`WATER_CODE` (200..220) by liquidity (`TerrainSurface.water_liquid()`; frozen water has no code); `SHALLOW_CODE` 240 + 0..7 for shallow open sea (depth below sea level < `SHALLOW_DEPTH`) for whitecaps; `FOAM_CODE` 50 + shape for open sea on the shoreline; `WASH_CODE` 100 + shape for ground on a sea shore (`WASH_GRASS_CODE` 150 + shape for grass); `GRASS_CODE` 253 for grass and dry grass ground. A shape (`TerrainCodes.shore_shape()`) is 1 + the index in `SHORE_SHAPES` (46 entries, mirrored in the shader) of the mask of neighbours across the shoreline - 4 edges plus diagonal corners where neither adjacent edge is set - from elevation vs. sea level, so it is exact across chunk borders; a cheap gate (`SHORE_ELEVATION_MARGIN`) keeps it off most tiles. Surf is coast only (ocean and sea; lakes and rivers stay plain). The shader moves water (waves along the wind, phase-warped by drifting value noise; steady glints on ~10% of tiles; all scaled by liquidity), breaks shallow crests into whitecaps and shoreline water into surf foam, runs swash up the ground beside it, and tints grass by `Seasons.tint("grass")`. With `ground_detail` (set each frame to `is_time_tinted_view()`) ground gets a subtle grain and mottle, and ground borders: every tile edge bumps up to `EDGE_PX` in or out, outer corners are cut along a `CORNER_PX` quarter circle, and some borders between different grounds get a splotch (`edge_blob()`, `BLOB_*`); each pixel belongs to exactly one tile. Land never takes a water tile's colour. To read neighbours across chunk borders each shown image is padded with a 1-texel border (`ChunkPresenter._padded_image()`) that `ChunkPresenter._share_borders()` fills from each loaded same-LOD neighbour on the main thread (the sprite shows `region_rect` = the inside; `build_chunk_image()` and the snapshot hashes are unchanged). Other views bake plain opaque RGB8 images. `hash()` in the shader avoids `sin()`, which broke down far from the origin.
- **View modes** (`ViewModes`: the `ViewMode` enum and the `VIEWS` table; the dropdown lists their labels): `RESOURCES` is the default ("World": terrain + every placed resource), `MATERIAL` is "Terrain Only"; heatmap views (`TEMPERATURE`, `MOISTURE`, `TEMP_VARIATION`, `PRECIP_SEASONALITY`, `DRAINAGE`, `DISTURBANCE_AGE`, `DISTURBANCE_TYPE`, `FUEL_LOAD`, `FIRE_RISK`, `CAVE_POTENTIAL`, `CLIFF_TENDENCY`, and resource fields such as shade, deposits, farming potential, succession, quality) are blended onto the terrain (`HEATMAP_OVERLAY_STRENGTH` 0.65 in `ChunkBuilder`), not a full replacement; label views (`BASE_BIOME`, `SUBTYPE`, `MODIFIERS`) add a drawn-text overlay built from `ChunkBuilder.overlay_grids()`, since text can't be baked into a pixel image. Per-guild and oak debug views stay in the table but out of the dropdown.
- **LOD**: at low zoom `ChunkStreamer.current_lod_step()` (from `LOD_THRESHOLDS`, with `LOD_HYSTERESIS` 5%) picks a coarser sampling grid (1 sample per 2x2 / 4x4 / 8x8 tiles); the `Sprite2D`'s scale compensates so its footprint is unchanged. Markers are skipped above `ChunkBuilder.MAX_PLACEMENT_LOD_STEP` (2).
- **Showing**: `ChunkPresenter.show_chunk()` creates the chunk's sprite or swaps its texture, and replaces its label overlay and marker node. Only label overlays fade in (`FADE_IN_SEC`, review C1); terrain and markers appear at once.
- **"Go to"**: the menu (`biome_travel_dropdown.gd`) calls `travel_to_biome(name)`; `WorldTravel` runs `BiomeFinder` (`scripts/gen/biome_finder.gd`: rings outward on a 32-tile lattice, skipping the patch the player stands in and places already traveled to) or `StructureSites.find()` with its own `WorldGen` copy - so it needs no generation lock - on its own thread, or without threads a slice per frame (`TRAVEL_BUDGET_USEC`, review W1). The menu's first item cancels a running search. The player is moved to the result and chunks stream in around it.
- **Input**: `CameraRig` emits `map_tapped` (left click / tap: walk, and harvest on arrival) and `info_clicked` (right click / long press: the inspector). The camera follows the player loosely (`FOLLOW_ZONE`); wheel zoom is eased, pinch zooms around the finger midpoint; dragging doesn't pan.

## 6. Determinism and seed model

`world_seed` is resolved in `ChunkManager._ready()` (`_resolve_world_seed()`): the exported int on desktop; on web the `?seed=` URL param (numeric used directly, other text hashed with `String.hash()` - `_seed_from_text()`), or a fresh `randi()` that is written into the URL so a refresh keeps it (review W6). On web the seed UI reloads the page with a new `?seed=`; on desktop it calls `regenerate(seed_text)` (via `SeedReload.apply_seed()`), which swaps the seed in place under the generation lock (`GenerationContext.configure()`: `WorldGen.configure()` with a fresh water-topology cache, per-seed caches dropped) and unloads every chunk, which then streams back in. `WorldGen.configure()` tracks "configured" separately from the seed, so any int (even -1) works (review D2).

**Seed-offset registry** (the single source in the docs; it mirrors the comment in `world_gen.gd`). Every noise field is seeded `world_seed + <offset>`:

| Offset | Use | Owner |
|---|---|---|
| +1 .. +13, +15, +16 | WorldGen's own fields: +1 elev_base, +2 elev_ridge, +3 climate, +4 rainfall, +5 wind_strength, +6 wind_dir, +7 geology, +8 disturbance and disturbance_cell (shared), +9 resource_vein, +10 micro, +11 disturbance_warp, +12 river_line, +13 river_warp, +15 temp_variation, +16 precip_seasonality | `WorldGen` |
| +14 | unused (was water_region, removed with the continent-scale oceans) | - |
| +17 `RESOURCE_DISTRIBUTION_SEED_OFFSET` | per-resource patch noise, one `FastNoiseLite` per id seeded by `("<world_seed + 17>:<id>").hash()` | `ResourceManager.get_patch_modifier()` |
| +18 `RESOURCE_PLACEMENT_SEED_OFFSET` | per-resource / per-guild placement rolls | `ResourcePlacement` |
| +19 `DEPOSIT_VEIN_SEED_OFFSET` | per-deposit vein noise | `ResourceManager.get_vein_value()` |
| +20 `SURFACE_PATCH_SEED_OFFSET` | per-material ground patch noise | `TerrainSurface` |
| +21 `LAKE_SEED_OFFSET` | lake basins | `WorldGen` |
| +22 `STRUCTURE_SITE_SEED_OFFSET` | landmark site hashes (position, type, rotation, age, stamp rolls per cell) | `StructureSites` |

Next free: **+23**. New noise reserves a new offset here and in `world_gen.gd`. Noise derived per resource / guild / material id makes resources decorrelated, so ids must be unique (guild ids share the namespace of resource ids). The resource-layer noise objects are cached in static Dictionaries keyed by seed / id / scale - pure derived data, never serialized. `WaterTopology`'s cache is runtime-only and rebuilt lazily. Quality jitter reuses the instance key hash (`ResourcePlacement.instance_roll()`, salt 6) - no offset.

## 7. The resource layer

**Definitions.** `ResourceDefinition` (`scripts/resources/resource_definition.gd`, `Resource` + `@export`) is one resource type's data: suitability curves over EnvironmentalState fields in real units (`ResourceDefinition.CURVES`: each curve's field and its real range; `get_curve_domain_warnings()` checks each domain against that range and the game warns at startup), `required_curves` (the tolerance envelope), categorical weights (`biome_weights`, `geology_weights`, `water_body_weights`, `disturbance_type_weights`), additive affinities, spatial params (`cluster_scale`, `cluster_strength`, `cluster_curve`, `minimum_spacing`, `base_density`), deposit params (`vein_scale` > 0 marks a deposit, `vein_sharpness`, `exposure_field`, `exposure_curve`) and presentation (`sprite_tile` / `sprite_texture`, `sprite_color`, `debug_color`, `sway`, `casts_shadow`, `season_class`). `SurfaceMaterial`, `QualityProfile` and `StructureDefinition` extend it to reuse the suitability machinery. Any land-vegetation definition must set `water_body_weights` to exclude water - `elevation_curve` alone isn't enough, since rivers sit well above `sea_level` (`resources/species/oak.tres` is the worked example).

**Suitability** (`ResourceManager.get_suitability(state, definition, classified)`): categorical weights first (a zero returns 0 at once); then curve factors, where the lowest `required_curves` value multiplies the result and the other curves plus geology weight combine by geometric mean; biome weights apply against the tile's membership (classifier scores `^BIOME_MEMBERSHIP_SHARPNESS`, normalized) unless `strict_biomes` uses the tile's own base biome; subtype weights are label-based (no resource uses them); additive river / shore / disturbance affinities apply only when the core is non-zero; clamped 0..1. An unset curve or missing weight is neutral (1.0). Curves come from a per-definition `curve_plan` built by `ResourceManager.build_curve_plans()` (reset by the setters of every curve and `required_curves` - reassign `required_curves`, don't mutate it). `ResourceManager.explain_suitability()` mirrors it line by line for the Debug views.

**Density and patches.** `get_density()` = suitability x clamped `base_density` x `get_patch_modifier()` (patch noise, contrast-stretched x1.8, optional `cluster_curve`, blended by `cluster_strength`). It is always <= suitability. `get_density_bound()` / `get_guild_density_bound()` give an exact upper bound that lets placement skip candidates cheaply.

**Placement** (`ResourcePlacement`, `scripts/resources/resource_placement.gd`, pure data). `place_in_rect(definition, world_seed, tile_rect, density_fn)` returns `{id, cell, position}` for every instance in the rect: a world-aligned grid of cells `minimum_spacing` tiles wide, one hash-jittered candidate per cell, kept if a per-cell hash roll is below the density at its tile, then thinned so no two are closer than `minimum_spacing` (Matern type II: the higher hash priority wins; the conflict check is the 3x3 cell neighbourhood). Every decision depends only on world coordinates within one cell, so chunks are placed independently with no duplicates or seams. It saturates near 0.3 instances per `minimum_spacing`². `density_fn` is injected, keeping placement a separate layer. `(id, cell)` - for guilds `(guild id, cell)` - is the stable instance key. Hashes are 32-bit integer arithmetic with a sub-2^31 multiplier (no int64 overflow, same on web).

**Guilds** (`ResourceGuild`, `scripts/resources/resource_guild.gd`): competing resources are placed together by `place_guild_in_rect()` - one grid seeded by the guild id, density from `ResourceManager.get_guild_density()` = guild cover (`get_guild_cover()`: `cover_field` through `cover_curve`; `cover_field = ""` = full cover) x guild patch noise (`get_guild_patch_modifier()`) x the best member's score x `base_density`, reshaped by an optional `density_curve`; then a per-cell hash roll against the members' shares `s_i^sharpness / sum_j s_j^sharpness` (`get_species_shares()`) picks each instance's species. Inside a guild, members' own spacing / patch / base_density are ignored. Member scores come from `get_member_scores()`: each member's suitability, or for a deposit member its exposed deposit. With `cover_sets_area` (canopy trees, surface rocks) cover x best score is instead the SHARE of ground in dense stands: `get_stand_membership()` is 1 where the guild's raw patch noise is above the value that share of tiles exceeds (`PATCH_AREA_SHARES` / `PATCH_AREA_THRESHOLDS`, measured quantiles; share 0 admits nothing), faded over `stand_edge`; density = membership x `base_density`. The guilds (`resources/guilds/`):

| Guild | Members | Cover from |
|---|---|---|
| `ore_outcrops` | iron, copper, coal, clay, salt (exposed deposits) | full cover; `density_curve` |
| `surface_rocks` | granite, sandstone, basalt, limestone, shale, gravel, exposed_stone | falling `vegetation` (bare ground shows rock); stands |
| `canopy_trees` | oak, pine, palm, olive, willow, mangrove, young_tree, birch | `vegetation_potential`; stands |
| `wetland_plants` | reed, cattail, saltmarsh_grass | `moisture` |
| `shore_features` | shells, beach_grass, mud | `shore_proximity` |
| `deadwood` | dead_tree, fallen_log, mushrooms | `vegetation_potential` (formerly wooded scars) |
| `shrubs` | berry_bush | `vegetation_potential`; `cluster_curve` thickets |
| `desert_plants` | cactus, sagebrush | full cover (the members' own suitability) |
| `pioneer_plants` | pioneer_grass, fireweed | `vegetation_potential` |
| `ground_cover` | meadow_grass, wild_herbs, wildflowers | `vegetation_potential` |

Members' `succession_curve`s pick the stage on a scar (deadwood and pioneers
on fresh scars, young trees later, mature trees on undisturbed ground).

**The stack.** Guilds share the ground through one priority list, `guilds` in `resources/world_content.tres` (`WorldContent`, review A3; it also lists the World view's layers, deposits, farmland, ground materials and structures), in the table's order. `place_stack_in_rect()` / `place_stack_with()` place each guild on its own grid, then drop an instance if a surviving instance of a higher guild is closer than the sum of their `footprint_radius` values. To stay chunk-safe, each guild is placed in the rect grown by the reach of every guild below it. `GenerationContext` caches each guild's raw per-chunk placement (`_raw_guild_chunks`, valid across view changes) and assembles the grown rects from it. Two more per-seed caches sit under it: `_tile_env()` keeps each tile's EnvironmentalState + `classify_full()` (per chunk, FIFO-bounded by `ENV_CACHE_CHUNKS` = 48, ~5 KB per tile), shared by every guild's callbacks and the density heatmaps, and `_density_memo()` memoizes each guild's density per tile, so a chunk's one-cell candidate ring reuses its neighbour's values. All are pure functions of (seed, tile); `tests/test_placement_snapshot.gd` checks output stays identical. Every view draws from this stack (placed only down to the lowest guild it shows), so the per-guild views show exactly the instances the World view does.

**Deposits** (fields, not instances): `get_deposit_potential()` = suitability (geology affinity, water weights) x district (the deposit's patch noise with a steep `cluster_curve`) x vein (`get_vein_value()`: `pow(1 - |n|, vein_sharpness)`) x base_density; `get_exposed_deposit()` = potential x `get_exposure()` (the definition's `exposure_field` - `rock_exposure` for ores, `river` for clay, `shore_proximity` for salt - through its optional `exposure_curve`). The ore_outcrops guild places the exposed part; the Deposits view shows both. Farmland (`resources/farmland.tres`) is a suitability field only (Farming Potential view, inspector).

**Shade.** Guilds never read each other's instances. The one cross-guild link is canopy shade, a derived per-tile value = the canopy guild's density (`ResourceManager.get_shade()`, source `SHADE_SOURCE`), kept on the tile's EnvironmentalState (`shade` / `shade_known`) and read by members' `shade_curve` like any other field. `get_member_scores()` attaches it for guilds whose members read shade (`ResourceGuild.reads_shade()`: ground cover, deadwood, shrubs), and `GenerationContext._guild_density()` fills it from the canopy density memo first. So it is chunk-independent and only changes guilds *below* the canopy; ground materials read it too. Since shade is the canopy's density, it is ~`base_density` (0.7) inside a stand and 0 in gaps.

**Quality** - a layer after placement that rates instances, never decides them. A definition points at a `QualityProfile` (`scripts/resources/quality_profile.gd`, data in `resources/quality/`: `tree_age` on the seven mature tree species, `berry_yield`, `ore_richness` on the five deposits; `young_tree` has none). `ResourceManager.get_quality(state, definition, seed, wx, wy, roll, classified)` = the profile's suitability over the instance's tile x deposit richness (`richness_from_deposit`: `get_deposit_potential() / base_density`) + `(roll - 0.5) * 2 * jitter`, clamped 0..1; -1 = no profile. `roll` = `ResourcePlacement.instance_roll(inst, seed)`. Tiers (`tier_names` / `tier_thresholds`, `get_quality_tier()`) are for display and gameplay. Quality is computed only for instances that are shown or inspected (`ChunkBuilder.instance_quality()`, from the cached `_tile_env()` state): the inspector's "Quality" line and the `QUALITY` view.

**Gameplay records.** `ResourceInstance` (`scripts/resources/resource_instance.gd`) is one placed object's record - `key` ("<guild id>:<cell>"), resource id, position, quality / tier, size (`base_size` x the profile's `size_by_quality`), health (`max_health` x size) and `harvest_state`. `ChunkManager.get_resource_instance(inst)` builds it on demand (the inspector's `ResourcePicker.resource_at()` adds it as `"entity"`) and applies the player's changes. `WorldChanges` (`scripts/world/world_changes.gd`) holds those changes - `key -> {resource_id, harvest_state}`, re-validated by resource id - plus the time and the player's position, as JSON per seed at `changes_path()` (`user://world_changes/<seed>.json`; written to a temp file and renamed, the previous kept as `.bak`, review C4). `ChunkManager._unchanged()` drops harvested instances when a marker node is made. A harvest (`_on_harvest_clicked()`, when the player reaches the tapped instance) saves and redraws that chunk from `ChunkPresenter.chunk_placements` (no generation). Under a scripted (test) SceneTree the default `changes_dir` resolves to no file.

**Developer tooling.** The `DEBUG_SUITABILITY` / `DENSITY` / `PATCH` / `PLACEMENT` views show `_debug_resource` (a stack member; `set_debug_resource()`, `DebugResourceDropdown`) through `ChunkBuilder.debug_values()` (member score, guild cover, patch or stand membership, best score, species share, density = guild density x share; `DEBUG_PLACEMENT` filters its guild's stack placement to that id); `debug_breakdown()` = `explain_suitability()` + the guild lines, shown by the inspector in Debug views only. **F5** (desktop, `reload_content()`) re-reads every `.tres` under `res://resources` into the loaded instances and rebuilds the chunks (review X3); **F3** or `?debug=1` shows the perf overlay (`scripts/ui/perf_overlay.gd`, review W4).

## 8. Drawing, time and effects

- **Markers**: one `resource_marker_chunk.gd` node (`ResourceMarkerChunk`) per loaded chunk under the y-sorted `Resources` node, made by `ChunkPresenter.marker_node()` from the chunk's placement layers (`ViewModes` / `WorldContent.world_view_layers`). It draws each layer's instances as sprites, or as a marker `Shape` in debug views and for members without art. Sprites come from the Urizen one-bit sheet (`urizen_onebit_tileset__v2d0.png`, 12 px tiles, 1 px margin and separation, as in `tileset.tres`; `sprite_image()` turns a white-on-black tile into white-on-transparent) or from new art in `assets/sprites/` (drawn 1:1, `sprite_texture`), tinted by `sprite_color`, with a baked outline (`outlined_image()`). Each sprite pivots at its bottom middle: its tile centre offset by up to `PIVOT_SPREAD` px, deterministically from where in the tile it was placed (`pivot()`, `pivot_rect()`); structure parts stay on the grid. Depth: each marker node draws in one `_Row` child per pivot y, and `Resources` y-sorts them together with the player, so anything further south draws in front.
- **Picking**: in the World view only what is drawn counts - the frontmost sprite with an opaque pixel under the point (`ResourcePicker`: `_sprite_covers()`, `sprite_drawn()`, `sprite_point()`); debug marker views use the tile / marker reach. Hover and tap pick from what `ChunkPresenter` shows (`_drawn_near()`), never generating (review W2); the inspector's `resource_at()` places the stack around the point.
- **Player** (`scripts/world/player.gd`): taps go to `ChunkManager._on_map_tapped()`, which plans an A* tile path round open water (`Navigation.find_path()`, `MAX_PATH_NODES` 6000, else the closest tile found; frozen water is walkable) over walkability kept per chunk in `GenerationContext` (a byte per tile, recorded as chunk images bake at LOD 1, else sampled; capped at 4096 chunks), string-pulls it into straight legs (`Navigation.smooth_path()`, `walkable_line()`) ending at the tapped point or `STAND_OFF` beside a tapped resource or tent, and the player walks it in real time with a hop and a footstep every `STEP_TILES`. Its position (the feet) is saved per seed; new worlds spawn on the nearest dry tile to the origin.
- **Time** (`GameClock`, `scripts/world/game_clock.gd`, pure logic): total in-game minutes since Year 1 Spring 1 00:00; `MINUTES_PER_SECOND` = 1, four 30-day seasons, new worlds start at 08:00; `light_at(hour)` is a keyframed daylight colour. `WorldSession` owns the clock and saves it with the changes (`time_minutes`, key "time") each in-game hour, on harvest, seed switch, window close, focus loss and pause; while fast, at most every `CLOCK_SAVE_MSEC`. `DayNight` (`scripts/render/day_night.gd`, a CanvasModulate) tints the world - not the UI - in the World and Terrain Only views only (`is_time_tinted_view()`); `ClockLabel` (bottom-left) shows "date · time". `TimeControls` (`scripts/ui/time_controls.gd`) drive `GameClock.rewind()` / `play_pause()` / `fast_forward()`: `rate()` is 0 paused, 1 normal, +-`SPEEDS` (x4, x16, x64). `GameClock.sleep()` fast-forwards to the next night start or dawn while the player sleeps in a camp tent (`TentSleepEffect`).
- **Wind and sway**: `ResourceDefinition.sway` (0 rigid .. 1 grass) reaches `shaders/sway.gdshader` through the sprite draw colour's alpha (`ChunkPresenter.marker_colors()` / `sway_alpha()`: alpha = 1 - sway/2, opaque draws never move); every marker node shares ChunkManager's `sway_material`, whose vertex shader bends only a sprite's top vertices downwind by a gust wave, in whole sprite pixels. `Wind` (`scripts/render/wind.gd`): direction and strength are smooth functions of the in-game minutes; the animation phase advances with real time x the clock rate capped at +-4. GPU-only: no per-frame redraw.
- **Cast shadows**: per `ResourceDefinition.casts_shadow`; `ResourceMarkerChunk.add_shadows()` records each caster in a `_ShadowLayer` parented under World/ShadowLayer (below every chunk's sprites; the player's shadow is there too). `shaders/cast_shadow.gdshader` flattens each silhouette along `cast_dir`, per pixel of height (the sprite's height reaches it through the red channel of the draw colour, `shadow_color()`, scaled by `SHADOW_HEIGHT_SCALE`), bent by the shared wind code (`shaders/wind_bend.gdshaderinc`). `SunShadow` (`scripts/render/sun_shadow.gd`) sets `cast_dir` and `darkness` from the hour: the sun east to west 06:00-18:00, the moon faintly at night, fading at the horizon.
- **Seasons** (`scripts/render/seasons.gd`): per `season_class` ("deciduous", "evergreen", "grass", "flower") a keyframed loop over the year; `ChunkPresenter.sprite_fill()` applies it to World-view sprites and `update_seasons()` redraws loaded markers from stored placements once per in-game day; grass ground takes `Seasons.tint("grass")` in the terrain shader.
- **Ambient particles** (`AmbientParticles`, `scripts/render/ambient_particles.gd`): a pure `weights(env)` rule table (hour, year, wind, temperature, moisture, vegetation, shade, water, biome) for fireflies, pollen, butterflies, leaves, sand and snow; spawned at random visible tiles through `ChunkManager.ambient_env()` (`try_lock` - never waits on generation); capped pool, culled off-view, frozen when paused or rewinding, gameplay views and zoom >= 1 only; fireflies are divided by the night tint so they glow.
- **Other effects**: drifting cloud shadows (`CloudShadows`, `shaders/cloud_shadows.gdshader`: value-noise fbm over world position, drifting along `Wind.direction_at()` at the capped clock rate, gameplay views only, coverage calibrated to the noise's measured distribution), the harvest pop (`scripts/render/harvest_effect.gd`), the desktop hover outline (`scripts/render/hover_highlight.gd`: the sprite's silhouette, `outline_texture()`, swaying with it; `ChunkManager.hover_target()`), footsteps (`assets/sfx/footstep.wav`, made by `tools/generate_sfx.gd`).
- Headless tests can't compile shaders; shader work is checked on the GL Compatibility renderer under Xvfb (dev-workflow.md).

## 9. Landmarks (`scripts/gen/structure_sites.gd`)

Rare, discrete sites - `StructureDefinition` (`scripts/gen/structure_definition.gd`, extends ResourceDefinition; data in `resources/structures/`: camp, standing_stones, ruins) placed by `StructureSites` (pure data). The world is cut into `CELL_SIZE` (64) tile cells; each cell has one candidate centre, jittered by `ResourcePlacement`'s cell hash (seed `world_seed + 22`) but kept `margin` (largest radius + 1) tiles from the cell edge, so every footprint lies inside its own cell and the site affecting a tile is found from the tile's cell alone - chunk-independent and seam-free. At the centre each structure's weight is `frequency x suitability` (the inherited curves, no biome weights; suitability below `min_suitability` counts 0; the generic `wind_exposure_curve` reads `exposure`); a hash roll picks one type or none (`pick_type()`); a structure with `water_within` then needs open water (ocean / sea / lake / river) on 8 probe rays within that distance, else the cell stays empty - a veto after the roll, so the up-to-80-sample probe only runs for picked cells. Rotation (quarter turns) and `age` (in `age_range`) are further cell hashes. The stamp is `parts` (offset, Urizen sheet tile, kind, chance, decay): a part appears when its chance roll passes and survives while its decay roll >= age x decay; free footprint tiles grow `overgrowth_tiles` with probability overgrowth x age x centre vegetation. Consumers (the sites live in `GenerationContext`, under its lock): the **structure mask** - `GenerationContext._guild_density()` / `_resource_density()` return 0 where `is_masked()` (a footprint disc), so no guild places anything there; the World view's marker node draws the parts first (`parts_in_rect()`); the inspector's "Structure" line (`site_at()`); tents (sleeping); and the "Go to..." menu (`StructureSites.find()`: rings of cells outward, nearest site of that type not at the start or already visited, within `FIND_MAX_RADIUS` 3000 tiles, ~1 s). Static only: structures don't block walking or cast shadows yet; no loot or saving.
