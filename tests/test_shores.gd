extends SceneTree

## Phase 10 steps 3-4 (river mouths, shores): WorldGen's shore_salinity tells
## sea shores (1) from lake shores (0) and is 0 away from any shore; sea-only
## resources (shells, salt, mangroves, salt marsh) never touch a lake shore;
## placed shore features, salt-marsh grass and mangroves stand only where
## their species can live; mud sits only at river mouths; coastal swamps get
## salt marsh where cattails (freshwater) stop. Run via tests/run_tests.sh.

const SHORE := preload("res://resources/guilds/shore_features.tres")
const WETLAND := preload("res://resources/guilds/wetland_plants.tres")
const TREES := preload("res://resources/guilds/canopy_trees.tres")
const SALT := preload("res://resources/deposits/salt.tres")
const SEA_ONLY := ["shells", "salt", "mangrove", "saltmarsh_grass"]
const SEED := 4242
## The last one holds a lake (its shores and a river running into it).
const CENTERS := [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(20000, 20000), Vector2i(-600, 80)]

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

	# Seed -1 (reachable as ?seed=-1) is configured like any other (review
	# D2): it once matched the "not configured yet" sentinel and kept
	# FastNoiseLite's defaults.
	var minus_one := WorldGen.new()
	minus_one.configure(-1)
	check(minus_one._elev_base.frequency == wg._elev_base.frequency and minus_one._climate.seed == -1 + 3,
		"seed -1 sets up the noise fields (elevation frequency %s, climate seed %d)" % [minus_one._elev_base.frequency, minus_one._climate.seed])

	# 4. Water body labels don't depend on the order tiles are asked in
	# (review D1): an enclosed sea sharing a 64x64 cell with open ocean once
	# read as ocean if an ocean tile of that cell was asked first. Each case
	# is a sea tile that did; each 64x64 cell is scanned both ways as well.
	for case in [[4242, Vector2i(-1052, -1212)], [1337, Vector2i(-1912, -2112)]]:
		var seed: int = case[0]
		var tile: Vector2i = case[1]
		var cell := Vector2i(floori(tile.x / 64.0), floori(tile.y / 64.0)) * 64
		var tiles: Array[Vector2i] = []
		for y in range(cell.y, cell.y + 64, 2):
			for x in range(cell.x, cell.x + 64, 2):
				tiles.append(Vector2i(x, y))
		var fresh := func() -> WorldGen:
			var g := WorldGen.new()
			g.configure(seed)
			return g
		var alone: String = fresh.call().sample(tile.x, tile.y)["water_body"]
		var forward: WorldGen = fresh.call()
		var first_ocean := Vector2i.MAX
		var labels := {}
		for t in tiles:
			var s := forward.sample(t.x, t.y)
			labels[t] = [s["water_body"], s["shore_salinity"]]
			if first_ocean == Vector2i.MAX and s["water_body"] == "ocean":
				first_ocean = t
		var ocean_first: WorldGen = fresh.call()
		ocean_first.sample(first_ocean.x, first_ocean.y)
		var after_ocean: String = ocean_first.sample(tile.x, tile.y)["water_body"]
		var backward: WorldGen = fresh.call()
		var differ := 0
		for i in range(tiles.size() - 1, -1, -1):
			var s := backward.sample(tiles[i].x, tiles[i].y)
			if [s["water_body"], s["shore_salinity"]] != labels[tiles[i]]:
				differ += 1
		check(alone == "sea" and after_ocean == "sea" and differ == 0,
			"seed %d: %s is %s asked first, %s after ocean at %s; %d of %d tiles in its cell differ scanned in reverse" % [
				seed, tile, alone, after_ocean, first_ocean, differ, tiles.size()])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
