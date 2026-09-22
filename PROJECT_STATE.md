# Project State

> This file is maintained by Claude during development.
> It is the persistent handoff point between development sessions.

## Current Objective

Extend the procedural world generator (see `docs/architecture.md`) into a resource-generation system per the phased plan in `docs/resource-generation-plan.md`: natural objects and harvestable/strategic resources emerging from the existing environmental fields, not biome-only spawn rules.

## Current Phase

Phase 8 — First Playable Resources (trees, rocks, berries; not started - see `docs/resource-generation-plan.md`).

## Completed

- Phase 0: verified and documented the existing generator pipeline in `docs/architecture.md` (WorldGen.sample() field table, water topology, 3-stage biome classifier, chunk rendering/LOD, seed model), flagged the no-per-tile-object-rendering gap for Phase 7+, identified `scripts/resource_manager.gd` (empty stub) as the ResourceManager integration point.
- Phase 1: added `scripts/environmental_state.gd`, an `EnvironmentalState` typed wrapper with `from_sample(dict)`, built as an *additional* representation alongside the existing Dictionary (decision: `WorldGen.sample()` keeps returning a Dictionary unchanged; all 7 existing callers - biome_classifier, biome_subtype, biome_modifiers, debug_colorizer, heatmap_colorizer, chunk_manager, tile_inspector_panel - are untouched, per the plan's own "introduce a clean representation without breaking existing callers"). Verified via a headless script: same-seed/same-coordinate determinism across multiple WorldGen instances, and field-for-field match between the wrapper and the source Dictionary. PASS.
- Phase 2: added `scripts/resource_definition.gd` (`ResourceDefinition`, `class_name ... extends Resource` with `@export` fields), following WorldGen's own Resource+@export pattern - the project's one existing precedent for a large tunable/inspector-editable data object. Suitability curves use Godot's built-in `Curve` resource (matches the plan's own `temperature_curve.sample(temperature)` language exactly; a fresh Curve defaults to a 0..1 domain/range). Categorical weights (biome/subtype/geology) are plain `Dictionary` exports; an unset curve or missing weight-map entry is defined as neutral (1.0), not 0.0 - see the file's doc comment, this convention matters for Phase 3. Verified via a headless script: instantiation, Curve.sample() behavior, Dictionary round-trip, and a real ResourceSaver.save()/load() round-trip (confirms it behaves as a genuine Godot Resource, not just a plain object). PASS.

- Phase 3: implemented `ResourceManager.get_suitability(state, definition, classified={}) -> float`. Curve-based physical factors (temperature/moisture/fertility/elevation/slope/drainage/erosion) plus geology weight combine via GEOMETRIC MEAN (not a blind product - the plan warns that craters every score); biome/subtype weights are separate multiplicative modifiers applied after; river/shore/disturbance affinities are additive bonuses; final result clamped to [0,1]. Unset curve or missing weight-map entry = neutral 1.0, per the established convention. Verified headless against the plan's own Oak/Iron examples: neutral-when-empty, good vs. hostile temperature, unlisted-biome-is-neutral vs. listed-lower-weight-biome-reduces-score, geology as a hard requirement for Iron, and output clamping. PASS.
- Fixed a real gap in the headless dev workflow: this project's `.godot/global_script_class_cache.cfg` (gitignored, local-only) only gets rebuilt by opening the editor, so any `class_name` added since the last rebuild fails to resolve in ad hoc `--script` test runs. One-time fix documented in "Things To Watch Out For" below; applied this session so `EnvironmentalState`/`ResourceDefinition`/`ResourceManager` all resolve normally now.

- Phase 4: added `resources/oak.tres` (first real `ResourceDefinition` instance) and wired a "Oak Suitability" heatmap view into `chunk_manager.gd`/`view_mode_dropdown.gd`, following the existing heatmap-view pattern exactly (`HeatmapColorizerScript.resource_suitability()`, blended 65% onto Material). Visual validation (headless PNG render, per the plan's own Phase 4 gate: "do not proceed until these maps look believable") caught two real correctness bugs before they shipped:
  1. `elevation_curve` interpolated *up* toward its peak from -1, so deep water still scored 0.3-1.0 - a lake read as highly suitable. Fixed by flattening the curve to 0 at/below sea_level.
  2. Rivers can sit well above sea_level, so the elevation fix alone didn't exclude them - a river tile still read moderately suitable. Fixed generically (not just for oak) by adding `water_body_weights: Dictionary` to `ResourceDefinition` (mirrors `geology_weights` exactly, keyed by WorldGen's `water_body` string) and wiring it into `ResourceManager.get_suitability()`'s geometric-mean core. This stays fully data-driven per Rule 6/Rule 3 - a land plant sets water bodies to 0.0, a future river/shore plant (Phase 10) sets the opposite, with no hardcoded water logic in ResourceManager itself.
  Re-rendered after both fixes: lake, river, and small pond all correctly read as low suitability; land transitions (forest/desert/disturbance-scar boundaries) are smooth with no hard edges. Also verified the real `chunk_manager.gd._color_for()` code path directly (not just the standalone render script), headless.
