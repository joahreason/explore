# Development Changelog

Important development history, newest first: one entry per merged change or
phase. Measurements and benchmarks are in `docs/tuning-log.md`, decisions in
`docs/decisions.md`, how the systems fit together in `docs/architecture.md`.
"PR #n" is a GitHub pull request; short hashes are commits. This clone's Git
history is shallow, so work before 2026-09-23 is dated from the plan doc and
old notes.

## 2026-09-26

### Review batch 6: docs restructure (X2) - into `review-followup`

PROJECT_STATE.md (126 KB) is a snapshot under 10 KB again. Its history moved
here, decisions to `docs/decisions.md`, workflow and gotchas to
`docs/dev-workflow.md`, numbers to `docs/tuning-log.md`. The three template
files hold their own contents again (the workflow doc is folded into
dev-workflow.md). `docs/architecture.md` trimmed to the current state
(`TILE_SIZE` is 16, not 12). README's tileset and player notes fixed. CI fails
when PROJECT_STATE.md reaches 10 KB.

### Review batch 5: chunk_manager.gd split (§4.1 steps 1-9) - PRs #45-#53, into `review-followup`

- ChunkManager (`scripts/world/chunk_manager.gd`, 846 lines, was 2559) is a
  facade over: `WorldContent` data (`resources/world_content.tres`: guild
  stack, World-view layers, deposits, terrain materials, structures; A3),
  `TerrainCodes`, `Navigation` (pure A*), `WorldSession` (clock, saves,
  tent), `ViewModes` (one table per view; A2), `GenerationContext`
  (WorldGen, sites, generation caches and their mutex; its public methods
  lock), `ChunkBuilder` (one chunk's content as data), `ChunkStreamer`
  (epochs, jobs, worker, LOD), `ChunkPresenter` (nodes, borders, markers,
  seasons), `ResourcePicker` and `WorldTravel`.
- Tests use the modules directly; no forwarding members are left (A4, T4).
- Scripts moved into `scripts/{gen,resources,world,render,ui}`, data into
  `resources/{species,guilds,deposits}` (O1; layout in architecture.md §1).
- Every step: all 36 views dump identical chunk hashes, placement snapshot
  identical, full suite green.

### Review batch 4: before feature work - into `review-followup`

- C4: saves go to a temp file that is renamed over the old one; the old one
  is kept as `.bak` and loaded if the main file is torn (e8d1c67).
- C3: a tap harvests the instance it targeted, even if the view changed on
  the way (2671b50).
- X3: **F5** (desktop) re-reads every `.tres` under `res://resources` into
  the loaded instances and rebuilds the chunks: edit, save, F5 (4252a37).
  `CACHE_MODE_REPLACE` on 4.7 refreshes instances and curves in place but
  only sets what a file stores, so resources are first reset to their script
  defaults.
- W4: **F3** or `?debug=1` shows a debug overlay: frame p50/max over 5 s,
  longest job step, queued chunks, chunks shown per second, node count
  (3205066). It is how P2's budgets get decided (batch 7).
- Neither F5 nor F3 was tried in a real window or browser yet.

### Review batch 3: small fixes - into `review-followup`

- D2: WorldGen's configured flag is separate from the seed, so seed -1
  works (2039945).
- W6: a web visit without `?seed=` writes its random seed into the URL; the
  game saves on focus loss and pause as well as close (061b0b2). Not checked
  in a real browser.
- W5: LOD steps have 5% hysteresis (67c007a).
- C1: only label overlays fade in; terrain and markers appear at once
  (b22975b; see decisions.md).
- C2: tent lookups and the chunk image format are read under the generation
  lock (4b910a9).
- C5: curve plans are built in `_ready()` before any thread starts
  (1155404).
- X4: the two game_constants `.uid` files are committed (507f661).
- W3: walkability is a byte per tile in per-chunk arrays, capped at 4096
  chunks (ca548a6; memory numbers in tuning-log).
- O1 (part): the unused original-colour tileset is excluded from the web
  export (c803796).

### Review batch 2: web stalls - PR #42, into `review-followup`

- W2: hover and tap pick from the drawn instances of loaded chunks
  (`_drawn_near()`, now in `ResourcePicker`), no placing and no lock; nothing to pick in views
  without markers; the click inspector still places (57e79b2).
- W1: "Go to" searches are resumable (`BiomeFinder` instances,
  `StructureSites.Search`): stepped from `_process()` without threads
  (`TRAVEL_BUDGET_USEC`), on a thread otherwise; the menu's first item
  cancels a running search (107cdfd).
- Not checked in a real browser.

### Review batch 1: safety net - PR #41, into `review-followup`

- X1, T5: the runner uses `--import` and fails a suite on script or engine
  errors (42fe572, 09d9e00).
- D1: WaterTopology marks open water per tile (a bitmap per 64x64 cell), so
  water labels no longer depend on query order; checked in test_shores;
  placement snapshot unchanged (ebcceee).
- T2 (order part): the snapshot gained a reverse-order pass from a fresh
  no-worker world (cce2edf).
- T3: the no-worker stepping test flushes instead of a 5000-frame cap
  (4219516).
- T1: CI runs the fast suites on PRs and before deploy (74d24e4).

### Code review - PR #40, on `main`

`docs/reviews/2026-09-26-code-review.md`: architecture, determinism, web and
testing review at 2c97bf0. Its follow-up runs in batches (TODO.md "Review
follow-up"); batch PRs merge into `review-followup`, one PR to `main` at the
end.

### Ground borders - 5aaa794, a56ba8e, 2c97bf0, bd8e849 on `main`

- Tile size and the shadow height scale live only in
  `scripts/game_constants.gd` (`GameConstants`); `ChunkManager.TILE_SIZE`
  and `Player.TILE_SIZE` alias it. Shaders get them as uniforms from
  `shaders/game_constants.gdshaderinc`, set on each material by
  `GameConstants.apply_to()` (no defaults, so a missed material shows at
  once).
- Terrain shader: every tile edge bumps up to `EDGE_PX` in or out, fading to
  zero at tile corners (`edge_offset()`), so the tiles form one wobbly grid.
  Each pixel belongs to exactly one tile, decided from the four tiles round
  its nearest corner, so there are no stray pixels.
- Outer corners of a ground are cut along a `CORNER_PX` quarter circle
  (saddles: only the darker pair; the cut takes the surrounding ground).
  About one edge in three between different grounds (`ground_differs()`:
  hue, or brightness beyond per-tile jitter) gets a small round splotch just
  off it (`edge_blob()`, `BLOB_*`). Borders only between different grounds;
  later passes made the waves gentler and splotches fewer and smaller.
- Sea-washed shore tiles take part; land never takes a water tile's colour;
  swash and foam stay tied to each pixel's own tile.
- `hash()` avoids `sin()`, which broke down far from the origin.
- Mangrove art added.

## 2026-09-25

### New art style test: 16 px tiles, pivoted sprites, free movement - f0fd74a, cd86787 on `main`

- Tiles are 16 px (were 12).
- New art in `assets/sprites/` (player, oak, birch, mangrove, spruce - drawn
  for `pine.tres`): outline drawn in, white body tinted by `sprite_color`,
  pivot at the bottom middle, drawn 1:1 (`ResourceDefinition.sprite_texture`,
  `ResourceMarkerChunk.pivot_rect()`). Old Urizen sheet art stays at its
  native 12 px, also pivoted at its bottom middle.
- A resource sprite's pivot is its tile centre offset by up to +-6 px,
  deterministically from where in the tile it was placed
  (`ResourceMarkerChunk.pivot()`, `PIVOT_SPREAD`); structure parts stay on
  the grid (the tile's bottom middle).
- Depth: marker chunks draw in one `_Row` child per pivot y; `Resources`
  y-sorts them together with the Player (`Resources/Player`), so anything
  further south draws in front.
- The player walks freely (no tile lock): `_on_map_tapped()` turns the A*
  tile path into string-pulled straight legs (now
  `Navigation.smooth_path()` / `walkable_line()`) ending at the tapped
  point, or `STAND_OFF` beside a tapped resource or tent. Hop and footsteps
  come every `STEP_TILES` walked; the exact position is saved.
- The player's shadow lives in `ShadowLayer` with the plants'. Cast shadows
  get each sprite's height through the red channel of its draw colour
  (`ResourceMarkerChunk.shadow_color()`).
- World-view clicks pick only what is drawn: the frontmost sprite with an
  opaque pixel under the pointer (`_sprite_covers()`, `sprite_drawn()`,
  `sprite_point()`); debug
  marker views keep the tile / half-tile reach pick.
- The hover highlight outlines the sprite's silhouette
  (`HoverHighlight.outline_texture()`) and sways with it (sway material, the
  sprite's sway in the draw alpha). Tent wake fades.

### Harvest sound removed - PR #38

Removed at the user's request: the sound, its asset and the generator
recipe. The harvest pop stays (a first commit removed the pop by mistake and
was corrected in the same PR).

### Sleeping in camp tents - PR #37 (then 122c3d8)

Tapping a camp tent walks the player up to it and inside (hidden). The
tent's marker is swapped for `TentSleepEffect`
(`scripts/render/tent_sleep_effect.gd`: slow squash-and-stretch bounce,
pixel Zs rising), and `GameClock.sleep()` fast-forwards to the next night
start (19:30) or dawn (06:00), whichever comes first at least an hour away:
easing in to x300 over 0.4 s and slowing back to x1 over the last in-game
hour, so the stop isn't abrupt. The player comes out when the clock wakes;
a tap anywhere or any time-control button wakes them early. Hover outlines
tents. Sleep state isn't saved. 122c3d8 adjusted the night start and dawn
hours. Tests: `test_game_clock.gd` (next_wake, easing, wake), `test_player.gd`
(tap a tent, hidden, bounce and Zs, wake at night start).

### Landmarks and structures - PR #36

- Rare discrete sites - Abandoned Camp, Standing Stones, Ruins - via
  `StructureSites` (`scripts/gen/structure_sites.gd`) and
  `StructureDefinition` (`scripts/gen/structure_definition.gd`, extends
  ResourceDefinition; data in `resources/structures/*.tres`).
- At most one site per 64-tile cell; centre, type, rotation and age from
  hashes of (seed, cell), seed offset +22; footprints stay inside their
  cell.
- Type = frequency x suitability at the centre (curves, no biome weights;
  new generic `wind_exposure_curve` on `exposure`), then a water veto
  (`water_within`: camp 30, ruins 20 tiles).
- Stamps are part lists (offset, Urizen tile, kind, chance, decay) rotated
  in quarter turns; age removes parts by decay and grows plants (ruins scale
  with vegetation).
- Structure mask: guild and resource density return 0 on a footprint.
  Drawn first in the World view's marker node; inspector "Structure" line;
  the "Go to..." menu lists them after the biomes and searches sites
  directly (`StructureSites.find()`, ~1 s).
- `tests/test_structures.gd`. Shares measured in tuning-log. Open: by-eye
  tuning; structures don't block walking or cast shadows; static only
  (interaction, loot and saving are Phases 15/16).
- Placement snapshot re-recorded: 11 instances removed, all inside the camp
  footprint near the origin, plus 1 birch just outside it that the removed
  pine had thinned out.

### Harvest sound - PR #35 (removed again in PR #38)

`assets/sfx/harvest.wav` from the same generator: a brief band-passed
rustle under a soft triangle blip gliding 520 -> 780 Hz, 160 ms, 91% of the
energy 400 Hz - 2 kHz. `ChunkManager` played it on each harvest at -18 dB,
pitch 0.92-1.1 (`harvest_sounds` counted plays). Never checked by ear.

### Footsteps - PRs #32-#34

First sound effect. `tools/generate_sfx.gd` synthesizes
`assets/sfx/footstep.wav`; `Player` plays it on each step's landing, pitch
0.82-1.18 (never within 0.06 of the previous step) and +-1.5 dB jitter. No
volume setting or mute yet. The first version (thump + bit-crush, -12 dB)
sounded like a harvest to the user; the second (two low-passed brushes,
-20 dB) was still too deep, crunchy and heavy; now one 60 ms brush of
smoothed band-passed noise (73% of the energy 400 Hz - 2 kHz, 3% below
200 Hz), played at -26 dB. The user found this one good. Also:
terrain.gdshader no longer passes TEXTURE into a helper (Godot logged a
sampler error for it).

### Ground detail - PR #31

Subtle grain + mottle on ground and dithered blending between different
ground tiles (4 px each side of an edge, 50/50 at the edge) in the World and
Terrain Only views (terrain.gdshader `ground_detail`); water, foam and swash
keep their own tiles. Chunk textures carry a 1-texel border shared with
loaded neighbours so blends cross chunk borders. View-switch cost within
noise (tuning-log). test_ambience +2 checks.

### Player: click / tap to move - PRs #28-#30

- Replaces camera panning (the first step before Phase 19).
  `scripts/world/player.gd` (sheet tile (104, 0), cast shadow, 4 tiles per
  real second - not the game clock). PR #29 locked movement to tiles (one
  step per tile incl. diagonals, a 2 px hop per step instead of a walk frame
  - the second frame was a different sprite - no destination marker); PR #30
  put the pivot at the feet (`feet_point()`, since removed) so the hop,
  facing flip and camera follow are about the feet. The tile lock was
  dropped again in the new art style (2026-09-25).
- `_on_map_tapped()`: A* `find_path()` round open water (frozen water
  walkable; walkability recorded as chunk images bake at LOD 1, else
  sampled; `MAX_PATH_NODES` 6000, else the closest tile found). Tapping a
  resource walks within one tile and harvests on arrival (another tap
  cancels).
- Camera follows loosely (`FOLLOW_ZONE` 0.2 of the view each way; eases back
  to the zone edge). Drag no longer pans; pinch zooms around the view
  centre; momentum removed.
- Position saved per seed (`WorldChanges.player_position`, JSON "player");
  new worlds spawn on the nearest dry tile to the origin; biome travel
  teleports the player.
- Tests: test_camera_touch rewritten (12), new test_player (7);
  test_world_scene teleports the player instead of moving the camera;
  bench_pan detaches the follow.

## 2026-09-24

### Barrens - 3de15ee on `main`

User report: most deserts were cold or snowy, few had cacti. The Desert
score only looked at moisture and vegetation, and cold ground is sparse
anyway (high ground is both cold and wind-dried). `BiomeClassifier` now
splits dry, bare land by warmth (`BARRENS_TEMP` -0.2..0.05) into Desert and a
new base biome **Barrens** (halved where Tundra is full). Barrens copies
Desert's biome weights in every resource that lists Desert, except cactus
(0). Barrens has its own plant, `resources/species/sagebrush.tres` (sprite
(17,9), a patchy scrub, silver-green; evergreen; strict to Barrens; cold (1
from -0.6 to -0.15, 0 at 0.15), dry, bare ground), a second member of the
desert_plants guild. Unused plant sprites that would suit it later: (18,9)
dense scrub (rabbitbrush), (11,9) arching stems (needlegrass), (14,5) low
mound (cushion plant). Tests: test_ecological_profiles checks Desert is warm
and Barrens cool, and cacti and sagebrush stay in their biome (real species
shares); test_polish counts sagebrush as a shadow caster. Snapshot
re-recorded: only ground_cover 117 -> 118 (biome-weight blending shifts where
Desert, Barrens and Tundra meet). Only the related suites were run
(ecological, polish, snapshot, terrain). No Barrens subtypes yet (the Desert
"Cold" subtype still labels Desert's cool fringe). Shares in tuning-log.

### Oceans and seas - PR #27

Bigger oceans without shrinking land, seas less common, lakes kept:
continent-scale elevation at 0.3x the frequency (0.004 -> 0.0012). Ridges are
full mountains on high ground but only hills in the lowlands (never below
`lowland_ridge_level` 0.2 - their troughs had scattered the lowlands with
ponds) and fade out just below the coast (`COAST_FADE`), so oceans are large
open bodies with ragged hilly shores. Open (unbounded) water is always Ocean
- the `water_region` noise is gone (+14 is now unused); Sea = an enclosed
body with a strait to open water. Lakes are their own feature: `_lake` noise
(seed +21, freq 0.012) basins above `lake_threshold` 0.87, up to
`lake_max_elevation`, not in coastal flats. `SHALLOW_DEPTH` 0.03 -> 0.008
(gentler shelf). Shares in tuning-log. Tests: ambience scans the nearest ocean
coasts (BiomeFinder), shores adds a lake centre (-600, 80), the snapshot adds
a coastal area (-1920, -2280) and was re-recorded.

### Shadows per resource; cactus - PR #26

`ResourceDefinition.casts_shadow` replaces `ResourceGuild.shadow_size`.
Trees, dead trees, berry bushes, grasses (meadow, pioneer, beach,
saltmarsh), flowers (wildflowers, fireweed) and cacti cast; rocks, ore, logs
and mushrooms don't (herbs, reeds, cattails, shells, mud neither). Cactus
(sheet tile (0, 9)): new `desert_plants` guild after shrubs in the guild
stack, cover from the cactus's own suitability (`cover_field` ""): hot
(temperature > ~0.1), desert-dry (moisture < ~0.28), bare (vegetation <
~0.18), Desert only. New `ResourceDefinition.strict_biomes` makes biome
weights use the tile's own base biome instead of blending across biome
edges, so none stray past a desert's edge; cold deserts get none. Casts a
shadow; rigid-ish (sway 0.05), no seasonal colour, no quality profile.
test_ecological_profiles checks 494 cacti around seed 1337 (1900, -2980),
none outside hot desert.

### Surf 2 - PRs #24, #25

Swash whiter (nearly white from the waterline for most of its run, first row
always washed - no hard water/ground edge) and on every ground type on a sea
shore (grass keeps its seasonal tint via `WASH_GRASS_CODE`). Diagonal
corners: shore shapes include corner neighbours (46 shapes) so foam and
swash bands round corners instead of stepping. Offshore whitecaps on shallow
sea (`SHALLOW_CODE` + shallowness). Surf is ocean / sea only - lakes and
rivers stay plain water (user decision, PR #25). test_ambience 21 checks;
checked on the GL renderer at seed 1337 coast (-78,-55) and river (-5,8,
plain). Cost in tuning-log.

### Surf - PR #23

Waves slower (about half speed) and noisier: drifting value noise bends the
fronts and varies their speed by place and over time, plus fine ripples.
Shoreline foam: open sea / lake tiles beside land flicker with white foam
that surges toward the land edge and back; sand / gravel beside open water
gets swash (wet darkening + foam specks riding up the beach). Frozen or
partly frozen water and rivers don't foam. Codes carry a 4-bit shoreline
mask, computed from elevation so they match across chunk borders; view
switch unchanged within noise. Checked on the GL renderer at seed 1337
(-75,-57). test_ambience 19 checks; snapshot `image_material` re-recorded
(alpha codes only).

### Water tweak - PR #22

Glints toned down (strength 0.3, ~10% of tiles) and steady - a fixed spot
per tile from a hash, no fade in/out; waves and glints scale with liquidity,
so frozen seas and lakes are still (codes moved to 200..220 to stay clear of
`GRASS_CODE` 253). Checked on the GL renderer: two frames 4 in-game hours
apart have glints in the same pixels while the waves move.

### Pinch: lifting one finger no longer snaps the camera - PR #21

User report (mobile): lifting one finger of a pinch snapped the camera
toward the other finger. Cause: one-finger panning used `event.relative`,
and after a lift the browser can renumber the remaining finger (or report
its motion relative to the lifted one) - a jump by the finger gap.
camera_rig.gd now pans by its own stored finger positions, re-baselines
remaining fingers after any lift (`_settle`: the first move after a lift
doesn't pan), and adopts a renumbered or unknown finger as the nearest
tracked one. test_camera_touch +1 check (fails on the old code). Not
reproducible on a real phone here - user to confirm.

### Polish pass 2 - PR #20

Seasonal colours (sprites by `season_class`: 5 deciduous, 4 evergreen, 7
grass, 2 flower; grass ground via the terrain shader), water shimmer,
ambient particles (fireflies, pollen, butterflies, leaves, sand, snow) by
place, time, season and wind. Sound and textured ground left out (sound
needed assets; textured ground was parked by the user). Checked on the real
GL renderer: spring noon (pollen), autumn forest (orange / bare deciduous,
green pines, golden grass, leaves), summer night (glowing fireflies, water
glints), windy desert (sand), winter tundra (snow). Snapshot: only
`image_material` re-recorded (World / Terrain Only images are RGBA with tile
codes; colours unchanged). New `tests/test_ambience.gd` (17 checks);
test_terrain compares RGB only.

### Cast shadows - PR #19

Replaces pass 1's ovals: silhouettes of the sprites (trees, shrubs, rocks,
ore, deadwood; not grass) flattened onto the ground, swaying with their
plant, thrown by the sun (06:00-18:00, west in the morning, short at noon,
east in the evening; length capped at 1.3 x height) or faintly by the moon,
fading at dawn and dusk (`scripts/render/sun_shadow.gd`,
`shaders/cast_shadow.gdshader`, shared `shaders/wind_bend.gdshaderinc`). All
shadows on one World/ShadowLayer under every sprite. Checked on the real GL
renderer at 07:30 / 12:00 / 16:30 / 23:00. test_polish now 11 checks (sun
direction, noon shortest, moon fainter, horizon fade, minute-by-minute
smoothness, one layer, freed with markers). Which resources cast was later
made per resource (PR #26).

### Polish pass 1 - PR #18

All small-effort items, with my defaults (no questions needed): harvest pop
+ specks, drifting cloud shadows (subtle: darkness 0.32, ~42% cover,
gameplay views only), soft ground shadows under trees / rocks / ore / shrubs
/ deadwood (none under grass), 0.2 s chunk fade-in, flick momentum + eased
wheel zoom, desktop hover outline. Checked on the real GL renderer under Xvfb
(shadows, harvest pop mid-animation, clouds - the first coverage edge assumed
uniform noise and showed almost nothing; now calibrated). New
`tests/test_polish.gd` (7 checks), test_camera_touch +3 (momentum, no glide
after a stopped drag, eased wheel). Candidates listed for pass 2: water
shimmer, ambient particles, seasonal colours, sound, textured ground.

### Wind sway - PR #17

No weather yet. `ResourceDefinition.sway` data (grass 1.0, flowers / reeds /
beach grass 0.9, herbs / cattail / saltmarsh 0.8, berry bush 0.45, young tree
0.4, palm / willow 0.35, other trees 0.25; rocks, ore, logs, snags,
mushrooms, shells, mud 0); `shaders/sway.gdshader` (sway via the sprite
colour's alpha, top vertices bent downwind, whole-pixel steps, max 3 sprite
px); `scripts/render/wind.gd` (direction and strength from in-game time,
animation capped at x4, paused = still). New `tests/test_wind.gd` (8
checks). Verified on the real GL renderer under Xvfb (1263 px moved between
two wind phases, sprites opaque and crisp). Not yet seen animated by the
user.

### Time controls - PR #16

`<<` / play-pause / `>>` buttons above the clock
(`scripts/ui/time_controls.gd`, `UI/TimeControls`); rewind and fast-forward
each have 3 speeds (x4, x16, x64; each press steps and wraps); play-pause
pauses at normal speed or returns to normal from rewind / fast-forward; the
clock label adds "Paused" / ">> x16". Rewind only moves the clock (harvests
stay), clamped at minute 0. Clock saves throttled to one per 10 s at speed.
Plain-text button labels (the default font may lack arrow glyphs).
test_game_clock +3 checks.

### In-game time - PR #15

All constants in `scripts/world/game_clock.gd`: 1 in-game minute per real
second (a day = 24 real minutes), new worlds start 08:00 on Spring 1, Year
1; four seasons x 30 days; keyframed tint (night (0.34, 0.38, 0.62), warm
dawn 6:00 / dusk 18:30, white 7:30-17:00); only World and Terrain Only are
tinted (data and debug views stay true); clock label bottom-left above the
position readout. Time is saved per seed in the WorldChanges file ("time"),
on each in-game hour, harvest, seed switch and window close - on web a
closed tab lost up to one in-game hour (W6 later added saves on focus loss
and pause). New `tests/test_game_clock.gd` (21 checks: calendar rollovers,
formatting, no backwards time, tint shape and minute-by-minute smoothness
incl. midnight wrap, save format, scene: clock runs, World / Terrain tinted,
data views untinted, label text, per-seed save/restore across seed switches
and reload). Tint look only checked numerically.

### Mobile web on-screen keyboard - PR #14

Export preset `html/experimental_virtual_keyboard=true` (was false: no
keyboard appeared); `SeedReload.close_keyboard()` (release GUI focus +
`DisplayServer.virtual_keyboard_hide()`) on seed submit / Randomize / Reload
and on any map press (camera_rig.gd). test_camera_touch +1 check (focus
released by map tap, map click, seed action). The keyboard itself is only
testable on a phone - user to check on iOS / Android.

### Phase 18: developer tooling - PR #13

Four generic Debug views (Debug: Suitability / Density / Patch Noise /
Placement) for any guild-stack member, picked in a "Debug resource" dropdown
(`scripts/ui/debug_resource_dropdown.gd`, visible only in Debug views);
right-click in a Debug view adds a factor breakdown to the info panel
(`ResourceManager.explain_suitability()` + guild cover / patch or stand /
best / share / density). The oak-only debug views stay (tests, snapshot).
New helper `ResourceManager.get_guild_cover()` (used by get_guild_density,
no behaviour change). Plan doc Phase 18 amendment, architecture §7, README.
New `tests/test_debug_tools.gd` (10 checks: explain == get_suitability for
31500 resource x tile cases, 8601 nonzero; view colours per tile; members'
densities sum to the guild's; Placement = exactly the real stack's pines
(138/138); resource switch rebuilds; breakdown only in Debug views; the
dropdown lists all 35 resources, follows the current one, only visible in
Debug views).

### Phase 16: world persistence + click-to-harvest - PR #12

User decisions: left click / tap = harvest, right click / long press (0.5 s)
= info. Saving is automatic (my call; no save button). `WorldChanges`
(`scripts/world/world_changes.gd`): key "<guild id>:<cell>" ->
{resource_id, harvest_state}, re-validated by resource id on every read
(stale changes never apply to a different object), JSON per seed at
`user://world_changes/<seed>.json` (format version 1), saved after each
harvest, loaded on start and seed change. Harvest removes any placed
resource (markers redrawn from the chunk's shown placements); info on the
spot says "harvested", health 0. No yields or inventory, no regrowth;
procedural placement untouched (lower guilds don't fill the gap). Tests
never use the player's save dir (scripted-SceneTree guard in
`changes_path()`). Plan doc Phase 16 amendment; architecture §7; README
controls. New `tests/test_world_changes.gd` (24 checks: store,
re-validation, JSON / version / seed / malformed, file round trip, scene
harvest -> one marker fewer + saved + info "harvested" + no re-harvest,
reload keeps it gone, other seed clean and switching back restores, stale
change ignored, default dir unused under tests); test_camera_touch +2 (long
press = info once while held and no harvest on release; left = harvest,
right = info). The user confirmed on the web build that right click and
reload persistence (IndexedDB) work.

### Phase 15 groundwork: ResourceInstance - PR #11

User decisions: build records on demand (not for every placed object), size
is data only (do not scale sprites), no harvesting or mechanic yet, no
saving. `ResourceInstance` (`scripts/resources/resource_instance.gd`): key
"<guild id>:<cell>", guild, cell, resource id, position, quality + tier,
size (`ResourceDefinition.base_size` x `QualityProfile.size_by_quality` at
its quality: trees 0.5-1.5, berries / ore 0.7-1.3), max_health
(`ResourceDefinition.max_health`, default 100, untuned) x size, health
(full), harvest_state "available". `ChunkManager.get_resource_instance(inst)`
is the one lookup point (inspector -> "entity", Quality view). Inspector
shows "Size / Health / State". Plan doc Phase 15 amendment, architecture §7.
New `tests/test_resource_instance.gd` (8 checks: data; records for all 3016
placed instances of all 9 guilds in two regions match their sources field by
field; unprofiled resources; unique keys; tree size young 0.71 < mature 0.96
< old growth 1.32; identical records from another rect, cold caches, reverse
order; unknown id -> null); test_world_scene checks the entity line.
Placement unchanged (snapshot passes without re-recording).

### Phase 14 part 2: clustering - PR #10 (d57a0f0)

New generic guild option `cover_sets_area`
(`ResourceManager.get_stand_membership()`, measured patch quantiles
`PATCH_AREA_THRESHOLDS`): cover x best member score = share of ground in
dense stands, density inside = base_density. Data alone (smaller spacing +
steep cluster curve) left open country with thin, even clumps. Canopy trees:
stand mode, spacing 2.0 -> 1.2, cluster_scale 48 -> 32, base_density 0.7,
cover capped 0.8. Surface rocks: stand mode, spacing 1.5 -> 1.2,
cluster_scale 24 -> 16, cover curve x0.7. Ore outcrops: spacing 3.0 -> 1.5,
stricter density_curve. Quality re-tuned for it (shade is ~0.7 inside every
stand now: tree age = edges young, old growth from fertile moist undisturbed
ground). Found and fixed on the way: a linear patch-threshold formula still
admitted ~5% of tiles at a tiny area share (desert oak 0.02 -> 0.60 per 100
tiles); replaced with the measured quantile table (share 0 admits nothing),
checked by the stand-share calibration test. BENCH_THREADED=0 first showed a
whole dense canopy chunk placed in one inline step; fixed by
`_warm_guild_density()` steps (density at the placement candidates, 4-row
bands, `ResourcePlacement.candidate_tiles()`). New `tests/test_clustering.gd`
(8 checks). Snapshot re-recorded once (agreed change: canopy 313 -> 825,
rocks 552 -> 589, ore 49 -> 59; lower guilds lose ground to the denser canopy
- shrubs 189 -> 156, wetland 240 -> 186, ground cover 122 -> 98, deadwood 190
-> 156, pioneers 197 -> 189, shore 101 -> 98; Oak Placement unchanged; every
image hash changed - shade and forest floor follow the stands). All 13 suites
pass. Details: plan doc Phase 14 "clustering as implemented", architecture
§7. Numbers in tuning-log.

### Phase 14 part 1: quality - PR #9 (e84ac19, commit e65fb66)

Branch `claude/phase-14-start-4zcb39` from `main` 8f9b67d (cloud).
`QualityProfile` (extends `ResourceDefinition`; `resources/quality/`:
`tree_age` on the 7 mature tree species, `berry_yield` on berry_bush,
`ore_richness` on iron / copper / coal / clay / salt; young_tree has none) ->
`ResourceManager.get_quality()` (profile suitability x deposit potential for
ores + per-instance jitter from `ResourcePlacement.instance_roll()`, the
(guild id, cell) key hash, salt 6 - no new noise offset) and
`get_quality_tier()`. Surfaced as the inspector's "Quality" line and a
"Quality" view (markers red -> green). Quality is computed only for shown or
inspected instances. Decisions: plan doc Phase 14 "quality as implemented";
architecture §7. Verified (cloud, Linux, Godot 4.7.2): all 12 suites pass
(234 PASS lines) incl. new `tests/test_quality.gd` (20 checks: profile data +
wiring, tier_for, the math (jitter bounds, no profile -> -1), range over 6044
placed instances, chunk path == direct from a fresh WorldGen, order / rect /
cache independence, every tier >= 5%, driver correlations) and a
Quality-view + inspector check in test_world_scene. Placement snapshot
unchanged (not re-recorded). Renders of the Quality view at 0,0 and
12000,-7000 inspected: grove interiors green (old growth), open-grown trees
orange / red. `tests/bench_views.gd` also times QUALITY. Shares and
benchmarks in tuning-log.

### Pinch zoom drift fix - 7fa792b on `main`

User report: pinch zoom caused sporadic camera movement. camera_rig.gd
dropped the emulated-mouse mirror of touches (Godot dispatches it BEFORE the
touch, so the old guard never fired: 1-finger and 2-finger pans ran 2x, the
first finger yanked the camera mid-pinch), pinch now zooms around the finger
midpoint, and a pinch never counts as a tap. Guarded by
`tests/test_camera_touch.gd` (real input pipeline; hides the UI because
headless viewports are 64x64).

## 2026-09-23

### Sprites: one tile each, baked outlines - df24b15 on `main`

Every resource sprite 12x12 = one tile (the 7 mature trees were
sprite_size 2); outlines baked once per sprite tile
(`ResourceMarkerChunk.outlined_image()`: 1 px ring in 8 directions + enclosed
dark detail, one draw per sprite, snapped to its pixel grid - replaces four
offset copies that left corners open and let ground show through); sprites
drawn centred in the tile their instance falls in (data positions unchanged)
and clicks picked the instance in the clicked tile. Verified with
test_world_scene + the placement snapshot (the user stopped the final
full-suite run and asked to merge). Known: two instances of different guilds
can occasionally share a tile and overlap. (Pivots and picking changed again
in the 2026-09-25 art style.)

### Phase 13.5: terrain surface layer - f9eafe7, merged to `main`

Branch `claude/phase-13.5-terrain-surface` from `main` 0e0a10e (local
Windows). Ground is one data-driven `SurfaceMaterial` per land tile (12
materials in `resources/terrain/`; `TerrainSurface` chooses by suitability x
prevalence x per-material patch noise, seed offset +20; shade on a 4-tile
lattice). The old averaged `debug_colorizer.gd` is deleted; the default view
is RESOURCES ("World" = terrain + every placed resource), MATERIAL is
"Terrain Only"; the inspector shows "Ground". New generic
`ResourceDefinition.vegetation_curve`. Details and first-pass mixtures: plan
doc Phase 13.5 "as implemented" amendment and architecture §5. New
`tests/test_terrain.gd` (20 checks: data, per-biome mixtures, coherence,
every material only where its cause is, determinism, chunk path == direct);
all 11 suites pass on Windows. Placement dump byte-identical to `main` - only
5 image layers changed; snapshot re-recorded with SNAPSHOT_WRITE=1 (agreed:
the plan says image hashes change in this phase). Renders of grassland,
forest, swamp, desert, plains and tundra inspected: organic patches, forest
floor under groves, bare dirt + burnt ground on scars, dry grass and sand in
dry country. Open (first pass): material curves and colours; Beach tiles are
~50% rock (eroded coasts); cold deserts get ~10% snow; the snow line is a
speckled, patchy band (temperature micro-jitter vs patch noise). Optimisation
lead if fill time matters (web startup now places resources too): a leaner
suitability path for ground (`get_suitability` allocates arrays per call, x12
materials per tile), or skip materials whose required curves are cheaply 0.
Benchmarks in tuning-log.

### Phase 13: correlated ecosystems - 68be1f0 (with 61aea15, eb23a75), fast-forwarded to `main`

Branch `claude/phase-13-correlated-ecosystems` from `main` 98473c8 (local
Windows); the user delegated the design questions (decisions.md; plan
Phase 13 Amendment).

- Snapshot guard fixed first (61aea15): the 9-layer Windows mismatch was the
  C runtime's `%.6f` tie rounding, not placement (dev-workflow.md). Golden
  re-recorded from unchanged output; `bench_views.gd` gained
  `BENCH_THREADED=0` (eb23a75).
- Canopy shade: `ResourceManager.get_shade()` = density of
  `ResourceManager.SHADE_SOURCE` (canopy_trees), kept on
  `EnvironmentalState.shade` / `shade_known`, attached automatically by
  `get_member_scores()` for guilds with a shade-reading member
  (`ResourceGuild.reads_shade()`), and in the chunk path's guild density
  from the canopy density memo. New `ResourceDefinition.shade_curve`. New
  "Shade" view (dropdown: shade heatmap + ground cover / deadwood / shrub
  markers) and a "Shade" line in the tile inspector.
- Data (first pass): required shade curves on meadow_grass (1 to 0.1, 0.3 at
  0.45, 0.15 at 1), wildflowers (1 to 0.08, 0.2 at 0.4, 0.1 at 1), berry_bush
  (1 to 0.25, 0.55 at 0.6, 0.4 at 1); mushrooms a preference curve (0.03 at
  0, 0.1 at 0.12, 1 from 0.4), with their biome_weights removed; grass
  Forest / Rainforest weights 0.25 / 0.1 -> 0.5 / 0.25, flowers 0.3 / 0.2 ->
  0.6 / 0.4. Wild herbs unchanged (shade-tolerant).
- Floodplains: no data change - already emergent from the Phase 10-12
  fields; locked in by the new test.
- New `tests/test_correlations.gd` (22 checks: warnings; shade source clean
  (no canopy member reads shade); which guilds read shade; shade curves 1 at
  0 except the shade-dependent mushrooms; shade in [0,1] and == canopy
  density, cached, deterministic; open ground (shade 0) suitability identical
  to the species without a shade curve; placement: mushrooms / herbs above
  the vegetated-land background shade, grass / flowers below, berries in
  between; ground cover placement deterministic; floodplain density and
  willow / reed shares; chunk-path shade == direct get_shade()).
  test_world_scene checks the Shade view and inspector line. All 10 suites
  pass on Windows.
- Snapshot re-recorded (SNAPSHOT_WRITE=1, agreed): only deadwood 193 -> 190,
  ground_cover 123 -> 122, pioneer_plants 198 -> 197 (via the stack filter),
  shrubs 192 -> 189 changed; every layer above the canopy, Oak Placement and
  all images identical.
- Renders (OUT_PNG, seed 4242) of the origin forest edge and the river
  floodplain at 18000,8820 inspected: grass and flowers in the open band and
  clearings, herbs / mushrooms / berries under groves, willows on the banks,
  no seams. Measurements and benchmarks in tuning-log.
- Candidates if more correlation is wanted later: shade for pioneers (their
  succession curves already encode canopy closure), a species that depends
  on shade the way mushrooms do (ferns), berries tuned toward forest edges.

### Phase 17 steps 5-6, closed for now - d311baa, 274f036, 88819ef on `main`

Branch `claude/phase-17-chunk-streaming` (local Windows), fast-forwarded
into `main`.

- Step 5 (user goal: "while zoomed in, slowly pan the camera, load/unload
  chunks smoothly without stuttering"; desktop-only was acceptable if web
  couldn't keep up). Diagnosis: `_update_chunks()` generated every newly
  needed chunk synchronously in one frame - crossing a chunk boundary at zoom
  4 built a 9-chunk column (17 diagonally). Rendering is not a cost (windowed:
  Resources draws in ~0.8 ms, 52 draw calls; off-screen chunks are culled).
  Fix: chunk jobs (architecture.md §5): content built as data, nearest first,
  on one worker thread (the generation lock owns all generation state; the
  main thread only applies results within `APPLY_BUDGET_USEC`); main-thread
  fallback within `INLINE_BUDGET_USEC` where threads are unavailable (web).
  View and LOD changes go through the same queue via `_epoch` (stale chunks
  keep old content until rebuilt), so view switches and zoom LOD changes no
  longer freeze either. `flush_chunk_work()` for tests; new
  `tests/bench_pan.gd` measures per-frame time and "holes" (visible chunk not
  loaded) during a pan. Snapshot instance dump byte-identical. All suites
  passed except the then pre-existing Windows snapshot-hash mismatch (fixed
  in Phase 13).
- Step 6 (user: "option 1", then merge so web builds): the web fallback runs
  chunk jobs as small steps (`job_steps()`), so one Resources chunk spreads
  over many frames instead of costing one 40-130 ms frame. The first
  per-chunk step profile showed a guild's first placement in a fresh chunk at
  up to 15-20 ms (it samples + classifies every candidate tile), so the
  fallback adds `_tile_env()` warm-up bands; the worker skips them (no
  throughput change). test_world_scene checks the stepped build matches
  one-go placement (2324 markers). Trade-off: at 5 ms of work per frame a cold
  Resources view takes ~1300 frames to fill all 81 chunks (nearest first -
  the screen itself fills in about the first tenth).
- Same branch, user requests: desktop seed UI - the seed field (Enter) and
  Randomize show on desktop and regenerate the world in place
  (`ChunkManager.regenerate()` via `SeedReload.apply_seed()`; web still
  reloads the page); Reload stays web-only and on desktop the view dropdown
  moves up into its slot; covered by test_world_scene (Enter, text seed,
  Randomize, back to 4242 gives identical objects) (439f0c7). "Go to biome"
  dropdown under the view dropdown - moves to the nearest tile of a base
  biome, or to the next patch if already in one (`BiomeFinder`, threaded,
  own WorldGen copy); covered by test_world_scene (two Desert trips from the
  origin land on two different patches, ~0.4 s each); web ran the search
  inline, not measured (c01fd23). Smaller UI + position readout (01aa142).
- Closed (88819ef): the user checked web panning by eye after step 6: "way
  better, almost on par with desktop" (no web timings). Parked (each needs
  agreement; TODO.md "Later"): more worker throughput (per-worker generation
  caches + a WorkerThreadPool - only for very fast pans or zoomed-out
  Resources); LOD / aggregation per the plan's Phase 17 sketch; cheaper
  per-chunk density (GDScript trimming, or native code - the biggest lever,
  but web extensions are off); splitting the WaterTopology flood fill (the
  last ~15-40 ms single-sample spike); merging biome-overlay border segments
  (one draw_line per tile edge today). Timings in tuning-log.

### Phase 17 guard + steps 1-4 - PR #8 (a22a1eb)

Rule for every step: output identical, checked by
`tests/test_placement_snapshot.gd`.

- Guard: `test_placement_snapshot.gd` places the full guild stack + Oak
  Placement for seed 4242 over six 3x3-chunk areas (origin forest, river
  18000,8820, storm scar -540,-2060, fire scar 1760,-870, wetland
  8000,-12000, sea coast 19946,20042) through the real chunk paths, bakes 5
  views' images at LOD 1/2, and compares per-layer count + md5 with
  `tests/placement_snapshot.txt` (recorded from unchanged main, 2088 lines).
  `SNAPSHOT_DUMP=path` writes the lines for diffing; `SNAPSHOT_WRITE=1` only
  for an agreed output change. `tests/bench_views.gd` prints cold Oak / Tree /
  Resources / Material switch times (`BENCH_REPEAT=n` for min of n; not in
  run_tests.sh).
- Step 1: `_tile_env()` caches EnvironmentalState + `classify_full()` per
  tile, per chunk, FIFO-bounded at `ENV_CACHE_CHUNKS` = 48 (~5 KB/tile, so
  the ~121-chunk Resources footprint is not kept whole; an unbounded cache
  gained nothing). `_density_memo()` memoizes guild (and Oak) density per
  tile in a PackedFloat64Array per id and chunk (NAN = unknown; Float64 so
  accept rolls compare against the exact value), shared by the placement
  callbacks and the density heatmaps, cleared like the raw guild chunks.
  Images and placements are processed row-major.
- Step 2a: placement skips candidates that can't pass.
  `ResourcePlacement.place_in_rect()` / `place_guild_in_rect()` take an
  optional `density_bound`: a candidate whose accept roll is >= it is
  rejected without calling density_fn. `ResourceManager.get_density_bound()`
  / `get_guild_density_bound()` = clamped base_density (1.0 when a guild has
  a density_curve) - exact because every other factor is in 0..1 and float
  products never round above a factor multiplied down from. The snapshot
  test also checks density <= bound on 1536 tiles x every guild + oak.
- Step 2b: `get_suitability()` evaluates the categorical weights first and
  returns 0 on a zero weight (a rock off its geology, a land plant on water)
  before touching curves, and appends them after the curve factors as before
  (float product order kept). Curves come from a per-definition list
  (`ResourceDefinition.curve_plan`: [curve, state field StringName,
  required] for non-null curves) built on first use and reset by setters on
  every curve property and `required_curves`. test_resource_guild section 7
  checks reassignment after first use.
- Step 3: rebuilding loaded chunks (view or LOD change) bakes each chunk's
  image and then its markers in one row-major pass, so both read a chunk's
  tiles while the env window still holds them.
- Step 4: the density memo is `_density_chunks[id][chunk]` (no Array keys)
  with one lookup per call (`_density_memo()`, written through);
  `ResourcePlacement._place` rolls accept first and hashes jitter / priority
  only for candidates under the bound (`_candidate()` -> `_jittered()`;
  survivors no longer carry "accept").
- Profiles and timings in tuning-log.

### Phase 12: ecological profiles - PR #6

Every category in plan Phase 12 has a data-driven definition (checked by
test_ecological_profiles). All data except one curve field:

- `ResourceDefinition.rock_exposure_curve` (WorldGen's `rock_exposure`).
- New guild `ground_cover` (cover from vegetation_potential 0.05 -> 1 at
  0.25; base 0.35, spacing 2, patch 20/1.0 with a steep cluster curve; last in
  the stack, in the Resources view). Members all require succession 0 at 0.45
  -> 1 at 0.7 (pioneers own younger scars): `meadow_grass` (15,5) open
  country, `wild_herbs` (12,9) moist fertile woodland, `wildflowers` (13,9)
  temperate meadows.
- `birch` (1,34), size 2: canopy member, cool (-0.6..0.1) and moist,
  succession 1 at 0.6..0.85 falling to 0.6 at 1 (a pioneer tree that
  persists).
- `mushrooms`: succession curve 0.3 (not 0) on mature ground, plus biome
  weights (Forest / Rainforest 1; removed again in Phase 13).
- `surface_rocks` gains `limestone` (7,11) (well-drained, moist), `shale`
  (9,11) (low, poorly drained, deposition) - both sedimentary-only like
  `sandstone`, which now prefers dry ground; `gravel` (17,5) (erosion
  required with a 0.1 floor, river_affinity 0.6: scree and banks) and
  `exposed_stone` (9,5) (requires rock_exposure 0.5 -> 1 at 0.8, any
  geology).
- New `tests/test_ecological_profiles.gd` (14): every plan category has a
  definition; no curve warnings; nothing on water; each new species placed;
  ground cover only at succession >= 0.45; grass open / herbs wooded; birch
  only where temperature <= 0.1; forest-floor mushrooms; sedimentary rocks
  only on sedimentary geology; exposed stone only at rock_exposure >= 0.5;
  gravel on eroded ground or banks. test_succession no longer requires
  mushrooms to be scar-only; test_resource_guild accepts the new rock types;
  test_world_scene counts ground cover.
- Render (seed 4242, 8000,-12000, sedimentary Wetland) inspected: birch /
  pine forest, shale / limestone boulders, fireweed on a scar; cattails
  dominate that area (Phase 10 behaviour, Wetland biome). Per-biome numbers
  in tuning-log.

### Phase 11: succession - PR #5

All data except two new sample keys:

- `WorldGen.sample()` gained `succession` (0 fresh scar .. 1
  mature/undisturbed) = 1 - footprint x (1 - disturbance_age), footprint =
  the scar's distance falloff before the age fade, so it is exactly 1 outside
  any scar and per-blob type / age can't leak (prep Traps 1 and 2); and
  `vegetation_potential` = vegetation before the (1 - disturbance) penalty.
  Both in EnvironmentalState and architecture.md §2.
- ResourceDefinition: `succession_curve` and `disturbance_type_weights`
  (keyed fire / flood / storm / landslide, applied as lerp(1, weight, 1 -
  succession) in the geometric mean - neutral outside scars).
  `get_suitability()` returns 0 as soon as a required curve is 0 (same
  result, skips the rest).
- Stages: canopy trees, shrubs and the new guilds take cover from
  `vegetation_potential` and members' required succession curves pick the
  stage, replacing the blanket scar penalty (oak's `disturbance_affinity =
  -0.15` removed): mature trees 0 at <= 0.55 -> 1 at 0.85; new canopy member
  `young_tree` (sprout (1,9), broad tree climate) 0.35 -> 1 at 0.55..0.8 -> 0
  at 0.95; berry_bush 0 at <= 0.15 -> 1 at 0.3..0.7 -> 0.8 at 1 (shrubs
  base_density 0.6 -> 0.75 keeps undisturbed berries unchanged).
- New guild `deadwood` (canopy's cover curve = only formerly wooded scars;
  base 0.4, spacing 2, patch 24/0.6): `dead_tree` snag (5,10) succession 1
  until 0.3 -> 0 at 0.5, fire-weighted; `fallen_log` (0,25) peak 0.1..0.45,
  storm / landslide-weighted; `mushrooms` (3,10) peak 0.35..0.65, moist only.
- New guild `pioneer_plants` (cover 0 at vegetation_potential 0.03 -> 1 at
  0.15; base 0.5, spacing 1.5): `pioneer_grass` (5,9) peak 0.2..0.45,
  flood-weighted; `fireweed` (8,9) peak 0.25..0.5, fire-weighted. Fresh scar
  centres (succession < ~0.1) stay bare apart from deadwood and the surface
  rocks.
- Stack: ... shore features, deadwood, shrubs, pioneer plants (pioneers last,
  on whatever ground remains). The Resources view draws both; new debug views
  `SUCCESSION` (heatmap, in the dropdown) and `SUCCESSION_PLACEMENT` (not in
  the dropdown).
- New `tests/test_succession.gd` (12): no curve-domain warnings; succession
  in [0,1], exactly 1 wherever disturbance is 0; vegetation_potential >=
  vegetation and equal outside scars; determinism; type weights neutral at
  succession 1; deadwood / pioneers / young trees never on undisturbed land;
  stage order by mean succession of placed instances. test_world_scene counts
  deadwood / pioneers in the Resources view (none in its origin area).
- Renders (OUT_PNG, seed 4242) of a fresh storm scar (-540,-2060) and fire
  scar (1760,-870) inspected: bare centre with snags / logs / rocks, pioneer
  ring, then young and mature trees outward.

### Last sprites; sprite swap

- Last sprites (user picks): shells = (20,5), the two round pebbles at the
  right end of row 5; mud = (11,34) streaky marsh texture; salt = (4,22)
  crystal cluster; each 1 tile, tinted cream / brown / white. Every placed
  resource in the Resources view is now a sprite; the scene test checks no
  fallback shapes are left (fallbacks still work for any future member
  without `sprite_tile`).
- Sprite swap (user pick, just before): clay outcrops use (5,13) - the
  scattered-pebble tile right of the rock tiles, slate-blue tint - and coal
  moved to the dark lumps at (13,18) so no two deposits share a tile. Other
  candidates from a full-sheet scan (the right ~2/3 of the sheet is
  characters and letters, objects are in the left third): shells (6,15)
  snail shell / (7,14) crab / (14,18) shrimp; mud (10,34); salt (5,22) /
  (18,34) dotted flats.

### Phase 10 steps 3-4: river mouths and shores

User: "finish phase 10".

- Measured first (tuning-log): river mouths exist but with weak river
  values, so mouth species key on river + shore together at low thresholds,
  no new field. Lake-only shores are why salt and shells needed a
  lake-vs-sea signal.
- New `WorldGen.sample()` key `shore_salinity` (0 lake shore / no shore .. 1
  sea shore): the shore_proximity probes check all 4 directions
  (shore_proximity itself unchanged) and classify each wet probe with
  `WaterTopology` (salty = open or strait-connected, the same test as
  water_body). `EnvironmentalState.shore_salinity`, new
  `ResourceDefinition.salinity_curve`. sample() cost unchanged.
- River mouths: `mud` (shore_features guild; required river 0.01 -> 0.08 and
  shore 0.05 -> 0.25, flat); reeds reach mouths (river curve 0 at 0.03 -> 0.6
  at 0.12, shore_affinity 0.3). Sediment at mouths = the mud flats (clay stays
  river-bank-only).
- Shores: new guild `resources/guilds/shore_features.tres` (shells on sea
  beaches: shore 0.45 -> 0.7, salinity 0.4 -> 0.8; beach_grass on beaches /
  dunes: shore 0.3 -> 0.5, any salinity; mud) - cover from shore_proximity (0
  -> 1 by 0.02, so inland candidates skip member evaluation), spacing 1.5,
  footprint 0.35, in the stack after wetland plants. `mangrove` joins canopy
  trees (hot >= 0.25..0.45, wet, coastal shore 0.25 -> 0.5, salinity; biome
  weights Swamp / Wetland 1, Beach 0.15; sprite (4,8)). `saltmarsh_grass`
  joins wetland plants (salty coastal marsh where cattails stop; sprite
  (4,9); same biome weights). `salt` deposit (hot, dry, flat, salinity >=
  0.5..0.9; exposure_field shore_proximity 0.3 -> 0.6 = coastal salt flats) in
  the deposits and ore_outcrops (hexagon fallback then). Beach grass sprite
  (7,9). New `SHORE_PLACEMENT` view mode (not in the dropdown).
- The first version put mangroves and salt marsh on sandy beaches; the Beach
  0.15 biome weight moved them into swamps.
- New `tests/test_shores.gd` (12 checks: warnings; salinity range and 0
  off-shore; lake and sea shores both occur; no sea-only species (shells,
  salt, mangrove, salt marsh) score on lake shores; coastal swamp favours
  salt marsh over cattail; reeds at mouths; real placement of all five new
  species only where they score > 0 and never on water; mud only at mouths,
  shells only on sea beaches; determinism). Coast render at (19925, 19985)
  inspected.

### Phase 10 step 2: floodplains; reed sprite

- Reed sprite (3,9) grass / stem tuft, straw tint; the wetland layer is all
  sprites.
- `resources/farmland.tres` (category "potential", not placed): required
  temperature (0 at -0.6 -> 1 at -0.1 .. 0.55 -> 0 at 0.85), moisture (0.2 ->
  0.4 .. 0.7, 0.4 at 0.85), elevation, slope (flat: 1 <= 0.002 -> 0 at
  0.008); preferences fertility (0 below 0.3 -> 1 at 0.75), deposition (0.35
  -> 1 at 0.12), river (0.35 -> 1 at 0.15), drainage; swamp 0.15, water 0. New
  "Farming Potential" view (dropdown, suitability palette) and a "Farming
  potential" line in the tile inspector.
- Tuning trail: the first version favoured banks too little - the floodplain
  factors now have lower floors. A render showed speckle along farmland's
  cold edge: WorldGen's temperature micro-jitter (+-0.06) flickering across a
  0.25-wide cold ramp; widening it to -0.6..-0.1 fixed it (slope and
  deposition were ruled out by removing them).
- Clay (`resources/deposits/clay.tres`) is a deposit like the ores but
  exposed differently: new `ResourceDefinition.exposure_field` (default
  "rock_exposure") + optional `exposure_curve`, read by
  `ResourceManager.get_exposure(state, definition)`;
  `get_exposed_deposit(potential, state, definition = null)` uses it. Clay:
  exposure_field "river", curve 0 at 0.03 -> 1 at 0.2 (river banks cut into
  clay beds). Potential needs flat low ground and sediment (deposition
  required, 0 -> 0.5 at 0.03 -> 1 at 0.1), prefers moisture, sedimentary /
  volcanic geology; broad beds (vein 28, sharpness 1.5) in districts (scale
  120, curve 0.5 -> 0.7). In the deposits list (Deposits view, inspector -
  which says exposed / hidden per deposit) and the ore_outcrops guild.
- New `tests/test_floodplains.gd` (9 checks: warnings; no farmland / clay on
  water or slopes > 0.008; farmland higher on flat banks; exposure =
  curve(river) for clay, rock_exposure for iron; clay exposed only on banks,
  rich share bounded; clay outcrops all on banks). The `test_deposits.gd`
  outcrop check is generalized to each member's exposure.

### Phase 8 step 6: sprites for trees, rocks, ore, berries and cattails

User request: "use the white versions of the sprites for the trees so we can
tweak their coloring".

- No earlier code had mapped tiles; the tree tiles were found by rendering
  the sheet: row 8 of `urizen_onebit_tileset__v2d0.png` holds oak (0,8), a
  dithered round tree (1,8), weeping tree (2,8), conifer (3,8), small round
  tree (4,8) and two palms (5,8) / (6,8); row 9 cactus / sprouts / grass /
  reeds / bushes; row 10 flowering shrubs, mushrooms, a stump (4,10) and a
  dead tree (5,10); vines at columns 23-24, rows 8-10.
- `ResourceDefinition.sprite_tile` (sheet column / row, (-1,-1) = none) and
  `sprite_color` (tint; separate from `debug_color`, which keeps the marker
  colours in the debug placement views). Trees: oak (0,8), olive (1,8),
  willow (2,8), pine (3,8), palm (5,8), tinted greens - meant to be tweaked
  in the .tres files.
- `resource_marker_chunk.gd` `Shape.SPRITE`: the one-bit sheet is white on
  OPAQUE BLACK, so `sprite_image()` converts each used tile to
  white-on-transparent (alpha = brightness) once and caches it; members
  without a tile fall back to a shape. Still one CanvasItem per chunk.
- Rocks and ore (user pointed at the sheet's bottom-left): row 13, columns
  0-5 are rock tiles (rows 11-12 are path / river connectors). Basalt (0,13)
  cracked block, sandstone (2,13) layered, granite (4,13) round boulder;
  outcrops iron (1,13) veined, copper (3,13) patterned boulder, coal (5,13)
  rubble (coal and clay changed in the later sprite swap). New
  `ResourceDefinition.sprite_size` (tiles; trees 2.0, rocks / ore 1.0 =
  native 12 px). The Deposits view keeps outcrop hexagons over its heatmap.
- Berries and cattails: berry_bush (0,10) flowering shrub, cattail (6,9) tall
  stems (checked by rendering rows 9-10 - an earlier note citing (5,9) /
  (7,9) for stems was wrong), tinted pink / tan. Layer entries take an
  optional fallback shape for members without a sprite (the wetland layer
  fell back to diamonds for reeds until they got a sprite).
- Tests: the scene test checks every Resources instance is a textured sprite
  in its species' sprite_color; `OUT_PX` sets the render's pixels per tile
  (12 = native). Renders at (18000, 8850) and (90, -265) inspected.

### Phase 9 step 2: ore outcrops - ba65c96

Done after Phase 10 step 1. New guild `resources/guilds/ore_outcrops.tres`
(iron / copper / coal; spacing 3, footprint 0.6, sharpness 8, no patch noise)
at the top of the stack (outcrops > rocks > trees > wetland plants > shrubs).

- Generic mechanisms, no ore special-casing in placement:
  `ResourceManager.get_member_scores(state, guild, seed, wx, wy, classified)`
  = each member's suitability, or for a deposit member (vein_scale > 0) its
  exposed deposit (0 without computing anything on buried rock).
  `get_guild_density()` and the species shares use it; for non-deposit
  guilds it equals the old `get_member_suitabilities()` (kept, tests use
  it). `ResourceGuild.cover_field = ""` means full cover. New
  `ResourceGuild.density_curve` (the plan's optional Phase 6 density_curve;
  unset = unchanged) reshapes the final density - outcrops: 0 below 0.02
  exposed, 0.5 at 0.1, 1 from 0.3. Without it, exposed values used as raw
  probabilities gave ~half as many outcrops.
- Drawn as hexagons (`Shape.HEXAGON`) in the Resources view and, over the
  heatmap, in the Deposits view; click-to-inspect names them ("Resource:
  Iron (Ore Outcrops)"). Coal's `debug_color` is a saturated purple (0.5,
  0.2, 0.8) - the old muted one read as the grey no-deposit background when
  dimmed.
- Tests: `test_deposits.gd` 20 -> 24 (outcrop guild warnings; member scores
  = suitability / exposed deposit; density_curve applied; real outcrops never
  on water, buried rock, or where their own ore isn't exposed).
  test_world_scene: the Deposits view shows only outcrop hexagons; Resources
  hexagons = outcrop placement. Densest 60x60 block rendered: outcrops
  follow the seams, no overlaps or chunk seams.

### Phase 10 step 1: rivers

The user asked to continue into Phase 10 (no design round). Plan Phase 10
split into steps: 1 rivers, 2 floodplains (farming potential, clay), 3 river
mouths, 4 shores.

- `ResourceDefinition` gains `river_curve` (WorldGen `river`: 0 off-river,
  rising toward the line, >= 0.5 is the river itself; land banks sit at
  ~0.05-0.5, about as wide as the river), `shore_curve` (`shore_proximity`)
  and `deposition_curve` (`deposition`). Same rules as the other curves
  (unset = neutral, listed in `required_curves` = tolerance envelope, domain
  warnings). `ResourceManager.CURVE_STATE_FIELDS` maps each curve to its
  state field. Unlike the additive `river_affinity`, a required
  `river_curve` confines a species to banks.
- New guild `resources/guilds/wetland_plants.tres` (cover from `moisture`: 0
  at 0.4 -> 1 at 0.7; base 0.7, spacing 1.5, footprint 0.35, patch 16/0.6):
  `reed` (straw; required river_curve 0 at 0.05 -> 1 at 0.3, temperature,
  elevation; moisture preference) and `cattail` (brown; required moisture
  0.45 -> 0.6, flat slope <= 0.002..0.006, shore_proximity <= 0.3..0.5 =
  freshwater, temperature, elevation; drainage preference; biome weights
  Wetland / Swamp 1.0, Rainforest / Tundra 0.3, other land 0.1-0.15). Stack =
  rocks > trees > wetland plants > shrubs; drawn as diamonds then; new
  `WETLAND_PLACEMENT` view mode (not in the dropdown).
- `resources/species/willow.tres` (pale blue-green), fifth canopy member:
  required river_curve 0 at 0.03 -> 1 at 0.25, moisture 0.35 -> 0.55,
  temperature -0.6..0.75, elevation. It takes most bank trees and appears
  nowhere else.
- Tuning trail: a first cattail used drainage as a hard limit - beaches (wet,
  shore lowers drainage) got many and swamps lost most (swamp drainage runs
  higher than land marsh). Now: a shore limit (beaches -> 0), drainage only a
  preference, biome membership for "marsh", wider elevation / cold range
  (Wetland sits higher and colder than swamp). A first willow with a 0.15
  off-river floor won Beach / Badlands wherever the other trees were excluded
  - now a hard river requirement.
- Performance: `get_guild_density()` checks cover and patch before
  evaluating member suitabilities (same result), and
  `EnvironmentalState.from_sample()` caches its script and types its local
  (no class-cache dependency, verified with the cache removed).
- Tests: `test_resource_guild.gd` 23 -> 28 (river_curve requirement +
  neutral unset curves; wetland guild warnings; real wetland plants never on
  open water or where they score 0; reeds only on banks, cattails only on
  flat wet ground; willows only by rivers and most bank trees; the real stack
  is four guilds). test_world_scene covers Wetland Placement;
  `OUT_CENTER="x,y"` centres the `OUT_PNG` render (river example:
  `OUT_CENTER=18000,8820`).

### Phase 9 step 1: geological deposits as fields

Per plan Phase 9's "resource exists" vs. "resource is exposed".

- `WorldGen.sample()` gains `rock_exposure` (0 buried .. 1 bare rock) =
  max(the erosion gate, `smoothstep(resource_cliff_exposure_requirement (0.1,
  new export), +0.3, cliff_tendency)`), 0 on water. Every existing key is
  unchanged (`resource` still uses the erosion gate only).
  `EnvironmentalState.rock_exposure` added.
- `ResourceDefinition` Deposit group: `vein_scale` (> 0 marks an ore; seam
  spacing in tiles), `vein_sharpness` (ridge exponent). The Spatial group
  gains `cluster_curve` (same meaning as `ResourceGuild.cluster_curve`;
  `get_patch_modifier()` applies it, included in the domain warnings).
- `ResourceManager.get_deposit_potential(state, def, seed, wx, wy)` =
  suitability (geology_weights = geological affinity; water weights) x
  district (the ore's patch noise, steep `cluster_curve` 0 below 0.55 -> 1 at
  0.75) x vein (`get_vein_value()`: `pow(1 - |n|, vein_sharpness)`, own
  FastNoiseLite per ore id seeded from new `WorldGen.DEPOSIT_VEIN_SEED_OFFSET`
  = +19) x base_density. `get_exposed_deposit(potential, state)` = potential
  x rock_exposure. Without the district factor the seams formed a map-wide
  lattice; with it, ore sits in provinces.
- Ores (`resources/deposits/iron|copper|coal.tres`, category "ore"): iron
  geology sed / meta / ign / volc 0.4 / 1.0 / 0.7 / 0.4, vein 48 tiles
  sharpness 5, districts 160; copper 0 / 0.3 / 1.0 / 0.8, vein 40 sharpness
  7, districts 140; coal 1 / 0.1 / 0 / 0 (sedimentary beds), vein 72
  sharpness 2.5, districts 200.
- Stone variants: already covered by the surface-rock guild (by geology); no
  separate stone deposit.
- Views: "Deposits" (strongest ore per tile in its `debug_color`, dimmed
  where buried, bright where exposed; grey = none) and "Rock Exposure", both
  in the dropdown. The inspector lists "Deposits: Iron 0.62, ...
  (exposed|hidden)" for tiles with ore.
- New `tests/test_deposits.gd` (20 checks: rock_exposure formula and 0 on
  water, potential in [0,1], 0 on water / zero-affinity geology /
  non-deposit definitions, exposed <= potential and 0 on buried rock, hidden
  and exposed both occur with most hidden, district coverage bounds per host
  rock, iron / copper veins decorrelated, determinism across fresh WorldGen +
  cleared caches, seed changes veins). test_world_scene checks the Deposits
  view (no markers, ore tile tinted, inspector line).

## 2026-09-22 to 2026-09-23 (Phases 0-8; exact dates not recorded, PRs #1-#4)

### Olive, the Resources view, click-to-inspect

`resources/species/olive.tres`: fourth canopy member for warm, non-tropical,
dry-to-moderate ground (temperature required 0 at 0.0 -> 1 from 0.2 to 0.5
-> 0 at 0.8; moisture required 0 at 0.12 -> 1 from 0.28 to 0.45 -> 0.15 at
0.75; prefers drainage; biome weights Savanna 0.3, Grassland / Plains 0.5,
Rainforest / Beach 0.3, Wetland 0.2, Swamp 0.1; yellow). Before it, warm
dry-moderate ground (temperature 0.15-0.5, moisture 0.3-0.45) only had oak
(out of its range) or palm. Olive raised the best-member cap there, so the
first version made Savanna denser than Forest; the open-biome weights (same
approach as oak's) fixed it. The "Vegetation" view became "Resources"
(`ViewMode.RESOURCES`), and the dropdown no longer lists the 7 per-resource
debug views (their view modes remain; tests use them). Clicking a tile shows
"Resource: <Species> (<Guild>)" or "-" in the inspector (nearest stack
instance whose marker covers the click point, in any view; `_place_stack()`
places the stack for any rect). New scene-test
check for the click.

### Forest species fix

User question: "does it make sense that a montane forest is a mix of pine
and palm, with some oak?" - it didn't. Causes: (1) `BiomeSubtype` labelled
Forest "Montane" from elevation 0.0 (median land elevation is 0.19), so 60%
of all forest was "Montane", median temperature ~0.0; (2) oak and pine had
label-based `subtype_weights` (oak Montane 0.4, Dry Woodland 0.5, ...), so
oak was cut to 40% across most forest and palm won at temperatures (~0.09)
right in oak's optimum. Changes: removed `subtype_weights` from oak and pine
(continuous climate curves cover it, and the per-tile label flickers - plan
Rule 7); palm's temperature requirement 0 at 0.1 -> 0.5 at 0.2 -> 1 from 0.3
(was 0 at 0.0 -> 1 from 0.25); Montane subtype `smoothstep(0.62, 0.75,
elev01)` = elevation 0.24..0.5 (was 0.0..0.44), which also changes the
Subtype view labels. No resource uses `subtype_weights` any more.

### Phase 8 step 5: cross-guild footprints

`ResourcePlacement.place_stack_in_rect(guilds, seed, rect, density_fns,
shares_fns)` / `place_stack_with(guilds, rect, raw_fn)` take guilds in
priority order, place each as before, then drop an instance if a surviving
higher-priority instance is closer than the sum of the two guilds' new
`ResourceGuild.footprint_radius` (trees 0.7, rocks 0.5, shrubs 0.5 tiles; ~
the marker sizes). Chunk-safe: guild i is filtered against higher guilds
placed in the rect grown by i's reach, and each guild is placed in a rect
grown by the reach of everything below it. Order then = rocks > trees >
shrubs. Every guild view uses the stack (placed only down to the lowest
guild shown), so Rock / Berry / Tree Placement match the Vegetation view
exactly. Each guild's raw per-chunk placement is cached (valid across view
changes, cleared when it grows past 8x the loaded area) so the grown rects
don't re-place neighbours. Tests: `test_resource_guild.gd` 19 -> 23
(synthetic stack: top guild unchanged, lower guild kept >= sum of radii
away, per-chunk union == whole rect for every level; real stack: no
footprint overlaps). Render: no overlapping markers, no seams.

### Phase 8 step 4: rocks and berry bushes

Two new guilds, no new environment fields.

- `resources/guilds/surface_rocks.tres` = granite (igneous + metamorphic),
  sandstone (sedimentary, weight 0.7 = soft rock weathers to soil), basalt
  (volcanic). Each member's `geology_weights` is 0 on every other geology,
  so the rock type follows the geology region exactly; hardness comes in
  through those weights (hardness is a pure function of geology). Cover uses
  `vegetation` through a *falling* `cover_curve` (bare ground exposes rock: 0
  -> 1, 0.2 -> 0.65, 0.35 -> 0.25, 0.5 -> 0.08). Members prefer slope,
  erosion and drainage (waterlogged ground buries rock), elevation is
  required (0 below sea level), water and swamp excluded. Spacing 1.5, patch
  24/0.7, base 0.8. The "derived cover input" idea wasn't needed.
- `resources/guilds/shrubs.tres` = berry_bush only (required temperature /
  moisture / elevation, fertility preference, Forest-weighted biome
  membership, `river_affinity` 0.35, water excluded). Cover rises with
  `vegetation` from 0.15. For the plan's "stronger clustering than trees":
  new optional `ResourceGuild.cluster_curve` (reshapes the raw 0..1 patch
  noise before `cluster_strength`; unset = unchanged) plus the public
  `ResourceManager.get_guild_patch_modifier()`. Shrubs use 0 below 0.5 -> 1
  by 0.65 at scale 20 = distinct thickets. Spacing 1.5, base 0.6.
- Tuning trail (numbers in tuning-log): the first rock cover curve (steep in
  vegetation) put Badlands below Plains - cover dominated, and Badlands is
  greener than Plains; a flat curve lifted Forest (placement saturation
  compresses contrast); the middle curve plus steeper slope / erosion
  preferences and a drainage preference was kept. Berries started denser
  than trees in Forest.
- Views "Rock Placement" and "Berry Placement". Vegetation drew rocks
  (squares), berry bushes (circles) and trees (triangles, on top) -
  `resource_marker_chunk.gd` holds several layers (`add_instances()`,
  `Shape` enum, `shape_polygon()`); the chunk code lists them in
  `_placement_layers()`. Startup curve-domain warnings cover all
  three guilds; `ResourceGuild` also checks `cluster_curve`'s domain.
- `tests/resource_by_biome.gd` samples 4 regions (300x300) per seed spread up
  to 28k tiles apart instead of one 600x600 around the origin - the origin
  held no sedimentary rock on any seed, so sandstone showed 0 everywhere.
- Tests: `test_resource_guild.gd` 12 -> 19 (both new guilds free of
  curve-domain warnings; real rocks and berries never on water or on a tile
  their species scores 0; rock type always matches geology, all 3 types
  present; berries denser on river banks; berry patches more dispersed than
  trees). test_world_scene checks Rock / Berry Placement markers and that
  Vegetation = the three guilds. Region: seed 4242 around (18000, 9000), which
  has sedimentary, metamorphic and volcanic ground.

### Palm and the Vegetation view

`resources/species/palm.tres` (hot + wet: temperature required 0 at 0.0 -> 1
from 0.25, moisture 0 at 0.3 -> 1 from 0.5; biome weights Rainforest 1.0,
Savanna 0.4, Wetland 0.4, Swamp / Beach 0.3, Desert 0.1; orange marker) is
the third canopy member. The first try had no Beach / Swamp / Wetland
weights and a +0.2 shore affinity - too many palms there. New "Vegetation"
view (second in the dropdown): base image + canopy-tree markers as
species-coloured triangles. `OUT_PNG` in `test_world_scene.gd` renders this
view (`OUT_TILES` sets its size).

### Biome balance

User request: less Tundra / Grassland, more Forest / Wetland.
`climate_contrast` 1.6 -> 1.35; vegetation cold ramp -0.8..-0.1 ->
-0.9..-0.35 (a boreal band can be wooded); `BiomeClassifier` constants
`TUNDRA_COLD_START/FULL` 0.5 / 0.75, `FOREST_VEG` (0.27, 0.37), `GRASS_VEG`
(0.2, 0.3); Wetland is `waterlogged` = wet (moisture 0.5-0.65) x poorly
drained (drainage < 0.42-0.55) and halves the wooded / grassy scores where it
applies (the old "wet but sparse" rule starved it once wet ground became
lush); Alpine Snow also needs cold (hot highlands were labelled snow). Shares
in tuning-log.

### Vegetation rework

User request: heat shouldn't kill vegetation where it's wet. `WorldGen`
vegetation = smoothstep cold limit (`vegetation_cold_limit/full` -0.8 /
-0.1) x (1 - heat stress), heat stress = smoothstep(`vegetation_heat_start`
0.15, 1, t) x (1 - moisture), x (moisture x fertility)^
`vegetation_water_exponent` (0.5; the plain product compressed land into
0.05..0.3, below Forest's 0.3-0.4 threshold). `BiomeClassifier`: Rainforest
and Savanna were bare products of Forest / Grassland's score and could never
outscore them - now `wooded` / `grassy` are split by `hot_wet` / `hot_dry`
(Grassland also halved under woodland so Forest wins without relying on
dict order); Wetland's vegetation cap raised to 0.25-0.35. Retuned for
trees: canopy cover curve 0.1 -> 0.15, 0.2 -> 0.4, 0.3 -> 0.8, 0.4 -> 1; oak
Savanna weight 0.3. Shares in tuning-log.

### Temperature variety

User request. `WorldGen.climate_contrast` (1.6, stretches the FBM climate
noise) and `WorldGen.temperature_offset` (0.2, cancels the land's
elevation-lapse cold bias); `BiomeClassifier` Tundra ramps over -0.3..-0.55
(`TUNDRA_COLD_START/FULL`, was -0.1..-0.4). Tests pass; the oak / pine guild
shifts with it. Numbers in tuning-log.

### Phase 8 steps 1-3: guilds

`scripts/resources/resource_guild.gd` (`ResourceGuild`, Resource + @export:
`id`, `members: Array[ResourceDefinition]`, `cover_field` = "vegetation",
`cover_curve`, `base_density`, `species_sharpness`, guild-level
`cluster_scale` / `cluster_strength` / `minimum_spacing`).
`ResourceManager.get_guild_density()` = cover_curve(vegetation) x
base_density x guild patch noise x best member's suitability;
`get_member_suitabilities()` + `get_species_shares()` (share_i =
s_i^sharpness / sum). `ResourcePlacement.place_guild_in_rect(guild, seed,
rect, density_fn, shares_fn)` runs the Phase 7 algorithm once on one grid
seeded by the guild id, then picks each instance's species with a per-cell
hash roll (new salt); instances carry `id` (species) and `guild`, key (guild
id, cell). New `resources/species/pine.tres` (cold / high / drier-tolerant,
real-unit curves, biome weights thinning it on Tundra / Grassland / Alpine /
Desert / wet biomes) and `resources/guilds/canopy_trees.tres` (oak + pine,
cover curve lifts vegetation's typical 0.05..0.3 land range, spacing 2,
patch 48/0.8). `ResourceDefinition.debug_color` colours markers per species.
New views "Tree Cover" (guild density) and "Tree Placement" (cover +
species-coloured markers); startup warnings come from the guild (members
included). `tests/resource_by_biome.gd` defaults to the guild with a
per-species column; new `tests/test_resource_guild.gd` (12 checks). First
tuning had pine winning Plains / Grassland (its warm edge overlapped oak's
optimum); pine's temperature optimum is now -0.4..-0.2, 0.4 at -0.05, 0 at
0.1.

### Test suite committed

`tests/` (scratch-only before): `tests/run_tests.sh` downloads the CI's
Godot if `$GODOT` is unset, rebuilds the class cache, runs
`test_resource_placement.gd` (14 checks) and `test_world_scene.gd` (8
checks); `--by-biome` adds the per-biome placement breakdown; `OUT_PNG=path`
renders the Oak Placement view. `tests/*` is excluded from the web export.
Verified from a clean `$HOME` (fresh download).

### Suitability refinements (plan Phase 3 amendment)

`ResourceDefinition.required_curves` names the curves that form a
resource's tolerance envelope - `get_suitability()` multiplies by the lowest
of them instead of averaging them in, so falling outside one means absent;
the other curves stay geometric-mean preferences. Biome weights apply
against the tile's normalized classifier scores (`score^4`,
`ResourceManager.BIOME_MEMBERSHIP_SHARPNESS`) rather than the argmax label -
continuous across boundaries; water / beach tiles (no scores) still use the
label. Subtype weights are still label-based. Oak's requirements:
temperature, elevation, moisture, erosion. Oak became sparser (moisture caps
it); the Grassland-weight speckle is gone in the render. Numbers in
tuning-log.

### Oak tuning fix

After Phase 7 deployed, oaks were densest in Tundra / Alpine Snow.
`oak.tres`'s temperature and elevation curves were left at Godot's default
0..1 domain while those fields run -1..1, and `Curve.sample()` clamps
out-of-domain input to the edge point - so every sub-zero tile (most land;
median land temperature was -0.21, Tundra -0.41) got a flat 0.4 temperature
score, and land between sea_level (-0.1) and 0 got elevation 0. Fixed with
real-unit curves (temperature 0 at <= -0.3; elevation 0 at/below sea_level
and above 0.32), plus data for fields oak ignored: an erosion curve
(Badlands), `shore_affinity = -0.6` (Beach), a dry-end moisture of 0. Not
done through more biome weights: a trial with Tundra / Alpine / Desert /
Badlands / Beach weights worked numerically but gave speckled edges wherever
the per-tile biome label flickers (plan Rule 7). Added
`ResourceDefinition.get_curve_domain_warnings()` (checks each curve's domain
covers its field's real range, `CURVE_FIELD_RANGES`), warned at startup - it
flags both broken curves in the old oak and nothing in the new one.

### Phase 7: spatial placement

- `scripts/resources/resource_placement.gd`
  (`ResourcePlacement.place_in_rect(definition, world_seed, tile_rect,
  density_fn) -> Array[Dictionary]` of `{id, cell, position}`):
  deterministic, chunk-independent Poisson-disc-style placement (algorithm
  in architecture.md §7). Rolls are seeded per resource from `world_seed +
  WorldGen.RESOURCE_PLACEMENT_SEED_OFFSET` (18) + id, with a 32-bit integer
  hash and a sub-2^31 multiplier (no int64 overflow, same on web).
  `density_fn` is injected (normally `get_density()`).
- Render path: a `Resources` Node2D root in `world.tscn`; one
  `resource_marker_chunk.gd` node per loaded chunk draws all its instances
  in one `_draw()`; created and freed with chunk load / unload, view change
  and LOD change; hidden above `MAX_PLACEMENT_LOD_STEP = 2`. New "Oak
  Placement" view (`RESOURCE_PLACEMENT_OAK`) = Oak Density heatmap + markers.
- Bug fixed in `get_suitability()` (found by the placement test): the
  additive river / shore / disturbance affinities were applied even when a
  requirement had zeroed the core score, so oak's `river_affinity = 0.1` put
  river tiles back at ~0.07-0.10 suitability (4 oaks in rivers in a 128x128
  area). A zeroed core now returns 0 before affinities.
- Verified: headless script, 14/14 PASS (zero density -> nothing;
  determinism; per-chunk union == one whole-rect call for a synthetic field
  and real oak; min pairwise spacing >= `minimum_spacing` across chunk edges
  and for non-integer spacing (3.5); instances stay in their rect; count
  rises with density; different seed / id -> decorrelated positions; real
  oak: 0 instances on water or zero-density tiles; identical from a fresh
  WorldGen). Scene script on the real `world.tscn`, 8/8 PASS (no markers in
  Material; one marker node per loaded chunk in Oak Placement; markers follow
  streaming after a pan; hidden past the LOD cap, rebuilt when zoomed back;
  removed when switching back to Material). A 160x160-tile render inspected:
  denser in high-density patches, none on the river, no seams. Headless boot
  clean.

### Phase 6: density

`ResourceManager.get_density(state, definition, world_seed, wx, wy,
classified={}) -> float` = `clamp(suitability * clamp(base_density, 0, 1) *
get_patch_modifier(), 0, 1)` - "how much should exist here" vs.
suitability's "would it like it here". `base_density` is
`@export_range(0, 1)`, documented as peak density; oak left at 1.0. The
plan's `patch_scale` / `patch_strength` are the existing `cluster_scale` /
`cluster_strength`; the optional `density_curve` was skipped then (added in
Phase 9 step 2). New "Oak Density" view (`RESOURCE_DENSITY_OAK`, amber
palette); the colour functions take `wx, wy` to feed patch noise. Verified
(headless script, seed 4242, 14/14 PASS): empty definition -> 1.0;
base_density scales linearly and clamps; over 384x384 oak tiles density is in
[0,1], <= suitability, equals the formula, 0 wherever suitability is 0, and
repeatable; identical across two fresh WorldGen instances; the real colour
function matches `get_density()`; the Material view unchanged. A side-by-side
render inspected: the uniform suitable region breaks into groves and
clearings.

### Phase 5: patch noise

`ResourceManager.get_patch_modifier(definition, world_seed, wx, wy) ->
float` (0..1 multiplier on top of suitability, never replacing it). One
`FastNoiseLite` per resource, seeded from `("<world_seed + 17>:<id>").hash()`
(offset +17 reserved as `WorldGen.RESOURCE_DISTRIBUTION_SEED_OFFSET`, but the
noise lives in ResourceManager - layer separation), cached in a static
Dictionary. Driven by `ResourceDefinition.cluster_scale` (patch size in
tiles, default 1.0 -> 32.0) and `cluster_strength` (0 = uniform 1.0, 1 = full
0..1; modifier = lerp(1, patch, strength)). Simplex FBM output is
contrast-stretched x1.8 then clamped so real clearings and dense groves
appear (FBM rarely leaves ~0.3..0.7). Oak tuned to `cluster_scale = 48`,
`cluster_strength = 0.85` after 0.5 gave only mottling. Verified (headless
script): same seed -> identical field even after dropping the cache;
different seed -> different; output in [0,1]; ids decorrelated; strength 0
-> exactly 1.0; oak's floor = 1 - strength; larger cluster_scale -> smoother
field. A 384x384 render (suitability | patch | product) inspected. Headless
boot clean.

### Phase 4: first resource and heatmap view

`resources/species/oak.tres` (first `ResourceDefinition`) and an "Oak
Suitability" heatmap view, following the heatmap-view pattern
(`HeatmapColorizerScript.resource_suitability()`, blended 65% onto the base
image). The visual check (plan Phase 4 gate: "do not proceed
until these maps look believable") caught two bugs:

1. `elevation_curve` interpolated *up* toward its peak from -1, so deep
   water scored 0.3-1.0. Fixed by flattening the curve to 0 at/below
   sea_level.
2. Rivers can sit well above sea_level, so a river tile still read
   moderately suitable. Fixed generically with `water_body_weights:
   Dictionary` on `ResourceDefinition` (mirrors `geology_weights`, keyed by
   WorldGen's `water_body` string) in `get_suitability()`'s geometric-mean
   core - no hardcoded water logic in ResourceManager.

Re-rendered (512x512, seed 4242) after both fixes: lake, river and pond read
low; land transitions smooth. Also exercised the real chunk colour path
headless.

### Headless class cache

`.godot/global_script_class_cache.cfg` (gitignored) was only rebuilt by
opening the editor, so a newly added `class_name` failed to resolve in ad hoc
`--script` runs. Fixed locally then; since review X1 `tests/run_tests.sh`
runs `--import` every time (dev-workflow.md).

### Phase 3: suitability

`ResourceManager.get_suitability(state, definition, classified={}) ->
float`. Curve factors (temperature / moisture / fertility / elevation /
slope / drainage / erosion) plus geology weight combine by GEOMETRIC MEAN
(the plan warns a blind product craters every score); biome / subtype
weights are multiplicative modifiers after; river / shore / disturbance
affinities are additive bonuses; clamped to [0,1]. Verified headless against
the plan's Oak / Iron examples: neutral when empty, good vs. hostile
temperature, unlisted biome neutral vs. listed lower weight, geology as a
hard requirement for Iron, clamping. PASS.

### Phase 2: ResourceDefinition

`scripts/resources/resource_definition.gd` (`ResourceDefinition`,
`class_name ... extends Resource` with `@export` fields), following
WorldGen's own Resource + @export pattern. Suitability curves use Godot's
`Curve` (matches the plan's `temperature_curve.sample(temperature)`; a fresh
Curve defaults to a 0..1 domain / range). Categorical weights (biome /
subtype / geology) are plain `Dictionary` exports; an unset curve or missing
weight entry is neutral (1.0). Verified headless: instantiation,
`Curve.sample()`, Dictionary round trip, and a real `ResourceSaver.save()` /
`load()` round trip. PASS.

### Phase 1: EnvironmentalState

`scripts/gen/environmental_state.gd`: a typed wrapper with
`from_sample(dict)`, added alongside the Dictionary (decisions.md). The 7
existing callers (biome_classifier, biome_subtype, biome_modifiers,
debug_colorizer, heatmap_colorizer, chunk_manager, tile_inspector_panel) were
untouched. Verified by a temporary headless script (never committed): same
seed / coordinate determinism across several WorldGen instances and
`sample()` calls, and a field-for-field match with the source Dictionary.
PASS.

### Phase 0: architecture review

Verified and documented the generator pipeline in `docs/architecture.md`
(`WorldGen.sample()` field table, water topology, 3-stage biome classifier,
chunk rendering / LOD, seed model); flagged the missing per-tile object
rendering for Phase 7+ (resolved in Phase 7); made
`scripts/resources/resource_manager.gd` an empty stub as the ResourceManager
integration point. Headless boot validated; no runtime changes.
