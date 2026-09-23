# TODO

Keep this list actionable and current.

## Current Task

- [ ] Phase 12: merge the first pass (branch `claude/phase-11-start-5kl6xx`); check scars and new species by eye in the web build (Succession + Resources views); tune pioneer/ground cover/deadwood abundance

## Next

- [ ] Phase 17 performance (moved up, next after Phase 12): profile the Resources view switch (~11.2s cold headless, 81 chunks, 9 guilds) and chunk placement; fix the largest costs with output unchanged
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
