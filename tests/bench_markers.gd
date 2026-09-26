extends SceneTree

## Frame cost of the World view's y-sorted marker rows (review P2): frame
## time with the markers and shadows shown vs hidden, at three zooms, 1080p.
## Needs a real renderer - headless draws nothing:
##
##   timeout 900 xvfb-run -a -s "-screen 0 1920x1080x24" $GODOT --path . \
##     --rendering-driver opengl3 --script res://tests/bench_markers.gd
##
## Under Xvfb the GL renderer is Mesa's software one, so compare the with /
## hidden gap between runs, not the absolute times (docs/tuning-log.md).
func _frames(n: int) -> Array:
	var times := []
	var last := Time.get_ticks_usec()
	for i in n:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append(now - last)
		last = now
	times.sort()
	return [times[n / 2] / 1000.0, times[n * 9 / 10] / 1000.0]

func _init() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var world: Node2D = load("res://world.tscn").instantiate()
	world.changes_dir = ""
	world.world_seed = 4242
	root.add_child(world)
	await process_frame
	root.get_window().size = Vector2i(1920, 1080)
	var cam: Camera2D = world.get_node("CameraRig/Camera2D")
	for zoom in [2.0, 1.0, 0.5]:
		cam.zoom = Vector2(zoom, zoom)
		for i in 5:
			await process_frame
		world.flush_chunk_work()
		for i in 30:
			await process_frame
		world.flush_chunk_work()
		var rows := 0
		var shadows := 0
		for m in world._presenter.loaded_placements.values():
			rows += m.get_child_count()
		var with_markers: Array = await _frames(120)
		world.resources_root.visible = false
		world.shadows_root.visible = false
		var without: Array = await _frames(120)
		world.resources_root.visible = true
		world.shadows_root.visible = true
		print("markers zoom %.1f: chunks %d, marker rows %d, frame ms median/p90 with markers %.2f/%.2f, hidden %.2f/%.2f" % [zoom, world._presenter.loaded_chunks.size(), rows, with_markers[0], with_markers[1], without[0], without[1]])
	quit(0)
