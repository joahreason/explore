# Procedural World Resource & Gameplay Generation

## Phased Implementation Plan

> **Amendments.** The original plan text below is kept as written. Design decisions made while implementing it are added as clearly marked **Amendment** blocks in the phase they refine. Scope decision (2026-09-22): this plan covers **static resources only**. Animals and other mobile creatures are out of scope for now.

## Objective

Extend the existing procedural world generator into a playable world-generation framework where natural objects, harvestable resources, and strategic resources emerge from the existing environmental simulation.

The current generator already produces approximately 30 environmental fields from `WorldGen.sample(wx, wy)`, including:

* Elevation
* Slope
* Curvature
* Temperature
* Moisture
* Rainfall
* Wind
* Wind exposure
* Soil fertility
* Drainage
* Erosion
* Deposition
* Geology
* Cave potential
* River state
* Water body
* Shore proximity
* Vegetation
* Fuel load
* Fire risk
* Disturbance type
* Disturbance age
* Resource vein potential
* Biome
* Biome subtype
* Biome modifiers

The goal is to use these existing fields as the foundation for an ecological/resource simulation rather than adding arbitrary biome-based spawning rules.

### Core design principle

Do NOT make resources primarily biome-driven.

Instead:

```text
Environmental State
        ↓
Habitat Suitability
        ↓
Resource Density
        ↓
Spatial Patches
        ↓
Individual Placement
        ↓
Gameplay Objects
```

Biomes and subtypes should act as modifiers to environmental suitability rather than being the sole determinant of resource placement.

---

# Phase 0 — Understand and Preserve the Existing Generator

Before implementing anything:

1. Read the existing world-generation code completely.
2. Identify:

   * `WorldGen.sample()`
   * biome classifier
   * biome subtype system
   * biome modifiers
   * water topology
   * chunk generation/rendering
   * deterministic seed handling
   * existing debug/heatmap rendering
3. Identify how world coordinates map to chunks and tiles.
4. Identify whether chunks are currently generated deterministically and whether generated data can be queried without rendering.
5. Do not rewrite or substantially restructure the existing environmental generator unless necessary.

### Deliverable

Produce a short architecture document describing:

```text
WorldGen.sample()
    ↓
EnvironmentalState
    ↓
Biome classification
    ↓
Rendering
```

and identify the cleanest integration point for:

```text
ResourceManager
```

---

# Phase 1 — Formalize Environmental State

If the current implementation returns an unstructured Dictionary, introduce a clean representation without breaking existing callers.

Conceptually:

```gdscript
EnvironmentalState:
    elevation
    slope
    curvature

    temperature
    moisture
    rainfall

    wind_strength
    wind_exposure

    fertility
    drainage
    erosion
    deposition

    geology
    hardness
    resource_bias
    cave_potential

    river
    water_body
    shore_proximity

    vegetation
    fuel_load
    fire_risk

    disturbance_type
    disturbance_age
    disturbance_intensity

    biome
    biome_subtype
    biome_modifiers
```

The exact implementation should follow the existing project's architecture.

### Requirements

* Preserve deterministic generation.
* Do not introduce per-tile mutable state yet.
* Keep `WorldGen.sample(wx, wy)` effectively pure except for the existing water topology caching.
* Do not duplicate environmental calculations in the resource system.

### Validation

Verify that sampling the same coordinate with the same seed produces identical results.

---

# Phase 2 — Create the Resource Definition System

Create a data-driven `ResourceDefinition` system.

Resources should not have hardcoded spawning logic scattered throughout the generator.

Each resource should define its environmental preferences.

Conceptual structure:

```gdscript
ResourceDefinition:
    id
    category

    base_density

    temperature_curve
    moisture_curve
    fertility_curve
    elevation_curve
    slope_curve
    drainage_curve
    erosion_curve

    biome_weights
    subtype_weights
    geology_weights

    river_affinity
    shore_affinity
    disturbance_affinity

    cluster_scale
    cluster_strength

    minimum_spacing

    placement_type
```

Use whatever resource/data format best matches the existing project.

### Important

Environmental curves should generally produce values between:

```text
0.0 → unsuitable
1.0 → highly suitable
```

Avoid binary conditions whenever possible.

For example, prefer:

```text
temperature_curve.sample(temperature)
```

over:

```gdscript
if temperature > 0.5:
```

This preserves the smooth environmental character of the existing generator.

---

# Phase 3 — Implement Habitat Suitability

Create:

```text
ResourceSystem.get_suitability(wx, wy, resource)
```

Conceptually:

```text
temperature suitability
×
moisture suitability
×
fertility suitability
×
elevation suitability
×
slope suitability
×
drainage suitability
×
erosion suitability
×
geology suitability
×
biome modifier
×
subtype modifier
×
special environmental modifiers
```

The exact formula should be tuned rather than blindly multiplying every factor.

Avoid making a single weak factor reduce every resource to almost zero.

Use a combination of:

* multiplicative factors for true requirements
* weighted modifiers for preferences
* additive contributions where appropriate

### Example

Oak:

```text
temperature: strong
moisture: moderate
fertility: strong
slope: mild preference for gentle terrain
elevation: moderate
forest subtype: strong preference
river: slight preference
```

