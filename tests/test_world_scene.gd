extends SceneTree

## Loads the real world.tscn, switches to Oak Placement, and checks the
## marker layer follows view/LOD/chunk streaming. If OUT_PNG is set, also
## renders the real _color_for() base + chunk-by-chunk placement (chunk grid
## drawn) to that path for visual inspection. Run via tests/run_tests.sh.

var _fails := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond:
		_fails += 1


func _init() -> void:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = 4242
	root.add_child(world)
	await process_frame
	await process_frame

	var CM = world.get_script()
	check(world._loaded_placements.is_empty(), "Material view: no placement markers")
	var t0 := Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.RESOURCE_PLACEMENT_OAK)
	print("INFO switch to Oak Placement: %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	await process_frame
	check(world._loaded_placements.size() == world._loaded_chunks.size(), "placement view: one marker node per loaded chunk (%d)" % world._loaded_placements.size())
	var total := 0
	for m in world._loaded_placements.values():
		total += m._positions.size()
	check(total > 0, "placement view: %d oak markers in loaded area" % total)

	# Pan far away: new chunks get markers, unloaded chunks' markers are freed.
	var cam: Node2D = world.get_node("CameraRig")
	cam.global_position = Vector2(5000, 3000)
	await process_frame
	await process_frame
	var match_keys := true
	for c in world._loaded_chunks.keys():
		match_keys = match_keys and world._loaded_placements.has(c)
	check(match_keys and world._loaded_placements.size() == world._loaded_chunks.size(), "after pan: markers track streamed chunks exactly")
	check(world.resources_root.get_child_count() >= world._loaded_placements.size(), "markers parented under Resources")

	# Zoom out past MAX_PLACEMENT_LOD_STEP: markers removed; back in: rebuilt.
	var camera: Camera2D = world.get_viewport().get_camera_2d()
	camera.zoom = Vector2(0.3, 0.3)
	await process_frame
	check(world._loaded_placements.is_empty(), "zoomed out (lod %d): markers hidden" % world._current_lod_step())
	camera.zoom = Vector2(4, 4)
	await process_frame
	await process_frame
	check(world._loaded_placements.size() == world._loaded_chunks.size(), "zoomed back in: markers rebuilt")

	world.set_view_mode(CM.ViewMode.MATERIAL)
	check(world._loaded_placements.is_empty(), "back to Material: markers removed")

	var out := OS.get_environment("OUT_PNG")
	if out != "":
		_render_png(world, CM, out)

	print("RESULT %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(1 if _fails > 0 else 0)


## Real _color_for() in the placement view + instances, chunk grid drawn.
func _render_png(world: Node2D, CM, out: String) -> void:
	world.set_view_mode(CM.ViewMode.RESOURCE_PLACEMENT_OAK)
	var tiles := 160
	var px := 5
	var origin := Vector2i(-80, -80)
	var img := Image.create(tiles * px, tiles * px, false, Image.FORMAT_RGB8)
	for ty in tiles:
		for tx in tiles:
			var wx := origin.x + tx
			var wy := origin.y + ty
			var c: Color = world._color_for(world._world_gen.sample(wx, wy), wx, wy)
			img.fill_rect(Rect2i(tx * px, ty * px, px, px), c)
	var density_fn := func(x: int, y: int) -> float:
		return world._resource_density(world._world_gen.sample(x, y), world.OAK_RESOURCE, x, y)
	var instances := []
	# Place chunk by chunk, exactly as the game does.
	for cy in range(origin.y / 16, (origin.y + tiles) / 16):
		for cx in range(origin.x / 16, (origin.x + tiles) / 16):
			instances.append_array(ResourcePlacement.place_in_rect(world.OAK_RESOURCE, 4242, Rect2i(cx * 16, cy * 16, 16, 16), density_fn))
	for inst in instances:
		var p: Vector2 = ((inst["position"] as Vector2) - Vector2(origin)) * px
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if dx * dx + dy * dy <= 9:
					var q := Vector2i(p) + Vector2i(dx, dy)
					if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
						img.set_pixelv(q, Color(0.02, 0.06, 0.02) if dx * dx + dy * dy > 4 else Color(0.2, 0.9, 0.2))
	# Chunk grid lines to eyeball seams.
	for i in range(0, tiles + 1, 16):
		for j in tiles * px:
			var k := mini(i * px, img.get_width() - 1)
			img.set_pixel(k, j, Color(1, 1, 1, 1).darkened(0.6))
			img.set_pixel(j, k, Color(1, 1, 1, 1).darkened(0.6))
	img.save_png(out)
	print("INFO rendered %d instances to %s" % [instances.size(), out])
