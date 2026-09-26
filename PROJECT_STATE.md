# Project State — updated 2026-09-26, branch review-followup (main @ a46ae53, deployed)

A snapshot for a new session: read it in one go, keep it under 10 KB (CI
checks). History is in `CHANGELOG_DEV.md`, decisions in `docs/decisions.md`.

## Now

- **Focus:** the code review follow-up (`docs/reviews/2026-09-26-code-review.md`).
  All 7 batches are merged into the `review-followup` integration branch.
- **Exact next step:** the user reviews the PR from `review-followup` to
  `main` (never merged by Claude); answer D4 below.
- **After the review:** by-eye tuning passes and Phase 19 (gameplay loop:
  harvest yields from quality / size, inventory, crafting, building). See
  TODO.md "Next".
- `main` (a46ae53, deployed to GitHub Pages) has everything up to the code
  review; the review batches are only on `review-followup`.

## Deployed / verified

"Headless" = test suites and headless PNG renders; "GL" = real GL
Compatibility renderer under Xvfb; "web by eye" = the user looked at the
deployed build.

| Area | State | Verified how |
|---|---|---|
| World fields, water, biomes (incl. Barrens, open oceans) | main | headless |
| Resource placement, guilds, deposits (Phases 7-12) | main | headless; Phase 11/12 scars and species never by eye |
| Canopy shade (13), terrain surface (13.5) | main | headless renders; by-eye check owed |
| Clustering + quality (14), records (15), Debug views (18) | main | headless |
| Chunk streaming, smooth panning (17) | main | headless benches; web by eye ("almost on par with desktop") |
| Harvest + persistence (16) | main | headless; web by eye (right click, reload persistence) |
| Time, tint, time controls | main | headless; tint only numerically |
| Wind, cast shadows, seasons, particles, surf, ground borders | main | GL frames; wind never seen animated by the user |
| Player walking, camera follow, tent sleep | main | headless (test_player, test_camera_touch) |
| Landmarks (camps, stones, ruins) | main | headless (test_structures); not tuned by eye |
| Footsteps | main | user listened (third version accepted) |
| Mobile: pinch-lift fix, on-screen keyboard | main | headless only; user to confirm on a phone |
| Deployed sprites, coasts, Farming Potential, Deposits views | main | not yet looked at on the web build |
| Review batches 1-7 (safety net, web stalls, fixes, F5 reload, F3 overlay, module split, docs, perf, cleanups) | review-followup | full suite green; F5 / F3, W6 URL seed and focus-loss save, W1 / W2 and the P2 marker cost not tried in a real window or browser |

## Open questions for the user

- Landmarks: should walls block walking? Should structures cast shadows?
  Which natural features next (volcanoes, hot springs, oases)?
- Forests roughly doubled with Phase 14 stands: too dense? (lever:
  `canopy_trees` base_density / cover cap)
- Should sleep state be saved? Should sound get a volume setting / mute?
- Phase 17 leftovers (multi-worker, LOD / aggregation, cheaper density,
  flood-fill splitting, merged overlay borders): each needs agreement.
- Textured ground was parked by the user: still parked?
- Phase 19 scope once the review is merged.
- Review D4: must one seed give the identical world on desktop and web?
  If so, add a `?selftest=snapshot` mode that prints the snapshot hashes to
  the browser console (nothing checks this today).

## Known issues

- A single `sample()` can cost ~15-40 ms when it triggers a WaterTopology
  flood fill (first touch of a 64x64 open-water region): a web hitch.
- Web (no threads): a cold World view takes ~1300 frames to fill 81 chunks
  at 5 ms per frame (the screen itself fills in about the first tenth).
- Cold full rebuilds got heavier with ground materials (~50 us per tile):
  fill time only, not smoothness (tuning-log.md).
- View switches and clicks wait for a running chunk job (up to ~130 ms).
- Two instances of different guilds can occasionally overlap on one tile.
- Terrain first pass: Beach tiles ~50% rock; cold deserts ~10% snow; a
  speckled snow line.
- Placement count is concave in density (tuning-log.md "Standing
  observations").
- Marker rows cost ~55 ms of a 144 ms frame at zoom 0.5 (1080p, Xvfb GL,
  review P2); kept as they are until measured in a real browser (F3).

## Recent changes (last ~10; details in CHANGELOG_DEV.md)

- 2026-09-26 Review batch 7: perf P1-P4 (PR #55); cleanups Q1-Q6, T6, D3, T2
- 2026-09-26 Review batch 6: docs restructure (X2) - this snapshot, CI size check (PR #54)
- 2026-09-26 Review batch 5: chunk_manager.gd split into modules; scripts in folders (PRs #45-#53)
- 2026-09-26 Review batch 4: atomic saves, tap targets, F5 content reload, F3 debug overlay
- 2026-09-26 Review batch 3: small fixes (D2, W6, W5, C1, C2, C5, X4, W3, O1 part)
- 2026-09-26 Review batch 2: web stalls - pick from drawn instances, resumable "Go to" (PR #42)
- 2026-09-26 Review batch 1: safety net - `--import`, fail on errors, water determinism, CI tests (PR #41)
- 2026-09-26 Code review added (PR #40)
- 2026-09-26 Ground borders: bumped tile grid, rounded corners, splotches (2c97bf0, bd8e849)
- 2026-09-25 New art style: 16 px tiles, pivoted sprites, depth sorting, free walking (f0fd74a, cd86787)

## Where to look

- architecture: `docs/architecture.md` · decisions: `docs/decisions.md`
- workflow and gotchas: `docs/dev-workflow.md` · tuning numbers: `docs/tuning-log.md`
- plan: `docs/resource-generation-plan.md` · backlog: `TODO.md`
- history: `CHANGELOG_DEV.md` · review: `docs/reviews/2026-09-26-code-review.md`