Iron:

```text
geology: extremely strong
resource vein: extremely strong
erosion/exposure: strong
temperature: irrelevant
moisture: mostly irrelevant
```

### Deliverable

Return a normalized:

```text
0.0 → 1.0 suitability
```

for every resource at any world coordinate.

> **Amendment (2026-09-22, after Phase 7): requirements vs. preferences, and biome membership.** The first implementation combined every curve with one geometric mean. That makes only a true 0 exclusive: with ~6 factors, a factor of 0.3 costs only ~20%, so marginal habitat (Badlands, Desert, Alpine) scored close to good habitat. Two refinements, both still generic and data-driven:
>
> 1. **Split tolerances from preferences.** A `ResourceDefinition` marks some curves as *requirements* (its tolerance envelope), combined multiplicatively or by minimum, so being outside any one of them means absent. The rest stay *preferences*, averaged as now, shaping abundance inside the envelope. This is what the "multiplicative factors for true requirements, weighted modifiers for preferences" guidance above describes.
> 2. **Weight biomes by membership, not by label.** `BiomeClassifier.classify_detailed()` already scores every candidate biome per tile, but only the argmax label is used, and weighting by that label produces speckled edges where it flickers between neighboring tiles (seen when tuning oak). Instead, `biome_weights` are applied against the tile's *normalized biome scores* (a 70% Forest / 30% Plains tile gets a blend), so biome dependence can be strong while staying continuous (Rule 7). Subtypes need their scores exposed the same way. Hard categorical gates remain acceptable where something is genuinely categorical (a mangrove on the Beach/Mangrove subtype, a reed on river tiles; see Rule 6). `ResourceDefinition.strict_biomes` is that gate for biomes: the tile's own base_biome decides instead of the blend (cactus: deserts only).

---

# Phase 4 — Add Resource Suitability Debug Views

Before spawning actual objects, add debug visualization.

For every registered resource, support:

```text
Resource Suitability
```

as a heatmap.

Example:

```text
Oak Suitability
Iron Suitability
Berry Suitability
Rock Suitability
Mushroom Suitability
```

The heatmap should overlay the existing terrain/material view similarly to the current environmental heatmaps.

### Critical validation

Walk across:

* biome boundaries
* biome subtype transitions
* rivers
* coastlines
* mountains
* dry regions
* wet regions
* disturbed areas
* different geological regions

Confirm that suitability changes smoothly and logically.

Do not proceed until these maps look believable.

---

# Phase 5 — Add Deterministic Resource Distribution Noise

Resource suitability determines *where a resource can exist*, but not its local spatial pattern.

Introduce deterministic distribution noise for resources.

Conceptually:

```text
resource suitability
        ×
resource patch noise
        ↓
resource density
```

Each resource should have its own deterministic noise field or deterministic derived seed.

Do not use a single noise field for every resource.

Example:

```text
tree_distribution
berry_distribution
mushroom_distribution
rock_distribution
```

### Requirements

* Same world seed → identical result.
* Different resources must have decorrelated patterns.
* Distribution noise should have configurable scale.
* Distribution noise must not replace environmental suitability.

### Result

A forest should contain:

```text
dense groves
sparse woodland
clearings
dense groves
```

rather than uniform tree density.

---

# Phase 6 — Implement Resource Density

Create:

```text
density = suitability × base_density × patch_modifier
```

Normalize and clamp the result.

Resource definitions should expose:

```text
base_density
patch_scale
patch_strength
```

Potentially also:

```text
density_curve
```

if needed.

### Debug output

Add a density visualization distinct from suitability.

This lets developers distinguish:

```text
"Would this resource like this environment?"
```

from:

```text
"How much of the resource should exist here?"
```

---

# Phase 7 — Implement Spatial Object Placement

Do NOT independently roll each tile for object placement.

Implement a spatial placement system capable of:

* minimum spacing
* deterministic placement
* chunk boundaries
* local density
* object footprint
* collision avoidance
* natural randomness

Prefer Poisson-disc / blue-noise-style placement or an equivalent deterministic spatial sampling approach.

Conceptually:

```text
Resource Density Field
        ↓
Candidate Points
        ↓
Minimum-Spatial-Separation Filter
        ↓
Valid Resource Instances
```

### Important chunk requirement

Objects near chunk boundaries must not duplicate when neighboring chunks are generated.

Placement must be based on stable world coordinates rather than local chunk coordinates alone.

---

# Phase 8 — First Playable Resources

Implement only three initial resource types:

## 1. Trees

Trees should primarily respond to:

* temperature
* moisture
* fertility
* elevation
* slope
* drainage
* vegetation
* biome subtype
* disturbance age

Trees should demonstrate different densities in:

* dense forests
* sparse forests
* woodland
* grassland edges
* disturbed areas
* cold regions

## 2. Rocks

Rocks should primarily respond to:

* geology
* slope
* erosion
* elevation
* hardness

Different geology types should eventually produce different rock types.

## 3. Berry Bushes

Berries should respond to:

* vegetation
* moisture
* fertility
* temperature
* forest/woodland habitat
* river proximity

Berries should have stronger clustering than trees.

### Goal

At the end of this phase the world should already feel like a place containing natural ecosystems.