- Phase 5: added `ResourceManager.get_patch_modifier(definition, world_seed, wx, wy) -> float` (0..1 multiplier, applied on top of suitability in Phase 6, never replacing it). One `FastNoiseLite` per resource, seeded from `("<world_seed + 17>:<id>").hash()` - reserved `WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET = 17` in WorldGen's offset registry (next free now +18) but the noise itself lives in ResourceManager (Rule 4, layer separation), cached in a static Dictionary. Driven by the existing `ResourceDefinition.cluster_scale` (now defined as patch size in tiles, default changed 1.0 -> 32.0; nothing set it before) and `cluster_strength` (0 = uniform 1.0, 1 = full 0..1; modifier = lerp(1, patch, strength)). Simplex FBM output is contrast-stretched x1.8 then clamped so real clearings/dense groves appear (without it FBM rarely leaves ~0.3..0.7). Oak tuned to `cluster_scale = 48`, `cluster_strength = 0.85` after a visual check showed the old 0.5 only produced mottling with no clearings.
- Phase 6: added `ResourceManager.get_density(state, definition, world_seed, wx, wy, classified={}) -> float` = `clamp(suitability * clamp(base_density, 0, 1) * get_patch_modifier(), 0, 1)` - "how much should exist here" vs. suitability's "would it like it here". `base_density` is now `@export_range(0, 1)` and documented as peak density; oak left at the default 1.0 (no tuning evidence to change it yet). The plan's `patch_scale`/`patch_strength` are the existing `cluster_scale`/`cluster_strength` (no duplicate fields); the optional `density_curve` was skipped as not needed. New "Oak Density" view (`RESOURCE_DENSITY_OAK`, amber palette, distinct from suitability's green); to feed patch noise, `chunk_manager.gd`'s `_color_for`/`_heatmap_color_for` now take `wx, wy` (single caller, `_build_chunk_image`). Tuning observation for Phase 7: with oak's suitability mostly 0.6-0.8 and patch strength 0.85, density rarely exceeds 0.6 (28 of 10,776 tiles with suitability > 0.6, seed 4242) - fine for a debug view, but Phase 7 should decide how density maps to placement probability rather than assume 1.0 is commonly reached.

- Phase 7: added `scripts/resource_placement.gd` (`ResourcePlacement.place_in_rect(definition, world_seed, tile_rect, density_fn) -> Array[Dictionary]` of `{id, cell, position}`), a deterministic, chunk-independent Poisson-disc-style placement: world-aligned cells `minimum_spacing` tiles wide, one hash-jittered candidate per cell, accepted if a per-cell hash roll < density at its tile, then hard-core thinned (Matern type II: of two survivors closer than `minimum_spacing`, the higher hash priority wins; 3x3 cell neighborhood). Each instance's fate depends only on world coordinates within one cell, so chunks are placed independently with no duplicates/seams. Rolls are seeded per resource from `world_seed + WorldGen.RESOURCE_PLACEMENT_SEED_OFFSET (18)` + id, using a 32-bit integer hash with a sub-2^31 multiplier (no int64 overflow, same on web). `density_fn` is injected (normally `get_density()`), keeping placement a separate layer (Rule 4). Render path (the §7 design decision): new `Resources` Node2D root in `world.tscn`; one `resource_marker_chunk.gd` node per loaded chunk draws all its instances in one `_draw()`; created/freed with chunk load/unload, view change and LOD change; hidden above `MAX_PLACEMENT_LOD_STEP = 2`. New "Oak Placement" view (`RESOURCE_PLACEMENT_OAK`) = Oak Density heatmap + markers.
  - Bug fixed in `ResourceManager.get_suitability()` (found by Phase 7's placement test): the additive river/shore/disturbance affinities were applied even when a true requirement had zeroed the core score, so oak's `river_affinity = 0.1` put river tiles back at ~0.07-0.10 suitability (and 4 oaks in rivers in a 128x128 area). A zeroed core now returns 0 before affinities. Visually this only changes those previously-faint river tiles in the suitability/density views.

- Oak tuning fix (after Phase 7 deployed, oaks were densest in Tundra/Alpine Snow): `oak.tres`'s temperature and elevation curves were left at Godot's default 0..1 domain while those fields run -1..1, and `Curve.sample()` clamps out-of-domain input to the edge point - so every sub-zero tile (most land; median land temperature is -0.21, Tundra -0.41) got a flat 0.4 temperature score, and land between sea_level (-0.1) and 0 got elevation 0. Fixed with real-unit curves (temperature 0 at <= -0.3; elevation 0 at/below sea_level and above 0.32), plus data that uses fields oak previously ignored: a new erosion curve (Badlands), `shore_affinity = -0.6` (Beach), a dry-end moisture of 0. Deliberately NOT done via more biome weights: a trial with Tundra/Alpine/Desert/Badlands/Beach weights worked numerically but produced speckled edges wherever the per-tile biome label flickers (plan Rule 7); the field-based curves give smooth edges. Added `ResourceDefinition.get_curve_domain_warnings()` (checks each curve's domain covers its field's real range, `CURVE_FIELD_RANGES`), warned at startup by `chunk_manager.gd` - it flags both broken curves in the old oak and nothing in the new one. Result over 4 seeds x 600x600 tiles, oaks/100 tiles, before (seed 4242 only) -> after: Plains 4.3 -> 6.6, Tundra 5.7 -> 1.9 (61% of Tundra tiles now score exactly 0), Alpine Snow 6.3 -> 3.3, Beach -> 1.6, Grassland 0.5 -> 2.8; water still 0.

## In Progress

- (none - Phase 7 complete, Phase 8 not yet started)

## Next

- Phase 8: first playable resources (trees, rocks, berries). Brings the second/third resource types, so it's also where cross-resource collision (tree vs. rock footprint) and real sprites/art instead of debug circles belong.

## Important Architecture

### System Overview

```
WorldGen.sample(wx, wy) -> Dictionary   (scripts/world_gen.gd)
        ↓
BiomeClassifier.classify_full(sample) -> Dictionary   (biome_classifier.gd + biome_subtype.gd + biome_modifiers.gd)
        ↓
Rendering (scripts/chunk_manager.gd) - one baked Image/Sprite2D per chunk, no per-tile Node instances yet
```

Full field-by-field breakdown, water topology algorithm, classifier stages, and chunk/LOD/seed mechanics are documented in `docs/architecture.md` - treat that as the source of truth rather than re-deriving it.

### Important Dependencies

- `EnvironmentalState` (`scripts/environmental_state.gd`) is a typed, transient wrapper the new resource system should consume instead of raw Dictionary string keys. It does NOT replace `WorldGen.sample()`'s Dictionary return - both exist in parallel.
- `ResourceDefinition` (`scripts/resource_definition.gd`, Resource + `@export`) is the per-resource-type data asset (curves + categorical weights + affinities + spatial params). `resources/oak.tres` is the first real instance.
- `ResourcePlacement` (`scripts/resource_placement.gd`) turns a density field into instances; it only sees density through the `density_fn` Callable. `(id, cell)` is a stable per-instance key (intended for Phase 15/16 gameplay state/persistence).
- `ResourceManager` (`scripts/resource_manager.gd`) implements `get_suitability(state, definition, classified={}) -> float` - consumed by `chunk_manager.gd`'s `RESOURCE_SUITABILITY_OAK` view mode the same way `BiomeClassifier`/`HeatmapColorizer` are.
- Any land-vegetation `ResourceDefinition` MUST set `water_body_weights` to exclude actual water (`{"none": 1.0, "ocean": 0.0, "sea": 0.0, "lake": 0.0, "river": 0.0}`, swamp optional) - `elevation_curve` alone is not sufficient, since rivers can sit well above `sea_level`. See `resources/oak.tres` for a worked example.

### Determinism / Data Flow

`WorldGen.configure(world_seed)` seeds 16 `FastNoiseLite` fields off `world_seed + <reserved offset>` (offsets +1..+16 in use; +17 reserved for per-resource distribution noise, owned by `ResourceManager.get_patch_modifier()`; +18 for per-resource placement rolls, owned by `ResourcePlacement`; next free +19). Any new noise must reserve a new offset the same way. Resource patch noise derives one seed per `ResourceDefinition.id`, so ids must be unique. `WaterTopology` is the only non-pure/cached piece of the existing pipeline; its cache is runtime-only, rebuilt lazily, never serialized.

## Important Decisions

- Resource-generation plan doc lives at `docs/resource-generation-plan.md` (pasted in verbatim by the user) - phases/rules there are the authority for this work; do not deviate without flagging it.
- Phase 1 decision (this session): `EnvironmentalState` is an additive typed wrapper, not a replacement for `WorldGen.sample()`'s Dictionary - chosen specifically to avoid a large, risky refactor across 7 existing callers for zero behavior change. Confirmed against the plan's own wording ("introduce a clean representation without breaking existing callers").
- Water bodies use real bounded/cached flood-fill topology (not a cheap local probe) - established in an earlier session, unaffected by this work.

## Known Issues

- None currently blocking.

## Verification

### Last Verified

- Phase 0: headless boot validated (no changes to runtime code, docs-only + empty stub).
- Phase 1: headless script (`scripts/_tmp_test_environmental_state.gd`, temporary - written, run, passed, then deleted, never committed) - RESULT: PASS.

### Checks Run

- Phase 1: same-seed/same-coordinate determinism check across multiple `WorldGen` instances and multiple `sample()` calls; field-for-field match between `EnvironmentalState` and the source Dictionary.
- Phase 2: `ResourceDefinition` instantiation, `Curve.sample()` output, `Dictionary` weight round-trip, and `ResourceSaver.save()`/`load()` round-trip, all headless.
- Phase 3: `ResourceManager.get_suitability()` against the plan's own Oak/Iron worked examples (see Completed above), headless.
- Phase 5: headless script (temp, in the job scratch dir, not committed): same seed -> identical patch field even after dropping the noise cache; different seed -> different; output in [0,1]; different ids decorrelated (|r| ~0.02 for oak/berry/rock); strength 0 -> exactly 1.0; oak's floor = 1 - strength; larger cluster_scale -> smoother field (lag-8 autocorr 0.00 at scale 8 vs 0.87 at 96). PASS. Plus a 384x384 seed-4242 render (suitability | patch | suitability x patch) inspected visually: groves/sparse woodland/clearings, water still excluded. Headless game boot exits cleanly.
- Phase 6: headless script (temp, deleted, not committed), seed 4242: 14/14 PASS - empty definition -> 1.0; base_density scales linearly and clamps (>1, <0); over 384x384 oak tiles density is in [0,1], <= suitability, equals the formula exactly, is 0 wherever suitability is 0, and is repeatable; identical across two fresh WorldGen instances; the real `chunk_manager._color_for()` for `RESOURCE_DENSITY_OAK` matches `get_density()`, and the Material view is unchanged by the signature change. Side-by-side suitability | density render inspected visually: the uniform suitable region breaks into groves/clearings, water and the unsuitable pocket stay dark. Headless game boot exits cleanly.
- Phase 7: headless script (temp, scratch dir, not committed), 14/14 PASS: zero density -> nothing; determinism; per-chunk union == one whole-rect call (no duplicates, nothing missing) for both a synthetic field and real oak; min pairwise spacing >= `minimum_spacing` including across chunk edges and for non-integer spacing (3.5); instances stay in their rect; count increases monotonically with density (873/1884/2939/3437/3626 per 200x200 at 0.1/0.25/0.5/0.75/1.0, spacing 2); different seed/id -> different/decorrelated positions; real oak (seed 4242, 128x128): 0 instances on water or zero-density tiles (this is the check that caught the affinity bug), identical from a fresh WorldGen. Scene-level script loading the real `world.tscn`, 8/8 PASS: no markers in Material; one marker node per loaded chunk in Oak Placement; markers follow chunk streaming after a pan; hidden when zoomed out past the LOD cap, rebuilt when zoomed back in; removed when switching back to Material. 160x160-tile render (real `_color_for()` + chunk-by-chunk placement, chunk grid drawn) inspected visually: denser in high-density patches, sparse in low, none on the river, no visible seams. Headless game boot clean (no errors/warnings).
- Phase 4: headless PNG render of Oak Suitability (blended onto Material, 512x512, seed 4242) inspected visually twice (before/after the water-body fix); direct exercise of `chunk_manager.gd`'s real `_color_for()` for the new view mode via an off-tree instance, headless.

### Known Unverified Areas

- Oak Suitability, Oak Density and Oak Placement views have not been checked inside the actual Godot editor/running game or web build (only headless PNG renders + scene-level scripts under the headless dummy renderer).
- Performance: switching to Oak Placement with 81 chunks loaded took ~1.8s headless (that includes re-baking every chunk's density image, ~256 samples+classifications per chunk, plus ~7ms/chunk of placement). Fine for a debug view on desktop; likely a noticeable hitch on web. Phase 17 territory unless it gets in the way sooner.
- Oak still separates Plains from Badlands (5.1) / Desert (4.5) / Alpine Snow (3.3) less than it should. Two structural causes, both better tackled in Phase 8 than by more per-curve tweaking: (1) `get_suitability()`'s geometric mean means only a true 0 excludes - with ~6 factors a factor of 0.3 costs only ~20%; (2) placement count is concave in density (Matern thinning: density 0.25 already gives ~half the instances of density 1.0), compressing mid vs. high density. The plan's optional `density_curve` (Phase 6) is the natural, data-driven lever for (2).
- Tuning: groves vs. clearings read in the placement, but contrast is mild - oak density rarely exceeds ~0.6, and hard-core thinning saturates around 0.3 instances / spacing^2. Worth revisiting in Phase 8 (base_density / curves / spacing) rather than changing the algorithm.

## Session Handoff

### Last Completed Work

- Phase 0 (`8a50906`), Phase 1 (`83646be`), Phase 2 (`9f8b67c`), Phase 3 (`4f019ad`), Phase 4 (`ac62173`), Phase 5 (`48f8665`), Phase 6 (`3fd943e`) on branch `resource-generation`. Phase 7 was built on top of it on branch `claude/phase-6-continuation-k99sqh` (a cloud session); not yet merged into `resource-generation` or `main`, so the live deploy is untouched.

### Next Action

- Merge/fast-forward `claude/phase-6-continuation-k99sqh` into `resource-generation`, then begin Phase 8 (trees, rocks, berries) per `docs/resource-generation-plan.md`.

### Things To Watch Out For

- Background-job worktrees (`EnterWorktree`) branch from `origin/main` by default, NOT `resource-generation` - immediately run `git checkout -B <worktree-branch> origin/resource-generation` before doing anything else, or none of the resource-generation files will exist. Also `git fetch` first: the local `resource-generation` can lag the remote (it did at the start of the Phase 6 session).
- Cloud (Linux) sessions have no Godot installed: download the CI's version (`Godot_v4.7.2-stable_linux.x86_64.zip` from `godotengine/godot-builds` releases) into the scratch dir, then do the same `--headless --editor --quit-after 30` class-cache rebuild described below before running test scripts (a `--quit-after 3` was too short for a cold cache). Test scripts can live outside the repo (`--script /abs/path.gd`).
- In a fresh worktree, the headless game boot prints `invalid UID: uid://hx4p5eruo1tv ... chunk_manager.gd` - that's the worktree's partial `.godot` UID cache (the `--quit-after 3` editor scan is cut short), not a real problem; the tracked `scripts/chunk_manager.gd.uid` is correct and Godot falls back to the path.
- GDScript `class_name`-based global class resolution fails in headless `--script` runs for any script added since `.godot/global_script_class_cache.cfg` was last built (that cache is gitignored, local-only, and is normally only rebuilt by opening the editor). Fix for a fresh session/checkout: run `Godot.exe --headless --path . --editor --quit-after 3` once to force a rebuild before running any other headless test scripts - confirm with `grep <new_file> .godot/global_script_class_cache.cfg`. Not needed for the real game (editor/export always rebuilds it), only for this project's headless-script verification workflow.
- `WorldGen.sample()`'s Dictionary keys don't always match the plan doc's conceptual field names 1:1 (e.g. actual key is `laplacian`, not `curvature`; actual key is `exposure`, not `wind_exposure`) - `docs/architecture.md` §2 has the verified real key table; use that, not the plan doc's conceptual sketch, when writing code.
