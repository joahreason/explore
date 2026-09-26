# TODO

Keep this list actionable and current.

## Current Task

- [ ] Phase 13: check shade by eye (Shade view + Resources view, forest edges and groves); tune shade curves (first pass)
- [ ] Phase 13.5 (on main): check terrain and sprites by eye (World + Terrain Only views); tune material curves/colours (first pass)
- [ ] Phase 14 (Resource Quality and Variants + tree clumps / rock formations / ore clusters, after 13.5): prep notes written (PROJECT_STATE "Phase 14 prep") - settle open questions, implement

## Review follow-up

Works through `docs/reviews/2026-09-26-code-review.md`, one batch per session. Each batch PR merges into the `review-followup` branch; one PR from it to `main` at the end.

- [x] 1. Safety net: X1, T5, T3, D1 + T2's order test, T1 - PR #41 (merged into review-followup)
- [x] 2. Web stalls: W2, W1 - PR (see review-followup history)
- [ ] 3. Small fixes: D2, W6, W5, C1, C2, C5, X4, W3, unused PNG from O1
- [ ] 4. Before feature work: C3, C4, X3, W4
- [ ] 5. chunk_manager.gd split, §4.1 steps 1-9, one per session (A2 in view modes, A3 in content, A4 and T4 throughout, O1 folders in step 9). Steps done: none
- [ ] 6. Docs restructure: X2, per §4.2
- [ ] 7. Remaining: P1, P3, P4, then P2 (using W4's numbers); Q1-Q6, T2's coverage additions, T6, D3, D4

## Next

- [ ] Landmarks: check camps, standing stones and ruins by eye (Go to... menu); tune frequencies/stamps; decide whether walls block walking and structures cast shadows; next natural features (volcanoes, hot springs, oases)

- [ ] Phase 11/12: check scars and new species by eye in the web build (Succession + Resources views); tune pioneer/ground cover/deadwood abundance
- [ ] Concave placement count (density 0.25 -> ~half of peak instances) - revisit once guilds define density; the plan's optional `density_curve` is the lever

- [ ] Look at the deployed web build (sprites, coasts, Farming Potential, Deposits) - so far only headless renders
- [ ] Subtype weights are still label-based - expose BiomeSubtype scores when a resource leans on subtypes (plan Phase 3 amendment)

## Later

- [ ] Phase 17 leftovers (parked 2026-09-23): multi-worker throughput, LOD/aggregation, cheaper per-chunk density, WaterTopology flood-fill spike, merged overlay border segments


## Bugs

- [ ]

## Technical Debt

- [ ]

## Ideas

- [ ]

---

## Rules

- Keep tasks small enough to complete in a focused development session.
- Do not turn speculative ideas into active tasks prematurely.
- Remove completed tasks rather than leaving a large historical checklist.
- Put important architectural decisions in `PROJECT_STATE.md`, not here.