Do not implement crafting yet.

> **Amendment (2026-09-22): resource guilds (competition within a group).** A single species scored in isolation fills every tile no competitor wants (oak covered most of the map as the only resource). Phase 8 therefore introduces **guilds**: resources that occupy the same ecological slot (e.g. canopy trees; shrubs incl. berry bushes; ground cover) are grouped.
>
> * **How much** of a guild grows at a tile comes from the environment, e.g. canopy-tree cover from `WorldGen`'s existing `vegetation` field (modulated by patch noise), not from any one species.
> * **Which species** it is comes from the members' relative suitability (a softmax-style share with a per-guild sharpness), so pine takes the cold, oak the temperate zone, and adding a species narrows its neighbors' ranges automatically.
> * **Placement** runs once per guild on one shared Phase 7 grid (guild spacing), then assigns each instance a species with a deterministic roll against the shares. This also gives cross-resource collision avoidance within a guild for free. Different guilds (trees vs. rocks) still need a footprint check against each other.
> * **Scope limit (Phase 13):** competition is *only* within a guild, splitting a budget that itself comes from the environment. There are no cross-guild rules ("if oak then mushroom"); correlations between guilds must still come from shared environmental causes.
> * **Cost (Phase 17):** each instance needs every guild member's suitability. That is acceptable because it is evaluated only at candidate points, not per tile, but it grows with species count.
> * Suggested first test: oak + a cold-tolerant conifer (pine) in the canopy-tree guild.

---

# Phase 9 — Geological Resources

Build on the existing:

```text
resource_vein
geology
erosion
cave_potential
```

Implement deposits rather than individual random ore tiles.

Conceptually:

```text
Geological Affinity
        ×
Resource Vein Noise
        ×
Exposure
        ↓
Deposit Potential
```

Support:

* iron
* copper
* coal
* stone variants

as initial examples.

### Critical distinction

Separate:

```text
resource exists
```

from:

```text
resource is exposed
```

A resource can exist underground without being visible to the player.

Eventually:

```text
deep terrain
    → hidden deposit

cliff / exposed terrain
    → visible deposit
```

This should make geological exploration meaningful.

---

# Phase 10 — Rivers, Shores, and Special Habitats

Use existing water topology rather than creating a second water system.

Implement environmental resource specialization.

### Rivers

Potential resources:

* reeds
* cattails
* willow
* clay
* fertile vegetation
* river-specific plants

### Floodplains

Use:

* high fertility
* deposition
* moisture
* flatness

for:

* dense vegetation
* farming potential
* wetland plants

### River mouths

Increase suitability for:

* mud
* reeds
* marsh vegetation
* sediment deposits

### Shores

Use:

* shore proximity
* beach classification
* water body type

for:

* beach vegetation
* salt
* shells
* coastal plants
* mangroves where appropriate

---

# Phase 11 — Disturbance and Ecological Succession

Connect resources to the existing:

```text
disturbance_type
disturbance_age
disturbance_intensity
```

Resources should respond differently depending on disturbance history.

Example succession:

```text
Fresh disturbance
    ↓
bare ground
    ↓
grass / herbs
    ↓
shrubs
    ↓
young trees
    ↓
mature forest
```

Create age-dependent modifiers for:

* trees
* grass
* herbs
* berries
* mushrooms
* deadwood
* fallen trees

Do not hardcode "forest regeneration" separately from the existing disturbance system.

The resource system should consume the existing disturbance fields.

---

# Phase 12 — Ecological Resource Profiles

Once the basic resources work, expand the data-driven definitions.

Potential resource categories:

### Vegetation

* Oak
* Pine
* Birch
* shrubs
* grass
* flowers
* herbs
* berries
* mushrooms
* reeds
* cattails

### Geological

* granite
* limestone
* shale
* basalt
* clay
* coal
* iron
* copper

### Environmental

* deadwood
* fallen trees
* gravel
* mud
* exposed stone

Each should be driven by environmental suitability rather than a biome-only lookup.

---

# Phase 13 — Correlated Ecosystems

At this stage, begin allowing resources to influence one another indirectly.

Do NOT create arbitrary dependencies such as:

```text
if oak then spawn mushroom
```

Instead, share environmental conditions.

For example:

```text
wet + fertile + shaded
        ↓
dense vegetation
        ↓
high mushroom suitability
```

Similarly:

```text
river + deposition + flat terrain
        ↓
fertile floodplain
        ↓
dense vegetation
        ↓
different plant composition
```

The goal is for correlations to emerge from shared environmental causes.

