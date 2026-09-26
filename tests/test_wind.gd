extends SceneTree

## Wind sway: resource sprites bend in the wind by their data `sway` (grass
## most, shrubs less, trees a little, rocks / ore / logs not at all); the
## sway reaches the shader (shaders/sway.gdshader) through the sprite draw
## colour's alpha; Wind (scripts/wind.gd) drives direction, strength and
## the animation from the in-game clock (paused = still, fast-forward capped,
## rewind backwards). The shader itself is checked on a real renderer by
## hand (headless has none). Run via tests/run_tests.sh.

const ViewModes := preload("res://scripts/world/view_modes.gd")
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
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()

	# Data.
	var by_guild := {}
	for guild in world.CONTENT.guilds:
		for member in guild.members:
			by_guild[member.id] = member.sway
	var rigid := ["granite", "sandstone", "basalt", "limestone", "shale", "gravel", "exposed_stone", "iron", "copper", "coal", "clay", "salt", "dead_tree", "fallen_log", "mushrooms", "shells", "mud"]
	var rigid_ok := true
	for id in rigid:
		rigid_ok = rigid_ok and by_guild[id] == 0.0
	check(rigid_ok, "rocks, ore, logs, snags, mushrooms, shells and mud never sway")
	check(by_guild["meadow_grass"] >= 0.8 and by_guild["meadow_grass"] > by_guild["berry_bush"] and by_guild["berry_bush"] > by_guild["oak"] and by_guild["oak"] > 0.0,
		"grass sways most, shrubs less, trees a little (%.2f > %.2f > %.2f > 0)" % [by_guild["meadow_grass"], by_guild["berry_bush"], by_guild["oak"]])

	# Encoding: draw alpha <-> sway, as the shader decodes it.
	var enc_ok := true
	for s in [0.0, 0.25, 0.5, 1.0]:
		var a: float = world._presenter.sway_alpha(s)
		enc_ok = enc_ok and is_equal_approx(clampf((1.0 - a) * 2.0, 0.0, 1.0), s)
	check(enc_ok and world._presenter.sway_alpha(0.0) == 1.0, "sway rides in the sprite colour's alpha (opaque = rigid) and decodes back exactly")
	var rock_c: Dictionary = world._presenter.marker_colors(ViewModes.SURFACE_ROCKS, true)
	var grass_c: Dictionary = world._presenter.marker_colors(ViewModes.GROUND_COVER, true)
	var debug_c: Dictionary = world._presenter.marker_colors(ViewModes.GROUND_COVER, false)
	check(rock_c["granite"].a == 1.0 and is_equal_approx(grass_c["meadow_grass"].a, world._presenter.sway_alpha(by_guild["meadow_grass"])) and debug_c["meadow_grass"].a == 1.0,
		"World-view sprite colours carry sway; debug markers stay opaque")
	var mat_ok: bool = not world._presenter.loaded_placements.is_empty()
	for m in world._presenter.loaded_placements.values():
		mat_ok = mat_ok and m.material == world.sway_material
	check(mat_ok and world.sway_material.shader == world.SWAY_SHADER, "every marker node uses the shared sway material")

	# Wind model.
	var dir_ok := true
	var str_ok := true
	var smooth := true
	var prev_d := Wind.direction_at(0.0)
	var prev_s := Wind.strength_at(0.0)
	var lo := 1.0
	var hi := 0.0
	for m in range(1, 60 * 24 * 10):
		var d := Wind.direction_at(float(m))
		var s := Wind.strength_at(float(m))
		dir_ok = dir_ok and is_equal_approx(d.length(), 1.0)
		str_ok = str_ok and s >= Wind.STRENGTH_MIN and s <= Wind.STRENGTH_MAX
		smooth = smooth and d.distance_to(prev_d) < 0.01 and absf(s - prev_s) < 0.01
		lo = minf(lo, s)
		hi = maxf(hi, s)
		prev_d = d
		prev_s = s
	check(dir_ok and str_ok and smooth and hi - lo > 0.4, "direction is a unit vector, strength stays in range and varies (%.2f..%.2f), both change smoothly minute by minute" % [lo, hi])
	var w := Wind.new()
	w.advance(1.0, 1.0)
	var normal := w.phase
	w.advance(1.0, 0.0)
	var paused_same := w.phase == normal
	w.advance(1.0, 64.0)
	var capped := is_equal_approx(w.phase - normal, Wind.MAX_ANIMATION_RATE)
	w.advance(1.0, -16.0)
	check(normal == 1.0 and paused_same and capped and is_equal_approx(w.phase, normal + Wind.MAX_ANIMATION_RATE - Wind.MAX_ANIMATION_RATE),
		"animation runs with the clock: still when paused, capped at x%d, backwards when rewinding" % int(Wind.MAX_ANIMATION_RATE))

	# Scene: the world's wind (pushed into the sway material every frame -
	# headless can't read shader uniforms back, the real-renderer frames were
	# checked by hand) runs with the clock and holds while paused.
	var p0: float = world.wind.phase
	for f in 5:
		await process_frame
	var p1: float = world.wind.phase
	world.clock.play_pause()
	for f in 5:
		await process_frame
	var p2: float = world.wind.phase
	for f in 5:
		await process_frame
	var p3: float = world.wind.phase
	check(p1 > p0 and p2 == p3, "the world's wind runs with the game and holds while paused (%.3f -> %.3f, paused %.3f = %.3f)" % [p0, p1, p2, p3])

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
