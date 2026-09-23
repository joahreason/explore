extends SceneTree

## Phase 10 steps 3-4 (river mouths, shores): WorldGen's shore_salinity tells
## sea shores (1) from lake shores (0) and is 0 away from any shore; sea-only
## resources (shells, salt, mangroves, salt marsh) never touch a lake shore;
## placed shore features, salt-marsh grass and mangroves stand only where
## their species can live; mud sits only at river mouths; coastal swamps get
## salt marsh where cattails (freshwater) stop. Run via tests/run_tests.sh.

const SHORE := preload("res://resources/shore_features.tres")
const WETLAND := preload("res://resources/wetland_plants.tres")
const TREES := preload("res://resources/canopy_trees.tres")
const SALT := preload("res://resources/salt.tres")
const SEA_ONLY := ["shells", "salt", "mangrove", "saltmarsh_grass"]
const SEED := 4242
const CENTERS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(20000, 20000)]

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
	for res in [SHORE, WETLAND, TREES, SALT]:
		check(res.get_curve_domain_warnings().is_empty(), "%s: no curve-domain warnings %s" % [res.id, res.get_curve_domain_warnings()])

	var wg := WorldGen.new()
	wg.configure(SEED)
	var definitions := {"salt": SALT}
	for g in [SHORE, WETLAND, TREES]:
		for m in g.members:
			definitions[m.id] = m

	# 1. shore_salinity, and sea-only species on lake shores.
	var range_ok := true
	var no_shore_zero := true
	var lake_shores := 0
	var sea_shores := 0
	var lake_sea_only := 0
	var coastal_swamp := Vector2.ZERO  # (salt marsh, cattail) summed suitability on swamp with shore > 0.5
	var mouth_reed := Vector2.ZERO     # (sum, n) reed suitability at river mouths
	for c in CENTERS:
		for y in range(c.y - 150, c.y + 150, 3):
			for x in range(c.x - 150, c.x + 150, 3):
				var s := wg.sample(x, y)
				var sal: float = s["shore_salinity"]
				range_ok = range_ok and sal >= 0.0 and sal <= 1.0
				if s["shore_proximity"] <= 0.0:
					no_shore_zero = no_shore_zero and sal == 0.0
					continue
				if s["water_body"] in ["ocean", "sea", "lake", "river"]:
					continue
				var state: EnvironmentalState = EnvironmentalState.from_sample(s)
				var cls := BiomeClassifier.classify_full(s)
				if sal == 0.0:
					lake_shores += 1
					for id in SEA_ONLY:
						if ResourceManager.get_suitability(state, definitions[id], cls) > 0.0:
							lake_sea_only += 1
				elif sal == 1.0:
					sea_shores += 1
				if s["water_body"] == "swamp" and s["shore_proximity"] > 0.5:
					coastal_swamp += Vector2(ResourceManager.get_suitability(state, definitions["saltmarsh_grass"], cls),
						ResourceManager.get_suitability(state, definitions["cattail"], cls))
				if s["river"] > 0.02 and s["shore_proximity"] > 0.1:
					mouth_reed += Vector2(ResourceManager.get_suitability(state, definitions["reed"], cls), 1)
	check(range_ok and no_shore_zero, "shore_salinity in [0,1], 0 away from any shore")
	check(lake_shores > 20 and sea_shores > 200, "both lake shores (%d, salinity 0) and sea shores (%d, salinity 1) occur" % [lake_shores, sea_shores])
	check(lake_sea_only == 0, "no shells, salt, mangroves or salt marsh on lake shores (%d)" % lake_sea_only)
	check(coastal_swamp.x > coastal_swamp.y * 2.0, "coastal swamp: salt marsh %.1f vs cattail %.1f (summed suitability)" % [coastal_swamp.x, coastal_swamp.y])
	check(mouth_reed.y > 20 and mouth_reed.x / mouth_reed.y > 0.1, "reeds reach river mouths: mean suitability %.2f over %d mouth tiles" % [mouth_reed.x / maxf(mouth_reed.y, 1.0), mouth_reed.y])

	# 2. Real placement: every instance on a tile its species tolerates, never
	# on open water; mud only at river mouths, shells only on sea beaches.
	var counts := {}
	var bad := 0
	var mud_off := 0
	var shells_off := 0
	for g in [SHORE, WETLAND, TREES]:
		var density_fn := func(x: int, y: int) -> float:
			var s := wg.sample(x, y)
			return ResourceManager.get_guild_density(EnvironmentalState.from_sample(s), g, SEED, x, y, BiomeClassifier.classify_full(s))
		var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
			var s := wg.sample(x, y)
			var scores := ResourceManager.get_member_scores(EnvironmentalState.from_sample(s), g, SEED, x, y, BiomeClassifier.classify_full(s))
			return ResourceManager.get_species_shares(scores, g.species_sharpness)
		for c in CENTERS:
			for inst in ResourcePlacement.place_guild_in_rect(g, SEED, Rect2i(c - Vector2i(150, 150), Vector2i(300, 300)), density_fn, shares_fn):
				var id: String = inst["id"]
				if not id in ["shells", "beach_grass", "mud", "mangrove", "saltmarsh_grass"]:
					continue
				counts[id] = counts.get(id, 0) + 1
				var p: Vector2 = inst["position"]
				var s := wg.sample(floori(p.x), floori(p.y))
				var state: EnvironmentalState = EnvironmentalState.from_sample(s)
				if s["water_body"] in ["ocean", "sea", "lake", "river"] or ResourceManager.get_suitability(state, definitions[id], BiomeClassifier.classify_full(s)) <= 0.0:
					bad += 1
				if id == "mud" and (s["river"] <= 0.01 or s["shore_proximity"] <= 0.05):
					mud_off += 1
				if id == "shells" and (s["shore_proximity"] <= 0.45 or s["shore_salinity"] <= 0.4):
					shells_off += 1
	var all_present := true
	for id in ["shells", "beach_grass", "mud", "mangrove", "saltmarsh_grass"]:
		all_present = all_present and counts.get(id, 0) > 0
	check(all_present and bad == 0, "real shore/mouth species %s: 0 on water or where they score 0 (%d)" % [counts, bad])
	check(mud_off == 0 and shells_off == 0, "mud only at river mouths (%d off), shells only on sea beaches (%d off)" % [mud_off, shells_off])

	# 3. Determinism of the new field.
	var wg2 := WorldGen.new()
	wg2.configure(SEED)
	var same := true
	for y in range(-150, 150, 7):
		for x in range(-150, 150, 7):
			same = same and wg.sample(x, y)["shore_salinity"] == wg2.sample(x, y)["shore_salinity"]
	check(same, "shore_salinity identical from a fresh WorldGen")

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
