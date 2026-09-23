# TODO

Keep this list actionable and current.

## Current Task

- [ ] Phase 17 step 2: cut member-suitability cost in `ResourceManager.get_suitability()` (precomputed curve list per definition, invalidated on reassignment) with `test_placement_snapshot` unchanged; then re-profile and pick the next cost (raw `_place` candidates/hashing; Tree view's image pass evicting the env window)

## Next

- [ ] Phase 11/12: check scars and new species by eye in the web build (Succession + Resources views); tune pioneer/ground cover/deadwood abundance
- [ ] Measure the Resources view switch on the web build (only headless timings so far)
- [ ] Concave placement count (density 0.25 -> ~half of peak instances) - revisit once guilds define density; the plan's optional `density_curve` is the lever

- [ ] Look at the deployed web build (sprites, coasts, Farming Potential, Deposits) - so far only headless renders
- [ ] Subtype weights are still label-based - expose BiomeSubtype scores when a resource leans on subtypes (plan Phase 3 amendment)

## Later


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
