extends SceneTree

## Phase 17 benchmark: cold view-switch times with the real world.tscn
## (seed 4242, default camera = 81 loaded chunks), each from Material with
## the per-chunk guild placement cache dropped first - the numbers quoted in
## PROJECT_STATE.md. Not a pass/fail suite (run_tests.sh only runs test_*):
##
##   $GODOT --headless --path . --script res://tests/bench_views.gd
##
## BENCH_REPEAT=n repeats each switch n times and reports the minimum.


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = 4242
	root.add_child(world)
	await process_frame
	await process_frame

	var CM = world.get_script()
	var repeat := maxi(int(OS.get_environment("BENCH_REPEAT")), 1)
	for mode in [CM.ViewMode.RESOURCE_PLACEMENT_OAK, CM.ViewMode.TREE_PLACEMENT, CM.ViewMode.RESOURCES, CM.ViewMode.MATERIAL]:
		var best := INF
		for r in repeat:
			world.set_view_mode(CM.ViewMode.MATERIAL if mode != CM.ViewMode.MATERIAL else CM.ViewMode.TEMPERATURE)
			if world.has_method("clear_generation_caches"):
				world.clear_generation_caches()
			else:  # before Phase 17
				world._raw_guild_chunks.clear()
			await process_frame
			var t0 := Time.get_ticks_usec()
			world.set_view_mode(mode)
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
			await process_frame
		print("BENCH %s: %.0f ms (%d chunks, cold)" % [CM.ViewMode.keys()[mode], best, world._loaded_chunks.size()])
	quit()
