extends SceneTree

## Loads the real world.tscn, switches to Oak Placement, and checks the
## marker layer follows view/LOD/chunk streaming, then that the guild views
## (Tree/Rock/Berry Placement, Resources) draw their members. If OUT_PNG is
## set, also renders the real _color_for() base + chunk-by-chunk Resources
## view (every guild, in its marker shapes; chunk grid drawn) to that path
## for visual inspection - OUT_TILES tiles wide, centered on OUT_CENTER="x,y"
## (default the origin), OUT_PX pixels per tile (default 5; 12 = native
## sprite size). Run via tests/run_tests.sh.

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

	# Rock/Berry/Wetland Placement: each guild's members only.
	var guild_counts := {}
	for mode in [CM.ViewMode.ROCK_PLACEMENT, CM.ViewMode.BERRY_PLACEMENT, CM.ViewMode.WETLAND_PLACEMENT]:
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

	# Resources view: Material base image; the same trees as Tree Placement,
	# rocks, ore outcrops, berry bushes, reeds and cattails, all as tinted
	# sheet sprites; clay outcrops (no sprite) as hexagons.
	var tree_count := 0
	world.set_view_mode(CM.ViewMode.TREE_PLACEMENT)
	for m in world._loaded_placements.values():
		tree_count += m._positions.size()
	# Cold: drop the per-chunk guild placement cache the views above filled.
	world._raw_guild_chunks.clear()
	t0 = Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.RESOURCES)
	print("INFO switch to Resources (5 guilds, cold cache): %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	var shape_counts := {}
	for m in world._loaded_placements.values():
		for s in m._shapes:
			shape_counts[s] = shape_counts.get(s, 0) + 1
	var Shape = world.ResourceMarkerChunkScript.Shape
	var outcrops_placed := 0
	for c in world._loaded_chunks:
		outcrops_placed += world._place_stack_chunk(c * world.CHUNK_SIZE, 1)[world.ORE_OUTCROPS].size()
	var sprites_ok := true
	var sprite_colors := {}
	for g in [world.CANOPY_TREES, world.SURFACE_ROCKS, world.ORE_OUTCROPS, world.SHRUBS, world.WETLAND_PLANTS]:
		for member in g.members:
			sprite_colors[member.sprite_color] = true
	for m in world._loaded_placements.values():
		for i in m._shapes.size():
			if m._shapes[i] == Shape.SPRITE:
				sprites_ok = sprites_ok and m._textures[i] != null and sprite_colors.has(m._fills[i])
	# Clay has no sprite: its outcrops stay hexagons, everything else is a sprite.
	var clay_outcrops := 0
	for c in world._loaded_chunks:
		for inst in world._place_stack_chunk(c * world.CHUNK_SIZE, 1)[world.ORE_OUTCROPS]:
			if inst["id"] == "clay":
				clay_outcrops += 1
	var all_placed: int = tree_count + guild_counts["surface_rocks"] + outcrops_placed + guild_counts["shrubs"] + guild_counts["wetland_plants"]
	check(sprites_ok and tree_count > 0 and guild_counts["shrubs"] > 0 and guild_counts["wetland_plants"] > 0
		and shape_counts.get(Shape.SPRITE, 0) == all_placed - clay_outcrops
		and shape_counts.get(Shape.HEXAGON, 0) == clay_outcrops
		and shape_counts.get(Shape.DIAMOND, 0) == 0 and shape_counts.get(Shape.CIRCLE, 0) == 0,
		"resources view: %d sprites (%d trees, %d rocks, %d outcrops less %d clay, %d berry bushes, %d wetland plants; textured, sprite colors), %d clay hexagons" % [
			shape_counts.get(Shape.SPRITE, 0), tree_count, guild_counts["surface_rocks"], outcrops_placed, clay_outcrops, guild_counts["shrubs"], guild_counts["wetland_plants"], shape_counts.get(Shape.HEXAGON, 0)])
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

	# Deposits view (Phase 9): a heatmap plus ore outcrop markers (step 2);
	# clicking a tile with ore lists it in the inspector.
	world.set_view_mode(CM.ViewMode.DEPOSITS)
	var ore_tile := Vector2i(1 << 30, 0)
	for y in range(-64, 64):
		for x in range(-64, 64):
			if not world._deposit_potentials(world._world_gen.sample(x, y), x, y).is_empty():
				ore_tile = Vector2i(x, y)
				break
		if ore_tile.x != 1 << 30:
			break
	world._on_tile_clicked((Vector2(ore_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var ore_sample: Dictionary = world._world_gen.sample(ore_tile.x, ore_tile.y)
	var outcrop_count := 0
	var outcrops_ok := true
	for m in world._loaded_placements.values():
		outcrop_count += m._positions.size()
		for sh in m._shapes:
			outcrops_ok = outcrops_ok and sh == world.ResourceMarkerChunkScript.Shape.HEXAGON
	check(outcrops_ok and ore_tile.x != 1 << 30
		and world._color_for(ore_sample, ore_tile.x, ore_tile.y) != DebugColorizer.color_for(ore_sample)
		and world._inspector_panel.label.text.contains("[b]Deposits:[/b]"),
		"deposits view: only outcrop hexagons (%d); ore tile %s tinted and listed under Deposits in the inspector" % [outcrop_count, ore_tile])

	# Farming Potential (Phase 10): a heatmap, no markers; the inspector
	# shows the tile's value.
	world.set_view_mode(CM.ViewMode.FARMING_POTENTIAL)
	var farm_tile := Vector2i(1 << 30, 0)
	for y in range(-64, 64, 2):
		for x in range(-64, 64, 2):
			var st = EnvironmentalState.from_sample(world._world_gen.sample(x, y))
			if ResourceManager.get_suitability(st, world.FARMLAND, BiomeClassifier.classify_full(world._world_gen.sample(x, y))) > 0.5:
				farm_tile = Vector2i(x, y)
				break
		if farm_tile.x != 1 << 30:
			break
	world._on_tile_clicked((Vector2(farm_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var farm_sample: Dictionary = world._world_gen.sample(farm_tile.x, farm_tile.y)
	check(world._loaded_placements.is_empty() and farm_tile.x != 1 << 30
		and world._color_for(farm_sample, farm_tile.x, farm_tile.y) != DebugColorizer.color_for(farm_sample)
		and world._inspector_panel.label.text.contains("[b]Farming potential:[/b]"),
		"farming potential view: no markers; farmland tile %s tinted, value in the inspector" % farm_tile)
	world.set_view_mode(CM.ViewMode.RESOURCES)

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
	var px := int(OS.get_environment("OUT_PX")) if OS.get_environment("OUT_PX") != "" else 5
	var center := Vector2i.ZERO
	var center_env := OS.get_environment("OUT_CENTER").split(",")
	if center_env.size() == 2:
		center = Vector2i(int(center_env[0]), int(center_env[1]))
	var origin := center - Vector2i(tiles / 2, tiles / 2)
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
		var as_sprites: bool = layer[1] == markers.Shape.SPRITE
		var colors: Dictionary = world._marker_colors(source, as_sprites)
		var sprite_tiles: Dictionary = world._sprite_tiles(source)
		for base in stacks:
			for inst in stacks[base][source]:
				var p: Vector2 = ((inst["position"] as Vector2) - Vector2(origin)) * px
				total += 1
				if as_sprites and sprite_tiles.has(inst["id"]):
					_blit_sprite(img, markers.sprite_image(sprite_tiles[inst["id"]]["tile"]), p, roundi(sprite_tiles[inst["id"]]["size"] * px), colors[inst["id"]], outline)
					continue
				var shape: int = (layer[2] if layer.size() > 2 else markers.Shape.TRIANGLE) if as_sprites else layer[1]
				_fill_polygon(img, markers.shape_polygon(shape, p, radius + 1.5), outline)
				_fill_polygon(img, markers.shape_polygon(shape, p, radius), colors[inst["id"]])
	# Chunk grid lines to eyeball seams.
	for i in range(0, tiles + 1, 16):
		for j in tiles * px:
			var k := mini(i * px, img.get_width() - 1)
			img.set_pixel(k, j, Color(1, 1, 1, 1).darkened(0.6))
			img.set_pixel(j, k, Color(1, 1, 1, 1).darkened(0.6))
	img.save_png(out)
	print("INFO rendered %d instances to %s" % [total, out])


## A white-on-transparent sheet tile, px pixels wide, centered on p and
## tinted, with a one-sprite-pixel dark outline - as resource_marker_chunk.gd.
func _blit_sprite(img: Image, sprite: Image, p: Vector2, px: int, tint: Color, outline: Color) -> void:
	var n := sprite.get_width()
	var cell := float(px) / n
	var top_left := p - Vector2(px, px) * 0.5
	for pass_i in 2:
		var offsets := [Vector2(cell, 0), Vector2(-cell, 0), Vector2(0, cell), Vector2(0, -cell)] if pass_i == 0 else [Vector2.ZERO]
		for offset in offsets:
			for sy in n:
				for sx in n:
					if sprite.get_pixel(sx, sy).a < 0.5:
						continue
					var q: Vector2 = top_left + offset + Vector2(sx, sy) * cell
					var r := Rect2i(Vector2i(floori(q.x), floori(q.y)), Vector2i(maxi(ceili(cell), 1), maxi(ceili(cell), 1)))
					img.fill_rect(r.intersection(Rect2i(Vector2i.ZERO, img.get_size())), outline if pass_i == 0 else tint)


func _fill_polygon(img: Image, poly: PackedVector2Array, c: Color) -> void:
	var box := Rect2(poly[0], Vector2.ZERO)
	for v in poly:
		box = box.expand(v)
	for y in range(floori(box.position.y), ceili(box.end.y) + 1):
		for x in range(floori(box.position.x), ceili(box.end.x) + 1):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height() and Geometry2D.is_point_in_polygon(Vector2(x, y), poly):
				img.set_pixel(x, y, c)
