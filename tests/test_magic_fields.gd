extends SceneTree

## Magic overlay (WorldGen's "Magic" group): `ley` (lines of mystic energy,
## strongest where two cross) and `void_taint` (rare pockets leaning toward
## caves). Checks: both are deterministic and seed-dependent; both stay in
## 0..1; rarity stays near its targets (a few percent of land); retuning
## magic changes no physical field (the overlay rule - existing worlds stay
## identical); void leans toward cave-prone ground; ley_curve / void_curve
## reach ResourceManager.get_suitability() like any other curve; and the
## Ley / Void heatmaps tell strong from none. Run via tests/run_tests.sh.

const SEED := 1337
const STEP := 37
const HALF := 45

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

	# One scan; most checks below read it.
	var samples := []
	for gy in range(-HALF, HALF):
		for gx in range(-HALF, HALF):
			samples.append(wg.sample(gx * STEP, gy * STEP))

	var in_range := true
	var land := 0
	var ley_on := 0
	var void_on := 0
	var cave_hi := [0.0, 0]
	var cave_lo := [0.0, 0]
	for s in samples:
		var ley: float = s["ley"]
		var v: float = s["void_taint"]
		if ley < 0.0 or ley > 1.0 or v < 0.0 or v > 1.0:
			in_range = false
		if s["water_body"] != "none":
			continue
		land += 1
		if ley > 0.3:
			ley_on += 1
		if v > 0.3:
			void_on += 1
		var cave: float = s["cave_potential"]
		if cave > 0.5:
			cave_hi[0] += v
			cave_hi[1] += 1
		elif cave < 0.1:
			cave_lo[0] += v
			cave_lo[1] += 1
	check(in_range, "ley and void_taint stay within 0..1")
	var ley_share := float(ley_on) / land
	var void_share := float(void_on) / land
	print("INFO %d land tiles: ley > 0.3 on %.2f%%, void > 0.3 on %.2f%%" % [land, 100.0 * ley_share, 100.0 * void_share])
	check(ley_share > 0.01 and ley_share < 0.08, "ley is rare but present (%.2f%% of land, target 1-8%%)" % (100.0 * ley_share))
	check(void_share > 0.003 and void_share < 0.04, "void is rarer still (%.2f%% of land, target 0.3-4%%)" % (100.0 * void_share))
	var mean_hi: float = cave_hi[0] / maxi(cave_hi[1], 1)
	var mean_lo: float = cave_lo[0] / maxi(cave_lo[1], 1)
	print("INFO mean void: cave-prone %.4f (%d tiles), cave-poor %.4f (%d tiles)" % [mean_hi, cave_hi[1], mean_lo, cave_lo[1]])
	check(mean_hi > mean_lo, "void leans toward cave-prone ground")

	# Determinism and seed dependence.
	var again := WorldGen.new()
	again.configure(SEED)
	var other := WorldGen.new()
	other.configure(SEED + 1)
	var same := true
	var differs := false
	for i in range(0, samples.size(), 13):
		var gx: int = i % (2 * HALF) - HALF
		var gy: int = i / (2 * HALF) - HALF
		var s: Dictionary = samples[i]
		var t: Dictionary = again.sample(gx * STEP, gy * STEP)
		var u: Dictionary = other.sample(gx * STEP, gy * STEP)
		if t["ley"] != s["ley"] or t["void_taint"] != s["void_taint"]:
			same = false
		if u["ley"] != s["ley"] or u["void_taint"] != s["void_taint"]:
			differs = true
	check(same, "same seed gives the same ley and void")
	check(differs, "another seed gives different ley and void")

	# Overlay rule: retuning magic leaves every physical field unchanged.
	var retuned := WorldGen.new()
	retuned.ley_region_range = Vector2(0.1, 0.2)
	retuned.ley_line_width = 0.2
	retuned.void_share = 0.9
	retuned.configure(SEED)
	var physical_same := true
	var magic_moved := false
	for i in range(0, samples.size(), 29):
		var gx: int = i % (2 * HALF) - HALF
		var gy: int = i / (2 * HALF) - HALF
		var s: Dictionary = samples[i]
		var r: Dictionary = retuned.sample(gx * STEP, gy * STEP)
		for key in s:
			if key == "ley" or key == "void_taint":
				if r[key] != s[key]:
					magic_moved = true
			elif r[key] != s[key]:
				physical_same = false
	check(magic_moved, "the retuned magic exports do change ley / void")
	check(physical_same, "retuning magic changes no physical field")

	# Curves: a definition that requires ley scores 0 off ley and > 0 on it;
	# void_curve reads void_taint the same way.
	var ley_def := ResourceDefinition.new()
	ley_def.id = "test_ley"
	ley_def.ley_curve = _rising()
	ley_def.required_curves = PackedStringArray(["ley_curve"])
	var void_def := ResourceDefinition.new()
	void_def.id = "test_void"
	void_def.void_curve = _rising()
	void_def.required_curves = PackedStringArray(["void_curve"])
	check(ley_def.get_curve_domain_warnings().is_empty() and void_def.get_curve_domain_warnings().is_empty(),
		"ley_curve / void_curve are known curves with the 0..1 range")
	var off := _state({"ley": 0.0, "void_taint": 0.0})
	var on := _state({"ley": 0.8, "void_taint": 0.8})
	check(ResourceManager.get_suitability(off, ley_def) == 0.0, "ley_curve required: suitability 0 off ley")
	check(ResourceManager.get_suitability(on, ley_def) > 0.5, "ley_curve required: suitability high on ley")
	check(ResourceManager.get_suitability(off, void_def) == 0.0, "void_curve required: suitability 0 off void")
	check(ResourceManager.get_suitability(on, void_def) > 0.5, "void_curve required: suitability high in void")

	# Heatmaps.
	check(HeatmapColorizer.ley({"ley": 0.0}) != HeatmapColorizer.ley({"ley": 1.0}), "Ley view tells none from strong")
	check(HeatmapColorizer.void_taint({"void_taint": 0.0}) != HeatmapColorizer.void_taint({"void_taint": 1.0}), "Void view tells none from strong")

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _rising() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(1.0, 1.0))
	return c


## A land tile's real sample with the magic fields overridden.
func _state(magic: Dictionary) -> EnvironmentalState:
	var wg := WorldGen.new()
	wg.configure(SEED)
	var s: Dictionary = wg.sample(0, 0)
	for key in magic:
		s[key] = magic[key]
	return EnvironmentalState.from_sample(s)
