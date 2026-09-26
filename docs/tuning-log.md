# Tuning Log

Measured distributions, counts and benchmark numbers, newest first, with the
change they belong to (`CHANGELOG_DEV.md` has the change itself). Numbers are
per 100 tiles unless noted; "4 seeds x 4 regions" is `tests/resource_by_biome.gd`
(4 regions of 300x300 per seed, up to 28k tiles apart). The
`tests/bench_views.gd` header still says its numbers are quoted in
PROJECT_STATE.md: they are here now.

Timings depend on the machine: the cloud container is slower than the local
Windows desktop, and Windows headless frame times floor at the OS timer tick
(dev-workflow.md). Compare only A/B runs made on one machine.

## Standing observations

- **Placement saturates.** Matern (type II) thinning makes the count concave
  in density: density 0.25 already gives about half the instances of density
  1.0, and thinning saturates near 0.3 instances per `minimum_spacing`².
  That compresses mid vs. high density. (The other half of the old contrast
  problem, the geometric mean, was solved by `required_curves`.) The plan's `density_curve` (now on
  `ResourceGuild`) is the data lever if needed; see TODO.md.
- **Rock contrast is moderate.** Before Phase 14 clustering, bare or rugged
  biomes had ~6-10 rocks per 100 tiles and forests ~2; saturation limits how
  far curves alone can push it.
- **Narrow temperature ramps speckle** (+-0.06 micro-jitter): keep ramps
  wide (dev-workflow.md).

## 2026-09-26 - review follow-up

- W3 walkability: a long walk went from 163,584 dictionary entries (~14 MB)
  to 639 chunk arrays; the 4096-chunk cap is ~1.5 MB.
- O1: dropping the original-colour tileset shrank the web pack 707 KB ->
  570 KB.
- D1: marking open water per tile roughly doubles classify cost on open
  ocean, still a few us per tile.
- Code review baseline at 2c97bf0 (cloud container): 23 suites, 412 checks,
  18 min 18 s; the timing-sensitive no-worker check passed at 4,595 of its
  5,000 allowed frames (fixed by T3).
- P1 (`tests/bench_tile_cost.gd`, seed 4242, 3 x 48x48 tiles, best of 5,
  us per tile): sample 35, EnvironmentalState copy 18, classify 20, all 37
  species' suitability ~225, all 10 guild densities ~285 -> ~265 after the
  noise-key fix, terrain material + colour ~70 -> ~67. Biome memberships
  once per tile: ~4 us saved per biome-weighted resource on a land tile, no
  measurable change per tile in this mix (not kept).
- P3: one season recolour of the default 81-chunk World view (2,154 marker
  rows): 59-76 ms rebuilding nodes -> 2.8-3.0 ms recolouring in place.
- P4 (81 chunks, set_view_mode + flush): World -> Terrain Only 2.5-2.7 s ->
  5 ms; Terrain Only -> World 3.2-3.4 s -> 0.6 s; Subtype -> Quality
  3.1-3.2 s -> 0.6 s.
- P2 (`tests/bench_markers.gd`, GL Compatibility under Xvfb = Mesa software
  rendering, 1080p, frame ms median with markers / hidden): zoom 2 (81
  chunks, 2,637 rows) 99 / 90; zoom 1 (165 chunks, 5,613 rows) 115 / 85;
  zoom 0.5 (401 chunks, 13,917 rows) 144 / 88. Bucketing rows by whole
  tiles (option 1) cut rows 2.5x (to 5,661 at zoom 0.5) but the markers'
  cost only from 55 to 53 ms: the cost is per sprite drawn, not per sorted
  node, so option 1 was not kept. Still owed: the same numbers from the F3
  overlay (W4) in a real browser, where per-node overhead may weigh more.

## 2026-09-25

- Landmarks (3 seeds): Abandoned Camp on ~6.5% of land cells, Standing
  Stones ~3%, Ruins ~1.5%. A "Go to" site search takes ~1 s (scattered
  `sample()` calls cost ~1-3 ms cold because of water topology).
