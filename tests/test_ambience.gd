extends SceneTree

## Polish pass 2: seasonal colours (Seasons), water shimmer / grass tint on
## the terrain (codes in the gameplay views' chunk images, read by
## shaders/terrain.gdshader) and ambient particles by place, time, season
## and wind (AmbientParticles.weights()). Visuals were checked on a real
## renderer by hand; this checks the rules and the wiring.
## Run via tests/run_tests.sh.

const SEED := 4242

var _fails := 0
var _passes := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("PASS ", msg)
	else:
		_fails += 1
		print("FAIL ", msg)


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
			var s: Dictionary = world._world_gen.sample(x, y)
			var col: Color = world._color_for(s, x, y)
			var a8 := roundi(col.a * 255.0)
			if s["water_body"] in ["ocean", "sea", "lake", "river"]:
				water_ok = water_ok or a8 == world.WATER_CODE
			elif world._surface_at(s, x, y).id == "grass":
				grass_ok = grass_ok or a8 == world.GRASS_CODE
	var sprite: Sprite2D = world._loaded_chunks.values()[0]
	check(water_ok and grass_ok and sprite.material == world.terrain_material and sprite.texture.get_image().get_format() == Image.FORMAT_RGBA8,
		"World view: water and grass tiles carry their codes; chunks use the terrain shader")
	# Frozen water: no code (no waves, no glints); partly frozen: a code in
	# between; rivers and open water: fully liquid.
	var lake := {"water_body": "lake", "elevation": -0.2, "temperature": 0.3}
	var codes := []
	for t in [0.3, -0.35, -0.8]:
		lake["temperature"] = t
		codes.append(roundi(world._terrain_color(lake, 0, 0).a * 255.0))
	var river := {"water_body": "river", "elevation": 0.1, "temperature": -0.9}
	check(codes[0] == world.WATER_CODE and codes[1] > world.WATER_CODE_ICE and codes[1] < world.WATER_CODE and codes[2] == 255
		and roundi(world._terrain_color(river, 0, 0).a * 255.0) == world.WATER_CODE,
		"water codes follow how liquid it is: open %d, half-frozen %d, ice %d (no code); rivers stay liquid" % codes)
	world.set_view_mode(CM.ViewMode.TEMPERATURE)
	world.flush_chunk_work()
	var s0: Dictionary = world._world_gen.sample(0, 0)
	check(world._color_for(s0, 0, 0).a == 1.0 and world._loaded_chunks.values()[0].texture.get_image().get_format() == Image.FORMAT_RGB8,
		"data views bake plain opaque images (no codes)")
	world.set_view_mode(CM.ViewMode.RESOURCES)
	world.flush_chunk_work()

	# Sprites recolour with the season, once per in-game day.
	var oak: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "oak")[0]
	var pine: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "pine")[0]
	var granite: ResourceDefinition = world.debug_resources().filter(func(d): return d.id == "granite")[0]
	world.clock.minutes = 40 * GameClock.MINUTES_PER_DAY + 12 * 60  # summer
	await process_frame
	var oak_summer: Color = world.sprite_fill(oak)
	var pine_summer: Color = world.sprite_fill(pine)
	var rock_summer: Color = world.sprite_fill(granite)
	world.clock.minutes = 76 * GameClock.MINUTES_PER_DAY + 12 * 60
	await process_frame
	await process_frame
	var oak_autumn: Color = world.sprite_fill(oak)
	# The clock runs on between frames, so compare colours approximately.
	var drawn_autumn := false
	for m in world._loaded_placements.values():
		for f in m._fills:
			drawn_autumn = drawn_autumn or (absf(f.r - oak_autumn.r) < 0.01 and absf(f.g - oak_autumn.g) < 0.01 and absf(f.b - oak_autumn.b) < 0.01)
	check(oak_autumn != oak_summer and oak_autumn.r > oak_autumn.g and world.sprite_fill(pine).is_equal_approx(pine_summer) and world.sprite_fill(granite) == rock_summer and drawn_autumn,
		"oaks turn orange in autumn and the World view redraws them; pines and rocks don't change")

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

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func AmbientParticles_weights(env: Dictionary) -> Dictionary:
	return load("res://scripts/ambient_particles.gd").weights(env)


func _with(env: Dictionary, changes: Dictionary) -> Dictionary:
	var e := env.duplicate()
	for k in changes:
		e[k] = changes[k]
	return e
