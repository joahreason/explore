extends SceneTree

const ResourceMarkerChunk := preload("res://scripts/resource_marker_chunk.gd")

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
	# Phase 17 streaming: chunks come from queued jobs (on a worker thread
	# here), so a test settles them with flush_chunk_work() after each change.
	check(world._worker != null, "chunk jobs run on a worker thread")
	world.flush_chunk_work()
	check(world._loaded_chunks.size() == 81 and _all_current(world), "startup: %d chunks loaded, all built for the current view" % world._loaded_chunks.size())
	# Phase 13.5: the default view is the World (terrain + every placed resource).
	check(world._view_mode == CM.ViewMode.RESOURCES and world._loaded_placements.size() == 81, "startup: default World view shows placed resources (%d marker nodes)" % world._loaded_placements.size())
	world.set_view_mode(CM.ViewMode.MATERIAL)
	world.flush_chunk_work()
	check(world._loaded_placements.is_empty(), "Terrain Only view: no placement markers")
	var t0 := Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.RESOURCE_PLACEMENT_OAK)
	world.flush_chunk_work()
	print("INFO switch to Oak Placement: %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	await process_frame
	check(world._loaded_placements.size() == world._loaded_chunks.size(), "placement view: one marker node per loaded chunk (%d)" % world._loaded_placements.size())
	var total := 0
	for m in world._loaded_placements.values():
		total += m._positions.size()
	check(total > 0, "placement view: %d oak markers in loaded area" % total)

	# Pan far away: new chunks get markers, unloaded chunks' markers are freed.
	var cam: Node2D = world.get_node("CameraRig")
	world.teleport_player(Vector2(5000, 3000))
	# After a jump to new ground chunks stream in over frames instead of all
	# inside one, and those shown so far are the nearest ones.
	await process_frame  # its _process unloads the old area and queues the new
	var frames := 1
	while world._loaded_chunks.size() < 3 and frames < 500:
		await process_frame
		frames += 1
	var center: Vector2i = world._chunk_of(cam.global_position)
	var nearest_first := true
	for cy in range(center.y - 4, center.y + 5):
		for cx in range(center.x - 4, center.x + 5):
			var missing := Vector2i(cx, cy)
			if world._loaded_chunks.has(missing):
				continue
			for c in world._loaded_chunks:
				nearest_first = nearest_first and (c - center).length_squared() <= (missing - center).length_squared()
	check(world.has_pending_chunks() and world._loaded_chunks.size() < 81 and nearest_first, "after a jump: %d of 81 chunks shown after %d frames, nearest first" % [world._loaded_chunks.size(), frames])
	world.flush_chunk_work()
	var match_keys := true
	for c in world._loaded_chunks.keys():
		match_keys = match_keys and world._loaded_placements.has(c)
	check(match_keys and world._loaded_placements.size() == world._loaded_chunks.size(), "after pan: markers track streamed chunks exactly")
	check(world.resources_root.get_child_count() >= world._loaded_placements.size(), "markers parented under Resources")

	# Zoom out past MAX_PLACEMENT_LOD_STEP: markers removed; back in: rebuilt.
	var camera: Camera2D = world.get_viewport().get_camera_2d()
	camera.zoom = Vector2(0.3, 0.3)
	world.flush_chunk_work()
	check(world._loaded_placements.is_empty(), "zoomed out (lod %d): markers hidden" % world._current_lod_step())
	camera.zoom = Vector2(4, 4)
	world.flush_chunk_work()
	check(world._loaded_placements.size() == world._loaded_chunks.size() and _all_current(world), "zoomed back in: markers rebuilt")

	world.set_view_mode(CM.ViewMode.MATERIAL)
	world.flush_chunk_work()
	check(world._loaded_placements.is_empty(), "back to Material: markers removed")

	# Guild view: one marker node per chunk, markers in both species' colors.
	world.teleport_player(Vector2.ZERO)
	world.flush_chunk_work()
	t0 = Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.TREE_PLACEMENT)
	world.flush_chunk_work()
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
	for mode in [CM.ViewMode.ROCK_PLACEMENT, CM.ViewMode.BERRY_PLACEMENT, CM.ViewMode.WETLAND_PLACEMENT, CM.ViewMode.SHORE_PLACEMENT]:
		world.set_view_mode(mode)
		world.flush_chunk_work()
		var guild: ResourceGuild = world._placement_layers()[0][0]
		var ok: bool = world._loaded_placements.size() == world._loaded_chunks.size()
		var n := 0
		for m in world._loaded_placements.values():
			n += m._positions.size()
			for c in m._fills:
				ok = ok and guild.members.any(func(member): return member.debug_color == c)
		guild_counts[guild.id] = n
		# The loaded area has no sea coast; shore features are covered by
		# test_shores.gd.
		check(ok and (n > 0 or guild == world.SHORE_FEATURES), "%s view: %d markers, one node per chunk, member colors only" % [guild.id, n])

	# Resources view: Material base image; the same trees as Tree Placement,
	# rocks, ore outcrops, plants and shore features, all as tinted sheet
	# sprites.
	var tree_count := 0
	world.set_view_mode(CM.ViewMode.TREE_PLACEMENT)
	world.flush_chunk_work()
	for m in world._loaded_placements.values():
		tree_count += m._positions.size()
	# Cold: drop the per-chunk placement/density/environment caches the views
	# above filled.
	world.clear_generation_caches()
	t0 = Time.get_ticks_msec()
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()
	print("INFO switch to Resources (9 guilds, cold cache): %d ms for %d chunks" % [Time.get_ticks_msec() - t0, world._loaded_chunks.size()])
	var shape_counts := {}
	for m in world._loaded_placements.values():
		for s in m._shapes:
			shape_counts[s] = shape_counts.get(s, 0) + 1
	var Shape = world.ResourceMarkerChunkScript.Shape
	var outcrops_placed := 0
	var succession_placed := 0  # deadwood + pioneer plants (Phase 11) + ground cover (Phase 12)
	for c in world._loaded_chunks:
		outcrops_placed += world._place_stack_chunk(c * world.CHUNK_SIZE, 1)[world.ORE_OUTCROPS].size()
		var stack: Dictionary = world._place_stack_chunk(c * world.CHUNK_SIZE)
		succession_placed += stack[world.DEADWOOD].size() + stack[world.PIONEER_PLANTS].size() + stack[world.GROUND_COVER].size()
	var sprites_ok := true
	var sprite_colors := {}
	for g in [world.CANOPY_TREES, world.SURFACE_ROCKS, world.ORE_OUTCROPS, world.SHRUBS, world.WETLAND_PLANTS, world.SHORE_FEATURES, world.DEADWOOD, world.PIONEER_PLANTS, world.GROUND_COVER]:
		for member in g.members:
			sprite_colors[world.sprite_fill(member)] = true  # season colour + sway alpha
	# Landmark structure parts are sprites too, tinted by their kind.
	var structure_parts := 0
	for c in world._chunk_placements:
		for entry in world._chunk_placements[c]:
			if entry[0][0] == null:
				structure_parts += entry[1].size()
				for inst in entry[1]:
					sprite_colors[inst["fill"]] = true
	for m in world._loaded_placements.values():
		for i in m._shapes.size():
			if m._shapes[i] == Shape.SPRITE:
				sprites_ok = sprites_ok and m._textures[i] != null and sprite_colors.has(m._fills[i])
	# Clay has no sprite: its outcrops stay hexagons, everything else is a sprite.
	# Every placed resource has a sprite: no fallback shapes left.
	var all_placed: int = tree_count + guild_counts["surface_rocks"] + outcrops_placed + guild_counts["shrubs"] + guild_counts["wetland_plants"] + guild_counts["shore_features"] + succession_placed + structure_parts
	check(sprites_ok and tree_count > 0 and guild_counts["shrubs"] > 0 and guild_counts["wetland_plants"] > 0
		and shape_counts.get(Shape.SPRITE, 0) == all_placed and shape_counts.size() == 1,
		"resources view: all %d instances are sprites (%d trees, %d rocks, %d outcrops, %d berry bushes, %d wetland plants, %d shore features, %d deadwood/pioneers/ground cover)" % [
			shape_counts.get(Shape.SPRITE, 0), tree_count, guild_counts["surface_rocks"], outcrops_placed, guild_counts["shrubs"], guild_counts["wetland_plants"], guild_counts["shore_features"], succession_placed])
	# Click-to-inspect names the placed resource under the click, in any view.
	var some_tree: Dictionary = {}
	for base in [Vector2i(0, 0), Vector2i(-16, 0), Vector2i(0, -16), Vector2i(-16, -16)]:
		var trees: Array = world._place_stack_chunk(base)[world.CANOPY_TREES]
		if not trees.is_empty():
			some_tree = trees[0]
			break
	var tree_pos: Vector2 = some_tree["position"]
	world.set_view_mode(CM.ViewMode.MATERIAL)
	world.flush_chunk_work()
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
	world.flush_chunk_work()

	var probe: Dictionary = world._world_gen.sample(3, 5)
	check(world._color_for(probe, 3, 5) == world._terrain_color(probe, 3, 5), "resources view: base image is the terrain")

	# Deposits view (Phase 9): a heatmap plus ore outcrop markers (step 2);
	# clicking a tile with ore lists it in the inspector.
	world.set_view_mode(CM.ViewMode.DEPOSITS)
	world.flush_chunk_work()
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
		and world._color_for(ore_sample, ore_tile.x, ore_tile.y) != world._terrain_color(ore_sample, ore_tile.x, ore_tile.y)
		and world._inspector_panel.label.text.contains("[b]Deposits:[/b]"),
		"deposits view: only outcrop hexagons (%d); ore tile %s tinted and listed under Deposits in the inspector" % [outcrop_count, ore_tile])

	# Farming Potential (Phase 10): a heatmap, no markers; the inspector
	# shows the tile's value.
	world.set_view_mode(CM.ViewMode.FARMING_POTENTIAL)
	world.flush_chunk_work()
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
		and world._color_for(farm_sample, farm_tile.x, farm_tile.y) != world._terrain_color(farm_sample, farm_tile.x, farm_tile.y)
		and world._inspector_panel.label.text.contains("[b]Farming potential:[/b]"),
		"farming potential view: no markers; farmland tile %s tinted, value in the inspector" % farm_tile)

	# Shade (Phase 13): canopy shade heatmap + the understory guilds that
	# read it; the inspector shows the tile's shade.
	world.set_view_mode(CM.ViewMode.SHADE)
	world.flush_chunk_work()
	var shade_markers := 0
	for m in world._loaded_placements.values():
		shade_markers += m._positions.size()
	var shade_tile := Vector2i(1 << 30, 0)
	var shade_value := 0.0
	for y in range(-32, 32, 2):
		for x in range(-32, 32, 2):
			var s: Dictionary = world._world_gen.sample(x, y)
			shade_value = ResourceManager.get_shade(EnvironmentalState.from_sample(s), world.world_seed, x, y, BiomeClassifier.classify_full(s))
			if shade_value > 0.3:
				shade_tile = Vector2i(x, y)
				break
		if shade_tile.x != 1 << 30:
			break
	world._on_tile_clicked((Vector2(shade_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var shade_sample: Dictionary = world._world_gen.sample(shade_tile.x, shade_tile.y)
	var want: Color = world._terrain_color(shade_sample, shade_tile.x, shade_tile.y).lerp(HeatmapColorizer.shade(shade_value), world.HEATMAP_OVERLAY_STRENGTH)
	check(shade_markers > 100 and shade_tile.x != 1 << 30
		and world._color_for(shade_sample, shade_tile.x, shade_tile.y) == want
		and world._inspector_panel.label.text.contains("[b]Shade:[/b] %.2f" % shade_value),
		"shade view: %d understory markers; shaded tile %s colored by its shade %.2f, value in the inspector" % [shade_markers, shade_tile, shade_value])

	# Quality (Phase 14): markers only for instances with a quality, each
	# filled by it; clicking a tree names its tier in the inspector.
	world.set_view_mode(CM.ViewMode.QUALITY)
	world.flush_chunk_work()
	var quality_markers := 0
	var quality_fills := {}
	for m in world._loaded_placements.values():
		quality_markers += m._positions.size()
		for fill in m._fills:
			quality_fills[fill] = true
	var q_tree: Dictionary = {}
	for inst in world._place_stack(Rect2i(-32, -32, 64, 64), 3)[world.CANOPY_TREES]:
		if inst["id"] != "young_tree":
			q_tree = inst
			break
	var quality_tree_pos: Vector2 = q_tree.get("position", Vector2.ZERO)
	world._on_tile_clicked((quality_tree_pos.floor() + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var tree_quality: float = world._instance_quality(q_tree) if not q_tree.is_empty() else -1.0
	var q_tier := ResourceManager.get_quality_tier(world._definitions_by_id().get(q_tree.get("id", ""), world.OAK_RESOURCE), tree_quality)
	check(quality_markers > 100 and quality_fills.size() > 20 and tree_quality >= 0.0
		and world._inspector_panel.label.text.contains("[b]Quality:[/b] %s (%.2f)" % [q_tier, tree_quality])
		and world._inspector_panel.label.text.contains("[b]State:[/b] available"),
		"quality view: %d markers in %d fills; a clicked %s shows its tier '%s' (%.2f) and its entity line" % [quality_markers, quality_fills.size(), q_tree.get("id", "?"), q_tier, tree_quality])
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()

	var out := OS.get_environment("OUT_PNG")
	if out != "":
		_render_png(world, CM, out)

	# Desktop seed UI: Enter in the seed field and Randomize regenerate the
	# world in place (web reloads the page instead). Material keeps the
	# rebuilds cheap; the placements are compared directly.
	world.set_view_mode(CM.ViewMode.MATERIAL)
	world.flush_chunk_work()
	var seed_input: LineEdit = world.get_node("UI/SeedInput")
	var randomize: Button = world.get_node("UI/RandomizeButton")
	check(seed_input.visible and randomize.visible and seed_input.text == "4242", "desktop: seed field (showing '%s') and Randomize shown" % seed_input.text)
	var before := str(world._place_stack_chunk(Vector2i.ZERO))
	seed_input.text_submitted.emit("777")
	world.flush_chunk_work()
	check(world.world_seed == 777 and world._loaded_chunks.size() == 81 and _all_current(world)
		and not world._inspector_panel.visible and str(world._place_stack_chunk(Vector2i.ZERO)) != before,
		"seed field Enter: regenerated as seed 777 - all 81 chunks rebuilt, different objects, stale inspector closed")
	seed_input.text_submitted.emit("hello")
	world.flush_chunk_work()
	check(world.world_seed == "hello".hash() and seed_input.text == "hello", "text seed 'hello' hashed to %d" % world.world_seed)
	randomize.pressed.emit()
	world.flush_chunk_work()
	check(seed_input.text == str(world.world_seed) and world.world_seed != "hello".hash(), "Randomize: new seed %s, shown in the field" % seed_input.text)
	seed_input.text_submitted.emit("4242")
	world.flush_chunk_work()
	check(str(world._place_stack_chunk(Vector2i.ZERO)) == before, "back to seed 4242: identical objects (other seeds' caches dropped)")

	# Biome travel menu: picking a biome moves the camera onto it; picking it
	# again from there moves on to another patch of it.
	var travel: OptionButton = world.get_node("UI/BiomeTravelDropdown")
	var desert := -1
	for i in travel.item_count:
		if travel.get_item_text(i) == "Desert":
			desert = i
	world.teleport_player(Vector2.ZERO)
	var spots: Array[Vector2i] = []
	var biomes: Array[String] = []
	for trip in 2:
		var t_find := Time.get_ticks_msec()
		travel.item_selected.emit(desert)
		var waited := 0
		while world.is_finding_biome() and waited < 5000:
			await process_frame
			waited += 1
		world.flush_chunk_work()
		var tile := Vector2i((cam.global_position / world.TILE_SIZE).floor())
		spots.append(tile)
		biomes.append(BiomeClassifier.classify(world._world_gen.sample(tile.x, tile.y)))
		print("INFO desert trip %d: %s in %d ms" % [trip + 1, tile, Time.get_ticks_msec() - t_find])
	check(biomes == ["Desert", "Desert"] and Vector2(spots[1] - spots[0]).length() >= BiomeFinder.AVOID_RADIUS
		and travel.selected == 0 and not travel.disabled and world._loaded_chunks.size() == 81,
		"biome travel: Desert at %s, then another Desert patch at %s; menu reset" % [spots[0], spots[1]])

	# Without a worker (the web export has no threads) the jobs run on the
	# main thread within a per-frame budget: a few chunks per frame, not the
	# whole load square in one.
	world.queue_free()
	await process_frame
	var inline_world: Node2D = load("res://world.tscn").instantiate()
	inline_world.world_seed = 4242
	inline_world.threaded_generation = false
	inline_world.set_view_mode(CM.ViewMode.MATERIAL)  # so the Resources switch below builds in steps
	root.add_child(inline_world)
	var inline_frames := 0
	while inline_world._loaded_chunks.is_empty() and inline_frames < 60:
		await process_frame
		inline_frames += 1
	var early: int = inline_world._loaded_chunks.size()
	inline_world.flush_chunk_work()
	check(inline_world._worker == null and early > 0 and early < 81 and inline_world._loaded_chunks.size() == 81 and _all_current(inline_world),
		"no worker: first chunks after %d frames (%d shown, not all at once), all 81 once flushed" % [inline_frames, early])

	# The main-thread fallback builds a chunk in small steps over several
	# frames (Phase 17 step 6); the markers must match placing it in one go.
	# Frames only prove the stepping (the first chunks show, not all of
	# them); the rest is flushed, so a slow machine can't fail a correct build.
	inline_world.set_view_mode(CM.ViewMode.RESOURCES)
	var step_frames := 0
	while _current_count(inline_world) == 0 and step_frames < 2000:
		await process_frame
		step_frames += 1
	var stepped: int = _current_count(inline_world)
	inline_world.flush_chunk_work()
	check(stepped > 0 and stepped < 81 and _all_current(inline_world),
		"no worker: Resources view steps in (%d of 81 chunks after %d frames), all current once flushed" % [stepped, step_frames])
	var same: bool = inline_world._loaded_placements.size() == 81
	var markers_total := 0
	for c in inline_world._loaded_placements:
		var one_go := PackedVector2Array()
		var node = inline_world._loaded_placements[c]
		for entry in inline_world._placement_chunk(c):
			for inst in entry[1]:
				var pos: Vector2 = inst["position"]
				# Sprites stand on their pivot (resource_marker_chunk.gd), structure
				# parts on their tile's bottom middle.
				var drawn: bool = node._textures[one_go.size()] != null
				if drawn:
					pos = Vector2(pos.floor()) + Vector2(0.5, 1.0) if entry[0][0] == null else ResourceMarkerChunk.pivot(inst)
				var local: Vector2 = (pos - Vector2(c * inline_world.CHUNK_SIZE)) * inline_world.TILE_SIZE
				one_go.append(local.round() if drawn else local)
		var shown: PackedVector2Array = node._positions
		markers_total += shown.size()
		same = same and shown == one_go
	check(same and markers_total > 0, "no worker: Resources built in steps - all %d markers match one-go placement" % markers_total)

	print("RESULT %s" % ("PASS" if _fails == 0 else "%d FAILED" % _fails))
	quit(1 if _fails > 0 else 0)


## How many loaded chunks show content built for the current view and LOD.
func _current_count(world: Node2D) -> int:
	var n := 0
	for c in world._loaded_chunks:
		if world._shown_epoch.get(c, -1) == world._epoch:
			n += 1
	return n


## Every loaded chunk shows content built for the current view and LOD.
func _all_current(world: Node2D) -> bool:
	for c in world._loaded_chunks:
		if world._shown_epoch.get(c, -1) != world._epoch:
			return false
	return true


## Real _color_for() in the Resources view (Material) + every placement
## layer (rocks, berry bushes, trees) placed chunk by chunk through the real
## _place_stack_chunk(), in the view's shapes and colors, chunk grid drawn.
func _render_png(world: Node2D, CM, out: String) -> void:
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()
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
