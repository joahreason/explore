# Project State

> This file is maintained by Claude during development.
> It is the persistent handoff point between development sessions.

## Current Objective

Extend the procedural world generator (see `docs/architecture.md`) into a resource-generation system per the phased plan in `docs/resource-generation-plan.md`: natural objects and harvestable/strategic resources emerging from the existing environmental fields, not biome-only spawn rules.

## Current Phase

Phase 2 — Resource Definition system (about to start; see `docs/resource-generation-plan.md`).

## Completed

- Phase 0: verified and documented the existing generator pipeline in `docs/architecture.md` (WorldGen.sample() field table, water topology, 3-stage biome classifier, chunk rendering/LOD, seed model), flagged the no-per-tile-object-rendering gap for Phase 7+, identified `scripts/resource_manager.gd` (empty stub) as the ResourceManager integration point.
- Phase 1: added `scripts/environmental_state.gd`, an `EnvironmentalState` typed wrapper with `from_sample(dict)`, built as an *additional* representation alongside the existing Dictionary (decision: `WorldGen.sample()` keeps returning a Dictionary unchanged; all 7 existing callers - biome_classifier, biome_subtype, biome_modifiers, debug_colorizer, heatmap_colorizer, chunk_manager, tile_inspector_panel - are untouched, per the plan's own "introduce a clean representation without breaking existing callers"). Verified via a headless script: same-seed/same-coordinate determinism across multiple WorldGen instances, and field-for-field match between the wrapper and the source Dictionary. PASS.

## In Progress

- (none - Phase 1 complete, Phase 2 not yet started)

## Next

- Phase 2: `ResourceDefinition` data-driven system (`scripts/resource_definition.gd`).

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

### Known Unverified Areas

- No in-editor/visual check performed yet for this phase (not applicable - no rendering changes).

## Session Handoff

### Last Completed Work

- Phase 0 committed on branch `resource-generation` (commit `8a50906`). Phase 1 (`EnvironmentalState`) written, verified (PASS), about to be committed.

### Next Action

- Begin Phase 2 (`ResourceDefinition` system) per `docs/resource-generation-plan.md`.

### Things To Watch Out For

- GDScript `class_name`-based global class resolution is unreliable in headless `--script` runs in this project (seen before, in this session and prior ones) - use `preload("res://scripts/<file>.gd")` with an explicit const in throwaway test scripts instead of referring to the class_name directly.
- `WorldGen.sample()`'s Dictionary keys don't always match the plan doc's conceptual field names 1:1 (e.g. actual key is `laplacian`, not `curvature`; actual key is `exposure`, not `wind_exposure`) - `docs/architecture.md` §2 has the verified real key table; use that, not the plan doc's conceptual sketch, when writing code.
