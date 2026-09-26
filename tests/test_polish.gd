extends SceneTree

## First polish pass: cast shadows (silhouettes thrown by the sun / moon
## under trees, rocks, ore, shrubs, deadwood - not grass), chunk fade-in, the harvest pop effect, drifting
## cloud shadows and the desktop hover highlight. Visuals were checked on a
## real renderer by hand; this checks the wiring. Momentum and eased zoom
## are in test_camera_touch. Run via tests/run_tests.sh.

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

	# Fade-in: a freshly streamed chunk starts transparent and fades in.
	var faded := 0
	var seen := {}
	var deadline := Time.get_ticks_msec() + 20000
	while seen.size() < 20 and Time.get_ticks_msec() < deadline:
		await process_frame
		for c in world._loaded_chunks:
			if not seen.has(c):
				seen[c] = true
				faded += int(world._loaded_chunks[c].modulate.a < 1.0)
	world.flush_chunk_work()
	await create_timer(world.FADE_IN_SEC + 0.2).timeout
	var all_opaque := true
	for c in world._loaded_chunks:
		all_opaque = all_opaque and world._loaded_chunks[c].modulate.a == 1.0 and world._loaded_placements.get(c, world._loaded_chunks[c]).modulate.a == 1.0
	check(faded == seen.size() and faded > 0 and all_opaque, "new chunks fade in (%d of %d caught mid-fade on arrival), all fully shown after %.1f s" % [faded, seen.size(), world.FADE_IN_SEC])

	# Shadows: per-resource data, and drawn only for resources that cast them.
	var defs: Dictionary = world._definitions_by_id()
	var casting := func(ids: Array) -> bool: return ids.all(func(i): return defs[i].casts_shadow)
	var flat := func(ids: Array) -> bool: return ids.all(func(i): return not defs[i].casts_shadow)
	check(casting.call(["oak", "pine", "palm", "dead_tree", "berry_bush", "meadow_grass", "wildflowers", "pioneer_grass", "fireweed", "beach_grass", "cactus", "sagebrush"])
		and flat.call(["granite", "basalt", "gravel", "iron", "coal", "fallen_log", "mushrooms", "shells", "mud"]),
		"shadows under trees, shrubs, grass, flowers, cacti and sagebrush; none under rocks, ore, logs or mushrooms")
	var shadows := 0
	var casters := 0
	for c in world._chunk_placements:
		for entry in world._chunk_placements[c]:
			if entry[0][0] is ResourceGuild and entry[0][1] == world.ResourceMarkerChunkScript.Shape.SPRITE:
				for inst in world._unchanged(entry[1]):
					casters += 1 if defs[inst["id"]].casts_shadow else 0
		shadows += world._loaded_placements[c].shadow_count()
	var layer_ok := true
	for m in world._loaded_placements.values():
		var layer: Node2D = m.shadow_layer()
		layer_ok = layer_ok and (layer == null or (layer.get_parent() == world.shadows_root and layer.material == world.shadow_material and layer.position == m.position))
	check(shadows == casters and casters > 100 and layer_ok,
		"one silhouette shadow per casting sprite (%d), all on one layer under every sprite, with the cast-shadow material" % shadows)
	var old_layer: Node2D = world._loaded_placements.values()[0].shadow_layer()
	world._redraw_markers(world._loaded_placements.keys()[0])
	await process_frame
	check(old_layer == null or not is_instance_valid(old_layer), "a chunk's shadows go away with its markers (redraw)")

	# Sun and moon.
	var morning := SunShadow.at(7.5)
	var noon := SunShadow.at(12.0)
	var evening := SunShadow.at(16.5)
	var night := SunShadow.at(0.0)
	var noon_len := Vector2(noon.x, noon.y).length()
	check(morning.x < -0.3 and evening.x > 0.3 and absf(noon.x) < 0.05 and noon_len < Vector2(morning.x, morning.y).length(),
		"shadows point west in the morning (%.2f), east in the evening (%.2f), and are shortest at noon" % [morning.x, evening.x])
	check(night.z > 0.0 and night.z < noon.z and SunShadow.at(6.0).z < 0.01 and SunShadow.at(18.0).z < 0.01,
		"moon shadows are fainter than the sun's (%.2f vs %.2f); both fade out at dawn and dusk" % [night.z, noon.z])
	var smooth := true
	var prev := SunShadow.at(0.0)
	for m in range(1, 24 * 60 + 1):
		var cur := SunShadow.at(m / 60.0)
		# Direction may swing near a horizon, but only while nearly invisible.
		smooth = smooth and absf(cur.z - prev.z) < 0.01 and (Vector2(cur.x, cur.y) - Vector2(prev.x, prev.y)).length() * minf(cur.z, prev.z) < 0.01
		prev = cur
	check(smooth, "shadows change smoothly minute by minute through the day and night")

	# Harvest effect: spawned at the object, frees itself.
	var target := {}
	for c in world._chunk_placements:
		for entry in world._chunk_placements[c]:
			if entry[0][0] == world.CANOPY_TREES and not entry[1].is_empty():
				target = entry[1][0]
				break
		if not target.is_empty():
			break
	var click: Vector2 = world.sprite_point(target) * world.TILE_SIZE
	var e = world._on_harvest_clicked(click)
	var effects: Array = world.resources_root.get_children().filter(func(n): return n.name.begins_with("HarvestEffect"))
	var at_object: bool = e != null and effects.size() == 1 and effects[0].position == (world.ResourceMarkerChunkScript.pivot({"position": e.world_position}) * world.TILE_SIZE).round()
	await create_timer(0.5).timeout
	var left: Array = world.resources_root.get_children().filter(func(n): return is_instance_valid(n) and n.name.begins_with("HarvestEffect"))
	check(e != null and at_object and left.is_empty(), "harvesting spawns one pop effect at the object, which frees itself")

	# Clouds: only in the gameplay views, cover the view, drift with the wind
	# and hold while paused.
	var clouds: ColorRect = world.get_node("CloudShadows")
	await process_frame
	var o0: Vector2 = clouds.offset
	await create_timer(0.3).timeout
	var o1: Vector2 = clouds.offset
	world.clock.play_pause()
	await process_frame
	var o2: Vector2 = clouds.offset
	await create_timer(0.3).timeout
	var o3: Vector2 = clouds.offset
	world.clock.play_pause()
	var view := Rect2(clouds.position, clouds.size)
	var cam: Camera2D = world.get_node("CameraRig/Camera2D")
	var covers := view.has_point(cam.get_screen_center_position())
	var moved_with_wind := (o1 - o0).normalized().dot(Wind.direction_at(world.clock.minutes)) > 0.9
	check(clouds.visible and covers and o1 != o0 and moved_with_wind and o2 == o3 and clouds.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"clouds cover the view, drift with the wind, hold while paused, and ignore the mouse")
	world.set_view_mode(world.get_script().ViewMode.TEMPERATURE)
	await process_frame
	await process_frame
	check(not clouds.visible, "no clouds over data views (tinted view: %s)" % world.is_time_tinted_view())
	world.set_view_mode(world.get_script().ViewMode.RESOURCES)
	world.flush_chunk_work()

	# Hover highlight: follows the harvest pick for a real mouse, hides after touch.
	var hover: Node2D = world.get_node("HoverHighlight")
	var next := {}
	for c in world._chunk_placements:
		for entry in world._chunk_placements[c]:
			for inst in world._unchanged(entry[1]):
				if entry[0][0] == world.SURFACE_ROCKS:
					next = inst
					break
			if not next.is_empty():
				break
		if not next.is_empty():
			break
	var on_art: Vector2 = world.sprite_point(next)
	var want: Dictionary = world.hover_target(on_art)
	hover._mouse_mode = true
	hover._pixel = Vector2i(1 << 30, 0)
	var move := InputEventMouseMotion.new()
	move.position = Vector2(-1000, -1000)
	hover._input(move)
	# Point the highlight's own lookup at that spot (headless has no real mouse).
	var pick: Dictionary = world.hover_target(on_art)
	hover._set_target(not pick.is_empty(), Vector2i((pick.get("position", Vector2.ZERO) as Vector2).floor()), world.sprite_drawn(pick))
	var outline: Texture2D = hover.outline_texture(hover.drawn()[0]) if not hover.drawn().is_empty() else null
	var shown: bool = hover.has_target() and hover.target_tile() == Vector2i((want["position"] as Vector2).floor()) and outline != null and outline.get_width() == (hover.drawn()[0] as Texture2D).get_width() + 2
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	hover._input(touch)
	await process_frame
	check(shown and not hover.has_target(), "hover highlight outlines the sprite of the object a click would harvest, and hides after a touch")

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
