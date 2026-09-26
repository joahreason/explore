extends "res://tests/harness.gd"

## Phase 7 invariants for ResourcePlacement: determinism, chunk-seam safety,
## minimum spacing, density response, seed/id decorrelation, and (with the
## real oak + WorldGen) no instances on water. Run via tests/run_tests.sh.

const OAK := preload("res://resources/species/oak.tres")
const CHUNK := 16


func const_fn(v: float) -> Callable:
	return func(_x: int, _y: int) -> float: return v


func key_set(arr: Array) -> Dictionary:
	var d := {}
	for inst in arr:
		d["%s|%s" % [inst["cell"], inst["position"]]] = true
	return d


func min_pair_dist(arr: Array) -> float:
	var best := INF
	for i in arr.size():
		for j in range(i + 1, arr.size()):
			best = minf(best, (arr[i]["position"] as Vector2).distance_to(arr[j]["position"]))
	return best


func _init() -> void:
	var def := ResourceDefinition.new()
	def.id = "test"
	def.minimum_spacing = 2.0

	# 1. Zero density places nothing.
	var none := ResourcePlacement.place_in_rect(def, 42, Rect2i(0, 0, 64, 64), const_fn(0.0))
	check(none.is_empty(), "zero density -> no instances")

	# 2. Determinism.
	var a := ResourcePlacement.place_in_rect(def, 42, Rect2i(-40, -40, 80, 80), const_fn(1.0))
	var b := ResourcePlacement.place_in_rect(def, 42, Rect2i(-40, -40, 80, 80), const_fn(1.0))
	check(key_set(a) == key_set(b) and a.size() == b.size(), "same inputs -> identical placement (%d)" % a.size())

	# 3. Chunk seam: one big rect == union of per-chunk rects, no duplicates.
	var union := []
	for cy in range(-3, 2):
		for cx in range(-3, 2):
			union.append_array(ResourcePlacement.place_in_rect(def, 42, Rect2i(cx * CHUNK, cy * CHUNK, CHUNK, CHUNK), const_fn(1.0)))
	var whole := ResourcePlacement.place_in_rect(def, 42, Rect2i(-3 * CHUNK, -3 * CHUNK, 5 * CHUNK, 5 * CHUNK), const_fn(1.0))
	check(union.size() == whole.size() and key_set(union) == key_set(whole), "per-chunk union == whole-rect (%d vs %d)" % [union.size(), whole.size()])
	check(key_set(union).size() == union.size(), "no duplicate instances across chunk boundaries")

	# 4. Minimum spacing holds, including across chunk edges.
	var md := min_pair_dist(union)
	check(md >= def.minimum_spacing, "min pairwise distance %.3f >= spacing %.1f" % [md, def.minimum_spacing])
	def.minimum_spacing = 3.5
	var wide := ResourcePlacement.place_in_rect(def, 42, Rect2i(-50, -50, 100, 100), const_fn(1.0))
	check(min_pair_dist(wide) >= 3.5, "non-integer spacing 3.5 respected (min %.3f)" % min_pair_dist(wide))
	def.minimum_spacing = 2.0

	# 5. All instances inside the rect.
	var inside := true
	var r := Rect2i(5, -7, 33, 21)
	for inst in ResourcePlacement.place_in_rect(def, 42, r, const_fn(1.0)):
		var p: Vector2 = inst["position"]
		inside = inside and r.has_point(Vector2i(floori(p.x), floori(p.y)))
	check(inside, "instances lie inside the requested rect")

	# 6. Count increases monotonically with density.
	var counts := []
	for dv in [0.1, 0.25, 0.5, 0.75, 1.0]:
		counts.append(ResourcePlacement.place_in_rect(def, 42, Rect2i(0, 0, 200, 200), const_fn(dv)).size())
	var mono := true
	for i in range(1, counts.size()):
		mono = mono and counts[i] > counts[i - 1]
	check(mono, "count grows with density %s (200x200, spacing 2)" % [counts])

	# 7. Different seed / different id -> different placement.
	var s2 := ResourcePlacement.place_in_rect(def, 43, Rect2i(-40, -40, 80, 80), const_fn(1.0))
	check(key_set(s2) != key_set(a), "different seed -> different placement")
	var def2 := def.duplicate()
	def2.id = "other"
	var o := ResourcePlacement.place_in_rect(def2, 42, Rect2i(-40, -40, 80, 80), const_fn(1.0))
	var shared := 0
	var ka := key_set(a)
	for k in key_set(o):
		if ka.has(k):
			shared += 1
	check(shared == 0, "different id -> decorrelated positions (%d shared)" % shared)

	# 8. Real oak on a real world: no instance on density-0 tiles (water),
	#    and chunk seams hold with the real density field too.
	var wg := WorldGen.new()
	var seed := 4242
	wg.configure(seed)
	var density_fn := func(x: int, y: int) -> float:
		var s := wg.sample(x, y)
		var st = EnvironmentalState.from_sample(s)
		return ResourceManager.get_density(st, OAK, seed, x, y, BiomeClassifier.classify_full(s))
	var t0 := Time.get_ticks_usec()
	var oaks := []
	for cy in range(-4, 4):
		for cx in range(-4, 4):
			oaks.append_array(ResourcePlacement.place_in_rect(OAK, seed, Rect2i(cx * CHUNK, cy * CHUNK, CHUNK, CHUNK), density_fn))
	var per_chunk_ms := (Time.get_ticks_usec() - t0) / 1000.0 / 64.0
	var on_water := 0
	var on_zero := 0
	for inst in oaks:
		var p: Vector2 = inst["position"]
		var s := wg.sample(floori(p.x), floori(p.y))
		if s["water_body"] in ["ocean", "sea", "lake", "river"]:
			on_water += 1
		if density_fn.call(floori(p.x), floori(p.y)) <= 0.0:
			on_zero += 1
	check(on_water == 0 and on_zero == 0, "real oak: %d instances, 0 on water (%d), 0 on zero density (%d)" % [oaks.size(), on_water, on_zero])
	var oak_whole := ResourcePlacement.place_in_rect(OAK, seed, Rect2i(-64, -64, 128, 128), density_fn)
	check(key_set(oak_whole) == key_set(oaks), "real oak: per-chunk union == whole-rect")
	check(min_pair_dist(oaks) >= OAK.minimum_spacing, "real oak: min spacing %.3f" % min_pair_dist(oaks))
	var wg2 := WorldGen.new()
	wg2.configure(seed)
	var density_fn2 := func(x: int, y: int) -> float:
		var s := wg2.sample(x, y)
		return ResourceManager.get_density(EnvironmentalState.from_sample(s), OAK, seed, x, y, BiomeClassifier.classify_full(s))
	var oak_fresh := ResourcePlacement.place_in_rect(OAK, seed, Rect2i(-64, -64, 128, 128), density_fn2)
	check(key_set(oak_fresh) == key_set(oaks), "real oak: identical from a fresh WorldGen instance")
	print("INFO real-oak placement cost: %.2f ms/chunk" % per_chunk_ms)

	finish()