- Ground detail (PR #31), view switch, single runs: Resources 8220 vs 8153
  ms, Material 1813 vs 1689 ms - within noise.

## 2026-09-24

- Barrens (4 seeds, stride-750 land sample, measured on the world before the
  continent-scale oceans): before, 35% of Desert tiles were below 0 and 45%
  too cool for good cactus cover. Desert 9.2% -> 6.2% of land (81% of it at
  temperature >= 0.2, was 55%); Barrens 2.4% (median temperature -0.41, 68%
  snowy); Tundra 10.6 -> 11.0%; others unchanged.
- Oceans and seas (seeds 4242 / 1337 / 7): land ~85% (as before), ocean
  13-16% (was 2-4%), sea ~0.05% (was 10-13%), lakes ~0.1% (was ~0.08%), swamp
  ~7% (as before), relief ~83% of the old slope.
- Surf 2: Material view switch ~+6% (1632 -> 1736 ms).
- Cactus: 494 cacti around seed 1337 (1900, -2980), none outside hot desert.
- Polish pass 1: cloud shadows darkness 0.32, ~42% cover (calibrated to the
  noise's measured distribution).

### Phase 14 part 2 - clustering (seed 4242, `tests/test_clustering.gd`)

| | Clark-Evans R | clump index | isolated | count |
|---|---|---|---|---|
| trees | 1.11 -> 0.74 | 0.95 -> 3.0 | 48% -> 2% | x1.9 |
| rocks | 1.11 -> 0.72 | 1.10 -> 2.95 | 28% -> 3% | x1.07 |
| ore | - | 8.2 -> 19.0 (6 tiles) | 11% -> 2% | x1.8 |

- Per biome (4 seeds): trees ~x2 with the ranking kept - Forest 5.3 -> 10.7,
  Grassland 2.8 -> 5.1, Desert 0.36 -> 0.50.
- Quality shares after: trees 13 / 54 / 33%, berries 22 / 45 / 33%, ore 25 /
  49 / 25%.
- The old linear patch-threshold formula admitted ~5% of tiles at a tiny
  area share: desert oak 0.02 -> 0.60.
- Benchmarks (cloud container vs a `main` e84ac19 worktree, interleaved):
  bench_views cold World 7915 / 7940 -> 8299 / 8336 ms (+5%), Tree 6263-6272
  -> 6697-6862 (+7-9%), Quality 7196-7253 -> 7837-7884, Oak and Material
  unchanged. Canopy placement 7.9 -> 20.5 ms per chunk (test_resource_guild).
  bench_pan threaded: 0 holes, work p99 <= 3.9 ms (main <= 5.7).
  BENCH_THREADED=0 first: 12 frames > 16.7 ms of 1536 (main 4), max 23.5 ms;
  after the `_warm_guild_density()` steps: 4 frames > 16.7 ms, max 20.3 ms
  (main 21.0), 0 holes.

### Phase 14 part 1 - quality (seed 4242)

- First pass: trees 16% young / 56% mature / 28% old growth; berries 20 / 45
  / 35% sparse / normal / abundant; ore 33 / 43 / 24% poor / normal / rich
  (thresholds 0.2 / 0.55).
- Driver correlations (test_quality): tree age r 0.83 with shade, 0.64 with
  fertility; scar trees younger (mean 0.24 vs 0.48 undisturbed); berries r
  0.90 fertility, 0.89 moisture, -0.17 shade; ore r 0.99 deposit potential,
  0.69 vein.
- Benchmarks (cloud container, baseline `main` 8f9b67d worktree,
  BENCH_REPEAT=3, interleaved): World cold 7722 / 7746 -> 7689 / 7732 ms
  (unchanged: nothing evaluates quality there); Quality view 7039-7141 ms;
  Oak / Tree / Material unchanged. bench_pan threaded: 0 holes, no frame >
  16.7 ms except one baseline Material outlier, main-thread work p99 <= 3.1
  ms in both. BENCH_THREADED=0 not run.

## 2026-09-23

### Phase 13.5 - terrain surface

- test_terrain coherence 90.9%.
- Ground choice costs ~50-55 us per tile vs 2.4 us for the old averaged
  colour (~5x); shade exact per tile would roughly triple it (hence the
  4-tile lattice).
- Benchmarks (Windows desktop, baseline from a `main` worktree): panning
  unchanged - threaded main-thread work <= 1.1 ms per frame, no-thread 8-14
  ms (was 11-26: image bands are 2 rows now), 0 holes. Cold full rebuilds
  heavier: Terrain Only 385 -> 1999 ms, World (Resources) 5232 -> 6833, Tree
  3793 -> 5398, Oak 1570 -> 3182 ms. Only fill time after startup / view /
  zoom changes, not smoothness.

### Phase 13 - canopy shade (seed 4242, 5 regions)

- Shade: land mean 0.15, 19% exactly 0; Forest p50 / p90 0.22 / 0.52,
  Rainforest 0.26 / 0.54, Grassland 0.10 / 0.37, Desert and Tundra ~0.
- Mean shade at placed instances, before -> after: meadow grass 0.153 ->
  0.116, wildflowers 0.187 -> 0.103, wild herbs 0.259 -> 0.293, mushrooms
  0.235 -> 0.316 (48% under shade > 0.3), berries 0.227 -> 0.218.
- Counts: grass 8990 -> 8206, flowers 1306 -> 1143, herbs 4117 -> 4246,
  mushrooms 4736 -> 4424 (Forest 2452 -> 1732, Grassland 426 -> 722:
  mushrooms follow groves rather than the biome label), berries 12433 ->
  12152.
- test_correlations placement: mushrooms / herbs at shade 0.281 / 0.267 vs a
  vegetated-land background of 0.149; grass / flowers 0.114 / 0.097.
- Floodplains (flat, sedimented river-side land, ~1% of land) vs elsewhere:
  trees 5.4 vs 3.0; willow ~50% of trees vs 2%; reeds ~67% of wetland plants
  vs 5%; herbs 60% of ground cover vs 38%.
- Benchmarks (Windows desktop, A/B interleaved vs a baseline worktree):
  bench_views cold ms, baseline -> Phase 13, threaded: Oak 1557 -> 1563, Tree
  3693 -> 3792, Resources 4494 -> 5239 (+17%), Material 381 -> 382;
  BENCH_THREADED=0: 1530 -> 1573, 3663 -> 3737, 4412 -> 5145 (+17%), 372 ->
  376. The Resources cost is the canopy density evaluated at shade-reading
  candidates the canopy memo doesn't cover. bench_pan unchanged in both
  modes: Resources worst frame threaded 16.2-16.7 vs 16.3-16.7 ms,
  BENCH_THREADED=0 15.7-16.6 vs 15.8-16.5 ms, no frame over 16.7 ms, 0 holes
  (the ~14-16 ms p50 / p99 here is the machine's pacing, identical for both
  trees; the Phase 17 record had a 6.9 ms floor).

### Phase 17 - chunk streaming

- Early (before Phase 17): the Tree Placement switch took ~2.1 s headless for
  81 chunks (guild placement ~5 ms per chunk; every candidate evaluated both
  members).
- Profile (seed 4242, 81 chunks, instrumented): the Resources switch did
  161,552 candidate evaluations, each a fresh `sample()` + `from_sample()` +
  `classify_full()` (~6.6 s together) over only ~31k distinct tiles (~5x per
  tile: every guild with a candidate there, plus each chunk re-testing its
  one-cell ring that the neighbour also tests), plus ~5.2 s of guild
  densities. Tree / Oak Placement: the density heatmap bake was 2.75 s / 1.6
  s of the switch. The suspected "shares_fn re-samples survivors" was only
  ~0.4 s.
- Step 2a's density bound skips 20-65% of candidates for rocks, shrubs,
  wetland, shore, deadwood, pioneers and ground cover (canopy, oak and
  outcrops are base 1.0 or curved).
- Profile after step 3 (Resources): density callback 3.7 s over 108k calls
  (env misses, member scores, memo-key lookups), `_place` machinery ~1.1 s (a
  Dictionary + 4 hashes per candidate, even for rejected ones), shares 0.15
  s, stack filter ~0.14 s, images 0.4 s. Tree / Oak were mostly their
  per-tile density heatmap bakes (2.2 s / 1.5 s).
- bench_views (cloud container, cold, 81 chunks, min of 2), Oak / Tree /
  Resources / Material ms:

  | | Oak | Tree | Resources | Material |
  |---|---|---|---|---|
  | before | 2176 | 7162 | 13616 | 398 |
  | step 1 | 1874 | 5195 | 6739 | 392 |
  | step 2a | 1881 | 4939 | 5711 | 389 |
  | step 2b | 1663 | 4137 | 5266 | 384 |
  | step 3 | 1695 | 4018 | 5019 | 393 |
  | step 4 | 1707 | 4048 | 4806 | 397 |

  (This container is slower than the machine that measured the 11.2 s
  baseline; cold Resources ~4.5 s of total work after step 4.)
- Step 5 diagnosis: crossing a chunk boundary cost 45-96 ms in Material (~5
  ms per chunk) and 386-1171 ms in Resources (~42 ms per chunk). Rendering is
  not the cost (windowed: Resources draws in ~0.8 ms, 52 draw calls).
- Step 5 results (Windows desktop, bench_pan, 6 chunks east / diagonal from
  fresh ground, forest + coast): worst frame before 46-96 ms Material /
  386-1171 ms Resources; after, threaded, every frame at the headless 6.9 ms
  sleep floor (max 7.7 ms), 0 holes, also at 8 px per frame (~1900 screen
  px/s). Windowed with the real renderer (165 Hz display): Resources and
  Material pans at 6.06 ms mean, max 8.7 ms, 0 holes. Main-thread fallback
  (BENCH_THREADED=0): Material max 15 ms (smooth); Resources still hitched at
  40-130 ms frames but no 0.4-1.2 s freezes. Total work per cold switch
  unchanged (HEAD vs step 5: Oak 1548 / 1565, Tree 3540 / 3713, Resources
  4338 / 4475, Material 372 / 374 ms).
- Step 6 (desktop, BENCH_THREADED=0): Resources pan worst frame 9.7-12.9 ms
  (6.9 ms idle floor), none over 16.7 ms, 0 holes (before: 46-68 frames over
  16.7 ms, max 93-132 ms). The warm-up bands cost no throughput (bench_views
  Resources 4458 ms vs 4475). A single sample can still cost ~15-40 ms when
  it triggers a WaterTopology flood fill (first touch of a 64x64 open-water
  region).
- `set_view_mode()` and clicks wait for the running job: up to ~130 ms in
  Resources.

### Phase 12 - ecological profiles (4 seeds)

- Ground cover: Savanna / Grassland ~3, Forest / Plains 2.4, Desert 0.07;
  grass 93% on open ground, herbs 93% wooded.
- Birch ~0.75 in Forest and Wetland; pine unchanged. Mushrooms 1.3-1.6 on
  forest floors. Rock totals per biome unchanged within ~5%.

### Phase 11 - succession (seed 4242 + 1337, 8 regions)

- succession < 0.5 on 4.8% of land, < 0.9 on ~21-29%.
- Mean succession of placed instances (seed 4242, 4 regions): dead trees
  0.24 < pioneers 0.43 < young trees 0.69 < oak / pine 0.98; berries 0.91.

### Phase 10 - rivers, floodplains, mouths, shores

- Deposition on land: p50 / p90 / p99 = 0.02 / 0.14 / 0.22, 41% exactly 0.
- River mouths (land with river > 0.02 and shore_proximity > 0.1): ~0.35% of
  land, median river 0.064 there (rivers fade toward the coast). Lake-only
  shores: 7.5% of shore tiles. Reeds' mean suitability at mouth tiles 0.52.
  `sample()` cost with shore_salinity: 13.1 vs 13.5 us (origin area).
- Rivers (4 seeds x 4 regions; reed | cattail): Wetland 0.44 | 8.99, Swamp
  0.11 | 2.15, Rainforest 0.44 | 1.29, Forest 0.22 | 0.17, Beach 0.30 | 0,
  Grassland 0.06 | 0.09, dry biomes 0. Willow: Wetland 0.44, Rainforest 0.27,
  Forest 0.20. Swamp stays below Wetland because a third of swamp tiles are
  coastal (shore > 0.5). Test area (seed 4242, 320x320 around (18000, 9000)):
  3024 cattails, 61 reeds (all on banks), 42 willows (42 of 45 bank trees).
  The first cattail (drainage as a hard limit) put 9 on beaches.
- Floodplains: farmland > 0.6 on 13.5% of land (Rainforest 35%, Forest 26%,
  Wetland 18%, Savanna 17%, Plains 9%, Grassland 5%, Swamp 0.3%); flat river
  banks 0.59 vs 0.36 on flat ground away from rivers. The first version put
  27% of land above 0.6 with banks barely favoured (0.66 vs 0.44). Clay rich
  on ~6% of land, exposed on ~0.45% (banks only).
- Shores (4 seeds x 4 regions): Beach shells 2.9, beach grass 8.5, mangrove
  0.6, salt marsh 1.2, salt 0.2; Swamp salt marsh 3.5 + cattail 2.1 (was 2.2
  total - the coastal-swamp gap is closed), mangrove 1.4, mud 0.2. The first
  version put mangroves (3.2) and salt marsh (6.1) on sandy beaches.
- Cost (headless, cold): the fourth guild took the Resources switch 5.2 s ->
  ~6.6 s (81 chunks); `EnvironmentalState.from_sample()` 40 -> 9 us per call.
  With 5 guilds (ore outcrops) ~7.0 s; with 6 guilds (shores) ~8.6 s (~7.1 s
  before); Tree Placement ~6.6 s (6 tree species).

### Phase 9 - deposits

- Land share with rock_exposure > 0.5: erosion alone ~2.8%, cliffs ~4%,
  combined ~5.7%.
- Rich (potential > 0.3) on 9.0% / 6.9% / 16.6% of iron's / copper's /
  coal's host rock (seed 4242, 6000x6000 at stride 30); most of it hidden
  (iron: 2079 hidden vs 123 exposed tiles in a 1400x1400 sample). Without the
  district factor, 28% of land was rich in iron. Iron / copper veins r =
  -0.009.
- Ore outcrops (iron / copper / coal): Badlands 0.56 / 0.24 / 0.39, Wetland
  0.28 / 0 / 0.69 (wet, soft sedimentary ground erodes and exposes coal
  beds), Beach 0.34 / 0.33 / 0.21, Rainforest 0.37 total, Grassland 0.18,
  Forest 0.08, Desert 0.04. Seed 4242, 800x800 around the origin: 275 iron,
  348 copper, 24 coal; densest 60x60 block at (90, -270) with 57. Exposed
  values: p75 0.10, p90 0.30 among the 29% of land with any exposed ore.

## 2026-09-22 to 2026-09-23 - Phases 5-8 (exact dates not recorded)

### Trees by biome over time (oak / pine / palm / olive)

- Olive added: Forest 1.74 / 1.91 / 0.06 / 1.31, Rainforest 1.07 / 0 / 3.04
  / 0.27, Savanna 0.07 / 0 / 0.28 / 2.34, Grassland 0.21 / 0.74 / 0.63 /
  0.64, Plains 0.27 / 0.43 / 0.45 / 0.78. Olive's first version made Savanna
  5.6 trees per 100 tiles (denser than Forest); the open-biome weights
  brought it to 2.7.
- Forest species fix, canopy trees in Forest by subtype, before -> after:
  Montane pine / palm / oak 3435 / 1493 / 662 -> 372 / 16 / 3 (now ~9% of
  forest, median elevation 0.38 - above oak's limit of 0.32); Temperate oak
  / pine / palm 746 / 14 / 91 -> 4526 / 1140 / 3; Dry Woodland palm / oak
  1507 / 216 -> 461 / 1683; Boreal pine-only. By biome (oak / pine / palm):
  Forest 2.47 / 1.93 / 0.19, Rainforest 1.15 / 0 / 3.20.
- Palm added (oak / pine / palm): Rainforest 0.92 / 0 / 4.79, Forest 1.14 /
  2.25 / 1.28, Savanna 1.02 / 0 / 0.79, Swamp 0.43 / 0 / 0.80, Beach 0.03 / 0
  / 0.82. The first try reached 3-6 palms on beach, swamp and wetland.
- Phase 8 steps 1-3 (total | oak pine): Plains 3.77 | 1.56 2.21, Grassland
  2.22 | 1.62 0.60, Swamp 0.79 | 0.79 0.00, Tundra 1.48 | 0.01 1.47, Alpine
  Snow 2.21 | 0.05 2.16, Badlands 2.46 | 0.46 2.00, Desert 0.33, Beach 0.33,
  water 0. Seed 4242, 320x320: pine mean temperature -0.18 vs oak -0.04.
  Forest was ~0% of area on these seeds (the world was cool overall, so pine
  was the majority species).

### Phase 8 steps 4-5 - rocks, berries, footprints

- Rocks (4 seeds x 4 regions): Tundra 9.5, Desert 7.8, Alpine Snow 7.3,
  Plains 6.4, Badlands 6.2, Grassland 4.4, Savanna 4.3, Forest 2.3,
  Rainforest 2.3, Beach 2.1, Wetland 1.9 (mostly sandstone), water / Swamp 0.
  Tuning trail: the steep first cover curve gave Badlands 4.4 < Plains 5.5
  and Forest 1.4; a flat curve lifted Forest to 3.4.
- Berries: Forest 4.3 (started at 7.5), Rainforest 3.6, Wetland 2.9,
  Grassland 1.2, Savanna 1.0, Badlands 0.9, Swamp 0.8, Plains 0.3, Desert /
  Tundra 0. On river banks 5.7 vs 3.2 on other green land; patch dispersion
  3.09 vs trees 0.57 in 16x16 blocks.
- With the 4-region sampler, tree numbers shifted without any tree change
  (Forest 4.17, Rainforest 4.72).
- Footprints (seed 4242, 160x160 around (17840, 8840)): rocks 869 / 869
  kept, trees 642 / 707, berry bushes 649 / 814.

### Biome shares

- Temperature variety (4 seeds, 60k x 60k tiles): land temperature p10 / 50
  / 90 -0.68 / -0.19 / 0.31 -> -0.76 / -0.01 / 0.78; Tundra 32% -> 18%. Seed
  4242 test area then mostly oak (pine at -0.07 vs oak at 0.07).
- Vegetation rework, shares before -> after: Forest 0.3% -> 8.7, Rainforest
  0 -> 5.5, Savanna 0 -> 6.0, Desert 11 -> 6.6, Grassland 12 -> 20, Plains 15
  -> 3.3, Wetland 6 -> 0.7 (Swamp still covers wet lowland, 5.8). Trees:
  Forest 4.17, Rainforest 3.84 (all oak - no tropical species yet),
  Grassland 1.57, Savanna 1.37, Tundra 0.28, Desert 0.11.
- Biome balance, land-only (4 seeds, 60k-tile stride-750 sample), before ->
  after: Grassland 26.5 -> 18.4, Tundra 23.8 -> 10.6, Forest 10.1 -> 21.5,
  Wetland 4.9 -> 5.8 (0.6 before the drainage rule), Plains 5.7 -> 11.4,
  Desert 9.3 -> 9.2, Rainforest 5.9 -> 8.0, Savanna 8.6 -> 5.4, Badlands 3.4
  -> 4.9, Alpine Snow 1.8 -> 4.9 (hot highlands had been labelled snow,
  median temperature +0.22). Trees: Forest 4.09, Rainforest 4.01, Grassland
  1.66, Tundra 0.

### Oak (Phases 5-7 and fixes)

- Suitability refinements, oaks per 100 tiles before -> after: Plains 6.6 ->
  4.3, Grassland 2.8 -> 2.1, Badlands 5.1 -> 2.3, Alpine Snow 3.3 -> 1.1,
  Desert 4.5 -> 0.6, Tundra 1.9 -> 0.4, Beach 1.6 -> 0.1.
- Oak tuning fix (4 seeds x 600x600; before = seed 4242 only): Plains 4.3 ->
  6.6, Tundra 5.7 -> 1.9 (61% of Tundra tiles now score exactly 0), Alpine
  Snow 6.3 -> 3.3, Beach -> 1.6, Grassland 0.5 -> 2.8; water still 0. Median
  land temperature was -0.21, Tundra -0.41.
- Phase 7 placement count per 200x200 at density 0.1 / 0.25 / 0.5 / 0.75 /
  1.0 (spacing 2): 873 / 1884 / 2939 / 3437 / 3626.
- Phase 6: with oak's suitability mostly 0.6-0.8 and patch strength 0.85,
  density rarely exceeded 0.6 (28 of 10,776 tiles with suitability > 0.6,
  seed 4242).
- Phase 5: patch fields of different ids decorrelated (|r| ~0.02 for oak /
  berry / rock); lag-8 autocorrelation 0.00 at cluster_scale 8 vs 0.87 at 96.
