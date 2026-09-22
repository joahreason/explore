# Project State

> This file is maintained by Claude during development.
> It is the persistent handoff point between development sessions.

## Current Objective

Extend the procedural world generator (see `docs/architecture.md`) into a resource-generation system per the phased plan in `docs/resource-generation-plan.md`: natural objects and harvestable/strategic resources emerging from the existing environmental fields, not biome-only spawn rules.

## Current Phase

Phase 4 — Resource Suitability Debug Views (about to start; see `docs/resource-generation-plan.md`).

## Completed

- Phase 0: verified and documented the existing generator pipeline in `docs/architecture.md` (WorldGen.sample() field table, water topology, 3-stage biome classifier, chunk rendering/LOD, seed model), flagged the no-per-tile-object-rendering gap for Phase 7+, identified `scripts/resource_manager.gd` (empty stub) as the ResourceManager integration point.
- Phase 1: added `scripts/environmental_state.gd`, an `EnvironmentalState` typed wrapper with `from_sample(dict)`, built as an *additional* representation alongside the existing Dictionary (decision: `WorldGen.sample()` keeps returning a Dictionary unchanged; all 7 existing callers - biome_classifier, biome_subtype, biome_modifiers, debug_colorizer, heatmap_colorizer, chunk_manager, tile_inspector_panel - are untouched, per the plan's own "introduce a clean representation without breaking existing callers"). Verified via a headless script: same-seed/same-coordinate determinism across multiple WorldGen instances, and field-for-field match between the wrapper and the source Dictionary. PASS.
- Phase 2: added `scripts/resource_definition.gd` (`ResourceDefinition`, `class_name ... extends Resource` with `@export` fields), following WorldGen's own Resource+@export pattern - the project's one existing precedent for a large tunable/inspector-editable data object. Suitability curves use Godot's built-in `Curve` resource (matches the plan's own `temperature_curve.sample(temperature)` language exactly; a fresh Curve defaults to a 0..1 domain/range). Categorical weights (biome/subtype/geology) are plain `Dictionary` exports; an unset curve or missing weight-map entry is defined as neutral (1.0), not 0.0 - see the file's doc comment, this convention matters for Phase 3. Verified via a headless script: instantiation, Curve.sample() behavior, Dictionary round-trip, and a real ResourceSaver.save()/load() round-trip (confirms it behaves as a genuine Godot Resource, not just a plain object). PASS.

- Phase 3: implemented `ResourceManager.get_suitability(state, definition, classified={}) -> float`. Curve-based physical factors (temperature/moisture/fertility/elevation/slope/drainage/erosion) plus geology weight combine via GEOMETRIC MEAN (not a blind product - the plan warns that craters every score); biome/subtype weights are separate multiplicative modifiers applied after; river/shore/disturbance affinities are additive bonuses; final result clamped to [0,1]. Unset curve or missing weight-map entry = neutral 1.0, per the established convention. Verified headless against the plan's own Oak/Iron examples: neutral-when-empty, good vs. hostile temperature, unlisted-biome-is-neutral vs. listed-lower-weight-biome-reduces-score, geology as a hard requirement for Iron, and output clamping. PASS.
- Fixed a real gap in the headless dev workflow: this project's `.godot/global_script_class_cache.cfg` (gitignored, local-only) only gets rebuilt by opening the editor, so any `class_name` added since the last rebuild fails to resolve in ad hoc `--script` test runs. One-time fix documented in "Things To Watch Out For" below; applied this session so `EnvironmentalState`/`ResourceDefinition`/`ResourceManager` all resolve normally now.

## In Progress

- (none - Phase 3 complete, Phase 4 not yet started)

## Next

- Phase 4: resource-suitability heatmap debug views wired into `chunk_manager.gd`'s view-mode dropdown (one per registered resource, e.g. "Oak Suitability"), following the existing heatmap-view pattern (`HeatmapColorizerScript`, blended 65% onto Material).

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
- `ResourceManager` (`scripts/resource_manager.gd`) is currently an empty stub - the identified integration point for Phase 2+ (suitability/density functions), to be consumed by `chunk_manager.gd` the same way `BiomeClassifier`/`HeatmapColorizer` are today.

### Determinism / Data Flow

`WorldGen.configure(world_seed)` seeds 16 `FastNoiseLite` fields off `world_seed + <reserved offset>` (offsets +1..+16 in use, next free +17). Any new resource-distribution noise must reserve a new offset the same way. `WaterTopology` is the only non-pure/cached piece of the existing pipeline; its cache is runtime-only, rebuilt lazily, never serialized.

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

### Known Unverified Areas

- No in-editor/visual check performed yet for this phase (not applicable - no rendering changes).

## Session Handoff

### Last Completed Work

- Phase 0 (`8a50906`), Phase 1 (`83646be`), Phase 2 (`9f8b67c`) committed on branch `resource-generation`. Phase 3 (`ResourceManager.get_suitability()`) written and verified (PASS), about to be committed.

### Next Action

- Begin Phase 4 (resource-suitability heatmap debug views in `chunk_manager.gd`) per `docs/resource-generation-plan.md`.

### Things To Watch Out For

- GDScript `class_name`-based global class resolution fails in headless `--script` runs for any script added since `.godot/global_script_class_cache.cfg` was last built (that cache is gitignored, local-only, and is normally only rebuilt by opening the editor). Fix for a fresh session/checkout: run `Godot.exe --headless --path . --editor --quit-after 3` once to force a rebuild before running any other headless test scripts - confirm with `grep <new_file> .godot/global_script_class_cache.cfg`. Not needed for the real game (editor/export always rebuilds it), only for this project's headless-script verification workflow.
- `WorldGen.sample()`'s Dictionary keys don't always match the plan doc's conceptual field names 1:1 (e.g. actual key is `laplacian`, not `curvature`; actual key is `exposure`, not `wind_exposure`) - `docs/architecture.md` §2 has the verified real key table; use that, not the plan doc's conceptual sketch, when writing code.