> **Amendment (2026-09-23): canopy shade is one derived value; floodplains already correlate.** Decisions made while implementing (the user delegated the open questions):
> * **Shade = the canopy-tree guild's density** at the tile (`ResourceManager.get_shade()`, source named once as `ResourceManager.SHADE_SOURCE`), 0 open .. 1 dense canopy. It is density, not placed tree instances: instance-based shade would be exactly an "if oak then X" dependency and would tie lower guilds to the stack's footprint filter. Density is a pure function of (seed, tile), patch noise included, so shade follows groves and clearings and stays chunk-independent. Young trees and birch count, because they are part of the tree cover that canopy placement draws from; shade and the visible trees agree statistically.
> * **Where it lives:** `EnvironmentalState.shade` (+ `shade_known`), attached lazily and once per state, not a `WorldGen.sample()` key (it depends on resource data, which the generator must not know). Guild evaluation (`get_member_scores()`) attaches it automatically for any guild with a shade-reading member. `chunk_manager.gd` fills it from its per-tile canopy density memo, which yields the same value. Species respond through a new `shade_curve` (in `CURVE_STATE_FIELDS` / `CURVE_FIELD_RANGES`, like succession and rock_exposure before it). Canopy members must not read shade.
> * **Who reacts (first-pass values):** meadow grass (1 to 0.1, 0.3 at 0.45) and wildflowers (1 to 0.08, 0.2 at 0.4) are sun-loving, and berry bushes mildly so (1 to 0.25, 0.55 at 0.6), each with shade as a *required* curve (light as the limiting factor). Their shade curves are 1 at shade 0, so open ground is unchanged. Wild herbs have no curve (shade-tolerant) and gain share as grass and flowers drop out. Mushrooms are shade-*dependent*: a preference curve (0.03 at 0, 0.1 at 0.12, 1 from 0.4) that **replaces their Forest/Rainforest biome weights**, which were a label proxy for shade. It is a preference, not a requirement, so the Phase 11 succession peak on scars isn't capped by shade. Meadow grass and wildflowers had Forest/Rainforest weights that also stood in for shade; they were softened (grass 0.25/0.1 to 0.5/0.25, flowers 0.3/0.2 to 0.6/0.4) so forest clearings can hold them while groves don't. Pioneers are left alone (their succession curves already encode canopy closure).
> * **Floodplains: no new data.** Measured before changing anything: flat, sedimented river-side land (~1% of land) already carries denser trees (5.4 vs 3.0 per 100 tiles) and a different mix (willow ~50% of trees vs 2%, reeds ~67% of wetland plants vs 5%, more herbs than grass). This emerges from the shared river/deposition/fertility fields added in Phases 10-12, and shade now thins the grass under its denser canopy. Encoding "floodplain" again in per-species curves would duplicate that condition (Rule 2), so it is locked in by `tests/test_correlations.gd` instead.

---

# Phase 13.5 — Terrain Surface Layer

> **Amendment (2026-09-24): phase added at the user's request, runs next, before Phase 14.** The original plan has no phase for how the ground itself looks.

The base view currently colors each tile by averaging the colors of several surface looks (snow, rock, sand, mud, soil, grass, forest) weighted by environmental fields. Because the blend is averaged and the fields are regional, large areas come out as one uniform color that tracks the biome, and a biome never contains different kinds of ground.

Replace this with a realistic "live game" ground layer: every tile has one discrete **surface material**, and the base view shows the ground together with the placed resources.

### Surface materials

Each tile gets exactly one material, chosen from environmental conditions, never from the biome label (Rule 3). A starting set, adjustable during implementation:

```text
grass, dry grass, dirt, sand, gravel, mud, rock, snow,
forest floor (leaf litter), burnt ground, marsh / shallow water
```

* **Data-driven, like resources.** Each material is a data definition with suitability curves over `EnvironmentalState` fields (Rules 2 and 6), reusing the suitability machinery where it fits. Examples: mud where it is wet, poorly drained, flat and near water; gravel on eroded ground and river banks; forest floor under canopy (Phase 13 `shade`); burnt ground on recent fire scars (`disturbance_type` + `succession`); beach sand vs lake-shore mud by `shore_salinity`.
* **Mixtures come from local patch noise.** Suitability says what the ground *could* be; a medium-scale patch noise (features roughly 5-30 tiles, new seed offset +20 - update the reserved-offset lists) picks which suitable material wins at each tile, so ground forms organic patches, not per-tile salt-and-pepper and not one flat region. A grassland is mostly grass with dirt patches and mud near rivers and lakes; a swamp mixes mud, pools, grass and dirt. These mixtures must emerge from the fields, not from per-biome rules.
* **Color varies within a material.** Each material has a base color modulated continuously by its drivers - e.g. grass from lush to dry with moisture and darker in the cold; dirt tinted by geology and darkened when wet; sand paler on beaches than in deserts; rock by geology - plus a small deterministic per-tile brightness jitter. Transitions stay smooth where the drivers change smoothly (Rule 7).
* **No sub-tile detail for now** (user decision): one color per tile, as today. Textured pixels and dithered material edges can be a later step.
* Water bodies (ocean, sea, lake, river) keep their current rendering. Swamp may show a mix of open water and wet ground, as long as placement, which reads `water_body`, stays consistent with what is drawn.

### Views

