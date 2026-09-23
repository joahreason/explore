extends SceneTree

## Phase 9 geological deposit invariants: rock_exposure matches its
## definition and is 0 on water; deposit potential ("exists") is
## deterministic, in [0,1], zero on water, for zero-affinity geology and for
## non-deposit definitions; exposed <= potential and 0 where rock is buried;
## both hidden and exposed deposits occur; ores have decorrelated seams and
## form districts rather than covering the map. Run via tests/run_tests.sh.

const IRON := preload("res://resources/iron.tres")
const COPPER := preload("res://resources/copper.tres")
const COAL := preload("res://resources/coal.tres")
const OAK := preload("res://resources/oak.tres")
const ORES := [IRON, COPPER, COAL]
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
	var wg := WorldGen.new()
	wg.configure(SEED)

	for ore in ORES:
		check(ore.get_curve_domain_warnings().is_empty(), "%s: no curve domain warnings" % ore.id)

	# Sample a spread of tiles once (stride 7 over a 1400x1400 area).
	var tiles := []
	for y in range(-700, 700, 7):
		for x in range(-700, 700, 7):
			tiles.append(Vector2i(x, y))

	var exposure_ok := true
	var water_exposure_ok := true
	var range_ok := true
	var water_zero := true
	var geology_zero := true
	var exposed_le := true
	var buried_zero := true
	var oak_zero := true
	var hidden := {}
	var exposed := {}
	for ore in ORES:
		hidden[ore.id] = 0
		exposed[ore.id] = 0
	for t in tiles:
		var s := wg.sample(t.x, t.y)
		var state: EnvironmentalState = EnvironmentalState.from_sample(s)
		var rock: float = s["rock_exposure"]
		if s["water_body"] != "none":
			water_exposure_ok = water_exposure_ok and rock == 0.0
		else:
			var gate := smoothstep(wg.resource_exposure_requirement, wg.resource_exposure_requirement + 0.25, float(s["erosion"]))
			var cliff := smoothstep(wg.resource_cliff_exposure_requirement, wg.resource_cliff_exposure_requirement + 0.3, float(s["cliff_tendency"]))
			exposure_ok = exposure_ok and is_equal_approx(rock, maxf(gate, cliff))
		oak_zero = oak_zero and ResourceManager.get_deposit_potential(state, OAK, SEED, t.x, t.y) == 0.0
		for ore in ORES:
			var p := ResourceManager.get_deposit_potential(state, ore, SEED, t.x, t.y)
			var e := ResourceManager.get_exposed_deposit(p, state)
			range_ok = range_ok and p >= 0.0 and p <= 1.0
			exposed_le = exposed_le and e <= p
			if rock == 0.0:
				buried_zero = buried_zero and e == 0.0
			if s["water_body"] in ["ocean", "sea", "lake", "river"]:
				water_zero = water_zero and p == 0.0
			if float(ore.geology_weights.get(s["geology"], 1.0)) == 0.0:
				geology_zero = geology_zero and p == 0.0
			if s["water_body"] == "none":
				if p > 0.3:
					if rock >= 0.5:
						exposed[ore.id] += 1
					else:
						hidden[ore.id] += 1
	check(exposure_ok, "rock_exposure = max(erosion gate, cliff gate) on land")
	check(water_exposure_ok, "rock_exposure = 0 on water")
	check(range_ok, "deposit potential in [0,1]")
	check(water_zero, "no deposits in ocean/sea/lake/river")
	check(geology_zero, "zero geology affinity -> no deposit (e.g. coal off sedimentary rock)")
	check(exposed_le, "exposed deposit <= potential")
	check(buried_zero, "fully buried rock -> nothing exposed")
	check(oak_zero, "non-deposit definition (oak) -> potential 0")
	var shares := _host_rock_shares(wg)
	for ore in ORES:
		var share: float = shares[ore.id].x / maxf(shares[ore.id].y, 1.0)
		check(hidden[ore.id] > 0 and exposed[ore.id] > 0 and hidden[ore.id] > exposed[ore.id],
			"%s: hidden (%d) and exposed (%d) deposits both occur, most hidden" % [ore.id, hidden[ore.id], exposed[ore.id]])
		check(shares[ore.id].y > 1000 and share > 0.01 and share < 0.25, "%s: rich (>0.3) on %.1f%% of its host rock (%d tiles) - districts, not everywhere" % [ore.id, share * 100.0, shares[ore.id].y])

	# Seams: each ore has its own vein field.
	var r := _correlation(ORES, SEED)
	check(absf(r) < 0.1, "iron/copper vein noise decorrelated (r = %.3f)" % r)

	# Determinism: fresh WorldGen and a dropped noise cache give the same values.
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var before := []
	for t in tiles.slice(0, 2000):
		before.append(_potential(wg, IRON, SEED, t))
	ResourceManager._vein_noise_cache.clear()
	ResourceManager._patch_noise_cache.clear()
	var same := true
	for i in before.size():
		same = same and before[i] == _potential(wg2, IRON, SEED, tiles[i])
	check(same, "same seed -> identical deposit potential (fresh WorldGen, cleared caches)")
	var differ := 0
	for i in before.size():
		if before[i] != _potential(wg2, IRON, SEED + 1, tiles[i]):
			differ += 1
	check(differ > before.size() / 4, "different seed -> different veins (%d/%d tiles differ)" % [differ, before.size()])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


## ore id -> Vector2(rich tiles (potential > 0.3), land tiles on the ore's
## host rock (geology weight >= 0.5)) over a wide area: geology domains are
## hundreds of tiles across, so a small window can hold almost none of one.
func _host_rock_shares(wg: WorldGen) -> Dictionary:
	var result := {}
	for ore in ORES:
		result[ore.id] = Vector2.ZERO
	for y in range(-3000, 3000, 30):
		for x in range(-3000, 3000, 30):
			var s := wg.sample(x, y)
			if s["water_body"] != "none":
				continue
			var state: EnvironmentalState = EnvironmentalState.from_sample(s)
			for ore in ORES:
				if float(ore.geology_weights.get(s["geology"], 1.0)) < 0.5:
					continue
				var rich := 1.0 if ResourceManager.get_deposit_potential(state, ore, SEED, x, y) > 0.3 else 0.0
				result[ore.id] += Vector2(rich, 1.0)
	return result


func _potential(wg: WorldGen, ore: ResourceDefinition, world_seed: int, t: Vector2i) -> float:
	var state: EnvironmentalState = EnvironmentalState.from_sample(wg.sample(t.x, t.y))
	return ResourceManager.get_deposit_potential(state, ore, world_seed, t.x, t.y)


func _correlation(ores: Array, world_seed: int) -> float:
	var a := PackedFloat32Array()
	var b := PackedFloat32Array()
	for y in range(-500, 500, 5):
		for x in range(-500, 500, 5):
			a.append(ResourceManager.get_vein_value(ores[0], world_seed, x, y))
			b.append(ResourceManager.get_vein_value(ores[1], world_seed, x, y))
	var ma := 0.0
	var mb := 0.0
	for i in a.size():
		ma += a[i]
		mb += b[i]
	ma /= a.size()
	mb /= b.size()
	var cov := 0.0
	var va := 0.0
	var vb := 0.0
	for i in a.size():
		cov += (a[i] - ma) * (b[i] - mb)
		va += (a[i] - ma) * (a[i] - ma)
		vb += (b[i] - mb) * (b[i] - mb)
	return cov / sqrt(va * vb)
