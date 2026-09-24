extends SceneTree

## Phase 13.5 terrain surface layer (TerrainSurface / SurfaceMaterial):
## data loads cleanly, choice is deterministic, per-biome mixtures are
## plausible (and come from the fields, not the biome label), ground forms
## coherent patches, each material appears only where its cause is present,
## and the chunk render path matches a direct evaluation. Run via
## tests/run_tests.sh.

const SEED := 4242
const TS := preload("res://scripts/terrain_surface.gd")

var _fails := 0
var _passes := 0
var _wg: WorldGen
var _shade_cache := {}


func check(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if cond:
		_passes += 1
	else:
		_fails += 1


## Exact shade at a lattice corner (what chunk_manager._corner_shade() does
## through its tile cache).
func _corner(cx: int, cy: int) -> float:
	var key := Vector2i(cx, cy)
	if not _shade_cache.has(key):
		var s := _wg.sample(cx, cy)
		_shade_cache[key] = ResourceManager.get_shade(EnvironmentalState.from_sample(s), SEED, cx, cy, BiomeClassifier.classify_full(s))
	return _shade_cache[key]


func _state(s: Dictionary, x: int, y: int) -> EnvironmentalState:
	var st: EnvironmentalState = EnvironmentalState.from_sample(s)
	st.shade = TS.lattice_shade(x, y, _corner)
	st.shade_known = true
	return st


func _init() -> void:
	_wg = WorldGen.new()
	_wg.configure(SEED)

	# 1. Data.
	var ids := {}
	var warnings := PackedStringArray()
	for m in TS.MATERIALS:
		ids[m.id] = true
		warnings.append_array(m.get_curve_domain_warnings())
	check(ids.size() == TS.MATERIALS.size() and TS.MATERIALS.all(func(m): return m.display_name != ""), "%d materials, unique ids, all named" % ids.size())
	check(warnings.is_empty(), "no curve-domain warnings %s" % warnings)

	# 2. Sample blocks across the world: mixture per biome, coherence, causes.
	var by_biome := {}
	var agree := 0
	var pairs := 0
	var cause_fail := {}
	var blocks := 0
	for by in range(-5, 5):
		for bx in range(-5, 5):
			blocks += 1
			var ox := bx * 1013 + 11
			var oy := by * 947 + 5
			for y in range(oy, oy + 20):
				var prev := ""
				for x in range(ox, ox + 20):
					var s := _wg.sample(x, y)
					if TS.water_color(s) != null:
						prev = ""
						continue
					var st := _state(s, x, y)
					var m: SurfaceMaterial = TS.material_at(st, SEED, x, y)
					var biome := BiomeClassifier.classify(s)
					if not by_biome.has(biome):
						by_biome[biome] = {}
					by_biome[biome][m.id] = by_biome[biome].get(m.id, 0) + 1
					if prev != "":
						pairs += 1
						agree += int(prev == m.id)
					prev = m.id
					var why := _cause_violation(m.id, st)
					if why != "":
						cause_fail[m.id + ": " + why] = cause_fail.get(m.id + ": " + why, 0) + 1

	var share := func(biome: String, id: String) -> float:
		var d: Dictionary = by_biome.get(biome, {})
		var total := 0
		for k in d:
			total += d[k]
		return float(d.get(id, 0)) / maxf(total, 1)
	var materials_over := func(biome: String, minimum: float) -> int:
		var n := 0
		for id in by_biome.get(biome, {}):
			n += int(share.call(biome, id) >= minimum)
		return n
	for biome in ["Grassland", "Swamp", "Desert", "Tundra", "Forest", "Plains", "Savanna"]:
		check(by_biome.has(biome), "sampled %s" % biome)
	check(share.call("Grassland", "grass") + share.call("Grassland", "dry_grass") >= 0.6 and materials_over.call("Grassland", 0.01) >= 4,
		"grassland mostly grass (%.0f%%) with patches of other ground (%d materials >= 1%%)" % [100 * (share.call("Grassland", "grass") + share.call("Grassland", "dry_grass")), materials_over.call("Grassland", 0.01)])
	check(materials_over.call("Swamp", 0.05) >= 3 and share.call("Swamp", "mud") + share.call("Swamp", "marsh") >= 0.1,
		"swamp is a mix (%d materials >= 5%%, mud + marsh %.0f%%)" % [materials_over.call("Swamp", 0.05), 100 * (share.call("Swamp", "mud") + share.call("Swamp", "marsh"))])
	check(share.call("Desert", "sand") >= 0.3 and share.call("Desert", "grass") < 0.15, "desert sandy (sand %.0f%%, grass %.0f%%)" % [100 * share.call("Desert", "sand"), 100 * share.call("Desert", "grass")])
	check(share.call("Tundra", "snow") >= 0.7, "tundra snowy (%.0f%%)" % [100 * share.call("Tundra", "snow")])
	check(share.call("Forest", "forest_floor") >= 0.15, "forest floor under forest canopy (%.0f%% of Forest)" % [100 * share.call("Forest", "forest_floor")])
	check(materials_over.call("Plains", 0.05) >= 3, "plains mix grass, dry grass, dirt (%d materials >= 5%%)" % materials_over.call("Plains", 0.05))
	check(pairs > 10000 and agree / float(pairs) >= 0.85, "coherent patches: %.1f%% of neighbouring tiles agree" % [100.0 * agree / maxf(pairs, 1)])
	check(cause_fail.is_empty(), "every material only where its cause is present %s" % [cause_fail])

	# 3. Determinism: a fresh WorldGen gives the same ground and colour.
	var other := WorldGen.new()
	other.configure(SEED)
	var same := true
	for i in 300:
		var x := i * 37 - 5000
		var y := i * 53 - 3000
		var a := _wg.sample(x, y)
		var b := other.sample(x, y)
		if TS.water_color(a) != null:
			continue
		var sa := _state(a, x, y)
		var sb := _state(b, x, y)
		var ma: SurfaceMaterial = TS.material_at(sa, SEED, x, y)
		var mb: SurfaceMaterial = TS.material_at(sb, SEED, x, y)
		same = same and ma == mb and TS.color_for(ma, sa, SEED, x, y) == TS.color_for(mb, sb, SEED, x, y)
	check(same, "deterministic: same material and colour from a fresh WorldGen")

	# 4. The world's render path matches a direct evaluation.
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	world.threaded_generation = false
	world.set_view_mode(world.get_script().ViewMode.MATERIAL)
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	var path_ok := true
	var water_ok := true
	var checked := 0
	for y in range(-40, 40, 3):
		for x in range(-40, 40, 3):
			var s := _wg.sample(x, y)
			var water: Variant = TS.water_color(s)
			if water != null:
				water_ok = water_ok and world._surface_at(s, x, y) == null and _rgb(world._terrain_color(s, x, y)) == _rgb(water)
				continue
			var st := _state(s, x, y)
			var m: SurfaceMaterial = TS.material_at(st, SEED, x, y)
			path_ok = path_ok and world._surface_at(s, x, y) == m and _rgb(world._terrain_color(s, x, y)) == _rgb(TS.color_for(m, st, SEED, x, y))
			checked += 1
	check(path_ok and checked > 400, "chunk path: material and colour match direct evaluation (%d tiles)" % checked)
	check(water_ok, "water tiles: no ground material, water colour")

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


## "" if material `id` fits the tile's conditions, else what's wrong -
## hard causes only (the requirement envelopes in the data).
func _cause_violation(id: String, st: EnvironmentalState) -> String:
	match id:
		"grass":
			if st.temperature < -0.8: return "too cold"
			if st.vegetation < 0.06: return "no vegetation"
		"dry_grass":
			if st.moisture > 0.5: return "too wet"
			if st.temperature < -0.3: return "too cold"
		"snow":
			if st.temperature > -0.3: return "too warm"
		"beach_sand":
			if st.shore_proximity < 0.6: return "not a shore"
		"rock":
			if st.rock_exposure < 0.55: return "no exposed rock"
		"forest_floor":
			if st.shade < 0.2: return "no canopy"
		"mud":
			if st.moisture < 0.45 or st.drainage > 0.5: return "not wet ground"
		"marsh":
			if st.moisture < 0.6 or st.drainage > 0.48: return "not waterlogged"
		"sand":
			if st.moisture > 0.28 or st.vegetation > 0.25: return "not dry and bare"
		"gravel":
			if st.erosion < 0.1: return "not eroded"
		"burnt_ground":
			if st.succession > 0.55: return "not a fresh scar"
	return ""


## Colour without alpha: the World view's terrain carries tile codes (water,
## grass) in alpha for shaders/terrain.gdshader - test_ambience checks those.
func _rgb(c: Color) -> Color:
	return Color(c.r, c.g, c.b)
