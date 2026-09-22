# TODO

Keep this list actionable and current.

## Current Task

- [ ] Phase 3: `ResourceManager.get_suitability(state, resource) -> float` (fill in `scripts/resource_manager.gd`, currently an empty stub)

## Next

- [ ] Phase 4: resource-suitability heatmap debug views in `chunk_manager.gd`'s view-mode dropdown

## Later

- [ ] Phase 5: deterministic per-resource distribution/patch noise (new reserved seed offsets, next free is +17)
- [ ] Phase 6: density formula + debug view
- [ ] Phase 7: spatial placement (Poisson-disc/blue-noise) - note this needs a new per-chunk object-instancing render path (`docs/architecture.md` §7 flags there is currently none)
- [ ] Phase 8: first playable resources (trees, rocks, berries)

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
