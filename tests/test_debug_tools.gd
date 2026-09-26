extends "res://tests/harness.gd"

## Phase 18 (developer tooling): the Debug views and the factor breakdown.
## Checks: ResourceManager.explain_suitability() rebuilds exactly the real
## get_suitability() for every placed resource over a tile grid (so the
## breakdown can't drift from the code); in the scene, the Debug views
## colour tiles by the chosen resource's score / density / patch value,
## Debug: Placement shows only that resource's instances, switching the
## resource rebuilds them, species densities add up to the guild's, the
## inspector shows the breakdown only in Debug views, and the resource
## dropdown lists every resource and only shows in Debug views. F5 reloads
## the content data from disk (review X3); F3 shows the debug overlay
## (review W4).
## Run via tests/run_tests.sh.

const ViewModes := preload("res://scripts/world/view_modes.gd")
const SEED := 4242


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	var CM = world.get_script()

	# explain_suitability == get_suitability, every resource, many tiles.
	var wg := WorldGen.new()
	wg.configure(SEED)
	var agree := true
	var nonzero := 0
	var compared := 0
	var worst := ""
	for y in range(-600, 600, 40):
		for x in range(-600, 600, 40):
			var s := wg.sample(x, y)
			var st: EnvironmentalState = EnvironmentalState.from_sample(s)
			var cl := BiomeClassifier.classify_full(s)
			ResourceManager.get_shade(st, SEED, x, y, cl)
			for definition in world.debug_resources():
				var e: Dictionary = ResourceManager.explain_suitability(st, definition, cl)
				compared += 1
				nonzero += int(e["suitability"] > 0.0)
				if not is_equal_approx(e["recomputed"], e["suitability"]) or not (e["lines"] as Array).back().begins_with("suitability:"):
					agree = false
					worst = "%s at %d,%d: %f vs %f" % [definition.id, x, y, e["recomputed"], e["suitability"]]
	check(agree and nonzero > 1000, "explained suitability == get_suitability for %d cases (%d nonzero) %s" % [compared, nonzero, worst])

	# Debug views for pine.
	var pine: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "pine")[0]
	world.set_debug_resource(pine)
	check(world.debug_guild() == ViewModes.CANOPY_TREES, "pine's guild is the canopy")
	var colours_ok := true
	var tiles := 0
	for mode in [CM.ViewMode.DEBUG_SUITABILITY, CM.ViewMode.DEBUG_DENSITY, CM.ViewMode.DEBUG_PATCH]:
		world.set_view_mode(mode)
		world.flush_chunk_work()
		for y in range(-24, 24, 6):
			for x in range(-24, 24, 6):
				var s: Dictionary = world._ctx.world_gen.sample(x, y)
				var v: Dictionary = world._builder.debug_values(x, y)
				var key: String = {CM.ViewMode.DEBUG_SUITABILITY: "score", CM.ViewMode.DEBUG_DENSITY: "density", CM.ViewMode.DEBUG_PATCH: "patch"}[mode]
				var heat: Color = HeatmapColorizer.resource_suitability(v[key]) if key == "score" else HeatmapColorizer.resource_density(v[key])
				var want: Color = world._builder.terrain_color(s, x, y).lerp(heat, world._builder.HEATMAP_OVERLAY_STRENGTH)
				colours_ok = colours_ok and world._builder.color_for(s, x, y) == want
				tiles += 1
	check(colours_ok, "Debug: Suitability / Density / Patch Noise colour each tile by the resource's own value (%d tiles)" % tiles)

	# Species densities add up to the guild density.
	var sums_ok := true
	for y in range(-40, 40, 8):
		for x in range(-40, 40, 8):
			var total := 0.0
			for member in ViewModes.CANOPY_TREES.members:
				world._debug_resource = member
				total += world._builder.debug_values(x, y)["density"]
			sums_ok = sums_ok and absf(total - world._ctx.guild_density(ViewModes.CANOPY_TREES, x, y)) < 1e-6 * maxf(1.0, total)
	world._debug_resource = pine
	check(sums_ok, "each member's debug density is its share of the guild density (they add up)")

	world.set_view_mode(CM.ViewMode.DEBUG_PLACEMENT)
	world.flush_chunk_work()
	var only_pine := true
	var pines := 0
	for chunk in world._presenter.chunk_placements:
		for entry in world._presenter.chunk_placements[chunk]:
			for inst in entry[1]:
				only_pine = only_pine and inst["id"] == "pine"
				pines += 1
	var expected := 0
	for chunk in world._presenter.chunk_placements:
		var stack: Dictionary = world._ctx.place_stack_chunk(chunk * world.CHUNK_SIZE, 3)
		for inst in stack[ViewModes.CANOPY_TREES]:
			expected += int(inst["id"] == "pine")
	check(only_pine and pines == expected and pines > 0, "Debug: Placement draws exactly the pines of the real stack (%d of %d)" % [pines, expected])
	var birch: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "birch")[0]
	world.set_debug_resource(birch)
	world.flush_chunk_work()
	var birches := 0
	var only_birch := true
	for chunk in world._presenter.chunk_placements:
		for entry in world._presenter.chunk_placements[chunk]:
			for inst in entry[1]:
				only_birch = only_birch and inst["id"] == "birch"
				birches += 1
	check(only_birch, "switching the resource rebuilds the view (%d birches)" % birches)

	# Inspector: breakdown only in Debug views.
	world.set_debug_resource(pine)
	world.flush_chunk_work()
	world._on_tile_clicked(Vector2(6.5, 6.5) * world.TILE_SIZE)
	var text: String = world._inspector_panel.label.text
	check(text.contains("[b]Pine[/b] (Canopy Trees)") and text.contains("suitability:") and text.contains("species share:") and text.contains("pine density:"),
		"inspector shows the breakdown in a Debug view")
	var dropdown: OptionButton = world.get_node("UI/Menu/DebugResourceDropdown")
	await process_frame
	var shown_in_debug := dropdown.visible
	# The menu column lays itself out (review Q6): without the web-only
	# Reload button the controls below close up into its slot, 36 px tall
	# and 8 apart, as the old hand-placed offsets did; and the camera treats
	# them as UI.
	var tops := []
	for control in world.get_node("UI/Menu").get_children():
		if control.visible:
			tops.append([String(control.name), control.get_global_rect().position.y, control.size.y])
	check(str(tops) == str([["SeedInput", 12.0, 36.0], ["RandomizeButton", 56.0, 36.0], ["ViewModeDropdown", 100.0, 36.0], ["BiomeTravelDropdown", 144.0, 36.0], ["DebugResourceDropdown", 188.0, 36.0]]), "menu layout: %s" % str(tops))
	check(world.get_node("CameraRig").is_over_ui(dropdown.get_global_rect().get_center()), "a menu control counts as UI for the camera")
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()
	await process_frame
	world._on_tile_clicked(Vector2(6.5, 6.5) * world.TILE_SIZE)
	check(not world._inspector_panel.label.text.contains("species share:"), "no breakdown outside the Debug views")
	check(shown_in_debug and not dropdown.visible and dropdown.item_count == world.debug_resources().size()
		and dropdown.get_item_text(dropdown.selected) == "Pine (Canopy Trees)",
		"resource dropdown: all %d resources, current one selected, visible only in Debug views" % dropdown.item_count)
	dropdown.select(0)
	dropdown.item_selected.emit(0)
	check(world.debug_resource() == world.debug_resources()[0], "picking in the dropdown sets the debug resource (%s)" % world.debug_resource().id)

	# F5 reloads the content .tres files from disk into the loaded
	# instances and rebuilds the chunks with them (review X3). Stand-in for
	# an edited file: the in-memory pine drifts from its file (a flat zero
	# temperature curve, so no pines) and the world is rebuilt from that; the reload
	# must bring back the file's values, in the same instances, and redraw.
	# base_density is not in pine.tres: a value set back to its default must
	# come back too.
	world.flush_chunk_work()
	var count_pines := func() -> int:
		var n := 0
		for chunk in world._presenter.chunk_placements:
			for entry in world._presenter.chunk_placements[chunk]:
				for inst in world._unchanged(entry[1]):
					n += int(inst["id"] == "pine")
		return n
	var pines_before: int = count_pines.call()
	var file_density: float = pine.base_density  # at its default, so not in the file
	var curve: Curve = pine.temperature_curve
	var file_points := []
	for i in curve.point_count:
		file_points.append(curve.get_point_position(i).y)
		curve.set_point_value(i, 0.0)
	pine.base_density = 0.5
	ResourceManager._patch_noise_cache["stale"] = null
	world._ctx.clear()
	world._streamer.invalidate()
	world.flush_chunk_work()
	var pines_stale: int = count_pines.call()
	var f5 := InputEventKey.new()
	f5.keycode = KEY_F5
	f5.pressed = true
	world._unhandled_input(f5)
	var rebuilding: bool = world.has_pending_chunks()
	world.flush_chunk_work()
	var pines_after: int = count_pines.call()
	var files: int = world._content_paths(world.CONTENT_DIR).size()
	check(pines_stale == 0 and rebuilding and pines_after == pines_before and pines_before > 0,
		"F5 rebuilds the chunks from the reloaded data (pines: %d, %d with the drifted data, %d after)" % [pines_before, pines_stale, pines_after])
	var points_back := true
	for i in curve.point_count:
		points_back = points_back and curve.get_point_position(i).y == file_points[i]
	check(pine.base_density == file_density and pine.temperature_curve == curve and points_back
		and pine.curve_plan != null and not ResourceManager._patch_noise_cache.has("stale") and files > 60,
		"F5 re-reads all %d content files into the loaded instances (curves in place) and drops curve plans and noise caches" % files)

	# Debug overlay (review W4): hidden until F3 (or ?debug=1 on the web),
	# then reports frames, job steps, the queue, chunks per second and nodes.
	var perf: Label = world.get_node("UI/PerfOverlay")
	var hidden_at_start := not perf.visible
	var f3 := InputEventKey.new()
	f3.keycode = KEY_F3
	f3.pressed = true
	perf._unhandled_input(f3)
	world._streamer.invalidate()  # something to stream
	var until := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < until:
		await process_frame
	var lines: PackedStringArray = perf.text.split("\n")
	var longest := 0
	for c in perf._counters:
		longest = maxi(longest, c[1])
	var shown: int = perf._counters.back()[2] - perf._counters[0][2]
	check(hidden_at_start and perf.visible and lines.size() == 4 and lines[0].begins_with("Frame p50") and lines[1].begins_with("Longest job step")
		and lines[2].begins_with("Queued chunks") and lines[3].begins_with("Nodes") and longest > 0 and shown > 0 and perf._frames.size() > 5,
		"F3 shows the debug overlay: %s" % " | ".join(lines))
	world.flush_chunk_work()
	world.take_perf_counters()
	var idle: Dictionary = world.take_perf_counters()
	perf._unhandled_input(f3)
	check(idle["longest_step_usec"] == 0 and idle["queued"] == 0 and not perf.visible, "the longest step resets once read; F3 hides the overlay again")

	finish()
