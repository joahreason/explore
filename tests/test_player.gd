extends SceneTree

## The player (user request, before Phase 19): taps walk it along A* paths
## that go round water and never cut a corner past it; a tap it can't reach
## walks to the closest reachable tile; tapping a resource walks up to it
## and harvests it on arrival (another tap on the way cancels that); a new
## world spawns it on dry land near the origin; its position is saved per
## seed; biome travel and teleports land it on dry land with the camera
## centred on it. Run via tests/run_tests.sh.

const SEED := 4242
const DIR := "user://test_player"

var _fails := 0
var _passes := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _init() -> void:
	_clean()
	var world: Node2D = await _world()
	var player: Node2D = world.get_node("Player")
	player.walk_speed = 60.0  # headless frames are short; same paths, sooner
	var rig: Node2D = world.get_node("CameraRig")
	# The same placed resource: species and exact position.
	var same := func(a: Dictionary, b: Dictionary) -> bool:
		return not a.is_empty() and not b.is_empty() and a["id"] == b["id"] and a["position"] == b["position"]
	var walkable := func(t: Vector2i) -> bool:
		world._gen_mutex.lock()
		var w: bool = world.is_walkable(t)
		world._gen_mutex.unlock()
		return w

	check(walkable.call(player.tile()) and rig.global_position == player.position,
		"a new world spawns the player on dry land near the origin (%s), camera on them" % player.tile())

	# A path around water: find a water tile with land on both sides along x.
	var lake := Vector2i(1 << 30, 0)
	for r in range(0, 400, 2):
		for y in range(-r, r + 1, 2):
			for x in [-r, r]:
				var t := Vector2i(x, y)
				if lake.x == 1 << 30 and not walkable.call(t) and walkable.call(t + Vector2i(-12, 0)) and not walkable.call(t + Vector2i(-6, 0)):
					lake = t
		if lake.x != 1 << 30:
			break
	var from: Vector2i = lake + Vector2i(-12, 0)
	var to: Vector2i = lake
	world._gen_mutex.lock()
	var path: Array[Vector2i] = world.find_path(from, to)
	var path_ok := not path.is_empty()
	var prev := from
	for t in path:
		var step: Vector2i = t - prev
		path_ok = path_ok and world.is_walkable(t) and maxi(absi(step.x), absi(step.y)) == 1
		if step.x != 0 and step.y != 0:
			path_ok = path_ok and world.is_walkable(prev + Vector2i(step.x, 0)) and world.is_walkable(prev + Vector2i(0, step.y))
		prev = t
	world._gen_mutex.unlock()
	var end: Vector2i = path[-1] if not path.is_empty() else from
	check(path_ok and end != to and Vector2(end - to).length() < Vector2(from - to).length(),
		"tapping water (%s) from %s: a path of %d steps over dry land, no cut corners, ending at the closest reachable tile %s" % [to, from, path.size(), end])

	# Walking: a tap on open ground a few tiles away gets there.
	world.teleport_player((Vector2(from) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var goal: Vector2i = end
	player.footsteps = 0
	var tapped: Array[Vector2i] = world._on_map_tapped((Vector2(goal) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var frames := 0
	var on_grid := true  # every frame on the segment between two neighbouring tile centres
	while player.is_walking() and frames < 600:
		await process_frame
		frames += 1
		if player._stepping:
			var a: Vector2 = player.feet_point(player._step_from)
			var b: Vector2 = player.feet_point(player.tile())
			var step: Vector2i = player.tile() - player._step_from
			var along := clampf((player.position - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
			on_grid = on_grid and maxi(absi(step.x), absi(step.y)) == 1 and player.position.distance_to(a.lerp(b, along)) <= 1.0
	check(not tapped.is_empty() and player.tile() == goal and not player.is_walking(), "a tap walks the player there (%s in %d frames)" % [player.tile(), frames])
	check(player.footsteps == tapped.size(), "one footstep per step (%d for %d steps)" % [player.footsteps, tapped.size()])
	# Footstep variation: pitches within range, never repeating closely.
	var pitches: Array[float] = []
	for k in 40:
		player._play_footstep()
		pitches.append(player.last_footstep_pitch)
	var varied := true
	for k in range(1, pitches.size()):
		varied = varied and absf(pitches[k] - pitches[k - 1]) >= player.FOOTSTEP_MIN_PITCH_CHANGE - 0.0001
		varied = varied and pitches[k] >= player.FOOTSTEP_PITCH.x and pitches[k] <= player.FOOTSTEP_PITCH.y
	var fs: AudioStreamPlayer = player.get_node("Footstep")
	check(varied and fs.stream != null and fs.stream.get_length() > 0.05 and fs.stream.get_length() < 0.2 and fs.volume_db < -8.0,
		"footsteps vary in pitch (%.2f..%.2f, never within %.2f of the last) at a faint volume (%.1f dB, %.0f ms sound)" % [pitches.min(), pitches.max(), player.FOOTSTEP_MIN_PITCH_CHANGE, fs.volume_db, fs.stream.get_length() * 1000.0])
	check(on_grid and player.position == player.feet_point(goal) and player.hop() == 0.0 and player.sprite_rect().end.y > 0.0 and player.sprite_rect().end.y < 2.0,
		"movement is locked to tiles: each step goes straight or diagonally to a neighbouring tile, and the player comes to rest with the pivot at their feet - the tile's bottom centre (%s), the sprite standing on it" % player.position)

	# Tapping a resource: walks up to it and harvests it on arrival.
	var target := {}
	var near: Vector2i = player.tile()
	for r in range(2, 40):
		for dy in range(-r, r + 1):
			for dx in [-r, r]:
				if target.is_empty():
					var inst: Dictionary = world.hover_target(Vector2(near + Vector2i(dx, dy)) + Vector2(0.5, 0.5))
					if not inst.is_empty() and walkable.call(Vector2i((inst["position"] as Vector2).floor())):
						target = inst
		if not target.is_empty():
			break
	var tile: Vector2i = Vector2i((target["position"] as Vector2).floor())
	var tap_at: Vector2 = (Vector2(tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE
	world._on_map_tapped(tap_at)
	var before_arrival: bool = same.call(world.hover_target(tap_at / world.TILE_SIZE), target)
	frames = 0
	while player.is_walking() and frames < 1200:
		await process_frame
		frames += 1
	var d: Vector2i = player.tile() - tile
	var hs: AudioStreamPlayer = world.get_node("HarvestSound")
	check(world.harvest_sounds == 1 and hs.stream != null and hs.volume_db < -12.0 and hs.pitch_scale >= world.HARVEST_SOUND_PITCH.x and hs.pitch_scale <= world.HARVEST_SOUND_PITCH.y,
		"the harvest plays one soft harvest sound (%d, %.0f dB, pitch %.2f)" % [world.harvest_sounds, hs.volume_db, hs.pitch_scale])
	check(before_arrival and maxi(absi(d.x), absi(d.y)) <= 1 and not same.call(world.hover_target(tap_at / world.TILE_SIZE), target),
		"tapping a %s walks up to it (stopped %s away) and harvests it on arrival" % [target.get("id", "?"), d])

	# A second tap on the way cancels the harvest.
	var other := {}
	for r in range(2, 40):
		for dy in range(-r, r + 1):
			for dx in [-r, r]:
				if other.is_empty():
					var inst: Dictionary = world.hover_target(Vector2(player.tile() + Vector2i(dx, dy)) + Vector2(0.5, 0.5))
					if not inst.is_empty() and walkable.call(Vector2i((inst["position"] as Vector2).floor())):
						other = inst
		if not other.is_empty():
			break
	var other_at: Vector2 = ((other["position"] as Vector2).floor() + Vector2(0.5, 0.5)) * world.TILE_SIZE
	var empty: Vector2i = player.tile()
	for r in range(3, 40):
		for dx in [-r, r]:
			var t: Vector2i = player.tile() + Vector2i(dx, 0)
			if empty == player.tile() and walkable.call(t) and world.hover_target(Vector2(t) + Vector2(0.5, 0.5)).is_empty() and Vector2(t - Vector2i((other["position"] as Vector2).floor())).length() > 3.0:
				empty = t
	world._on_map_tapped(other_at)
	world._on_map_tapped((Vector2(empty) + Vector2(0.5, 0.5)) * world.TILE_SIZE)  # redirect to bare ground
	for f in 60:
		await process_frame
	check(same.call(world.hover_target(other_at / world.TILE_SIZE), other), "another tap on the way cancels the harvest (%s still stands)" % other.get("id", "?"))

	# Tapping a camp tent: walk up, go inside (hidden), sleep until 20:00.
	world._gen_mutex.lock()
	var camp_at = world._structures.find("camp", player.tile())
	var camp: Dictionary = world._structures.site_at(camp_at) if camp_at != null else {}
	world._gen_mutex.unlock()
	var tent_tile := Vector2i(1 << 30, 0)
	for part in camp.get("parts", []):
		if part["kind"] == "tent":
			tent_tile = part["tile"]
	world.teleport_player((Vector2(camp_at) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	world.flush_chunk_work()
	world.clock.minutes = 2.0 * GameClock.MINUTES_PER_DAY + 10 * 60
	world._on_map_tapped((Vector2(tent_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	frames = 0
	while player.is_walking() and frames < 600:
		await process_frame
		frames += 1
	var effect: Node2D = world.resources_root.get_node_or_null("TentSleep")
	var chunk := Vector2i((Vector2(tent_tile) / world.CHUNK_SIZE).floor())
	var markers = world._loaded_placements.get(chunk)
	var marker_hidden := true
	if markers != null:
		for k in markers.instance_count():
			marker_hidden = marker_hidden and Vector2i((markers._positions[k] / world.TILE_SIZE).floor()) + chunk * world.CHUNK_SIZE != tent_tile
	check(world.is_tent(tent_tile) and world.is_in_tent() and not player.visible and effect != null and marker_hidden and world.clock.sleeping,
		"tapping a camp tent (%s) walks the player in: hidden, the tent's marker swapped for the bouncing one, time asleep" % tent_tile)
	var heights := {}
	var z_count := 0
	for f in 12:
		effect._process(0.2)  # real time, stepped: headless frames are too short to see it move
		heights[snappedf(effect.stretch(), 0.01)] = true
		z_count = maxi(z_count, effect.zs().size())
	check(heights.size() > 2 and z_count >= 1, "the tent bounces (%d heights) with Zs rising (%d at once)" % [heights.size(), z_count])
	world.clock.minutes = world.clock.wake_minutes - 2.0
	frames = 0
	while world.clock.sleeping and frames < 600:
		await process_frame
		frames += 1
	await process_frame
	check(not world.is_in_tent() and player.visible and not is_instance_valid(effect) and world.clock.time_text().begins_with("20:0") and world.clock.rate() == 1.0,
		"at night start the player comes out and time runs at normal speed (%s)" % world.clock.time_text())
	world.enter_tent(tent_tile)
	world._on_map_tapped((Vector2(tent_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	check(not world.clock.sleeping and player.visible and not player.is_walking(), "tapping the tent again while inside wakes the player")

	# Saved per seed: a reloaded world puts the player back.
	var saved: Vector2 = player.position
	world._save_gameplay_state()
	world.queue_free()
	await process_frame
	var world2: Node2D = await _world()
	var player2: Node2D = world2.get_node("Player")
	check(player2.position.is_equal_approx(saved) and world2.get_node("CameraRig").global_position == player2.position,
		"a reloaded world puts the player back where they stood (%s), camera on them" % player2.tile())

	# Teleporting onto water lands on the nearest dry tile.
	world2.teleport_player((Vector2(lake) + Vector2(0.5, 0.5)) * world2.TILE_SIZE)
	world2._gen_mutex.lock()
	var dry: bool = world2.is_walkable(player2.tile())
	world2._gen_mutex.unlock()
	check(dry and Vector2(player2.tile() - lake).length() < 12.0 and world2.get_node("CameraRig").global_position == player2.position,
		"teleporting onto water lands on the nearest dry tile (%s, %.1f tiles off)" % [player2.tile(), Vector2(player2.tile() - lake).length()])
	world2.queue_free()
	await process_frame

	_clean()
	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _world() -> Node2D:
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = SEED
	world.changes_dir = DIR
	world.threaded_generation = false
	root.add_child(world)
	await process_frame
	world.flush_chunk_work()
	return world


func _clean() -> void:
	var d := DirAccess.open(DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
