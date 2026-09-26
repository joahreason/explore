extends "res://tests/harness.gd"

## Phase 10 step 2 (floodplains): farming potential is a field that is 0 on
## water and steep ground and higher on flat river banks than on flat ground
## away from rivers; clay is a deposit that exists in sediment on flat
## ground and shows only where a river bank cuts into it (exposure_field
## "river"), while bedrock ores keep rock_exposure. Run via tests/run_tests.sh.

const FARMLAND := preload("res://resources/farmland.tres")
const CLAY := preload("res://resources/deposits/clay.tres")
const IRON := preload("res://resources/deposits/iron.tres")
const OUTCROPS := preload("res://resources/guilds/ore_outcrops.tres")
const SEED := 4242


func _init() -> void:
	for def in [FARMLAND, CLAY]:
		check(def.get_curve_domain_warnings().is_empty(), "%s: no curve-domain warnings %s" % [def.id, def.get_curve_domain_warnings()])
	check(OUTCROPS.get_curve_domain_warnings().is_empty(), "ore_outcrops (with clay): no curve-domain warnings")

	var wg := WorldGen.new()
	wg.configure(SEED)
	var water_zero := true
	var steep_zero := true
	var bank := Vector2.ZERO  # (sum, count) of farming potential
	var off := Vector2.ZERO
	var exposure_ok := true
	var clay_ok := true
	var land := 0
	var clay_rich := 0
	var clay_exposed := 0
	for c in [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000)]:
		for y in range(c.y - 150, c.y + 150, 3):
			for x in range(c.x - 150, c.x + 150, 3):
				var s := wg.sample(x, y)
				var cls := BiomeClassifier.classify_full(s)
				var state: EnvironmentalState = EnvironmentalState.from_sample(s)
				var f := ResourceManager.get_suitability(state, FARMLAND, cls)
				var clay_e := ResourceManager.get_exposure(state, CLAY)
				exposure_ok = exposure_ok and is_equal_approx(clay_e, clampf(CLAY.exposure_curve.sample(state.river), 0.0, 1.0))
				exposure_ok = exposure_ok and ResourceManager.get_exposure(state, IRON) == state.rock_exposure
				var p := ResourceManager.get_deposit_potential(state, CLAY, SEED, x, y)
				var e := ResourceManager.get_exposed_deposit(p, state, CLAY)
				if s["water_body"] in ["ocean", "sea", "lake", "river"]:
					water_zero = water_zero and f == 0.0 and p == 0.0
					continue
				if s["water_body"] != "none":
					continue
				land += 1
				if s["slope"] > 0.008:
					steep_zero = steep_zero and p == 0.0 and f == 0.0
				if s["slope"] < 0.002:
					if s["river"] > 0.1:
						bank += Vector2(f, 1)
					else:
						off += Vector2(f, 1)
				clay_ok = clay_ok and e <= p and (e == 0.0 or s["river"] > 0.03)
				if p > 0.3:
					clay_rich += 1
				if e > 0.1:
					clay_exposed += 1
	check(water_zero, "no farming potential or clay on open water")
	check(steep_zero, "no farming potential or clay on steep ground (slope > 0.008)")
	var bank_mean := bank.x / maxf(bank.y, 1.0)
	var off_mean := off.x / maxf(off.y, 1.0)
	check(bank.y > 100 and bank_mean > off_mean * 1.3,
		"farming potential higher on flat river banks: %.2f (n=%d) vs %.2f flat off-river (n=%d)" % [bank_mean, bank.y, off_mean, off.y])
	check(exposure_ok, "exposure: clay = exposure_curve(river), iron = rock_exposure")
	var rich_share := float(clay_rich) / land
	check(clay_ok and clay_exposed > 0 and rich_share > 0.01 and rich_share < 0.15,
		"clay: exposed <= potential and only on river banks; rich on %.1f%% of land, exposed (> 0.1) on %d tiles" % [100.0 * rich_share, clay_exposed])

	# Clay outcrops through the shared ore_outcrops guild.
	var density_fn := func(x: int, y: int) -> float:
		return ResourceManager.get_guild_density(EnvironmentalState.from_sample(wg.sample(x, y)), OUTCROPS, SEED, x, y)
	var shares_fn := func(x: int, y: int) -> PackedFloat32Array:
		var scores := ResourceManager.get_member_scores(EnvironmentalState.from_sample(wg.sample(x, y)), OUTCROPS, SEED, x, y)
		return ResourceManager.get_species_shares(scores, OUTCROPS.species_sharpness)
	var clay_n := 0
	var clay_off_bank := 0
	for c in [Vector2i(0, 0), Vector2i(12000, -7000), Vector2i(-9000, 15000), Vector2i(18000, 9000)]:
		for inst in ResourcePlacement.place_guild_in_rect(OUTCROPS, SEED, Rect2i(c - Vector2i(200, 200), Vector2i(400, 400)), density_fn, shares_fn):
			if inst["id"] != "clay":
				continue
			clay_n += 1
			var p: Vector2 = inst["position"]
			if wg.sample(floori(p.x), floori(p.y))["river"] <= 0.03:
				clay_off_bank += 1
	check(clay_n > 0 and clay_off_bank == 0, "clay outcrops: %d, all on river banks (%d off)" % [clay_n, clay_off_bank])

	finish()
