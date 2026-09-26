# Development Workflow

How to work on this repository: the session loop, then setup, tests, renders,
deploys and the gotchas found so far. `CLAUDE.md` has the rules; this file has
the how-to.

## Session loop

```text
Understand → Plan → Implement → Verify → Review → Record
```

1. **Understand.** Inspect the smallest relevant part of the repository: the
   existing implementation, related abstractions, tests, configuration, docs.
2. **Plan.** For meaningful changes, settle the desired behavior, the
   integration point, the files to change and how to verify. Keep the plan
   proportional to the task.
3. **Implement.** A focused change; no unrelated refactors.
4. **Verify.** Widen step by step, and don't run expensive checks when a
   narrow one gives enough confidence:

   ```text
   targeted test → related tests → build / lint / typecheck → integration or runtime check
   ```

5. **Review.** Read the diff: anything unrelated? unnecessary complexity?
   existing behavior kept? request actually met? edge cases? docs needed?
6. **Record.** Update the project files when the change affects future work
   (see "Where things are recorded" below).

### Fresh context

A new session recovers from the repository, not from a previous
conversation:

1. `CLAUDE.md`
2. `PROJECT_STATE.md` (snapshot, under 10 KB)
3. `TODO.md` (the only backlog)
4. The relevant `docs/`: `architecture.md`, `decisions.md`, this file,
   `tuning-log.md`, `resource-generation-plan.md`
5. Recent Git history (`CHANGELOG_DEV.md` for the longer story)
6. The relevant source files

### Task sizing

