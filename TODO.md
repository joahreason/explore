# TODO

Keep this list actionable and current.

## Current Task

- [ ] Phase 11: disturbance and ecological succession

## Next

- [ ] Concave placement count (density 0.25 -> ~half of peak instances) - revisit once guilds define density; the plan's optional `density_curve` is the lever

- [ ] Look at the Resources view (incl. Phase 10 wetland plants / willows) and the rebalanced biomes in the real game / web build - so far only headless renders
- [ ] `tests/resource_by_biome.gd` samples one climate zone per seed (600x600 around origin) - widen to a stride-sampled large area
- [ ] Subtype weights are still label-based - expose BiomeSubtype scores when a resource leans on subtypes (plan Phase 3 amendment)

## Later

- [ ] Placement view switch hitch (Oak ~2s, Tree Placement ~5.7s, Resources ~8.6s cold for 81 chunks headless) - revisit if it bites on web, otherwise Phase 17

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
