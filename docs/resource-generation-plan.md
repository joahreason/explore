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
> 2. **Weight biomes by membership, not by label.** `BiomeClassifier.classify_detailed()` already scores every candidate biome per tile, but only the argmax label is used, and weighting by that label produces speckled edges where it flickers between neighboring tiles (seen when tuning oak). Instead, `biome_weights` are applied against the tile's *normalized biome scores* (a 70% Forest / 30% Plains tile gets a blend), so biome dependence can be strong while staying continuous (Rule 7). Subtypes need their scores exposed the same way. Hard categorical gates remain acceptable where something is genuinely categorical (a mangrove on the Beach/Mangrove subtype, a reed on river tiles; see Rule 6).

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

> **Amendment (2026-09-23): closed for now, before Phases 13-16.** Done with output unchanged: shared per-tile environment and density caches, candidate skipping, cheaper suitability (cold Resources switch 13.6s -> ~4.5s of total work); chunk content built as queued jobs, nearest chunk first, on a worker thread on desktop, and as small per-frame steps on the thread-less web build, so panning and view/LOD switches no longer freeze (web checked by eye). The "far away: aggregated vegetation" LOD sketch above was not needed yet (zoomed-out views already skip placed objects) and stays open, as do multi-worker throughput and cheaper per-chunk density. Details in `PROJECT_STATE.md`.

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
