# TODO

Keep this list actionable and current.

## Current Task

- [ ] Code review follow-up (`docs/reviews/2026-09-26-code-review.md`): all 7 batches merged into `review-followup`; the PR from `review-followup` to `main` waits for the user's review. D4 is a question for the user (PROJECT_STATE "Open questions").

## Review follow-up

Works through `docs/reviews/2026-09-26-code-review.md`, one batch per session. Each batch PR merges into the `review-followup` branch; one PR from it to `main` at the end.

- [x] 1. Safety net: X1, T5, T3, D1 + T2's order test, T1 - PR #41 (merged into review-followup)
- [x] 2. Web stalls: W2, W1 - PR #42 (merged into review-followup)
- [x] 3. Small fixes: D2, W6, W5, C1, C2, C5, X4, W3, unused PNG from O1 - merged into review-followup
- [x] 4. Before feature work: C3, C4, X3, W4 - merged into review-followup
- [x] 5. chunk_manager.gd split, §4.1 steps 1-9 (A2 in view modes, A3 in content, A4 and T4 throughout, O1 folders in step 9) - PRs #45-#53 (merged into review-followup)
- [x] 6. Docs restructure: X2, per §4.2 - PR #54 (merged into review-followup)
- [x] 7. Remaining: P1, P3, P4, P2 (measured, kept) - PR #55; Q1-Q6, T6, D3, T2's coverage additions (merged into review-followup); D4 left as a question for the user

## Next (after the review)

- [ ] Phase 19: gameplay loop (harvest yields from quality / size, inventory, crafting, building - the player learns environmental patterns). Use the Debug views for the open first-pass tuning
- [ ] Phase 13: check shade by eye (Shade view + World view, forest edges and groves); tune shade curves and the softened grass / flower Forest weights (first pass)
- [ ] Phase 13.5: check terrain and sprites by eye (World + Terrain Only views); tune material curves / colours (first pass: Beach tiles ~50% rock, cold deserts ~10% snow, speckled snow line)
- [ ] Phase 14: check the clustered World view (tree stands, rock formations, ore groups) and the Quality view by eye; tune `canopy_trees` base_density / cover cap if forests feel too dense (tree counts roughly doubled); quality tiers and curves are untuned for gameplay
- [ ] Landmarks: check camps, standing stones and ruins by eye (Go to... menu); tune frequencies/stamps; decide whether walls block walking and structures cast shadows; next natural features (volcanoes, hot springs, oases)

- [ ] Phase 11/12: check scars and new species by eye in the web build (Succession + Resources views); tune pioneer/ground cover/deadwood abundance
- [ ] Concave placement count (density 0.25 -> ~half of peak instances) - revisit once guilds define density; the plan's optional `density_curve` is the lever

- [ ] Look at the deployed web build (sprites, coasts, Farming Potential, Deposits) - so far only headless renders
- [ ] Web build by eye, beyond the line above: wind animation, day/night tint; after the review merge also F5 reload, F3 overlay, W6 (seed in the URL, save on focus loss), hover / tap picking and "Go to" on web
- [ ] Phone checks (user): the pinch-lift fix; the on-screen keyboard for the seed field (iOS / Android)
- [ ] Phase 9: iron / copper / coal abundance and outcrop counts are first pass, not balanced against gameplay
- [ ] Subtype weights are still label-based - expose BiomeSubtype scores when a resource leans on subtypes (plan Phase 3 amendment)

## Later

- [ ] Phase 17 leftovers (parked 2026-09-23): multi-worker throughput, LOD/aggregation, cheaper per-chunk density, WaterTopology flood-fill spike, merged overlay border segments
  - Each needs agreement before starting; details in CHANGELOG_DEV.md, Phase 17
- [ ] Terrain fill time, if it matters (web startup places resources too): a leaner suitability path for ground (`get_suitability` allocates arrays per call, x12 materials per tile), or skip materials whose required curves are cheaply 0
- [ ] Landmarks beyond static: interaction, loot, saving
- [ ] Hidden deposits stay field-only until a mechanic (prospecting / mining) needs them

## Bugs

- [ ] Two instances of different guilds can occasionally share a tile and overlap

## Technical Debt

- [ ] Stale code comments left by the docs-only batch 6: `tests/bench_views.gd`'s header says its numbers are in PROJECT_STATE.md (now `docs/tuning-log.md`); `scripts/world/world_session.gd` mentions `_gen_mutex` (now `GenerationContext.mutex`); `scripts/world/chunk_manager.gd`'s header says the art tileset isn't used

## Ideas

- [ ] More shade correlations: shade for pioneers, a shade-dependent species (ferns), berries toward forest edges
- [ ] Quality beyond trees / berries / ore (rocks, shrubs); quality shown in the World view (tint / size); stand mode for shrubs or wetland plants
- [ ] Barrens subtypes; more Barrens plants from unused sheet sprites ((18,9) rabbitbrush, (11,9) needlegrass, (14,5) cushion plant)
- [ ] Sound volume / mute; save the sleep state

---

## Rules

- Keep tasks small enough to complete in a focused development session.
- Do not turn speculative ideas into active tasks prematurely.
- Remove completed tasks rather than leaving a large historical checklist.
- Put important decisions in `docs/decisions.md` and history in `CHANGELOG_DEV.md`, not here.
- This is the only backlog: PROJECT_STATE.md links here instead of keeping its own list.