* The **default view** shows the new terrain **with all placed resources** (today's Resources layers), as the "live game" view.
* The old averaged-color look is **removed** (user decision: it isn't useful). Heatmap and label views keep blending over / drawing on the base ground, which is now the terrain.
* The placement-only debug views stay as they are.

### Data, not just pixels

The material is a queryable per-tile value: shown in the tile inspector, available to later phases (Phase 14 quality, e.g. berries on good soil; Phase 15+ gameplay such as movement or farming).

### Validation

* Deterministic per seed; material choice depends only on (seed, tile).
* Per-biome mixtures are plausible: grassland mostly grass with some dirt; swamp contains at least three materials; no grass on snow or rock-only mountaintops; beach sand along sea coasts.
* Patches are spatially coherent (neighboring tiles usually agree), not per-tile noise.
* Placement output is unchanged: resource instances stay identical. Only image hashes in the snapshot change, which is agreed for this phase.
* Performance: measure panning (`tests/bench_pan.gd`, threaded and `BENCH_THREADED=0`) and view switches before and after; the default view now includes resource placement, so startup and panning in it cost what the Resources view does today.

> **Amendment (2026-09-24): as implemented.** Twelve materials (grass, dry grass, dirt, forest floor, mud, marsh, sand, beach sand, gravel, rock, snow, burnt ground) as `SurfaceMaterial` data (`resources/terrain/*.tres`); `SurfaceMaterial` extends `ResourceDefinition`, so ground reuses `get_suitability()` unchanged (one new generic curve, `vegetation_curve`). Winner = suitability x prevalence x the material's own patch noise (seed offset +20). Shade is exact on a 4-tile lattice and interpolated between, because exact shade per tile would triple the cost. First-pass mixtures (seed 4242): Grassland ~76% grass with forest floor under groves, dry grass, mud and dirt spots; Plains grass / dry grass / dirt / forest floor; Swamp grass / marsh / mud / forest floor; Desert sand / dirt / dry grass, some snow in cold deserts; Tundra ~90% snow with frozen dirt patches; Badlands mostly rock. Fresh disturbance scars read as bare dirt with burnt patches on fire scars. Dropdown: "World" (terrain + every placed resource, default) and "Terrain Only"; the old averaged colouriser (`debug_colorizer.gd`) is deleted. Cost: choosing and colouring ground is ~50 us per tile, about 5x the old averaged colour, so a full cold rebuild of 81 chunks takes ~2 s of work in Terrain Only and ~6.8 s in World (was ~0.4 s / ~5.2 s). Panning is unaffected: threaded frames stay ~1 ms of main-thread work with no holes, and the web fallback's per-step cost stays small (image bands halved to 2 rows).

---

# Phase 14 — Resource Quality and Variants

Once placement is working, add quality rather than immediately adding dozens of new resources.

Examples:

```text
Tree
 ├── young
 ├── mature
 └── old growth

Iron
 ├── poor
 ├── normal
 └── rich

Berry Bush
 ├── sparse
 ├── normal
 └── abundant
```

Quality can be influenced by:

* fertility
* age
* disturbance
* geology
* exposure
* local environmental conditions

This creates gameplay variation without requiring entirely new resource types.

> **Amendment (2026-09-24): Phase 14 also covers spatial clustering of trees, rocks and ore (user request).** Alongside quality, make the spatial pattern of existing resources more natural, in data where possible:
> * **Trees in tighter clumps:** dense stands with clear gaps between them, instead of today's evenly spread groves. Levers already in `resources/guilds/canopy_trees.tres`: a smaller `minimum_spacing` (2.0 today; sprites are one tile since Phase 13.5, so ~1-1.2 is possible), a steep `cluster_curve` like the shrub thickets, and `cluster_scale`/`cluster_strength`. Expect knock-on effects through Phase 13 shade (forest floor, understory and ground materials clump with the trees) and the stack's footprint check (clumps crowd out lower guilds).
> * **Rocks in formations:** boulders gathered into scatters and outcrops rather than evenly sprinkled - `resources/guilds/surface_rocks.tres` (spacing 1.5, patch noise scale 24 / strength 0.7, no `cluster_curve` today), following exposed and eroded ground as now.
> * **Ore in clusters:** outcrops grouped along exposed seams rather than isolated hexes/sprites - `resources/guilds/ore_outcrops.tres` (spacing 3.0, no patch noise today; it follows the exposed-deposit field and vein noise).
> * Out of scope here: RimWorld-style solid rock masses (impassable, mineable walls) - a terrain-layer feature (a Phase 13.5-style surface material plus a "mountain mass" field and edge rendering) for a later phase.
> * Checks: instance counts per biome stay in a sensible range (`tests/resource_by_biome.gd`), a measurable clustering increase (e.g. nearest-neighbour distance or neighbour counts vs. today), and performance - a smaller tree spacing means ~4x canopy candidates, so compare `tests/bench_views.gd` and `tests/bench_pan.gd` (threaded and `BENCH_THREADED=0`) before and after. Placement output changes by design: re-record the snapshot once agreed.

> **Amendment (2026-09-24): quality as implemented (first part of Phase 14).** First-pass tier shares below were re-tuned by the clustering amendment that follows.
> * **Data model:** a `QualityProfile` (extends `ResourceDefinition`, so its drivers are ordinary suitability curves/weights over `EnvironmentalState` - Rules 2, 3, 6) referenced by `ResourceDefinition.quality_profile`; one profile can serve many definitions. `ResourceManager.get_quality()` = the profile's suitability at the instance's tile x (deposits) the deposit potential + a small per-instance jitter from the instance's stable key `(guild id, cell)`; tiers are named thresholds on that 0..1 value. Rule 4 holds: quality never feeds back into density or placement (placement snapshot unchanged).
> * **Decisions on the open questions:** `young_tree` stays a separate canopy species (the sapling stage on recovering scars) and has no quality; the seven mature species get **young / mature / old growth**. The old-growth cue is canopy **shade** (the stand's density - a tree in a dense grove interior is old, an open-grown or edge tree young), limited together with **succession** (required curves: recently disturbed land can't carry old growth), shaped by **soil fertility**. Berry bushes: **sparse / normal / abundant** from fertility and moisture, reduced by shade (light). Ores/clay/salt: **poor / normal / rich** = deposit potential (geology x vein seam x district) - how much ore exists at the outcrop.
> * **Surfacing (Rule 5):** tile inspector line "Quality: old growth (0.74)" and a "Quality" debug view (markers red -> yellow -> green). Quality is computed only for shown/inspected instances, so placement cost is unchanged.
> * **First-pass shares (seed 4242, five 192-tile regions):** trees 16% young / 56% mature / 28% old growth; berries 20 / 45 / 35%; ore 33 / 43 / 24%. `tests/test_quality.gd` locks in range, determinism, order independence, chunk path == direct, every tier present and the driver correlations.

> **Amendment (2026-09-24): clustering as implemented (second part of Phase 14; Phase 14 complete).**
> * **Why a small mechanism, not only data:** with the old density model (cover x patch x best member's score) a smaller spacing and steep cluster curve still left open country with thin, even clumps - cover thinned the density inside every patch. New generic guild option `ResourceGuild.cover_sets_area` (`ResourceManager.get_stand_membership()`): cover x the best member's score decides how much of the ground lies in **stands** (the patch noise's highest share of tiles, via its measured quantiles `PATCH_AREA_THRESHOLDS`), and density inside a stand is `base_density`. Sparse or marginal ground gets a few dense clumps with clear ground between; forests get stands broken by clearings; a share of 0 admits no tile. `stand_edge` softens the edges. Off by default - every other guild is unchanged.
> * **Data:** canopy trees - stand mode, `minimum_spacing` 2.0 -> 1.2, `cluster_scale` 48 -> 32, `base_density` 0.7, cover curve capped at 0.8 (clearings stay in forests). Surface rocks - stand mode, spacing 1.5 -> 1.2, `cluster_scale` 24 -> 16, cover curve x0.7. Ore outcrops - spacing 3.0 -> 1.5, stricter `density_curve` (nothing below 0.1 exposed deposit, full at 0.45), so outcrops pack along the richest parts of each seam.
> * **Measured (seed 4242, five 192-tile regions, `tests/test_clustering.gd`):** trees Clark-Evans R 1.11 -> 0.74, clump index (neighbours within 3 tiles vs random) 0.95 -> 3.0, isolated 48% -> 2%, count x1.9; rocks R 1.11 -> 0.72, clump 1.10 -> 2.95, isolated 28% -> 3%, count x1.07; ore clump index (6 tiles) 8.2 -> 19.0, isolated 11% -> 2%, count x1.8. Per biome (`tests/resource_by_biome.gd`, 4 seeds) trees roughly double with the biome ranking kept (Forest 5.3 -> 10.7, Grassland 2.8 -> 5.1 per 100 tiles; Desert 0.36 -> 0.50).
> * **Knock-on effects (as expected):** shade and the forest floor follow the stands; lower guilds lose ground to the denser canopy (snapshot area: shrubs 189 -> 156, wetland plants 240 -> 186, ground cover 122 -> 98, deadwood 190 -> 156). Shade inside a stand is now near-constant, so tree age was re-tuned: edges (lower shade) read young, old growth comes from fertile, moist, undisturbed ground (trees 14 / 53 / 32%); berry and ore tier thresholds re-set (23 / 45 / 32%, 25 / 49 / 25%). Snapshot re-recorded once for the agreed change.

---

# Phase 15 — Convert Generated Objects into Gameplay Entities

Only after visual placement is working should resources become gameplay objects.

Create a generic resource entity:

```text
ResourceInstance
    resource_id
    world_position

    quality
    size
    health

    harvest_state
```

Example:

```text
Tree
    resource_id = oak
    size = 1.3
    quality = 0.82
    harvest_state = available
```

The renderer should be separate from the underlying resource data where practical.

This will make it possible to later support:

* harvesting
* destruction
* respawning
* growth
* player modification
* persistence

> **Amendment (2026-09-24): groundwork as implemented (user decisions).** Scope is the data model only - no harvesting or other mechanic yet (there is no player or tool to act), no saving (Phase 16).
> * `ResourceInstance` (`scripts/resources/resource_instance.gd`): `key` ("<guild id>:<cell x>,<cell y>", the stable Phase 7/8 placement key), `guild_id`, `cell`, `resource_id`, `world_position`, `quality` + `tier` (Phase 14), `size`, `max_health`, `health`, `harvest_state` (`"available"`).
> * **Built on demand** (user decision): `ChunkManager.get_resource_instance(placement instance)` is the one lookup point - used by the tile inspector and the Quality view - and records are never stored for every placed object. Every field is a pure function of (seed, key, tile fields, data), so a rebuilt record is identical.
> * **Size is data only** (user decision: sprites are not scaled): `ResourceDefinition.base_size` x the quality profile's `size_by_quality` range at the instance's quality (trees 0.5-1.5: young 0.71, mature 0.96, old growth 1.32 on average; berries and ore 0.7-1.3); `base_size` without a profile.
> * **Health** = `ResourceDefinition.max_health` (default 100, untuned) x size, starting full.
> * The renderer stays separate: markers still draw from placement output; the inspector shows "Size / Health / State" for a clicked object.

---

# Phase 16 — Add World Persistence

The procedural generator should remain deterministic, but gameplay modifications must eventually be persisted.

Separate:

```text
Procedural State
```

from:

```text
Gameplay State
```

For example:

```text
Procedural:
    "There should be an oak tree here."

Gameplay:
    "The player chopped it down."
```

The generator should still know the tree *would* exist, while the gameplay state overrides its current existence.

This avoids storing the entire world.

> **Amendment (2026-09-22): generation changes vs. saved state.** Procedural output is deterministic for a given seed *and content version*, not forever. Retuning a curve, or adding a species to a guild (Phase 8 amendment), moves or re-species instances. Gameplay overrides must therefore be keyed by the stable placement key `(resource/guild id, placement cell)` from Phase 7 **and** record the resource id they applied to, and must be dropped or re-validated when the generated instance at that key no longer matches, never silently applied to a different object.

> **Amendment (2026-09-24): as implemented, with the first mechanic (user decisions).**
> * **Controls:** left click / tap harvests the resource under it; right click / long press (0.5 s, finger still) opens the info panel (was: click/tap = info). `CameraRig` signals `harvest_clicked` / `info_clicked`.
> * **Gameplay state:** `WorldChanges` (`scripts/world/world_changes.gd`) = `key -> {resource_id, harvest_state}`, the key being `ResourceInstance.key` ("<guild id>:<cell>"). Every read re-validates the resource id (`is_harvested()`, `apply()`), so a change whose key now holds a different resource (after a generation change) is never applied to it - it simply stops applying. Procedural state is untouched: placement, density, shade and the stack's footprints still see the harvested object (nothing regrows; the space stays empty).
> * **Saved automatically** after every harvest, per seed, as JSON (`user://world_changes/<seed>.json`, format version 1; `user://` is IndexedDB-backed storage on web); loaded on start and on a seed change. Only changes are stored, never the world.
> * **Harvesting** is available for every placed resource and just removes it: the chunk's markers are redrawn without it (filtered when marker nodes are built, so a chunk generated before the harvest can't bring it back), its record reports `harvested` with health 0, and a second click there harvests whatever else still stands. No yields/inventory yet (Phase 19).
> * Tests never touch the player's saves: under a scripted test SceneTree the default save dir is not used (in-memory only) unless a test sets its own.

---

# Phase 17 — Performance and Chunk Integration

Profile the complete system.

Resource generation should work with the existing chunk architecture.

Avoid:

```text
For every tile:
    calculate every resource
    instantiate every object
```

Instead consider:

```text
Chunk
 ↓
Sample environmental fields
 ↓
Determine relevant resource types
 ↓
Generate candidate regions
 ↓
Place instances
 ↓
Instantiate only visible/active objects
```

Use distance/LOD rules for scenery where appropriate.

Examples:

```text
Far away:
    aggregated vegetation

Medium:
    individual visual instances

Nearby:
    gameplay entities
```

> **Amendment (2026-09-23): moved up, runs next after Phase 12.** At the user's request, performance work comes before Phases 13-16. Measured baseline (headless, 81 loaded chunks, cold cache): switching to the Resources view with 9 guilds takes ~11.2s, Tree Placement ~6.3s, Oak Placement ~2.3s, and every added guild has made it slower. Known cheap wins recorded during Phases 8-12: `place_guild_in_rect` re-samples and re-classifies every surviving candidate in `shares_fn` after `density_fn` already did; each candidate evaluates every member's suitability even when geology or succession rules most of them out; lower guilds in the stack re-place the guilds above them. Profile first, then fix the largest costs, with the output unchanged (same seed gives the same instances) unless a change is agreed.

> **Amendment (2026-09-23): closed for now, before Phases 13-16.** Done with output unchanged: shared per-tile environment and density caches, candidate skipping, cheaper suitability (cold Resources switch 13.6s -> ~4.5s of total work); chunk content built as queued jobs, nearest chunk first, on a worker thread on desktop, and as small per-frame steps on the thread-less web build, so panning and view/LOD switches no longer freeze (web checked by eye). The "far away: aggregated vegetation" LOD sketch above was not needed yet (zoomed-out views already skip placed objects) and stays open, as do multi-worker throughput and cheaper per-chunk density. Details in `CHANGELOG_DEV.md` (Phase 17 entries) and `docs/tuning-log.md`.

---

# Phase 18 — Developer Tooling

Create an ecosystem/resource debugging panel.

It should allow developers to select:

```text
Resource:
    Oak

View:
    Suitability
    Density
    Patch Noise
    Final Placement
```

And optionally display the contributing values:

```text
Oak Suitability: 0.82

Temperature:       0.91
Moisture:          0.77
Fertility:         0.84
Elevation:         0.65
Slope:             0.73
Subtype:           0.95
Disturbance:       0.88
Patch modifier:    0.79
```

This will make balancing the procedural system dramatically easier.

> **Amendment (2026-09-24): as implemented.** Four generic Debug views - Suitability, Density, Patch Noise, Placement - for any placed resource, picked in a "Debug resource" dropdown shown only in those views (every GUILD_STACK member, listed as "Oak (Canopy Trees)"). A member is evaluated as its guild sees it: score = its member score (suitability; exposed deposit for ores), density = guild density x its species share (members' densities add up to the guild's), patch = the guild's patch modifier or, for stand-mode guilds, its stand membership at full suitability; Placement draws only that resource's instances from the real stack. The contributing values come from `ResourceManager.explain_suitability()`, which mirrors `get_suitability()` step by step (weights, each curve with its field value and factor, required minimum, geometric mean, biome/subtype modifiers, affinities) and is tested to rebuild exactly the same value, followed by the guild lines (cover, patch/stand, best member, share, density); it shows in the info panel (right click) in a Debug view. The older oak-only debug views stay for their tests and the snapshot.

---

# Phase 19 — Gameplay Loop

Once resource generation is stable, begin layering gameplay onto it.

Initial loop:

```text
Explore
   ↓
Observe environment
   ↓
Identify useful habitats
   ↓
Find resources
   ↓
Harvest
   ↓
Craft
   ↓
Build
   ↓
Explore farther
```

The important design goal is that the player can eventually learn environmental patterns.

Examples:

```text
Wet + fertile forest
    → berries / mushrooms

Rocky exposed terrain
    → stone / exposed ore

River floodplain
    → fertile soil / reeds / clay

Dry rocky hills
    → sparse vegetation / different stone

Old-growth forest
    → mature trees / specialized resources
```

The player should be able to form useful expectations without the game explicitly displaying a resource map.

---

# Implementation Rules for the Development AI

## Rule 1 — Preserve determinism

Everything procedural must ultimately derive from:

```text
world_seed
+ world_coordinate
+ stable resource identifier
```

Do not use global random state for world generation.

---

## Rule 2 — Do not duplicate environmental logic

If `WorldGen.sample()` already calculates:

```text
moisture
fertility
erosion
geology
```

the resource system must consume those values.

Do not independently recalculate them.

---

## Rule 3 — Avoid biome-only spawning

Avoid logic such as:

```gdscript
if biome == FOREST:
    spawn_oak()
```

Prefer:

```text
environment
    ↓
oak suitability
    ↓
oak density
    ↓
oak placement
```

Biome/subtype may influence the result but should not be the sole requirement.

---

## Rule 4 — Separate the layers

Keep these concepts separate:

```text
Suitability
Density
Patch Distribution
Individual Placement
Gameplay State
```

Do not collapse them into one function.

---

## Rule 5 — Build debug visualization before content expansion

Every major generation system should have a debug view.

Do not add 20 resource types before validating the distribution of the first 3.

---

## Rule 6 — Prefer curves and data over hardcoded thresholds

If a relationship needs tuning, expose it as data.

Prefer:

```text
temperature_curve
```

over:

```text
if temperature > X
```

unless the condition is genuinely categorical.

---

## Rule 7 — Preserve natural transitions

Resource density should generally change smoothly as environmental conditions change.

Avoid obvious lines at biome boundaries.

---

# Recommended Milestone Sequence

The development AI should implement and validate in this exact broad sequence:

```text
1. Understand existing generator
        ↓
2. Formalize EnvironmentalState
        ↓
3. ResourceDefinition framework
        ↓
4. Habitat suitability
        ↓
5. Suitability debug views
        ↓
6. Resource patch noise
        ↓
7. Density system
        ↓
8. Deterministic spatial placement
        ↓
9. Trees + rocks + berries
        ↓
10. Geological deposits
        ↓
11. River/coastal resources
        ↓
12. Disturbance/succession
        ↓
13. Expanded ecosystem
        ↓
14. Resource quality/variants
        ↓
15. Gameplay resource entities
        ↓
16. Persistence
        ↓
17. Performance/LOD
        ↓
18. Developer tooling
        ↓
19. Gameplay loop
```

## Definition of Done for the Generation System

The system should eventually satisfy these properties:

### Deterministic

Same seed and coordinates produce the same procedural world.

### Environmentally coherent

Resources appear where their environmental requirements make sense.

### Spatially natural

Resources form believable patches, groves, deposits, clearings, and clusters rather than uniform random distributions.

### Continuous

Resource density changes naturally across environmental gradients.

### Geological

Rock and ore distribution reflects the underlying geology and exposure.

### Ecological

Vegetation responds to temperature, moisture, fertility, disturbance, elevation, drainage, and related conditions.

### Discoverable

Players can learn environmental patterns and use them to predict where resources might be found.

### Extensible

Adding a new resource should primarily require creating a new `ResourceDefinition`, not writing new procedural generation code.

### Performant

Resource generation scales with the existing chunk system and does not require fully materializing the entire world.

### Gameplay-ready

Procedural existence and player-modified state remain separate so that harvesting, destruction, growth, and persistence can be added without replacing the generator.
