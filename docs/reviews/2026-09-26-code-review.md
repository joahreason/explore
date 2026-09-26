# Code review: explore (2026-09-26)

Reviewed at `2c97bf0` (the head of `main` when this review started).

## Scope and method

- **Read:** all 47 scripts in `scripts/` (`chunk_manager.gd` and the generation core line by line, the rest fully or nearly), the six shaders, `project.godot`, the export preset, the CI workflow, `tests/run_tests.sh`, the snapshot and world-scene suites in detail (the other suites skimmed), README, `docs/architecture.md`, PROJECT_STATE, TODO.
- **Ran** (Godot 4.7.2, Linux container, 4 cores): the full test suite, plus throwaway probe scripts kept out of the repo, to check determinism, per-tile costs, node counts, and hover/pathfinding/search timings. One check ran on the real GL Compatibility renderer (the web build's renderer) under Xvfb/Mesa.
- **Not covered:** tuning values in `.tres` files (by request); anything inside a real browser. Web impact below is inferred from native timings, and WASM GDScript is slower, so treat native numbers as lower bounds. Also not covered: GPU cost of the shaders on phones, `tools/generate_sfx.gd`, and the plan doc beyond its rules.
- In a finding, **Verified** means I reproduced it here. Everything else comes from reading the code.

## 1. Summary

The generation core is healthy. The chain from fields to suitability, density, placement, instance and player changes is cleanly layered, data-driven (`.tres` everywhere) and deterministic by construction (integer cell hashes, order-free thinning). It is also carefully commented and guarded by a golden snapshot. The risk sits around that core:

- **`chunk_manager.gd` does about 12 jobs:** streaming, threading, colouring, placement assembly, picking, pathfinding, persistence, time, tents and debug tools. Its threading rule is enforced only by convention, and tests reach into 46 of its private members.
- **`WaterTopology` breaks seed determinism:** it is the one stateful generator component, and its cache makes water labels depend on the order tiles are queried in (**verified**).
- **The web build freezes in places the chunk budget doesn't cover:** a mouse-hover pick costs about 0.5 s where placements aren't cached, and a "Go to" search that finds nothing ran 28 s natively. On web that search runs on the main thread (**verified natively**).
- **The safety net has holes:** no tests run in CI, and the test runner can't bootstrap a fresh clone (**verified**, one-line fix).

There are no Critical findings: nothing loses saves in normal use, and there is no security exposure (§2.6).

**Test suite at `2c97bf0`, in this container:** all 23 suites passed (412 checks, 0 failures) in 18 min 18 s. The timing-sensitive no-worker check passed at 4,595 of its 5,000 allowed frames (T3).

**Top 3 priorities**
1. **Fix WaterTopology determinism (D1) and add an order-independence test (T2).** It's a small change. It must land before multi-worker streaming (Phase 17 leftover) and before Phase 15 builds more on stable instance keys.
2. **Close the safety-net gaps (X1, T5, T3, T1).** Use `--import` in the runner, fail on script errors, de-flake the no-worker test, and run the fast suites in CI before deploying. That's about an afternoon, and it protects every later change, including the `chunk_manager.gd` split.
3. **Remove the web main-thread stalls (W2, W1).** Pick from what is drawn instead of placing again, and spread "Go to" searches across frames. Both stalls hit the web tuning workflow directly, since it runs on data views and "Go to".

Then start the `chunk_manager.gd` split (§4.1) with its low-risk steps, before wall-blocking and Phase 15 add more to that file.

## 2. Findings

IDs: **A** architecture, **Q** code quality, **O** organization, **C** correctness, **T** testing, **P** performance/security, **X** developer experience, **D** determinism, **W** web. Within each area the most severe finding comes first. Line numbers refer to `2c97bf0`.

### 2.1 Architecture

**A1 · High · `chunk_manager.gd` does about 12 jobs** (whole file, 2,338 lines)

- **What it holds:**
  - streaming and the job queue (568–839), including the worker thread
  - colouring and tile codes (841–995)
  - generation caches (997–1137, 1673–1735)
  - image baking and job steps (1139–1214)
  - chunk nodes (1217–1366)
  - placement views and markers (1368–1575, 1737–1773)
  - picking (1577–1671, 2291–2297)
  - harvest and persistence (1776–1838, 1927–1949)
  - debug tools (1840–1924)
  - pathfinding (1957–2060, 2137–2288)
  - tents (2062–2134)
  - seasons and ambience (2300–2338)
  - seed handling and "Go to" travel
- **Impact:**
  - Every upcoming item lands in this file:
    - sprite pivots and depth → marker code
    - walls blocking → pathfinding and structures
    - Phase 15 → harvest, picking and generation queries
    - multi-worker → caches and locking
  - The threading rule ("generation state only under `_gen_mutex`") is a comment that about 40 functions must honour, and it already slips (C2).
  - Tests use 111 of its members, 46 of them private (T4).
- **Fix:** split it incrementally (§4.1).
- **Effort:** large, in increments.

**A2 · Medium · A view mode is defined in five places**

- **Where:** the `ViewMode` enum (173–210), `_heatmap_color_for()` (939–994), `_placement_layers()` (1376–1415), the `is_time_tinted_view()` / `is_debug_view()` / `_is_label_view()` flags, and the `ITEMS` list in `view_mode_dropdown.gd`.
- **Impact:** adding or changing a view touches three to five places.
- **Fix:** one registry, a table per view (`label`, colour function, placement layers, `tinted`, `label_view`, `debug`), read by the chunk builder, the presenter and the dropdown.
- **Effort:** medium (part of the split).

**A3 · Medium · Content lists are code**

- **Where:** `chunk_manager.gd:46-83` (`GUILD_STACK`, deposits, farmland), `structure_sites.gd:24-28`, `terrain_surface.gd:28-41`.
- **Impact:** adding a guild means editing `GUILD_STACK` and the World-view layer list in `chunk_manager.gd`. Stack order is a design decision, yet it lives in a const.
- **Fix:** a `WorldContent` resource (`.tres`) listing:
  - guilds in stack order, with their World-view draw style
  - deposits
  - terrain materials
  - structures

  ChunkManager and the tests read it, so new content is data-only.
- **Effort:** small to medium.

**A4 · Low · UI and effects treat the World node as a service locator**

- **Where:** 13 scripts reach it with `get_parent()` or `get_node("../..")`, using `clock` 12×, `TILE_SIZE` 7×, `is_time_tinted_view()`, `sway_material`, `sprite_image()`, and more. Several poll every frame (DayNight, CloudShadows, TimeControls, DebugResourceDropdown).
- **Impact:** fine at this size, but ChunkManager can't shrink without keeping facades.
- **Fix:** during the split, expose small objects (`world.clock`, `world.session`, `world.views`) and emit signals (`view_changed`, `seed_changed`) instead of relying on polling.
- **Effort:** small, alongside the split.

### 2.2 Code quality

**Q1 · Medium · A new environmental field needs four synchronized edits**

- **Where:**
  - 16 identical setter blocks in `resource_definition.gd:36-133`
  - `CURVE_FIELD_RANGES` in `resource_definition.gd:259-276`
  - `CURVE_STATE_FIELDS` in `resource_manager.gd:62-79`
  - the field and its copy in `environmental_state.gd`
- **Impact:** missing one edit means a curve that is silently never sampled, or never range-checked.
- **Fix:** one table, `curve name -> [state field, value range]`, used by both scripts. Setters call one helper that resets `curve_plan`.
- **Effort:** small.

**Q2 · Low–Medium · The terrain-shader contract is copied by hand**

- **Where:** `chunk_manager.gd:143-153` and `shaders/terrain.gdshader:38-45` both hold the tile codes and the 46-entry `SHORE_SHAPES` table.
- **Impact:** a mismatch silently mis-renders coasts. (`GameConstants` already solved this for tile size.)
- **Fix:** move the codes into a `.gdshaderinc` and add a test that parses the shader and compares it with the GDScript table.
- **Effort:** small.

**Q3 · Low–Medium · Tuning is scattered, and some of it is hardcoded twice**

- **Where tuning lives today:**
  - `WorldGen` `@export`s: good, one Resource. But `world_gen_params` is empty in `world.tscn`, so the code defaults are the real source.
  - `BiomeClassifier`, `BiomeSubtype` and `BiomeModifiers`: named constants plus many inline `smoothstep()` numbers.
  - `ResourceManager`: `PATCH_CONTRAST`, `BIOME_MEMBERSHIP_SHARPNESS`, and measured noise quantiles.
  - terrain and water colours in `TerrainSurface`
  - `Seasons.KEYS` and `AmbientParticles.weights()`
  - `GameClock`, `SunShadow` and `Wind`
  - terrain shader constants
  - `chunk_manager.gd` constants (`SHALLOW_DEPTH`, `SHORE_ELEVATION_MARGIN`, `HEATMAP_OVERLAY_STRENGTH`, LOD thresholds)
- **Duplicated values:**
  - `terrain_surface.gd:61` has `SEA_LEVEL := -0.1`, which copies `WorldGen.sea_level`, an `@export` meant for tuning. Water depth colours would silently drift if sea level is tuned.
  - Time of day lives in three files: `GameClock` light keys and dawn/night hours, `SunShadow.SUNRISE`/`SUNSET`, and `AmbientParticles._band(20, 22, 3, 5)` / `(7, 9, 17, 19)`.
- **Fix:**
  - Pass the WorldGen's sea level (or the depth) in.
  - Build one day-cycle table.
  - Move the biome classifier thresholds, the most-tuned numbers after curves, into named constants or a `BiomeRules` resource.
  - Keep a `default_world_gen.tres` in `world_gen_params` so WorldGen can be tuned in the Inspector.
- **Effort:** small.

**Q4 · Low · Private helpers are used across modules**

- **Where:** `ResourcePlacement._resource_seed()` / `_cell_unit()` are called from `terrain_surface.gd:104-105` and `structure_sites.gd:282`. `CameraRig._is_over_ui()` is called from `hover_highlight.gd:40`.
- **Impact:** the cell hash is the determinism core, but it's private. Terrain jitter also reuses the placement seed offset (+18) with the id `"terrain"`, so a resource or guild ever named "terrain" would share its rolls.
- **Fix:** make the hash a public utility, and give terrain jitter its own offset in the registry.
- **Effort:** small.

**Q5 · Low · Stale comments**

- **Where:**
  - `water_topology.gd:13-21` describes a noise fallback that was removed (offset +14 is now unused).
  - `chunk_manager.gd:3-7` says rendering is "a debug visualization only".
  - Many headers read like changelogs ("Phase 17 step 6…", "Polish pass 2…") instead of describing current behaviour.
- **Fix:** describe what the code does now; history belongs in the changelog.
- **Effort:** small.

**Q6 · Low · UI layout is done in code**

- **Where:** `reload_button.gd`, `biome_travel_dropdown.gd` and `debug_resource_dropdown.gd` shift each other's offsets in `_ready()`.
- **Impact:** correct layout depends on sibling `_ready()` order.
- **Fix:** a `VBoxContainer` reflows by itself when Reload hides.
- **Effort:** small.

### 2.3 Organization

**O1 · Low · Folders are flat, and the root is cluttered**

- **Where:**
  - `scripts/` holds 47 files: generation, rendering, UI and gameplay mixed.
  - `resources/` holds about 50 `.tres` files: species, guilds and deposits mixed.
  - The root holds two tileset PNGs, three template files with swapped contents (X2), and `urizen_onebit_tileset__v2d0_original_color.png`, which nothing references but the web export ships (`export_filter="all_resources"`; 137 KB imported).
- **Fix:**
  - Drop the unused PNG, or add it to `exclude_filter`.
  - Adopt `scripts/{gen,resources,world,render,ui}` and `resources/{species,guilds,deposits,…}` during the split, so paths change once rather than in a separate churn commit.
- **Effort:** small to medium.

### 2.4 Correctness and robustness

**C1 · Medium · The chunk fade-in never shows, and it corrupts the sway encoding while it runs**

- **Where:** `chunk_manager.gd:1257-1265`, `terrain.gdshader:358`, `sway.gdshader:15`, `cast_shadow.gdshader:35`.
- **Verified** on the real renderer, at `modulate.a = 0.5`:

  | Sprite | Red channel drawn |
  |---|---|
  | Plain sprite | 0.50 |
  | Terrain material | 1.00 |
  | Marker row with the sway material | 1.00 |

- **Why:** the terrain shader writes `COLOR = vec4(rgb, 1.0)`, the sway shader sets `COLOR.a = 1.0`, and the cast-shadow shader replaces `COLOR` too, so modulate never reaches the screen. Chunks, sprites and shadows pop in; only label overlays fade.
- **Worse:** Godot has already multiplied modulate into the vertex `COLOR` that `sway.gdshader` and `cast_shadow.gdshader` decode as sway (`decode_sway(COLOR.a)`). So for 0.2 s every sprite in a new chunk, rocks included, should bend like grass (sway 1.0 at half fade). This follows from the verified mechanism; I didn't capture it on screen.
- **Trap for planned work:** tinting sprites by quality, or highlighting them, via `modulate` would corrupt both sway and shadow height.
- **Fix now:** drop the tween, or keep it only for overlays. If the terrain fade matters, carry vertex alpha through a varying:

  ```glsl
  varying float fade;
  void vertex() { fade = COLOR.a; world_px = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
  // end of fragment():
  COLOR = vec4(rgb, fade);
  ```

- **Longer term:** stop packing data into `COLOR` (sway in alpha, height in red).
- **Effort:** small for the fix, medium for re-encoding.

**C2 · Low–Medium · Generation state is touched outside `_gen_mutex`**

- **Where:** `chunk_manager.gd:2099`, `:765-766`.
- **The race:** `enter_tent()` reads `_structures.site_at(tile)` without the lock. Meanwhile the worker may be inserting into the same StructureSites cache, or clearing it at `CACHE_LIMIT`. That is a concurrent Dictionary read and write: rare, but the kind that crashes.
- **Also:** `_new_job_state()` reads `_view_mode` on the worker without the lock. It's harmless today because of epoch ordering, but it breaks the documented rule.
- **Fix:** have `is_tent()` return the site from its locked lookup. Structurally, one object should own the mutex and lock inside its public methods (§4.1).
- **Effort:** small.

**C3 · Low · The harvest target is picked again on arrival**

- **Where:** `chunk_manager.gd:1978-1989`, `1796-1798`.
- **The problem:** a tap resolves its target with `hover_target()`. Arrival then calls `_on_harvest_clicked(world_pos)`, which picks again at the original point, using the rules of whatever view is current at arrival. After a view switch mid-walk it can harvest a different object, or nothing.
- **Why it matters:** Phase 15 yields need this to be exact.
- **Fix:** capture the instance key at tap time and harvest that key on arrival, if it still exists.
- **Effort:** small.

**C4 · Low · Saves are overwritten in place**

- **Where:** `world_changes.gd:118-126`.
- **The problem:** `FileAccess.open(path, WRITE)` truncates first. An interrupted write leaves invalid JSON, and `load_file()` then silently starts empty, losing every harvest.
- **Fix:** write `<seed>.json.tmp`, then `DirAccess.rename_absolute()` it into place. Keep the previous file as `.bak` and fall back to it when parsing fails.
- **Effort:** small.

**C5 · Low · A lazy cache on shared resources is written from two threads**

- **Where:** `resource_manager.gd:150-159`.
- **The race:** `curve_plan` is filled on first use. The finder thread (`StructureSites.find()`) calls `get_suitability()` on the same preloaded StructureDefinitions as the worker, without a lock. The worker almost certainly fills them first, so this is latent.
- **Fix:** build every curve plan eagerly in `_ready()`.
- **Effort:** trivial.

### 2.5 Testing

**T1 · High · No tests run before a deploy**

- **Where:** `.github/workflows/web-build.yml`.
- **The gap:** every push to `main` exports and deploys, but the 23 suites only run when a session remembers to. At the current pace (57 commits on 2026-09-24), that is the main way a regression reaches the public build.
- **Fix:** a test job that imports the project and runs a fast subset on pull requests and before `export-web`. Here the snapshot, resource_placement, world_changes, game_clock and structures suites took 86 s together. Move `concurrency: pages` from the workflow level onto the deploy job: GitHub cancels a *pending* run when another run joins the same group, so a PR run could otherwise cancel a queued deploy.

  ```yaml
  on:
    push: { branches: [main] }
    pull_request:
    workflow_dispatch:
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v7
        - uses: actions/cache@v4
          with: { path: ~/.cache/godot, key: godot-${{ env.GODOT_VERSION }} }
        - run: tests/run_tests.sh snapshot resource_placement world_changes game_clock structures
    export-web:
      needs: test
      if: github.event_name != 'pull_request'
      # ... as today
    deploy:
      needs: export-web
      concurrency: { group: pages, cancel-in-progress: false }
      # ... as today
  ```

- **Effort:** small.

**T2 · Medium · The snapshot misses order effects, desert plants and structures**

- **Where:** `tests/test_placement_snapshot.gd`, `tests/placement_snapshot.txt`.
- **Coverage gaps:**
  - The golden file lists 9 of the 10 guilds. `desert_plants` has no instance in any snapshot area, so cactus and sagebrush placement is unguarded.
  - Structure stamps (`parts_in_rect`) aren't hashed.
- **Order gap:** everything is computed once, in one order, in one process, so bugs that depend on query order (D1) or on worker vs inline stepping are invisible.
- **Fix:**
  - Add a hot-desert area, a Barrens area, and a structure-parts layer.
  - Add a second pass that rebuilds the same areas in reverse order from a fresh world, and once with `threaded_generation = false`, then compares hashes.
  - Add a coastal-sea area, such as seed 4242 near (-1052, -1212), which D1 affects.
- **Effort:** small.

**T3 · Medium · "no worker: Resources built in steps" fails on slow machines by design**

- **Where:** `tests/test_world_scene.gd:383-407`.
- **The problem:** it compares markers only after a 5,000-frame cap, so a slow container fails a correct build (the known issue). It passed here at 4,595 frames, 8 % from failing.
- **Fix:** keep the frame loop only to prove stepping happens (some chunks shown, not all, after N frames). Then call `flush_chunk_work()` and compare every chunk with one-go placement.
- **Effort:** small.

**T4 · Medium · Tests depend on ChunkManager internals**

- **Where:** the tests use 111 distinct ChunkManager members, 46 of them private: `_loaded_placements` 38×, `_loaded_chunks` 33×, `_world_gen` 28×, `_chunk_placements` 17×, `_gen_mutex` 10×.
- **Impact:** most suites boot the full `world.tscn` (81 chunks), even for pure logic. That's part of why the full suite takes 15–18 minutes, and it will make the split noisy.
- **Fix:** as modules are extracted (§4.1), give each a small public API, and move pure tests off the scene (navigation, placement, water topology, save format, picking).
- **Effort:** medium, alongside the split.

**T5 · Low–Medium · The runner ignores script and engine errors**

- **Where:** `tests/run_tests.sh:42`.
- **The problem:** `SCRIPT ERROR` and `ERROR:` lines are printed but never fail the run. A run full of load errors can still pass, which is how a fresh clone produces "meaningless" numbers.
- **Fix:**

  ```bash
  grep -q "SCRIPT ERROR" <<<"$out" && status=1
  ```

  Also fail on `ERROR:` lines that aren't allow-listed.
- **Effort:** trivial.

**T6 · Low · 23 copies of the same boilerplate**

- **The problem:** every suite re-implements its own `check()`, RESULT line and quit code.
- **Fix:** one `tests/harness.gd` base (check, summary, exit code, flush helpers).
- **Effort:** small.

### 2.6 Security and performance

**P1 · Medium · Much of the per-tile cost is data plumbing, not noise**

- **Measured natively, per tile:**

  | Step | Cost |
  |---|---|
  | `sample()` | 14–15 µs (the five `elevation()` calls ≈ 4 µs of it) |
  | `EnvironmentalState.from_sample()` | 11 µs |
  | `classify_full()` | 12 µs |
  | terrain `material_at()` + `color_for()` | 56 µs |
  | guild densities | 2–72 µs each (shade-reading guilds include the canopy's) |

  Startup took 10.8 s wall-clock to build 81 World-view chunks, with the worker and main thread both building. This container runs roughly 2–2.5× slower than the numbers in PROJECT_STATE.
- **Where the time goes:** copying a sample into an `EnvironmentalState` (11 µs) and classifying it (12 µs) together cost more than `sample()` itself (15 µs), which includes every noise lookup. The cause is Dictionary and object churn: each sample is a 35-key Dictionary, copied field by field into a 38-field object; each classification makes three Dictionaries and an Array; each cached tile is about 5 KB.
- **Quick wins:**
  - **Biome weights:** `_biome_modifier()` (`resource_manager.gd:165-175`) recomputes 11 `pow()` calls and walks the score Dictionary for every resource with biome weights. Oak's suitability costs 6.2 µs with biome weights vs 4.8 µs without. The membership vector is the same for every resource at a tile, so compute it once in `classify_full()`. Memberships sum to 1, so `modifier = 1 + Σ_{b in weights} m_b·(w_b − 1)` only needs the biomes a resource lists. This changes float rounding, so re-record the snapshot.
  - **String keys:** the noise caches build a String key on every call (`resource_manager.gd:252, 479`; `TerrainSurface._patch()`), at a measured 1.24 µs each and 12× per tile for terrain. `color_for()` also formats and hashes a seed string per tile (`terrain_surface.gd:104`). Keep per-seed noise objects in arrays aligned with the definitions instead.
- **Larger** (the "cheaper per-chunk density" leftover): sample a chunk in one batch. Compute elevation once per tile on an 18×18 grid instead of five times, keep fields in `PackedFloat32Array`s, and use a lighter per-tile state.
- **Effort:** small for the quick wins, large for batching.

**P2 · Medium · Depth sorting costs one node per sprite row**

- **Where:** `resource_marker_chunk.gd:96-108`.
- **Measured:** the default 81-chunk World view has 2,637 `_Row` nodes (32.6 per chunk) plus 82 shadow layers, all y-sorted. At zoom 0.5, markers are still drawn (LOD 2), and a 1080p load square reaches about 441 chunks, roughly 14,000 y-sorted canvas items.
- **Before settling the art style:** measure this in the web build (W4).
- **Options, cheapest first:**
  1. Bucket rows by whole tiles (at most 16 per chunk) and sort within a bucket.
  2. Draw flat sprites that can't overlap anything (grass, flowers, shells) in one unsorted layer, and y-sort only tall sprites.
  3. Use RenderingServer canvas items instead of Nodes.
- **Effort:** medium.

**P3 · Low · Recolouring for the season rebuilds every marker node**

- **Where:** `chunk_manager.gd:2305-2313`.
- **The cost:** once per in-game day (about every 22 s at ×64), every loaded marker node (about 2,700 nodes) is freed and rebuilt, just to change fill colours.
- **Fix:** update `_fills` in place and `queue_redraw()` the rows.
- **Effort:** small.

**P4 · Low · View switches rebuild images that haven't changed**

- **Where:** `set_view_mode()` bumps the epoch, so every chunk is rebuilt.
- **The waste:** World and Terrain Only bake identical images. Heatmap views re-bake the terrain beneath their blend.
- **Fix:**
  - Key cached images by image kind (coded terrain, plain terrain), not by view, so World ↔ Terrain Only reuses images.
  - Longer term, pass a heatmap's field to the terrain shader as a texture channel and colour it there, so switching between heatmaps costs nothing on the CPU.
- **Effort:** small (reuse) to medium (shader).

**Security: nothing to fix.** There is no network I/O. The only external inputs are:
- the `?seed=` URL parameter, which is hashed; the seed field strips non-alphanumerics, and the reload URL is `uri_encode`d before `JavaScriptBridge.eval`.
- the local save JSON, whose types `from_dict()` validates.

### 2.7 Developer experience

**X1 · High · The test runner can't bootstrap a fresh clone**

- **Where:** `tests/run_tests.sh:28`.
- **Verified:** `--editor --quit-after 30` stops the editor before its first filesystem scan finishes. In this container it imported 0 of 9 assets. Every scene suite then failed to load `oak.tres`, because `oak.png` was never imported.
- **Impact:** this is the source of your "copy `.godot/imported`" and "class cache" pain points, and of the "meaningless benchmark numbers" in fresh worktrees.
- **Fix (verified):**

  ```bash
  "$GODOT" --headless --path . --import
  ```

  This imported all 9 assets and rebuilt the class cache (24 of 24 classes) in about 7 s. It works for worktrees and CI too.
- **Effort:** trivial.

**X2 · Medium · PROJECT_STATE.md no longer works as a handoff**

- **Size:** 122 KB, about 29k tokens, too big to read in one tool call.
- **Contradictory "current" pointers:**
  - Current Phase: "Phase 14 complete".
  - TODO's Current Task: Phases 13, 13.5 and 14 by-eye work.
  - Next Action: "Phase 19".
- **Stale sections:** "Last Verified" still describes Phases 0–1.
- **Swapped template files:**

  | File | Actually contains |
  |---|---|
  | `CHANGELOG_DEV.md` | the session-handoff template |
  | `SESSION_HANDOFF_TEMPLATE.md` | the task template |
  | `CLAUDE_TASK_TEMPLATE.md` | the workflow doc |

  Because `CHANGELOG_DEV.md` was never a changelog, all history ended up in PROJECT_STATE.
- **Stale elsewhere:**
  - README says the tileset isn't wired up, and that the player steps tile by tile.
  - `architecture.md` says `TILE_SIZE = 12`.
- **Fix:** §4.2.
- **Effort:** medium (one docs session).

**X3 · Medium · By-eye tuning is slow**

- **The loop today:** every curve or density change goes edit → commit → PR → deploy (~1–2 min) → reload.
- **The gap:** a running game never picks up edited data. The desktop build uses the same GL Compatibility renderer as the web build, but nothing reloads content or rebuilds chunks.
- **Fix:** a debug key in the desktop build that:
  1. reloads the content `.tres` files from disk with `ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)`, which updates the loaded instances in place (verify on 4.7);
  2. clears the generation caches, curve plans and static noise caches;
  3. invalidates the chunks.

  Edit and save a `.tres`, press the key, and see the result in seconds instead of after a deploy. Use the web build only to confirm.
- **Effort:** small.

**X4 · Low · Two `.uid` files were never committed**

- **Where:** `scripts/game_constants.gd.uid`, `shaders/game_constants.gdshaderinc.uid`.
- **Impact:** every import regenerates them with random UIDs: untracked noise, and different UIDs on each machine.
- **Fix:** commit them.
- **Effort:** trivial.

### 2.8 Determinism

**D1 · High · Water body labels depend on query order**

- **Where:** `water_topology.gd:39-41, 57-58`.
- **The bug:** when a flood fill runs over budget (open water), `classify()` caches that result for the whole 64×64 cell containing the tile it started from. An enclosed lake or sea sharing that cell with open water then reads as `ocean` if an ocean tile in the cell was classified first, and as `lake`/`sea` if one of its own tiles was.
- **Verified** with fresh `WorldGen`s:

  | Seed | Tile | Queried first | After an open-water tile in the same cell |
  |---|---|---|---|
  | 4242 | (-1052, -1212) | `sea` | `ocean` |
  | 1337 | (-1912, -2112) | `sea` | `ocean` |

  In sweeps 3,000–6,000 tiles wide over seeds 4242, 1337 and 7, 3–5 cells per seed held both enclosed and open water. That puts about 1–5 % of sampled enclosed-water tiles at risk. Seas are the most exposed, because by definition they lie within `strait_probe_distance` (60 tiles) of open water.
- **Impact:**
  - The same seed can render differently depending on the path the player took, and on which chunk was built first. That covers water colour, surf, `shore_salinity` (salt- vs freshwater species), biome labels and placements.
  - Desktop and web can differ: the worker and the inline steps visit tiles in different orders.
  - The "Go to" search has its own `WorldGen`, so it can disagree with the rendered world.
  - This breaks plan Rule 1. Instance keys are then not a pure function of (seed, cell), so a saved harvest can stop applying.
- **Fix:** remember "open" per water tile the capped fill visited, and stop a new fill as soon as it reaches a tile already known to be open. Water connected to an open tile belongs to the same body, which is also over budget. Both rules give the same answer in any order. Also remove the stale header note (Q5).

  ```gdscript
  var _open: Dictionary = {}  # Vector2i -> true: tiles of bodies over the budget

  func classify(wx, wy, elevation_fn, sea_level, fill_budget, strait_probe_distance) -> Dictionary:
  	var tile := Vector2i(wx, wy)
  	if _cache.has(tile):
  		return _cache[tile]
  	if _open.has(tile):
  		return OPEN_RESULT
  	var fill := _flood_fill(...)  # now also returns "members" when capped
  	if not fill["enclosed"]:
  		for t in fill["members"]:
  			_open[t] = true
  	...

  # _flood_fill(), before queueing a water neighbour n:
  	if _open.has(n):
  		return {"enclosed": false, ..., "members": queue}
  ```

  Memory then grows with the ocean explored. Store `_open` as one 512-byte bitmap per 64×64 cell rather than one Dictionary entry per tile, which costs 88 bytes per tile (measured). A fill stays as cheap as today: a capped fill covers about 3,500 tiles, much as one coarse cell covered 4,096.
- **Effort:** small, plus a snapshot re-record if a snapshot area changes.

**D2 · Low · `?seed=-1` generates an unconfigured world**

- **Where:** `world_gen.gd:252, 280`.
- **The bug:** `_configured_seed` starts at -1, so `configure(-1)` returns immediately and all 17 noise fields keep FastNoiseLite defaults.
- **Verified:** elevation frequency 0.010 instead of 0.00015, and noise seed 0.
- **Reachable via:** the URL. The seed field strips "-".
- **Fix:** use `var _configured := false`.
- **Effort:** trivial.

**D3 · Low · Very large numeric seeds alias or don't survive the save**

- **Where:** `chunk_manager.gd:406-407`, `world_changes.gd:98`.
- **The bug:** FastNoiseLite keeps 32 bits of the seed, while placement hashes format the full 64-bit value. Two long numeric seeds can therefore share terrain but have different objects. JSON also parses numbers as doubles, so for seeds above 2^53 `int(data["seed"]) != world_seed`, and the save is silently ignored.
- **Fix:** normalise in `_seed_from_text()` (for example `& 0x7FFFFFFF`), and store the seed as a string.
- **Effort:** small.

**D4 · Low (question) · Nothing checks that web and native build the same world**

- **The gap:** the snapshot only runs natively, where it is identical across glibc and MSVC. The web build uses emscripten's math library. Calls such as `cos`/`sin` for the wind vector in `sample()`, and `pow` in geometric means, can differ in the last digit and flip rare threshold decisions.
- **When it matters:** only if one seed must give an identical world on desktop and web.
- **Fix, if so:** a `?selftest=snapshot` mode that prints the hashes to the browser console.
- **Effort:** small to medium.

### 2.9 Web constraints

**W1 · High · "Go to" searches run on the main thread on web, for up to tens of seconds**

- **Where:** `chunk_manager.gd:462-467`, `biome_finder.gd`, `structure_sites.gd:145`.
- **The problem:** without threads, `travel_to_biome()` runs `BiomeFinder.find()` and `StructureSites.find()` synchronously.
- **Measured natively:** a biome search that finds nothing (bounded by `MAX_RADIUS` 6000) took 27.9 s. Searches that succeed take about 0.4–1 s (per PROJECT_STATE).
- **Impact:** on WASM that is a frozen tab, probably with the browser's "page unresponsive" prompt. The menu lists every biome, including rare ones (Sea, Frozen Sea), so a failed search is one click away.
- **Fix:**
  1. Make both searches resumable: an object holding the ring index, best-so-far and visited cells, with `step(deadline_usec) -> bool`.
  2. On web, advance it from `_process()` within a frame budget, the way `_run_inline_steps()` already does. Keep the thread on desktop.
  3. Show "Searching…" with a cancel option.
- **Effort:** small to medium.

**W2 · High · Hover and tap picks can place whole guild stacks on the main thread**

- **Where:** `chunk_manager.gd:1594, 1978, 2293`, `hover_highlight.gd:54`.
- **The path:** `hover_target()` → `_resource_at()` → `_place_stack()` over a 5×5-tile rect. If they aren't cached, that places all 10 guilds in up to 4 chunks.
- **Measured:** 0.77 ms warm; 460–560 ms cold.
- **How often:** HoverHighlight calls it for every new world pixel under the mouse, and every tap calls it too.
- **When it's cold:**
  - Placements are cached only where the current view built them.
  - The cache is also dropped wholesale once it grows past eight times the loaded area (line 1709). Measured: after walking 47 chunks it went from 6,388 entries to 196. Picks over loaded World-view chunks near the player then cost 48–131 ms each, until those chunks scrolled away.
- **Impact:**
  - In Terrain Only and every data view, and when zoomed out past LOD 2, moving the mouse in a desktop browser freezes for about 0.5 s per chunk crossed, longer on WASM.
  - In the default World view the same happens intermittently: 50–130 ms hitches after each wipe.
  - A tap in Terrain Only can even harvest an object that isn't drawn.
  - On desktop builds, the main thread also waits on `_gen_mutex` behind worker steps.
- **Fix:**
  - Pick from what is drawn: `_chunk_placements`, the shown, already-filtered instances of loaded chunks.
  - Return `{}` in views or LODs without markers; a tap there just walks.
  - Use `try_lock()` for hover, as `ambient_env()` already does.

  ```gdscript
  func _drawn_instances_near(tile: Vector2i) -> Array:
  	var result := []
  	var c := Vector2i((Vector2(tile) / CHUNK_SIZE).floor())
  	for dy in range(-1, 2):
  		for dx in range(-1, 2):
  			for entry in _chunk_placements.get(c + Vector2i(dx, dy), []):
  				if entry[0][0] != null:  # skip the structure-parts layer
  					result.append_array(entry[1])
  	return result
  ```

- **Effort:** small.

**W3 · Medium · `_walkable` grows without bound during play**

- **Where:** `chunk_manager.gd:244, 1165, 2262`.
- **The problem:** every chunk baked at LOD 1 adds 256 entries. The 400,000-entry cap is only checked on an `is_walkable()` miss, and plain walking rarely misses.
- **Measured:** 20,736 entries after startup, and 205,216 (about 18 MB at a measured 88 bytes per entry) after walking 80 chunks east. That's about 2,300 entries (200 KB) per chunk walked, and it keeps growing until some lookup misses. For example, a path through unloaded tiles, or a tap while zoomed out.
- **Fix:** store walkability per chunk (a `PackedByteArray` of 256) in a bounded chunk cache. It is deterministic, so evicting and recomputing is safe. At minimum, enforce the cap in `_bake_rows()`.
- **Effort:** small.

**W4 · Medium · There is no way to measure the web build**

- **The gap:** PROJECT_STATE records "no web timings". Every budget (`INLINE_BUDGET_USEC`, `IMAGE_BAND_ROWS`, `APPLY_BUDGET_USEC`) was tuned natively.
- **Measured here:** one 2-row image band step on a cold World-view chunk takes 4.9–6.5 ms, as long as the whole 5 ms budget. A streaming frame can therefore do 10+ ms of chunk work plus up to 3 ms of applying, even natively. This container runs roughly 2–2.5× slower than the numbers in PROJECT_STATE, and WASM is slower again.
- **Fix:** a small overlay behind `?debug=1` or a key, showing:
  - frame time (p50 and max over 5 s)
  - the longest job step
  - queue length
  - chunks per second
  - node count

  P2 and W5 can then be decided from data.
- **Effort:** small.

**W5 · Low · LOD thresholds have no hysteresis**

- **Where:** `chunk_manager.gd:98-103, 570-574`.
- **The problem:** crossing a threshold invalidates every loaded chunk. A pinch hovering around zoom 1.0, 0.5 or 0.25 rebuilds the whole load square on each crossing (81 to 441+ chunks), and throws away the previous LOD's images.
- **Fix:** switch down at 0.95× and back up at 1.05× the threshold.
- **Effort:** trivial.

**W6 · Low · Refreshing or sharing the page gives a different world**

- **Where:** `chunk_manager.gd:387-399, 1947-1949`.
- **The problem:** a visit without `?seed=` picks a random seed but never writes it into the URL. Refreshing, bookmarking or sharing leads to a new world, and orphans the previous save. Also, the close-request save doesn't fire when a tab closes, so position and time are only saved hourly (PROJECT_STATE already notes that a closed tab loses up to an in-game hour).
- **Fix:**
  - Write the seed into the URL after resolving it:

    ```gdscript
    JavaScriptBridge.eval("history.replaceState(null, '', '?seed=%s')" % _seed_text.uri_encode())
    ```

  - Also save on focus-out. Check which notification the web build actually delivers.
- **Effort:** small.

## 3. What's working well

- **Layering that matches plan Rule 4.** `WorldGen.sample()` → `EnvironmentalState` → suitability and density (`ResourceManager`) → instances (`ResourcePlacement`) → records (`ResourceInstance`) → player changes (`WorldChanges`). Injecting `density_fn` and `shares_fn` makes each layer testable with synthetic inputs.
- **Chunk-independent, order-free placement.**
  - World-aligned cells.
  - 32-bit integer hashing that can't overflow on web.
  - Matérn thinning (a spacing rule where the higher-priority point wins) with a strict tie-break.
  - Stack margins for collisions between guilds.
  - Stable `(guild, cell)` keys, which is why persistence only needs to store changes.

  D1 is the one place this discipline is broken, and it's outside this code.
- **Content as data.** Species, guilds, terrain materials, structures and quality profiles all reuse one suitability machine. `get_curve_domain_warnings()` catches a real class of data bugs at startup.
- **Guard rails with teeth.** The golden snapshot was made platform-independent by writing integer micro-tiles. `explain_suitability()` is tested against `get_suitability()`, so the debug breakdown can't drift from the real calculation.
- **The streaming design.**
  - Epochs, so stale results are dropped.
  - Nearest-first jobs.
  - One code path for the worker and the inline fallback, with finer steps on web.
  - `flush_chunk_work()` for tests.
  - Benchmarks (`bench_pan`, `bench_views`) run against interleaved baselines.
- **Pure, static rules for time and visuals.** `GameClock`, `Seasons`, `Wind`, `SunShadow` and `AmbientParticles.weights()` are easy to test and reason about. No global RNG is used in generation; it appears only for new seeds, audio, and particle visuals.
- **Loud failure for shader constants.** `GameConstants` sets shader uniforms that have no defaults, so a material that missed them fails visibly.
- **Input handling with tested browser quirks.** Emulated-mouse ordering, renumbered touches and pinch lifts are all handled and tested through the real input pipeline.
- **Decisions and measurements are written down.** The problem is where they are written (§4.2), not whether.

## 4. Proposals

### 4.1 Splitting `chunk_manager.gd`

**Target.** ChunkManager stays the scene's composition root and public facade, at about 250 lines. Everything else moves into modules that each own one concern. Only the presenter, effects and the facade touch the scene tree. Dependencies point one way: leaf data (content, view modes, terrain codes) ← generation context ← chunk builder ← streamer (which calls the builder through a Callable); presenter ← picker; navigation is pure.

| New file | Takes over | Thread | Depends on |
|---|---|---|---|
| `world/world_content.gd` | preloads, `GUILD_STACK`, deposits, farmland, `_definitions_by_id`, member → guild, curve warnings, eager curve plans | any (read-only) | — |
| `world/terrain_codes.gd` | tile codes, `SHORE_SHAPES`/`SHORE_STEPS`/`CORNER_EDGES`, `_shore_shape()` | any | WorldGen |
| `world/view_modes.gd` | `ViewMode`, per-view table (label, colour function, layers, flags); the dropdown reads its labels | any | content |
| `world/generation_context.gd` | seed, WorldGen, StructureSites, `_gen_mutex`, the env / density / raw-placement / walkability caches; `tile_env`, `guild_density`, `resource_density`, `species_shares`, `raw_guild_chunk`, `place_stack`, `deposit_potentials`, `is_walkable`, `configure()`, `clear()`; public methods lock internally | any | content, WorldGen, ResourceManager, ResourcePlacement |
| `world/chunk_builder.gd` | job steps, `_bake_rows`, `_terrain_color`, `_color_for`, overlay grids, `_placement_chunk`, quality markers, warm-ups; returns plain data | worker or inline | context, view_modes, terrain_codes |
| `world/chunk_streamer.gd` | epochs, queue, in-flight, worker lifecycle, inline budget, `flush`, `has_pending`, load radius, LOD (with hysteresis) | main + worker | builder (via Callable) |
| `world/chunk_presenter.gd` | turns results into sprites, borders, overlays, markers and shadows; styling, seasons, redraw after harvest; the shown placements | main | results, content |
| `world/resource_picker.gd` | `_resource_at`, `hover_target`, sprite hit tests, all from the shown placements | main | presenter |
| `world/navigation.gd` | A*, heap, path smoothing, walkable line, nearest walkable; takes `is_walkable` (later plus structure blockers) | main | — (pure) |
| `world/world_session.gd` | clock, `WorldChanges`, load/save/throttle, harvest by key, tents, spawn | main | context, picker |
| `world/world_travel.gd` | biome and structure search: a thread on desktop, stepped on web | main (+thread) | its own WorldGen |

**Migration order.** One PR per step. The full suite and the snapshot must stay green at every step. Until step 9, ChunkManager keeps thin forwarding members so the tests keep working, for example `var _world_gen: WorldGen: get: return _ctx.world_gen`.

0. **Safety net first:** X1, T5, T3, T1, then D1 with T2. A refactor must not be able to hide an order-dependence bug.
1. `world_content.gd` + `terrain_codes.gd`: constants only.
2. `navigation.gd`: pure, with its own fast tests. This is where "walls block walking" goes: `is_walkable(t) and not structures.blocks(t)`.
3. `world_session.gd`, fixing C3 (harvest by key) and C4 (safe save) on the way.
4. `view_modes.gd`: the snapshot's image hashes prove the views are unchanged.
5. `generation_context.gd`: caches and mutex behind one API. This fixes C2 by construction, and is where W3's per-chunk walkability goes.
6. `chunk_builder.gd`.
7. `chunk_streamer.gd` + `chunk_presenter.gd`, with C1 (fade) and W5 (hysteresis).
8. `resource_picker.gd` (W2) + `world_travel.gd` (W1).
9. Move tests to module APIs, delete the forwarding members, and move files into folders (O1).

**Sequencing against upcoming work:**
- Steps 0–3 before wall-blocking and Phase 15.
- Step 5 before any multi-worker experiment. A per-worker context is the natural unit, and D1 must be fixed first, or per-worker caches will disagree.
- Step 7 before investing further in depth sorting and pivots.

### 4.2 A clearer PROJECT_STATE.md

**Principle.** PROJECT_STATE is a snapshot a new session reads in one go. History, decisions and how-tos live in their own files. Budget: about 10 KB.

```markdown
# Project State — updated 2026-09-26, main @ 2c97bf0 (deployed)

## Now
- Focus: <1–3 bullets>
- Exact next step: <one line; links the TODO.md item>

## Deployed / verified
| Area | State | Verified how (headless / GL renderer / web by eye) |
|---|---|---|

## Open questions for the user
- Walls block walking? Structures cast shadows? ...

## Known issues
- <bug / flaky test / workaround, with the test name or file:line>

## Recent changes (last ~10; details in CHANGELOG_DEV.md)
- 2026-09-26 Rounded ground corners; borders only between different grounds (2c97bf0)

## Where to look
- architecture: docs/architecture.md · decisions: docs/decisions.md
- workflow and gotchas: docs/dev-workflow.md · tuning numbers: docs/tuning-log.md
- plan: docs/resource-generation-plan.md · backlog: TODO.md
```

**Where today's content goes:**

| Today's content | New home |
|---|---|
| "Completed", "In Progress" (mostly finished work), "Session Handoff > Last Completed Work" | `CHANGELOG_DEV.md`, newest first, one entry per merged change (replacing the handoff template now in that file) |
| "Important Decisions", plus decisions buried in phase entries (guild model, shade as canopy density, deposits as fields, succession as one field, terrain materials as ResourceDefinitions, landmark cells) | `docs/decisions.md`, one short entry each: date, decision, why, when to revisit |
| "Things To Watch Out For" and the testing policy | `docs/dev-workflow.md`: setup with `--import`, suites and their timings, Xvfb renders, worktrees, the deploy flow, platform gotchas, tileset coordinates |
| Measured distributions and benchmark numbers | `docs/tuning-log.md` |
| "Important Architecture" | already in `docs/architecture.md` |

Also:
- **`docs/architecture.md`:** trim it to the current state (drop the Phase 0 narrative, fix `TILE_SIZE`), and keep the threading rule and the seed-offset registry there as their single source.
- **`TODO.md`:** keep it as the only backlog, and fix its stale Current Task.
- **Template files:** put their contents back under the right names, or fold them into `dev-workflow.md`.
- **CLAUDE.md:** add a line such as "PROJECT_STATE is a snapshot under 10 KB; history → CHANGELOG_DEV.md, decisions → docs/decisions.md". A CI size check keeps it honest.

## 5. Roadmap

**Quick wins** (each about an hour or less, low risk):
1. X1: `--import` in the runner (verified).
2. T5: fail on script and engine errors.
3. T3: de-flake the no-worker test.
4. D1 + T2: fix WaterTopology and add an order test. Run the full suite; re-record the snapshot only if an area changes.
5. W2: pick from drawn placements, `try_lock()` for hover, no picking without markers.
6. D2 seed sentinel, W6 seed in the URL, W5 LOD hysteresis.
7. C1 remove or fix the fade tween; C2 and C5 locking and eager curve plans.
8. X4 and O1: commit the `.uid` files; drop the unused PNG from the export.
9. W3: bound `_walkable`.
10. T1: the CI gate. It's a small change, but a process change, so it's worth doing deliberately.

**Before the upcoming work:**

| Before… | Do |
|---|---|
| By-eye tuning in the web build | W2 and W1 (the data views and "Go to" are the tuning tools), X3's rebuild key for fast desktop tuning, W4's overlay |
| Settling the art style | C1 (don't build on `modulate`); measure P2 on the web build with W4 |
| Landmark wall-blocking | split steps 1–2 (navigation) |
| Phase 15 (yields, prospecting) | D1, C3, C4, split step 3 (session) |
| Phase 17 multi-worker | D1 and split step 5 |

**Larger refactors, in order:**
1. The `chunk_manager.gd` split, steps 1–9 (§4.1), interleaved with feature work.
2. The PROJECT_STATE and docs restructure (§4.2), in one docs-only session.
3. P1 batching (per-chunk sampling) as the Phase 17 "cheaper density" item, measured with `bench_views`; P4 image reuse on the way.
4. P2: choose a sprite rendering approach from W4's web measurements.
