extends "res://tests/harness.gd"

## Polish pass 2: seasonal colours (Seasons), water shimmer, shore foam /
## swash and grass tint on
## the terrain (codes in the gameplay views' chunk images, read by
## shaders/terrain.gdshader) and ambient particles by place, time, season
## and wind (AmbientParticles.weights()). Visuals were checked on a real
## renderer by hand; this checks the rules and the wiring.
## Run via tests/run_tests.sh.

const TerrainCodes := preload("res://scripts/world/terrain_codes.gd")
const SEED := 4242


func _init() -> void:
	# Seasons.
	var c := GameClock.new()
	var fr := []
	for day in [0, 30, 60, 90]:
		c.minutes = day * GameClock.MINUTES_PER_DAY
		fr.append(Seasons.year_fraction(c))
	check(fr == [0.0, 0.25, 0.5, 0.75], "year fraction: Spring 1 = 0, Summer 1 = 0.25, Autumn 1 = 0.5, Winter 1 = 0.75 (%s)" % [fr])
	var autumn := Seasons.tint("deciduous", 0.65)
	var winter := Seasons.tint("deciduous", 0.87)
	var summer := Seasons.tint("deciduous", 0.35)
	check(autumn.a > 0.6 and autumn.r > autumn.g and autumn.g > autumn.b and summer.a == 0.0 and winter.a > 0.6 and winter.r < 0.6,
		"deciduous: green in summer, orange in autumn (%s), bare grey-brown in winter" % autumn)
	check(Seasons.tint("evergreen", 0.65).a == 0.0 and Seasons.tint("evergreen", 0.87).a > 0.2 and Seasons.tint("", 0.65).a == 0.0,
		"evergreens only darken in winter; no class = no change")
	check(Seasons.tint("grass", 0.45).r > Seasons.tint("grass", 0.1).r, "grass goes golden towards late summer")
	var smooth := true
	for cls in Seasons.KEYS:
		var prev := Seasons.tint(cls, 0.0)
		for k in range(1, 1201):
			var t := Seasons.tint(cls, k / 1200.0)
			smooth = smooth and absf(t.a - prev.a) < 0.02 and Vector3(t.r - prev.r, t.g - prev.g, t.b - prev.b).length() < 0.05
			prev = t
	check(smooth, "every class changes gradually through the year and wraps smoothly at Spring 1")

	# Particle rules.
	var base := {"hour": 23.0, "year": 0.35, "wind": 0.5, "temperature": 0.3, "moisture": 0.7, "vegetation": 0.4, "shade": 0.3, "water": false, "biome": "Forest"}
	var w := AmbientParticles_weights(base)
	check(w["firefly"] > 0.5 and w["pollen"] == 0.0, "fireflies on a warm damp summer night (%.2f), no pollen at night" % w["firefly"])
	check(AmbientParticles_weights(_with(base, {"hour": 13.0}))["firefly"] == 0.0 and AmbientParticles_weights(_with(base, {"year": 0.87}))["firefly"] == 0.0,
		"no fireflies by day or in winter")
	var meadow := _with(base, {"hour": 13.0, "shade": 0.0, "biome": "Grassland"})
	check(AmbientParticles_weights(meadow)["pollen"] > 0.5 and AmbientParticles_weights(meadow)["butterfly"] > 0.1, "pollen and butterflies over a sunny summer meadow")
	var grove := _with(base, {"hour": 13.0, "shade": 0.6})
	check(AmbientParticles_weights(_with(grove, {"year": 0.62}))["leaf"] > 0.8 and AmbientParticles_weights(_with(grove, {"year": 0.1, "wind": 0.3}))["leaf"] == 0.0,
		"falling leaves under canopy in autumn, not in spring")
	var desert := {"hour": 13.0, "year": 0.35, "wind": 0.9, "temperature": 0.7, "moisture": 0.05, "vegetation": 0.02, "shade": 0.0, "water": false, "biome": "Desert"}
	check(AmbientParticles_weights(desert)["sand"] > 0.8 and AmbientParticles_weights(_with(desert, {"wind": 0.3}))["sand"] == 0.0, "blowing sand in the desert when windy, not when calm")
	check(AmbientParticles_weights(_with(desert, {"temperature": -0.6, "biome": "Tundra"}))["snow"] > 1.0 and AmbientParticles_weights(desert)["snow"] == 0.0
		and AmbientParticles_weights(_with(base, {"year": 0.87, "temperature": 0.05}))["snow"] > 0.1,
		"snow in cold places all year, anywhere cool in winter, never in a hot summer desert")
	var wet := AmbientParticles_weights(_with(base, {"water": true}))
	var none := true
	for k in wet:
		none = none and wet[k] == 0.0
	check(none, "nothing spawns over water")

	# Scene.
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	var CM = world.get_script()
	# Terrain codes in the gameplay views only.
	var water_ok := false
	var grass_ok := false
	for y in range(-60, 60, 2):
		for x in range(-60, 60, 2):
			var s: Dictionary = world._ctx.world_gen.sample(x, y)
			var col: Color = world._builder.color_for(s, x, y)
			var a8 := roundi(col.a * 255.0)
			if s["water_body"] in ["ocean", "sea", "lake", "river"]:
				water_ok = water_ok or a8 == TerrainCodes.WATER_CODE
			elif world._builder.surface_at(s, x, y).id == "grass":
				grass_ok = grass_ok or a8 == TerrainCodes.GRASS_CODE
	var sprite: Sprite2D = world._presenter.loaded_chunks.values()[0]
	check(water_ok and grass_ok and sprite.material == world.terrain_material and sprite.texture.get_image().get_format() == Image.FORMAT_RGBA8,
		"World view: water and grass tiles carry their codes; chunks use the terrain shader")
	# Ground blending across chunk borders: each shown image has a 1-texel
	# border holding its neighbours' edge tiles; the sprite shows the inside.
	var borders_ok := true
	var pairs := 0
	for chunk in world._presenter.chunk_images:
		var right: Vector2i = chunk + Vector2i(1, 0)
		var below: Vector2i = chunk + Vector2i(0, 1)
		var img: Image = world._presenter.chunk_images[chunk]
		var n: int = img.get_width() - 2
		borders_ok = borders_ok and world._presenter.loaded_chunks[chunk].region_rect == Rect2(1, 1, n, n)
		if world._presenter.chunk_images.has(right):
			var r: Image = world._presenter.chunk_images[right]
			for y in range(1, n + 1):
				borders_ok = borders_ok and img.get_pixel(n + 1, y) == r.get_pixel(1, y) and r.get_pixel(0, y) == img.get_pixel(n, y)
			pairs += 1
		if world._presenter.chunk_images.has(below):
			var b: Image = world._presenter.chunk_images[below]
			for x in range(1, n + 1):
				borders_ok = borders_ok and img.get_pixel(x, n + 1) == b.get_pixel(x, 1) and b.get_pixel(x, 0) == img.get_pixel(x, n)
			pairs += 1
	await process_frame
	var detail_world: bool = world.terrain_material.get_shader_parameter("ground_detail")
	check(borders_ok and pairs > 50 and detail_world, "chunk images carry their neighbours' edge tiles in a 1-texel border (%d neighbour pairs) and show only their inside; ground detail is on in the World view" % pairs)
	# Shoreline (the coast only - ocean and sea, not lakes or rivers): open
	# sea beside land carries FOAM_CODE + its shore shape, ground on a sea
	# shore WASH_CODE (grass WASH_GRASS_CODE) + its shape -
	# 1 + the index in SHORE_SHAPES of the mask of neighbours across the
	# shoreline (edges 1 -x, 2 +x, 4 -y, 8 +y; diagonal corners 16..128 only
	# where neither edge beside them is set); tiles off the shoreline get
	# neither. Shallow open sea off the shoreline carries
	# SHALLOW_CODE + 0..7, higher the shallower.
	var shape_text := FileAccess.get_file_as_string("res://shaders/terrain_codes.gdshaderinc")
	var shader_shapes := shape_text.substr(shape_text.find("SHORE_SHAPES[46] = {") + 20).get_slice("}", 0).split(",")
	var shapes_ok: bool = shader_shapes.size() == TerrainCodes.SHORE_SHAPES.size()
	for i in mini(shader_shapes.size(), TerrainCodes.SHORE_SHAPES.size()):
		shapes_ok = shapes_ok and int(shader_shapes[i].strip_edges()) == TerrainCodes.SHORE_SHAPES[i]
	check(shapes_ok and TerrainCodes.SHORE_SHAPES.size() == 46, "the shader's shore shape table matches ChunkManager's (46 shapes)")
	var steps: Array = TerrainCodes.SHORE_STEPS
	var open_water := Vector2i(1 << 30, 0)
	var shore_water := Vector2i(1 << 30, 0)
	var foam_seen := 0
	var wash_seen := 0
	var wash_grass_seen := 0
	var corner_seen := 0
	var lake_seen := 0
	var shallow_seen := 0
	var shallow_ok := true
	var masks_ok := true
	# Around the ocean coasts nearest the origin (walk in from open ocean),
	# on to the next until one has grassy shore too (most are all beach).
	var coasts: Array[Vector2i] = []
	var oceans_seen: Array = []
	for attempt in 3:
		var ocean_at = BiomeFinder.find(world._ctx.world_gen, "Ocean", Vector2i.ZERO, oceans_seen)
		if ocean_at == null:
			break
		var ocean_tile: Vector2i = ocean_at if ocean_at is Vector2i else ocean_at["tile"]
		oceans_seen.append(ocean_tile)
		var inward := Vector2(-ocean_tile).normalized()
		var walk := Vector2(ocean_tile)
		while world._ctx.world_gen.elevation(walk.x, walk.y) < world._ctx.world_gen.sea_level:
			walk += inward
		coasts.append(Vector2i(walk.round()))
	for coast in coasts:
		if wash_grass_seen > 0:
			break
		for y in range(coast.y - 150, coast.y + 150):
			for x in range(coast.x - 150, coast.x + 150):
				var is_wet: bool = world._ctx.world_gen.elevation(x, y) < world._ctx.world_gen.sea_level
				var mask := 0
				for i in steps.size():
					if i >= 4 and mask & TerrainCodes.CORNER_EDGES[i - 4]:
						continue
					if (world._ctx.world_gen.elevation(x + steps[i].x, y + steps[i].y) < world._ctx.world_gen.sea_level) != is_wet:
						mask |= 1 << i
				if mask == 0:
					if is_wet and open_water.x == 1 << 30:
						open_water = Vector2i(x, y)
					var depth: float = world._ctx.world_gen.sea_level - world._ctx.world_gen.elevation(x, y)
					if is_wet and depth > 0.0 and depth < TerrainCodes.SHALLOW_DEPTH and shallow_seen < 40:
						var sw: Dictionary = world._ctx.world_gen.sample(x, y)
						if TerrainSurface.water_liquid(sw) >= 1.0 and sw["water_body"] in TerrainCodes.SEA_BODIES:
							var level: int = roundi(world._builder.terrain_color(sw, x, y).a * 255.0) - TerrainCodes.SHALLOW_CODE
							shallow_ok = shallow_ok and level == roundi(7.0 * (1.0 - depth / TerrainCodes.SHALLOW_DEPTH))
							shallow_seen += 1
					continue
				if foam_seen >= 80 and wash_seen >= 80 and wash_grass_seen > 0:
					continue
				var shape: int = TerrainCodes.SHORE_SHAPES.find(mask) + 1
				corner_seen += 1 if mask >= 16 else 0
				var ss: Dictionary = world._ctx.world_gen.sample(x, y)
				var code8 := roundi(world._builder.terrain_color(ss, x, y).a * 255.0)
				if is_wet and TerrainSurface.water_liquid(ss) >= 1.0 and ss["water_body"] in TerrainCodes.SEA_BODIES:
					masks_ok = masks_ok and shape > 0 and code8 == TerrainCodes.FOAM_CODE + shape
					foam_seen += 1
					if shore_water.x == 1 << 30 and mask < 16:
						shore_water = Vector2i(x, y)
				elif is_wet and ss["water_body"] == "lake":
					lake_seen += 1
					masks_ok = masks_ok and code8 <= TerrainCodes.WATER_CODE
				elif not is_wet and ss["water_body"] == "none" and ss["shore_salinity"] > 0.0 and TerrainSurface.shore_liquid(ss) >= 1.0:
					# Every ground type washes; grass keeps its seasonal tint.
					var grass: bool = world._builder.surface_at(ss, x, y).id in TerrainCodes.GRASS_GROUND
					masks_ok = masks_ok and shape > 0 and code8 == (TerrainCodes.WASH_GRASS_CODE if grass else TerrainCodes.WASH_CODE) + shape
					wash_seen += 1
					wash_grass_seen += 1 if grass else 0
	check(masks_ok and foam_seen >= 30 and wash_seen >= 30 and wash_grass_seen > 0 and corner_seen > 0 and open_water.x != 1 << 30,
		"shoreline codes (all shaped toward the shore: %s): %d foam sea tiles and %d washed ground tiles (%d grass), %d with diagonal corners; lake shores (%d) plain" % [masks_ok, foam_seen, wash_seen, wash_grass_seen, corner_seen, lake_seen])
	check(shallow_ok and shallow_seen >= 10, "shallow water off the shoreline carries its shallowness for whitecaps (%d tiles)" % shallow_seen)
	# Frozen water: no code (no waves, no glints); partly frozen: a code in
	# between; rivers and open water: fully liquid. Only fully open sea
	# foams at the shore - not a half-frozen sea, a lake or a river.
	var lake := {"water_body": "lake", "elevation": -0.2, "temperature": 0.3}
	var codes := []
	for t in [0.3, -0.35, -0.8]:
		lake["temperature"] = t
		codes.append(roundi(world._builder.terrain_color(lake, open_water.x, open_water.y).a * 255.0))
	var shore_codes := []
	for body_temp in [["sea", 0.3], ["sea", -0.35], ["lake", 0.3], ["river", 0.3]]:
		var at_shore := {"water_body": body_temp[0], "elevation": world._ctx.world_gen.sea_level - 0.005, "temperature": body_temp[1]}
		shore_codes.append(roundi(world._builder.terrain_color(at_shore, shore_water.x, shore_water.y).a * 255.0))
	check(shore_codes[0] > TerrainCodes.FOAM_CODE and shore_codes[0] <= TerrainCodes.FOAM_CODE + 46 and shore_codes[1] < TerrainCodes.WATER_CODE
		and shore_codes[2] == TerrainCodes.WATER_CODE and shore_codes[3] == TerrainCodes.WATER_CODE,
		"only open sea foams at a shore tile: half-frozen sea %d, lake %d, river %d don't" % shore_codes.slice(1))
	var river := {"water_body": "river", "elevation": 0.1, "temperature": -0.9}
	check(codes[0] == TerrainCodes.WATER_CODE and codes[1] > TerrainCodes.WATER_CODE_ICE and codes[1] < TerrainCodes.WATER_CODE and codes[2] == 255
		and roundi(world._builder.terrain_color(river, open_water.x, open_water.y).a * 255.0) == TerrainCodes.WATER_CODE,
		"water codes follow how liquid it is: open %d, half-frozen %d, ice %d (no code); rivers stay liquid" % codes)
	world.set_view_mode(CM.ViewMode.TEMPERATURE)
	world.flush_chunk_work()
	var s0: Dictionary = world._ctx.world_gen.sample(0, 0)
	check(world._builder.color_for(s0, 0, 0).a == 1.0 and world._presenter.loaded_chunks.values()[0].texture.get_image().get_format() == Image.FORMAT_RGB8,
		"data views bake plain opaque images (no codes)")
	await process_frame
	check(not world.terrain_material.get_shader_parameter("ground_detail"), "no ground noise or blending in the data views")
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()

	# Sprites recolour with the season, once per in-game day.
	var oak: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "oak")[0]
	var pine: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "pine")[0]
	var granite: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "granite")[0]
	world.clock.minutes = 40 * GameClock.MINUTES_PER_DAY + 12 * 60  # summer
	await process_frame
	var oak_summer: Color = world._presenter.sprite_fill(oak)
	var pine_summer: Color = world._presenter.sprite_fill(pine)
	var rock_summer: Color = world._presenter.sprite_fill(granite)
	world.clock.minutes = 76 * GameClock.MINUTES_PER_DAY + 12 * 60
	await process_frame
	await process_frame
	var oak_autumn: Color = world._presenter.sprite_fill(oak)
	# The clock runs on between frames, so compare colours approximately.
	var drawn_autumn := false
	for m in world._presenter.loaded_placements.values():
		for f in m._fills:
			drawn_autumn = drawn_autumn or (absf(f.r - oak_autumn.r) < 0.01 and absf(f.g - oak_autumn.g) < 0.01 and absf(f.b - oak_autumn.b) < 0.01)
	check(oak_autumn != oak_summer and oak_autumn.r > oak_autumn.g and world._presenter.sprite_fill(pine).is_equal_approx(pine_summer) and world._presenter.sprite_fill(granite) == rock_summer and drawn_autumn,
		"oaks turn orange in autumn and the World view redraws them; pines and rocks don't change")
	# Review P3: a new day recolours the marker nodes in place, to exactly
	# the fills a rebuild would give.
	var shown_markers: Dictionary = world._presenter.loaded_placements.duplicate()
	world.clock.minutes = 83 * GameClock.MINUTES_PER_DAY + 12 * 60
	world._presenter.update_seasons()
	var kept := true
	var same_fills := true
	for chunk in shown_markers:
		kept = kept and world._presenter.loaded_placements.get(chunk) == shown_markers[chunk]
		var rebuilt: Node2D = world._presenter.marker_node(chunk * world.CHUNK_SIZE, world._presenter.chunk_placements[chunk])
		same_fills = same_fills and rebuilt._fills == shown_markers[chunk]._fills
		if rebuilt.shadow_layer() != null:
			rebuilt.shadow_layer().free()
		rebuilt.free()
	check(kept and same_fills and not shown_markers.is_empty(), "a new day recolours markers in place, as a rebuild would")

	# Particles.
	var particles: Node2D = world.get_node("AmbientParticles")
	world.clock.minutes = 45 * GameClock.MINUTES_PER_DAY + 13 * 60
	var cam: Camera2D = world.get_node("CameraRig/Camera2D")
	cam.zoom = Vector2(2, 2)
	var t0 := Time.get_ticks_msec()
	while particles.count() == 0 and Time.get_ticks_msec() - t0 < 8000:
		await process_frame
	var spawned: int = particles.count()
	world.clock.play_pause()
	await process_frame
	var before: PackedVector2Array = particles._pos.duplicate()
	for f in 5:
		await process_frame
	var frozen: bool = particles._pos == before
	world.clock.play_pause()
	world.set_view_mode(CM.ViewMode.TEMPERATURE)
	await process_frame
	await process_frame
	check(spawned > 0 and frozen and particles.count() == 0, "particles spawn in the World view (%d: %s), freeze when paused, and clear in data views" % [spawned, particles.kinds_alive()])

	finish()


func AmbientParticles_weights(env: Dictionary) -> Dictionary:
	return load("res://scripts/render/ambient_particles.gd").weights(env)


func _with(env: Dictionary, changes: Dictionary) -> Dictionary:
	var e := env.duplicate()
	for k in changes:
		e[k] = changes[k]
	return e
