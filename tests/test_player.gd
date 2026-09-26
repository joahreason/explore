extends SceneTree

## The player (user request, before Phase 19): taps walk it along A* paths
## that go round water and never cut a corner past it; a tap it can't reach
## walks to the closest reachable tile; tapping a resource walks up to it
## and harvests it on arrival (another tap on the way cancels that); a new
## world spawns it on dry land near the origin; its position is saved per
## seed; biome travel and teleports land it on dry land with the camera
## centred on it. Run via tests/run_tests.sh.

const MarkerChunk := preload("res://scripts/resource_marker_chunk.gd")
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
	var player: Node2D = world.get_node("Resources/Player")
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

	# Walking: a tap on open ground a few tiles away gets there - to the
	# exact point, walking freely (not tile centre to tile centre).
	world.teleport_player((Vector2(from) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	var goal: Vector2i = end
	var goal_point: Vector2 = (Vector2(goal) + Vector2(0.3, 0.7)) * world.TILE_SIZE
	player.footsteps = 0
	var tapped: Array[Vector2i] = world._on_map_tapped(goal_point)
	var legs: int = player._path.size()
	var frames := 0
	var on_land := true  # every frame on walkable ground
	while player.is_walking() and frames < 600:
		await process_frame
		frames += 1
		world._gen_mutex.lock()
		on_land = on_land and world.is_walkable(player.tile())
		world._gen_mutex.unlock()
	check(not tapped.is_empty() and player.position == goal_point and not player.is_walking(), "a tap walks the player to the exact point tapped (%s in %d frames)" % [player.position, frames])
	check(on_land and legs < tapped.size(), "the walk is free: straight legs over dry land (%d legs for a %d-tile path)" % [legs, tapped.size()])
	# At most one per frame (the test walks fast; at walk speed a frame never spans two steps).
	check(player.footsteps > 0 and player.footsteps <= floori(player._stride / player.STEP_TILES),
		"footsteps as the player walks, one per step (%d over %.1f tiles, %d frames)" % [player.footsteps, player._stride, frames])
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
	check(player.hop() == 0.0 and player.sprite_rect().end.y == 0.0 and player.sprite_rect().get_center().x == 0.0,
		"the player comes to rest with the sprite standing on its pivot, their feet")
	var rows_at_pivots := true
	var row_count := 0
	for markers in world._loaded_placements.values():
		rows_at_pivots = rows_at_pivots and markers.y_sort_enabled
		for row in markers.get_children():
			row_count += 1
			for i in row.indices:
				rows_at_pivots = rows_at_pivots and markers._positions[i].y == row.position.y
	check(row_count > 0 and rows_at_pivots and world.resources_root.y_sort_enabled and player.get_parent() == world.resources_root,
		"sprites depth-sort with the player: markers draw in nodes at their pivot y (%d), y-sorted together with the player" % row_count)
	# Sprites stand on their pivots, offset from their tile centres by
	# their placement - within the tile, not all at one spot.
	var offsets := {}
	var in_tile := true
	for placements in world._chunk_placements.values():
		for entry in placements:
			if entry[0][0] == null:
				continue  # structure parts stay on the grid
			for inst in entry[1]:
				var pivot: Vector2 = MarkerChunk.pivot(inst)
				in_tile = in_tile and Vector2i(pivot.floor()) == Vector2i((inst["position"] as Vector2).floor())
				offsets[((pivot - pivot.floor()) * world.TILE_SIZE).round()] = true
	check(in_tile and offsets.size() > 20, "resource sprites stand at varied offsets inside their tile (%d distinct)" % offsets.size())
	# Picking follows the drawn sprites: a lone tree is picked through its
	# canopy, never from the ground just below its base.
	var occupied := {}
	var trees := []
	for placements in world._chunk_placements.values():
		for entry in placements:
			for inst in entry[1]:
				occupied[Vector2i((inst["position"] as Vector2).floor())] = true
				if inst.get("id", "") in ["oak", "birch"]:
					trees.append(inst)
	var lone := {}
	for inst in trees:
		var t := Vector2i((inst["position"] as Vector2).floor())
		if not (occupied.has(t + Vector2i(0, -1)) or occupied.has(t + Vector2i(0, 1)) or occupied.has(t + Vector2i(0, 2))):
			lone = inst
			break
	var lone_base: Vector2 = MarkerChunk.pivot(lone) if not lone.is_empty() else Vector2.ZERO
	var by_canopy: bool = same.call(world.hover_target(lone_base - Vector2(0, 20.0 / world.TILE_SIZE)), lone)
	var below_free: bool = world.hover_target(lone_base + Vector2(0, 3.0 / world.TILE_SIZE)).is_empty()
	check(not lone.is_empty() and by_canopy and below_free,
		"a click on a tree's canopy picks it; one just below its base doesn't (%s)" % lone.get("id", "none found"))

	# Tapping a resource: walks up to it and harvests it on arrival. Picks
	# come from what is drawn, so let the chunks around the player stream in.
	world.flush_chunk_work()
	var target := {}
	var near: Vector2i = player.tile()
	for r in range(2, 40):
		for dy in range(-r, r + 1):
			for dx in [-r, r]:
				if target.is_empty():
					var inst: Dictionary = world.hover_target(Vector2(near + Vector2i(dx, dy)) + Vector2(0.5, 0.5))
					if not inst.is_empty() and walkable.call(Vector2i((inst["position"] as Vector2).floor())) and same.call(world.hover_target(world.sprite_point(inst)), inst):
						target = inst
		if not target.is_empty():
			break
	var tile: Vector2i = Vector2i((target["position"] as Vector2).floor())
	var tap_at: Vector2 = world.sprite_point(target) * world.TILE_SIZE
	world._on_map_tapped(tap_at)
	var before_arrival: bool = same.call(world.hover_target(tap_at / world.TILE_SIZE), target)
	frames = 0
	while player.is_walking() and frames < 1200:
		await process_frame
		frames += 1
	var d: Vector2i = player.tile() - tile
	check(not world.has_node("HarvestSound"), "the harvest plays no sound (removed on request)")
	check(before_arrival and maxi(absi(d.x), absi(d.y)) <= 1 and not same.call(world.hover_target(tap_at / world.TILE_SIZE), target),
		"tapping a %s walks up to it (stopped %s away) and harvests it on arrival" % [target.get("id", "?"), d])

	# A second tap on the way cancels the harvest.
	var other := {}
	for r in range(2, 40):
		for dy in range(-r, r + 1):
			for dx in [-r, r]:
				if other.is_empty():
					var inst: Dictionary = world.hover_target(Vector2(player.tile() + Vector2i(dx, dy)) + Vector2(0.5, 0.5))
					if not inst.is_empty() and walkable.call(Vector2i((inst["position"] as Vector2).floor())) and same.call(world.hover_target(world.sprite_point(inst)), inst):
						other = inst
		if not other.is_empty():
			break
	var other_at: Vector2 = world.sprite_point(other) * world.TILE_SIZE
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

	# Tapping a camp tent: walk up, go inside (hidden), sleep until night start.
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
			marker_hidden = marker_hidden and markers._tiles[k] != tent_tile
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
	var night_start := GameClock.NIGHT_START_HOUR * 60
	check(not world.is_in_tent() and player.visible and world.clock.time_text().begins_with("%02d:%d" % [int(night_start / 60), int(fmod(night_start, 60)) / 10]) and world.clock.rate() == 1.0,
		"at night start the player comes out and time runs at normal speed (%s)" % world.clock.time_text())
	var z_alpha := 0.0
	if is_instance_valid(effect):
		effect._process(effect.WAKE_FADE * 0.5)
		for z in effect.zs():
			z_alpha = maxf(z_alpha, z[2])
	var fading: bool = is_instance_valid(effect) and effect.is_waking() and z_alpha > 0.0 and z_alpha <= 0.5
	if is_instance_valid(effect):
		effect._process(effect.WAKE_FADE)
	await process_frame
	check(fading and not is_instance_valid(effect), "on waking the Zs fade out (alpha %.2f halfway) and the effect frees itself" % z_alpha)
	world.enter_tent(tent_tile)
	world._on_map_tapped((Vector2(tent_tile) + Vector2(0.5, 0.5)) * world.TILE_SIZE)
	check(not world.clock.sleeping and player.visible and not player.is_walking(), "tapping the tent again while inside wakes the player")

	# Saved per seed: a reloaded world puts the player back.
	var saved: Vector2 = player.position
	world._save_gameplay_state()
	world.queue_free()
	await process_frame
	var world2: Node2D = await _world()
	var player2: Node2D = world2.get_node("Resources/Player")
	check(player2.position.is_equal_approx(saved) and world2.get_node("CameraRig").global_position == player2.position,
		"a reloaded world puts the player back where they stood (%s), camera on them" % player2.tile())

	# Teleporting onto water lands on the nearest dry tile.
	world2.teleport_player((Vector2(lake) + Vector2(0.5, 0.5)) * world2.TILE_SIZE)
	world2._gen_mutex.lock()
	var dry: bool = world2.is_walkable(player2.tile())
	world2._gen_mutex.unlock()
	check(dry and Vector2(player2.tile() - lake).length() < 12.0 and world2.get_node("CameraRig").global_position == player2.position,
		"teleporting onto water lands on the nearest dry tile (%s, %.1f tiles off)" % [player2.tile(), Vector2(player2.tile() - lake).length()])

	# Walkability is kept per chunk, at most WALKABLE_CHUNKS of them (review
	# W3); a dropped chunk is sampled again and gives the same answer.
	world2._gen_mutex.lock()
	var first_answer: bool = world2.is_walkable(lake)
	for i in world2.WALKABLE_CHUNKS + 10:
		world2._set_walkable(Vector2i(100000 + i * world2.CHUNK_SIZE, 0), true)
	var dropped: bool = not world2._walkable.has(world2._chunk_of_tile(lake))
	var again: bool = world2.is_walkable(lake)
	world2._gen_mutex.unlock()
	check(world2._walkable.size() == world2.WALKABLE_CHUNKS and dropped and again == first_answer and not first_answer,
		"walkability cache holds at most %d chunks; a dropped one is sampled again the same (lake %s: %s)" % [world2.WALKABLE_CHUNKS, lake, again])
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
