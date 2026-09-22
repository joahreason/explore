# Project State

> This file is maintained by Claude during development.
> It is the persistent handoff point between development sessions.

## Current Objective

Extend the procedural world generator (see `docs/architecture.md`) into a resource-generation system per the phased plan in `docs/resource-generation-plan.md`: natural objects and harvestable/strategic resources emerging from the existing environmental fields, not biome-only spawn rules.

## Current Phase

Phase 6 — Resource Density (about to start; see `docs/resource-generation-plan.md`).

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

## In Progress

- (none - Phase 5 complete, Phase 6 not yet started)

## Next

- Phase 6: `density = suitability * base_density * patch_modifier`, normalize/clamp, plus an in-game density debug view (there's no patch/density view mode yet - Phase 5 was validated with headless renders only).

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
- `ResourceManager` (`scripts/resource_manager.gd`) implements `get_suitability(state, definition, classified={}) -> float` - consumed by `chunk_manager.gd`'s `RESOURCE_SUITABILITY_OAK` view mode the same way `BiomeClassifier`/`HeatmapColorizer` are.
- Any land-vegetation `ResourceDefinition` MUST set `water_body_weights` to exclude actual water (`{"none": 1.0, "ocean": 0.0, "sea": 0.0, "lake": 0.0, "river": 0.0}`, swamp optional) - `elevation_curve` alone is not sufficient, since rivers can sit well above `sea_level`. See `resources/oak.tres` for a worked example.

### Determinism / Data Flow

`WorldGen.configure(world_seed)` seeds 16 `FastNoiseLite` fields off `world_seed + <reserved offset>` (offsets +1..+16 in use; +17 reserved for per-resource distribution noise, owned by `ResourceManager.get_patch_modifier()`; next free +18). Any new noise must reserve a new offset the same way. Resource patch noise derives one seed per `ResourceDefinition.id`, so ids must be unique. `WaterTopology` is the only non-pure/cached piece of the existing pipeline; its cache is runtime-only, rebuilt lazily, never serialized.

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
- Phase 4: headless PNG render of Oak Suitability (blended onto Material, 512x512, seed 4242) inspected visually twice (before/after the water-body fix); direct exercise of `chunk_manager.gd`'s real `_color_for()` for the new view mode via an off-tree instance, headless.

### Known Unverified Areas

- Oak Suitability view has not been checked inside the actual Godot editor/running game (only headless PNG renders + direct code-path exercise) - worth a quick look in-editor before Phase 5 changes distribution.

## Session Handoff

### Last Completed Work

- Phase 0 (`8a50906`), Phase 1 (`83646be`), Phase 2 (`9f8b67c`), Phase 3 (`4f019ad`), Phase 4 (`ac62173`), Phase 5 committed and pushed on branch `resource-generation` (tracks `origin/resource-generation`; not merged to `main`, so the live deploy is untouched).

### Next Action

- Begin Phase 6 (resource density + debug view) per `docs/resource-generation-plan.md`, consuming `ResourceManager.get_suitability()` and `get_patch_modifier()`.

### Things To Watch Out For

- GDScript `class_name`-based global class resolution fails in headless `--script` runs for any script added since `.godot/global_script_class_cache.cfg` was last built (that cache is gitignored, local-only, and is normally only rebuilt by opening the editor). Fix for a fresh session/checkout: run `Godot.exe --headless --path . --editor --quit-after 3` once to force a rebuild before running any other headless test scripts - confirm with `grep <new_file> .godot/global_script_class_cache.cfg`. Not needed for the real game (editor/export always rebuilds it), only for this project's headless-script verification workflow.
- `WorldGen.sample()`'s Dictionary keys don't always match the plan doc's conceptual field names 1:1 (e.g. actual key is `laplacian`, not `curvature`; actual key is `exposure`, not `wind_exposure`) - `docs/architecture.md` §2 has the verified real key table; use that, not the plan doc's conceptual sketch, when writing code.
