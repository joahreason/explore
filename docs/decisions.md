# Decisions

One short entry per decision, newest first: date, decision, why, and when to
revisit. The resource plan (`docs/resource-generation-plan.md`) and its
Amendment blocks hold the longer reasoning for plan phases. "My call" means
the developer chose because the user didn't specify.

## 2026-09-26

**Docs layout (review X2).** PROJECT_STATE.md is a snapshot under 10 KB
(checked in CI); history goes to CHANGELOG_DEV.md, decisions here, workflow
and gotchas to dev-workflow.md, numbers to tuning-log.md, backlog only in
TODO.md. *Why:* the 126 KB file could not be read in one go and had
contradictory "current" pointers. *Revisit:* if the snapshot keeps hitting
the limit.

**Review follow-up branch.** Batch PRs merge into `review-followup`, not
`main`; one PR from it to `main` at the end. *Why:* a big refactor lands on
the deployed branch in one reviewed step. *Revisit:* after batch 7.

**Folders (O1).** Player, camera and clock live in `scripts/world/`;
`game_constants.gd`, `world_content.tres` and `farmland.tres` stay at the top
of their folders. *Why:* they belong to the world scene / are shared by
everything. *Revisit:* when a folder grows a second meaning.

**GenerationContext locks itself (§4.1 step 5, C2).** Every public method
takes the mutex; private ones expect it held (the threading rule:
architecture.md §5). *Why:* the threading rule was
convention only, and callers forgot. *Revisit:* with multi-worker streaming
(Phase 17 leftover).

**World content as data (A3).** The guild stack, World-view layers,
deposits, farmland, terrain materials and structures are listed in
`resources/world_content.tres`. *Why:* adding content should not need code.
*Revisit:* -.

**C1: only label overlays fade in.** Terrain and markers appear at once. The
review's recommended option, taken without asking per the batch process.
*Why:* the chunk fade-in never showed, and while it ran it corrupted the
sway / shadow values packed into the sprites' draw colour. *Revisit:* if the user wants chunk fade-in back.

**C4: saves via temp file + rename, previous kept as `.bak`.** *Why:* an
interrupted write left invalid JSON, and loading then silently started empty. *Revisit:* -.

**W2: hover and tap pick from what is drawn.** No placing and no lock on
hover or tap; the click inspector still places. *Why:* picking by placing
stalled the web build for ~0.5 s. *Revisit:* -.

## 2026-09-25

**Tile size 16 px, one source.** `GameConstants.TILE_SIZE` (and the shadow
height scale) is the only definition; shaders get it as a uniform set by
`GameConstants.apply_to()`. *Why:* the new art style; one place to change it.
*Revisit:* if the art style test is dropped.

**Free player movement.** No tile lock: the A* tile path is string-pulled
into straight legs; the exact position is saved. *Why:* smoother walking with
the new art. *Revisit:* if walls need tile-exact movement.

**Landmark cells.** At most one site per 64-tile cell, footprint inside its
cell, type = frequency x suitability at the centre (no biome weights), water
veto after the roll, structure mask zeroes guild density on a footprint.
*Why:* chunk-independent and seam-free from the tile's cell alone; cheap.
*Revisit:* when walls should block walking or structures cast shadows
(open questions), and for interaction / loot / saving.

**Harvest sound removed; harvest pop kept.** User request. *Revisit:* when
sound gets a volume setting.

## 2026-09-24

**Barrens is its own base biome.** Cold, dry, bare land is Barrens, not
Desert; it copies Desert's biome weights except cactus. *Why:* most "deserts"
were cold or snowy with no cacti. *Revisit:* Barrens subtypes; the Desert
"Cold" subtype still labels Desert's cool fringe.

**Oceans are open water; seas enclosed; lakes their own noise.** Unbounded
water is always Ocean; Sea = enclosed with a strait; lakes are basins from
`_lake` noise. *Why:* bigger oceans without shrinking land, fewer seas.
*Revisit:* -.

**Surf on the coast only** (ocean and sea; lakes and rivers stay plain).
User decision. *Revisit:* -.

**Shadows are per resource** (`ResourceDefinition.casts_shadow`), and
`strict_biomes` uses the tile's own base biome. *Why:* per-guild shadow size
was too coarse; cacti strayed past desert edges. *Revisit:* -.

