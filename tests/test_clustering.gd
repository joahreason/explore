extends SceneTree

## Phase 14 clustering amendment (spatial pattern of trees, rocks and ore):
## trees in dense clumps with clear gaps, rocks in formations, ore outcrops
## grouped along their seams - by data (spacing, cluster curves, patch
## noise), not by new placement rules. Measured on the real Resources stack
## (world.tscn) over five regions:
##   * Clark-Evans ratio R = mean nearest-neighbour distance / the mean a
##     random (Poisson) layout of the same count would give on the same land,
##     0.5 / sqrt(count / land tiles). R ~ 1 random, > 1 evenly spread, < 1
##     clustered.
##   * clump index = mean neighbours within CLUMP_RADIUS tiles / the number a
##     random layout would give (pi r^2 x count / land tiles); 1 = random.
##   * isolated = share of instances with no neighbour within that radius.
## Instances within EDGE tiles of a region's border are only neighbours, not
## measured, so the border doesn't bias either value. Thresholds are set
## against the values before this change (recorded in BEFORE) - clustering
## must be clearly stronger - and counts must stay in a sensible range of
## them. Run via tests/run_tests.sh.

const SEED := 4242
const REGIONS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000), Vector2i(8000, -12000)]
const HALF := 96
const EDGE := 8
## Neighbour radius per guild: trees and rocks count what stands in the
## same clump or formation; ore outcrops are wider apart (spacing), so their
## groups along a seam are counted over a wider radius.
const CLUMP_RADIUS := {"canopy_trees": 3.0, "surface_rocks": 3.0, "ore_outcrops": 6.0}
## Measured on main e84ac19 (before clustering), same regions:
## guild id -> [count, R, clump index, isolated share].
const BEFORE := {
	"canopy_trees": [3822, 1.108, 0.95, 0.48],
	"surface_rocks": [6032, 1.115, 1.10, 0.28],
	"ore_outcrops": [351, 0.443, 8.17, 0.11],
}

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
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	var guilds := [world.ORE_OUTCROPS, world.SURFACE_ROCKS, world.CANOPY_TREES]
	var stats := {}  # guild id -> [count, nn sum, neighbour sum, land tiles, isolated count]
	for guild in guilds:
		stats[guild.id] = [0, 0.0, 0, 0, 0]
	for c in REGIONS:
		var rect := Rect2i(c - Vector2i(HALF, HALF), Vector2i(2 * HALF, 2 * HALF))
		var inner := rect.grow(-EDGE)
		var land := 0
		for y in range(inner.position.y, inner.end.y):
			for x in range(inner.position.x, inner.end.x):
				if world._world_gen.sample(x, y)["water_body"] == "none":
					land += 1
		var stack: Dictionary = world._place_stack(rect, 3)
		for guild in guilds:
			var points := PackedVector2Array()
			for inst in stack[guild]:
				points.append(inst["position"])
			var e: Array = stats[guild.id]
			e[3] += land
			var grid := _grid(points)
			for p in points:
				if not inner.has_point(Vector2i(p.floor())):
					continue
				var m := _measure(p, grid, CLUMP_RADIUS[guild.id])
				e[0] += 1
				e[1] += m[0]
				e[2] += m[1]
				e[4] += int(m[1] == 0)
	var summary := {}
	for guild in guilds:
		var e: Array = stats[guild.id]
		var n: int = e[0]
		var intensity: float = n / maxf(e[3], 1.0)
		var r: float = (e[1] / maxf(n, 1.0)) / (0.5 / sqrt(maxf(intensity, 1e-9)))
		var radius: float = CLUMP_RADIUS[guild.id]
		var clump: float = (float(e[2]) / maxf(n, 1.0)) / (PI * radius * radius * intensity)
		var isolated: float = float(e[4]) / maxf(n, 1.0)
		summary[guild.id] = [n, r, clump, isolated]
		print("INFO %s: %d instances (%.2f / 100 land tiles), Clark-Evans R %.3f, clump index %.2f (r %.0f), isolated %.0f%%" % [guild.id, n, intensity * 100.0, r, clump, radius, isolated * 100.0])
	var trees: Array = summary["canopy_trees"]
	check(trees[1] <= 0.85 and trees[2] >= 2.0 and trees[3] <= 0.15,
		"trees in clumps with gaps: R %.2f (was %.2f), clump index %.2f (was %.2f), isolated %.0f%% (was %.0f%%)" % [trees[1], BEFORE["canopy_trees"][1], trees[2], BEFORE["canopy_trees"][2], trees[3] * 100.0, BEFORE["canopy_trees"][3] * 100.0])
	var rocks: Array = summary["surface_rocks"]
	check(rocks[1] <= 0.9 and rocks[2] >= 1.8 and rocks[3] <= 0.15,
		"rocks in formations: R %.2f (was %.2f), clump index %.2f (was %.2f), isolated %.0f%% (was %.0f%%)" % [rocks[1], BEFORE["surface_rocks"][1], rocks[2], BEFORE["surface_rocks"][2], rocks[3] * 100.0, BEFORE["surface_rocks"][3] * 100.0])
	var ores: Array = summary["ore_outcrops"]
	check(ores[2] >= 1.3 * BEFORE["ore_outcrops"][2] and ores[3] <= 0.05,
		"ore outcrops grouped along seams: clump index %.1f (was %.1f), isolated %.0f%% (was %.0f%%)" % [ores[2], BEFORE["ore_outcrops"][2], ores[3] * 100.0, BEFORE["ore_outcrops"][3] * 100.0])
	for id in [["canopy_trees", 1.0, 2.5], ["surface_rocks", 0.7, 1.5], ["ore_outcrops", 1.0, 2.5]]:
		var ratio: float = float(summary[id[0]][0]) / BEFORE[id[0]][0]
		check(ratio >= id[1] and ratio <= id[2], "%s count %d = %.2fx before, within %.1f-%.1fx" % [id[0], summary[id[0]][0], ratio, id[1], id[2]])

	# Stand mode itself: membership is 0..1, grows with the area share, and
	# the share of tiles in a stand tracks that share (PATCH_AREA_THRESHOLDS),
	# down to none at share 0.
	var monotone := true
	var shares := PackedStringArray()
	var calibrated := true
	for a in [0.0, 0.02, 0.1, 0.3, 0.5, 0.7, 0.9]:
		var inside := 0.0
		var n := 0
		for y in range(-400, 400, 5):
			for x in range(-400, 400, 5):
				var m := ResourceManager.get_stand_membership(world.CANOPY_TREES, a, SEED, x, y)
				monotone = monotone and m >= 0.0 and m <= 1.0 and ResourceManager.get_stand_membership(world.CANOPY_TREES, a + 0.05, SEED, x, y) >= m
				inside += m
				n += 1
		shares.append("%.2f -> %.3f" % [a, inside / n])
		calibrated = calibrated and absf(inside / n - a) <= maxf(0.08 * a, 0.01) + 0.02
	check(monotone, "stand membership in [0, 1] and never shrinks as the area share grows")
	check(calibrated, "share of ground in stands tracks the area share (%s)" % ", ".join(shares))

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


## Points bucketed by 4-tile cell, for neighbour queries.
func _grid(points: PackedVector2Array) -> Dictionary:
	var grid := {}
	for p in points:
		var k := Vector2i((p / 4.0).floor())
		if not grid.has(k):
			grid[k] = PackedVector2Array()
		grid[k].append(p)
	return grid


## [nearest-neighbour distance (capped at 16 tiles), neighbours within
## radius] of p among the grid's points (p itself excluded).
func _measure(p: Vector2, grid: Dictionary, radius: float) -> Array:
	var k := Vector2i((p / 4.0).floor())
	var nearest := 16.0
	var within := 0
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			for q in grid.get(k + Vector2i(dx, dy), PackedVector2Array()):
				if q == p:
					continue
				var d := p.distance_to(q)
				nearest = minf(nearest, d)
				if d <= radius:
					within += 1
	return [nearest, within]
