extends SceneTree

## Loads the real world.tscn, switches to Oak Placement, and checks the
## marker layer follows view/LOD/chunk streaming, then that the guild views
## (Tree/Rock/Berry Placement, Resources) draw their members. If OUT_PNG is
## set, also renders the real _color_for() base + chunk-by-chunk Resources
## view (every guild, in its marker shapes; chunk grid drawn) to that path
## for visual inspection. Run via tests/run_tests.sh.

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

	# Guild view: one marker node per chunk, markers in both species' colors.
	cam.global_position = Vector2.ZERO
	await process_frame
	await process_frame
	t0 = Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.TREE_PLACEMENT)
	print("INFO switch to Tree Placement: %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	check(world._loaded_placements.size() == world._loaded_chunks.size(), "tree view: one marker node per loaded chunk")
	var fills := {}
	for m in world._loaded_placements.values():
		for c in m._fills:
			fills[c] = fills.get(c, 0) + 1
	var oak_c: Color = world.OAK_RESOURCE.debug_color
	var pine_c: Color = load("res://resources/pine.tres").debug_color
	var member_colors := {}
	for member in world.CANOPY_TREES.members:
		member_colors[member.debug_color] = true
	var only_members := true
	for c in fills:
		only_members = only_members and member_colors.has(c)
	check(fills.get(oak_c, 0) > 0 and fills.get(pine_c, 0) > 0 and only_members, "tree view: oak (%d) and pine (%d) markers, species colors only (%d colors)" % [fills.get(oak_c, 0), fills.get(pine_c, 0), fills.size()])

	# Rock/Berry Placement: each guild's members only.
	var guild_counts := {}
	for mode in [CM.ViewMode.ROCK_PLACEMENT, CM.ViewMode.BERRY_PLACEMENT]:
		world.set_view_mode(mode)
		var guild: ResourceGuild = world._placement_layers()[0][0]
		var ok: bool = world._loaded_placements.size() == world._loaded_chunks.size()
		var n := 0
		for m in world._loaded_placements.values():
			n += m._positions.size()
			for c in m._fills:
				ok = ok and guild.members.any(func(member): return member.debug_color == c)
		guild_counts[guild.id] = n
		check(ok and n > 0, "%s view: %d markers, one node per chunk, member colors only" % [guild.id, n])

	# Resources view: Material base image; the same trees as Tree Placement
	# as triangles, plus the same rocks (squares) and berry bushes (circles).
	var tree_count := 0
	world.set_view_mode(CM.ViewMode.TREE_PLACEMENT)
	for m in world._loaded_placements.values():
		tree_count += m._positions.size()
	# Cold: drop the per-chunk guild placement cache the views above filled.
	world._raw_guild_chunks.clear()
	t0 = Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.RESOURCES)
	print("INFO switch to Resources (3 guilds, cold cache): %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	var shape_counts := {}
	for m in world._loaded_placements.values():
		for s in m._shapes:
			shape_counts[s] = shape_counts.get(s, 0) + 1
	var Shape = world.ResourceMarkerChunkScript.Shape
	check(shape_counts.get(Shape.TRIANGLE, 0) == tree_count and tree_count > 0
		and shape_counts.get(Shape.SQUARE, 0) == guild_counts["surface_rocks"]
		and shape_counts.get(Shape.CIRCLE, 0) == guild_counts["shrubs"],
		"resources view: %d tree triangles (= Tree Placement), %d rock squares, %d berry circles" % [
			shape_counts.get(Shape.TRIANGLE, 0), shape_counts.get(Shape.SQUARE, 0), shape_counts.get(Shape.CIRCLE, 0)])
	# Click-to-inspect names the placed resource under the click, in any view.
	var some_tree: Dictionary = {}
	for base in [Vector2i(0, 0), Vector2i(-16, 0), Vector2i(0, -16), Vector2i(-16, -16)]:
		var trees: Array = world._place_stack_chunk(base)[world.CANOPY_TREES]
		if not trees.is_empty():
			some_tree = trees[0]
			break
	var tree_pos: Vector2 = some_tree["position"]
	world.set_view_mode(CM.ViewMode.MATERIAL)
	world._on_tile_clicked(tree_pos * world.TILE_SIZE)
	var panel_text: String = world._inspector_panel.label.text
	var expected := "[b]Resource:[/b] %s (Canopy Trees)" % String(some_tree["id"]).capitalize()
	var bare := Vector2.INF
	for y in range(-40, 40):
		for x in range(-40, 40):
			var p := Vector2(x + 0.5, y + 0.5)
			if world._resource_at(p).is_empty():
				bare = p
				break
		if bare != Vector2.INF:
			break
	world._on_tile_clicked(bare * world.TILE_SIZE)
	check(panel_text.contains(expected) and world._inspector_panel.label.text.contains("[b]Resource:[/b] -"),
		"click inspector: tree at %s shows '%s'; bare ground at %s shows '-'" % [tree_pos, expected, bare])
	world.set_view_mode(CM.ViewMode.RESOURCES)

	var probe: Dictionary = world._world_gen.sample(3, 5)
	check(world._color_for(probe, 3, 5) == DebugColorizer.color_for(probe), "resources view: base image is the Material color")

	var out := OS.get_environment("OUT_PNG")
	if out != "":
		_render_png(world, CM, out)

	print("RESULT %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(1 if _fails > 0 else 0)


## Real _color_for() in the Resources view (Material) + every placement
## layer (rocks, berry bushes, trees) placed chunk by chunk through the real
## _place_stack_chunk(), in the view's shapes and colors, chunk grid drawn.
func _render_png(world: Node2D, CM, out: String) -> void:
	world.set_view_mode(CM.ViewMode.RESOURCES)
	var tiles := int(OS.get_environment("OUT_TILES")) if OS.get_environment("OUT_TILES") != "" else 160
	var px := 5
	var origin := Vector2i(-tiles / 2, -tiles / 2)
	var img := Image.create(tiles * px, tiles * px, false, Image.FORMAT_RGB8)
	for ty in tiles:
		for tx in tiles:
			var wx := origin.x + tx
			var wy := origin.y + ty
			var c: Color = world._color_for(world._world_gen.sample(wx, wy), wx, wy)
			img.fill_rect(Rect2i(tx * px, ty * px, px, px), c)
	var markers = world.ResourceMarkerChunkScript
	var outline: Color = markers.OUTLINE
	var total := 0
	var stacks := {}  # chunk base -> {guild: instances}
	for cy in range(floori(origin.y / 16.0), ceili((origin.y + tiles) / 16.0)):
		for cx in range(floori(origin.x / 16.0), ceili((origin.x + tiles) / 16.0)):
			stacks[Vector2i(cx * 16, cy * 16)] = world._place_stack_chunk(Vector2i(cx * 16, cy * 16))
	for layer in world._placement_layers():
		var source: Resource = layer[0]
		var radius: float = source.minimum_spacing * px * 0.35
		var colors: Dictionary = world._marker_colors(source)
		for base in stacks:
			for inst in stacks[base][source]:
				var p: Vector2 = ((inst["position"] as Vector2) - Vector2(origin)) * px
				_fill_polygon(img, markers.shape_polygon(layer[1], p, radius + 1.5), outline)
				_fill_polygon(img, markers.shape_polygon(layer[1], p, radius), colors[inst["id"]])
				total += 1
	# Chunk grid lines to eyeball seams.
	for i in range(0, tiles + 1, 16):
		for j in tiles * px:
			var k := mini(i * px, img.get_width() - 1)
			img.set_pixel(k, j, Color(1, 1, 1, 1).darkened(0.6))
			img.set_pixel(j, k, Color(1, 1, 1, 1).darkened(0.6))
	img.save_png(out)
	print("INFO rendered %d instances to %s" % [total, out])


func _fill_polygon(img: Image, poly: PackedVector2Array, c: Color) -> void:
	var box := Rect2(poly[0], Vector2.ZERO)
	for v in poly:
		box = box.expand(v)
	for y in range(floori(box.position.y), ceili(box.end.y) + 1):
		for x in range(floori(box.position.x), ceili(box.end.x) + 1):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height() and Geometry2D.is_point_in_polygon(Vector2(x, y), poly):
				img.set_pixel(x, y, c)