**Testing policy** (user request): run only the suites covering a change;
the full suite only for generation / placement / resource data / shared code.
Details in dev-workflow.md.

**In-game time defaults** (my call): 1 in-game minute per real second, new
worlds at 08:00 Spring 1 Year 1, four 30-day seasons; only World and Terrain
Only are tinted. Time controls: x4 / x16 / x64, rewind moves only the clock.
*Revisit:* when gameplay needs a different pace.

**Player** (user request, my calls on the details): click / tap to move
replaces camera panning; harvest by walking up to a resource; rivers
impassable; resources don't block; walking runs in real time, not on the
game clock. *Revisit:* walls, Phase 19.

**Phase 16 persistence.** Left click / tap = harvest, right click / long
press = info (user). Saving is automatic, no save button (my call).
`WorldChanges` keys on the instance key and re-validates by resource id, JSON
per seed. Harvested objects leave a gap (lower guilds don't fill it); no
regrowth. *Why:* stale changes must never apply to a different object.
*Revisit:* regrowth, yields (Phase 19).

**Phase 15 records on demand.** `ResourceInstance` is built only for
objects that are shown or inspected; size is data only (sprites are not
scaled). User decisions. *Revisit:* Phase 19 yields.

**Phase 14 quality is a layer after placement.** It rates instances, never
decides them; per-instance jitter from the instance key hash
(`instance_roll()`, salt 6), no new noise offset; computed only for shown or
inspected instances. Clustering uses a measured quantile table
(`PATCH_AREA_THRESHOLDS`) so share 0 admits nothing. *Why:* placement and the
snapshot stay unchanged; exact stand shares. *Revisit:* quality for rocks
and shrubs, quality in the World view, gameplay use.

## 2026-09-23

**Phase 13.5: terrain materials as ResourceDefinitions** (user: add a
terrain surface layer before Phase 14). Ground is one discrete material per
tile (`SurfaceMaterial` extends `ResourceDefinition`, reusing the suitability
machinery), mixed by environment + local patches; the averaged Material look
is cut (the user doubts its value); terrain + all placed resources is the
default view; colour only, no sub-tile detail then. Shade is exact on a
4-tile lattice and interpolated between; ground uses a fresh
EnvironmentalState so interpolated shade never reaches placement's cached
states. *Why:* exact shade per tile would ~triple ground cost. *Revisit:*
material curves and colours are first pass.

**Phase 13: shade as canopy density** (the user delegated the open
questions). Shade is ONE derived per-tile value = the canopy_trees guild's
density (`ResourceManager.get_shade()`, source named once as
`SHADE_SOURCE`), not placed tree instances (that would be the forbidden "if
oak then X" and would couple lower guilds to the stack filter). It lives on
`EnvironmentalState` (`shade` / `shade_known`, attached lazily), not in
`WorldGen.sample()`, because it depends on resource data. Young trees and
birch count as canopy. Mushrooms' Forest / Rainforest weights were removed
(shade replaces that proxy); grass and flower Forest weights softened.
Floodplain composition needed no new data. *Revisit:* nothing persists yet;
easy to change.

**Snapshot positions are integer micro-tiles.** *Why:* `%.6f` rounds ties
differently on MSVC and glibc; integers are platform-independent. Keep float
output in tests out of `%f`. *Revisit:* -.

**Phase 17: one worker thread, output identical.** Chunk content is built as
data by one worker (not a pool), because the generation caches aren't
thread-safe; the web build (no threads) runs the same jobs as small steps.
Every step must keep output identical (placement snapshot). Leftovers
(multi-worker, LOD / aggregation, cheaper density, flood-fill splitting,
merged overlay borders) each need agreement. *Why:* smooth panning without
changing the world. *Revisit:* very fast pans or zoomed-out Resources.

**Phase 12: new species join existing guilds** where they compete for the
same slot (birch -> canopy, rock types / gravel / exposed stone ->
surface_rocks, forest mushrooms stay in deadwood); only ground cover got a
new guild. Sedimentary rock is split by environment (drainage / moisture /
deposition), not by new geology classes - WorldGen still has 4. (User: "Go
ahead with Phase 12".) *Revisit:* -.

**Phase 11: succession as one field** (user: "Start phase 11"; design
followed the prep notes). `succession` is one derived sample field, not
per-resource age curves - it gates type / age by the scar footprint once for
every consumer (plan Rule 2). Vegetation guilds take cover from
`vegetation_potential`, so succession curves choose WHICH stage grows on a
scar instead of stacking a second penalty. Stages are data (required
`succession_curve`s), no regeneration code. *Revisit:* nothing persists yet.

**Phase 10: no new field for river mouths; `shore_salinity` for lake vs.
sea.** Mouth species key on river + shore at low thresholds; salinity reuses
`WaterTopology`'s open / strait test. A required `river_curve` confines a
species to banks (unlike the additive `river_affinity`). *Revisit:* -.

**Phase 9: deposits as fields** (the user said to continue without a design
round). Deposits are per-tile fields computed on demand
(`get_deposit_potential()` = exists, `get_exposed_deposit()` = visible), not
placed instances; visible outcrops are placed instances derived from the
exposed field, as a guild whose deposit members score by exposed deposit (no
ore special-casing in placement). Per-ore vein noise lives in
`ResourceManager` like patch noise, and `sample()` only gained the
ore-independent `rock_exposure` (plan Rule 2: one exposure definition). Ores
are not a guild among themselves (they don't compete for one slot).
Abundance and outcrop counts are first pass, not balanced against gameplay.
*Revisit:* hidden deposits stay field-only until a mechanic (prospecting /
mining, Phase 15+) needs them; easy to change - no persistence depends on it.

## 2026-09-22 (Phases 0-8)

**The plan doc is the authority.** `docs/resource-generation-plan.md` was
pasted in verbatim by the user; its phases and rules govern this work.
Deviations are flagged, agreed changes recorded as **Amendment** blocks.

**Plan amendments** (agreed with the user): static resources only, no
animals for now; suitability splits requirements (tolerance envelope) from
preferences and uses biome *membership* (normalized classifier scores)
instead of the argmax label; Phase 8 is built around resource guilds
(environment sets how much, relative suitability sets which species);
persistence keys must survive content changes.

**Guild model.** Guild density = cover (an environment field through a
curve) x base density x guild patch noise x the BEST member's suitability;
species by share `s_i^sharpness / sum`. Members' own spacing / patch /
base_density are ignored inside a guild. *Why:* without the best-member cap,
green tiles no member tolerates (and biomes that should be open) get full
cover; using only the max keeps the member mix from changing the total.

**Guild priority stack** (Phase 8 step 5): outcrops > rocks > trees >
wetland plants > shore features > deadwood > shrubs > desert plants >
pioneers > ground cover (current order in `world_content.tres`). Rocks and
outcrops are geology and were there first; lower guilds fill in around them.
A design choice, easy to flip.

**Continuous fields over labels.** Prefer field curves to biome / subtype
label weights: the per-tile label flickers and gives speckled edges (plan
Rule 7). Subtype weights were removed from every resource. *Revisit:* expose
subtype scores when a resource first depends on subtypes heavily.

**Phase 7 placement.** Deterministic, chunk-independent cell placement with
hard-core thinning (every decision from world coordinates within one cell);
placement is its own layer (`density_fn` injected); one marker node per
chunk, not one node per object. *Why:* no seams or duplicates, cheap to
draw. *Trade-off:* saturates near 0.3 instances / spacing² (tuning-log).

**Phase 5: per-resource noise in ResourceManager.** Patch (+17), placement
(+18) and later vein (+19) noise are seeded per resource id but owned by the
resource layer, not WorldGen. *Why:* layer separation (plan Rule 4). Resource
ids must be unique. The offset registry is in architecture.md §6.

**Phase 3: geometric mean.** Physical curve factors and geology weight
combine by geometric mean; biome / subtype weights multiply after;
affinities add; a zeroed core returns 0 before affinities. Unset curve or
missing weight = neutral 1.0. *Why:* a plain product craters every score.

**Phase 1: EnvironmentalState is additive.** A typed wrapper next to
`WorldGen.sample()`'s Dictionary, not a replacement. *Why:* avoids a large,
risky refactor across 7 callers for zero behaviour change; matches the plan
("introduce a clean representation without breaking existing callers").

**Water bodies use real topology.** A bounded, cached flood fill, not a
cheap local probe (from an earlier session).