Prefer tasks that give one coherent milestone ("add deterministic resource
sampling", "add a debug visualization", "profile world generation"). "Finish
procedural generation" or "make the game feel better" is too broad: break it
into concrete milestones.

### Planning vs. implementation

Plan when several systems interact, the architecture is uncertain, the
change touches many files or has real trade-offs. Skip elaborate planning
when the change is obvious, local, or dictated by existing patterns. Don't
spend more context planning a simple change than implementing it.

### Debugging

1. Reproduce the issue.
2. Establish the expected behavior.
3. Inspect the execution path.
4. Form a hypothesis.
5. Add targeted instrumentation if useful.
6. Test the hypothesis.
7. Fix the root cause.
8. Add a regression test when practical.

Don't make random changes until the symptom disappears.

### Procedural and simulation work

Prefer debug visualizations and measurable diagnostics over subjective
tuning. Expose intermediate values: input parameters, noise values,
classification results, probabilities, selected categories, rejection
reasons, final placement. Debug tooling usually pays off more than tuning
blind. Keep generation deterministic.

### Performance work

```text
Measure → Identify bottleneck → Change → Measure again
```

Don't optimize on intuition, or code that hasn't been shown to matter.
Record findings that affect architecture (`docs/tuning-log.md` for the
numbers).

### Refactoring

Refactor when it improves something concrete: correctness, testability,
performance, maintainability, or a feature that needs it. Not because code
could look cleaner. Keep behavior unless changing it is part of the task.

## Where things are recorded

- `PROJECT_STATE.md`: the snapshot a new session reads first. Under 10 KB;
  CI fails at 10240 bytes. Update "Now", the verified table, open questions,
  known issues and the last ~10 changes.
- `CHANGELOG_DEV.md`: one entry per merged change or phase, newest first.
- `docs/decisions.md`: date, decision, why, when to revisit.
- `docs/tuning-log.md`: measured distributions and benchmark numbers, dated.
- `docs/architecture.md`: how the systems fit together (current state only).
- `TODO.md`: the only backlog.
- Templates: `CLAUDE_TASK_TEMPLATE.md` (a task prompt),
  `SESSION_HANDOFF_TEMPLATE.md` (ending a session).

## Setup

- Godot 4.7.2 (the CI's version). Cloud (Linux) sessions have no Godot
  installed: `tests/run_tests.sh` downloads it into `~/.cache/godot`. For ad
  hoc scripts point `$GODOT` at that binary
  (`~/.cache/godot/Godot_v4.7.2-stable_linux.x86_64`).
- A fresh clone or `git worktree` needs `$GODOT --headless --path . --import`
  once (imports every asset and builds the class cache, ~9 s).
  `tests/run_tests.sh` does it on every run (review X1). The old `--editor
  --quit-after N` pass stopped before its first scan and imported nothing.
- `class_name` lookups in headless `--script` runs need
  `.godot/global_script_class_cache.cfg` (gitignored); `--import` rebuilds
  it, so run it after adding a `class_name`.
- Local Windows: `tests/run_tests.sh` only auto-downloads the Linux Godot.
  Set `GODOT=~/.cache/godot/Godot_v4.7.2-stable_win64_console.exe`
  (extracted from `~/Downloads/Godot_v4.7.2-stable_win64.exe.zip`; use the
  `_console` exe so output reaches the shell).
- `python3` works in cloud sessions. On the Windows machine it is the
  Microsoft Store stub and hangs - do scripted edits with sed or the Edit
  tool.

## Tests

- `tests/run_tests.sh` runs every `tests/test_*.gd` suite (25 now) headless;
  `tests/run_tests.sh <word> ...` runs the suites whose file name contains a
  word (e.g. `clock touch world_scene`). A suite fails on a FAIL line, a
  missing RESULT line (crash or hang; each suite has a 900 s timeout), or
  any script / engine error line (review T5).
- A suite `extends "res://tests/harness.gd"`: `check(cond, msg)` for each
  expectation, then `finish()`, which prints the RESULT line and sets the
  exit code (review T6).
- Timings: the full suite takes ~15-18 minutes (23 suites, 412 checks, 18 min
  18 s in the cloud container at 2c97bf0) because most suites boot the full
  `world.tscn` (81 chunks). The fast suites CI runs on every PR and before
  each deploy - `snapshot resource_placement world_changes game_clock
  structures shores navigation world_session` - take about 4 minutes.
- **Testing policy** (user, 2026-09-24): don't run the full suite for every
  update; run the suites covering the change. Run the full suite for changes
  to generation, placement, resource data or shared code (the chunk modules,
  `resource_manager.gd`, placement), where the snapshot and cross-suite
  checks matter.
- `tests/test_placement_snapshot.gd` guards generation output: the full
  guild stack + Oak Placement over seven areas for seed 4242, plus image
  hashes, against `tests/placement_snapshot.txt`, and a reverse-order pass
  from a fresh no-worker world. `SNAPSHOT_DUMP=path` writes the lines for
  diffing; `SNAPSHOT_WRITE=1` re-records - only for an agreed output change.
  Ground reads canopy shade, so changing canopy data (trees, cover curves)
  changes terrain image hashes too, not only placement.
- Tests and benchmarks that change the camera, zoom or view must call
  `world.flush_chunk_work()` before asserting on chunks, markers or overlays,
  and before calling generation functions directly (the worker may be
  mid-job otherwise). `await process_frame` alone doesn't mean chunks are
  there.
- Tests never touch the player's save dir (scripted-SceneTree guard in
  `changes_path()`).
- Keep float output in tests out of `%f` formatting: MSVC rounds `%.6f` ties
  half away from zero, glibc half to even, and many far-from-origin float32
  positions are exact decimal ties. The snapshot stores positions as integer
  micro-tiles for this reason (proven by re-rounding a Windows dump half-even,
  which reproduced every Linux md5).
- Helpers: `tests/run_tests.sh --by-biome` prints the per-biome placement
  breakdown (`tests/resource_by_biome.gd`). `OUT_PNG=path` renders a view
  from test_world_scene (`OUT_TILES` size, `OUT_PX` pixels per tile,
  `OUT_CENTER="x,y"` centre, e.g. `OUT_CENTER=18000,8820` for a river).

## Benchmarks

- `tests/bench_views.gd`: cold view-switch times (seed 4242, 81 chunks),
  timed until `flush_chunk_work()` finishes. `BENCH_REPEAT=n` takes the min
  of n; `BENCH_THREADED=0` forces the no-thread (web) path. Not run by
  run_tests.sh.
- `tests/bench_pan.gd`: per-frame time and "holes" (a visible chunk not
  loaded) during a pan. Compare its "work" column (Performance.TIME_PROCESS,
  main-thread work), not frame times.
- Headless frame times floor at 6.9 ms: Godot's low-processor-mode sleep, not
  work. On Windows they now often round up to the ~15.6 ms default timer tick
  (earlier sessions saw a flat 6.9 ms because something had raised the timer
  resolution); "work" too occasionally shows a ~16 ms outlier on threaded
  runs. A windowed run (drop `--headless`) uses the real renderer and vsync.
- Benchmark old code from a baseline `git worktree`, not by stashing, and run
  A/B interleaved on one machine. A baseline worktree needs `--import` (or a
  copied `.godot`: `cp -r .godot ../<worktree>/.godot` - not into a missing
  directory, that copies .godot AS the worktree path) or its scripts fail to
  compile and the numbers are meaningless. Remove it with `git worktree
  remove` when done.
- Record the numbers in `docs/tuning-log.md`.

## Real-renderer renders (Xvfb)

Headless (dummy renderer) can't compile shaders or read shader uniforms
back. Cloud sessions have Xvfb + Mesa, so

```sh
xvfb-run -a -s "-screen 0 800x600x24" $GODOT --path . --rendering-driver opengl3 --script res://tests/<script>.gd
```

runs the scene with the GL Compatibility renderer (the web build's), and
`root.get_viewport().get_texture().get_image()` captures frames. Shader work
(terrain, sway, shadows, surf) is checked this way.

## Running Godot safely

- Wrap every Godot run in `timeout`: a headless script that errors before
  `quit()` hangs until it is killed.
- When a headless run is killed by `timeout`, piped stdout is lost - use
  `stdbuf -o0` and a log file to see how far it got.
- Never `pkill -f <script name>` from a shell whose own command line contains
  that name: it kills the shell too.
- Don't edit scripts while `tests/run_tests.sh` (or any headless run) is
  going: each suite loads the scripts when it starts, so a mid-run edit
  silently tests a mix (a half-written instrumentation edit once made a
  baseline test_world_scene "hang").

## Worktrees and branches

- Background-job worktrees (`EnterWorktree`) branch from `origin/main`.
  `main` is the integration branch (`resource-generation` is stale), except
  during the review follow-up, whose batches branch from and merge into
  `review-followup`. `git fetch` first: local branches can lag the remote
  (local `main` was once 20 commits behind).

## Deploys

- Pushing to `main` deploys the web build to GitHub Pages
  (`.github/workflows/web-build.yml`, ~1-2 min; `gh run list` to watch). The
  fast suites must pass first.
- From a cloud session, pushing to `main` is blocked by the auto-mode
  permission check ("Production Deploy"). The working path is a PR from the
  session branch that the user merges. The GitHub MCP listing reports merged
  PRs as closed / merged=false - check `git log origin/main` instead. After a
  merge, continue on the same branch name fast-forwarded to `origin/main`.
- From the local Windows machine, pushes to `main` work.

## Generation and data gotchas

- The threading rule and the seed-offset registry live in
  `docs/architecture.md` (§5 and §6). New noise reserves a new offset there
  and in `world_gen.gd`; resource ids must be unique (noise and placement are
  seeded from them).
- `WorldGen.sample()`'s keys don't always match the plan doc's conceptual
  names (e.g. `laplacian`, not `curvature`; `exposure`, not `wind_exposure`).
  Use the key table in architecture.md §2.
- Any land-vegetation `ResourceDefinition` must set `water_body_weights` to
  exclude water (`{"none": 1.0, "ocean": 0.0, "sea": 0.0, "lake": 0.0,
  "river": 0.0}`, swamp optional): `elevation_curve` alone isn't enough,
  since rivers sit well above `sea_level`. `resources/species/oak.tres` is a
  worked example.
- Curves are in real field units. A fresh Curve has a 0..1 domain and
  `Curve.sample()` clamps outside it, so a curve on a -1..1 field silently
  flattens; `ResourceDefinition.get_curve_domain_warnings()` checks this and
  the game warns at startup.
- Reassign `required_curves`, don't mutate it in place: the setter resets the
  cached `curve_plan`.
- Narrow temperature ramps speckle: WorldGen adds +-0.06 micro-jitter to
  temperature, so a curve that goes 0 -> 1 over ~0.25 flickers tile to tile
  (found on farmland; fixed with a -0.6..-0.1 ramp). Keep temperature ramps
  wide or expect salt-and-pepper edges.

## Tileset coordinates

- Urizen sheet tiles in code and docs are (column, row), 0-based, 12 px
  tiles with 1 px margin and separation (`resource_marker_chunk.gd`
  `SPRITE_SIZE`, `SPRITE_STRIDE`; the layout matches `tileset.tres`). The
  user may count 1-based or row-first - render the area with numbered
  columns before assuming.
- The right ~2/3 of the sheet is characters and letters; objects are in the
  left third. The sheet is white on opaque black: `sprite_image()` turns a
  tile into white-on-transparent.
- New art (`assets/sprites/`) is drawn 1:1 at the 16 px tile size with its
  pivot at the bottom middle (`ResourceDefinition.sprite_texture`).
