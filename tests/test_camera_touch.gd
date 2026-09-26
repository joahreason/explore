extends SceneTree

## Camera input (camera_rig.gd) through Godot's real input pipeline, with
## the project's emulate_mouse_from_touch=true: a tap or left click is one
## map tap (walks the player), a long press or right click is info, drags
## never move the camera, a pinch zooms without moving it and is never a
## tap, lifting a pinch finger changes nothing; and the camera follows the
## player loosely (still inside the follow zone, eased back to its edge
## outside it, never locked on). Run via tests/run_tests.sh.

var _fails := 0
var _passes := 0
var rig: Node2D
var cam: Camera2D
var clicks := 0  # map_tapped: left click / tap
var player: Node2D
var home := Vector2.ZERO  # where reset() put the player and camera
var infos := 0  # info_clicked: right click / long press


func check(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _send(e: InputEvent) -> void:
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func touch(i: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = i
	e.position = pos
	e.pressed = pressed
	_send(e)


func drag(i: int, from: Vector2, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = i
	e.position = to
	e.relative = to - from
	_send(e)


## World point shown at a screen position, from the viewport's own transform.
func world_under(screen: Vector2) -> Vector2:
	return root.get_viewport().canvas_transform.affine_inverse() * screen


func reset(zoom: float) -> void:
	rig._zoom_target = -1.0
	player.teleport(Vector2.ZERO)  # a tile centre; the camera on it: inside the follow zone
	home = player.position
	rig.global_position = home
	cam.zoom = Vector2(zoom, zoom)
	await process_frame
	await process_frame


func _init() -> void:
	check(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch"), "project emulates mouse from touch (the case under test)")
	var world: Node2D = load("res://world.tscn").instantiate()
	world.world_seed = 4242
	world.threaded_generation = false
	world.set_view_mode(world.get_script().ViewMode.MATERIAL)
	root.add_child(world)
	await process_frame
	# Headless runs use a 64x64 root viewport, where the right-anchored UI panel
	# covers the centre (touches on it are rightly ignored as UI). This test is
	# about the map, so hide the panel.
	for control in world.get_node("UI").get_children():
		control.visible = false
	rig = world.get_node("CameraRig")
	cam = rig.get_node("Camera2D")
	player = world.get_node("Resources/Player")
	rig.map_tapped.connect(func(_p): clicks += 1)
	rig.info_clicked.connect(func(_p): infos += 1)
	var center: Vector2 = root.get_viewport().get_visible_rect().size * 0.5
	var map_point := center + Vector2(-150, 60)  # off-centre

	# One finger drags 100 px: the camera doesn't move, and it isn't a tap.
	await reset(4.0)
	clicks = 0
	var p := map_point
	touch(0, p, true)
	for k in 10:
		drag(0, p, p + Vector2(10, 0))
		p += Vector2(10, 0)
		await process_frame
	touch(0, p, false)
	await process_frame
	check(rig.global_position == home and clicks == 0, "one-finger drag doesn't move the camera (%s) and isn't a tap (%d)" % [rig.global_position, clicks])

	# Symmetric pinch around the screen centre: zooms in, no pan.
	await reset(2.0)
	var a := center - Vector2(50, 0)
	var b := center + Vector2(50, 0)
	touch(0, a, true)
	touch(1, b, true)
	for k in 5:
		drag(0, a, a - Vector2(5, 0))
		a -= Vector2(5, 0)
		drag(1, b, b + Vector2(5, 0))
		b += Vector2(5, 0)
		await process_frame
	touch(0, a, false)
	touch(1, b, false)
	await process_frame
	check(rig.global_position.distance_to(home) < 0.01 and absf(cam.zoom.x - 3.0) < 0.01, "centred pinch zooms without drifting (moved %s, zoom %.2f, expect 3)" % [rig.global_position, cam.zoom.x])

	# Off-centre pinch, and two fingers moving together: zoom only, the
	# camera stays with the player.
	await reset(2.0)
	a = map_point - Vector2(40, 0)
	b = map_point + Vector2(40, 0)
	touch(0, a, true)
	touch(1, b, true)
	for k in 5:
		drag(0, a, a + Vector2(-8, 6))
		a += Vector2(-8, 6)
		drag(1, b, b + Vector2(8, 6))
		b += Vector2(8, 6)
		await process_frame
	touch(0, a, false)
	touch(1, b, false)
	await process_frame
	check(rig.global_position == home and absf(cam.zoom.x - 4.0) < 0.01, "off-centre / moving pinch zooms (%.2f) without moving the camera (%s)" % [cam.zoom.x, rig.global_position])

	# Lifting one finger of a pinch changes nothing, even when the browser
	# renumbers the remaining finger or reports a bogus relative motion.
	await reset(4.0)
	a = map_point
	b = map_point + Vector2(120, 0)
	touch(0, a, true)
	touch(1, b, true)
	for k in 3:
		drag(0, a, a - Vector2(10, 0))
		a -= Vector2(10, 0)
		drag(1, b, b + Vector2(10, 0))
		b += Vector2(10, 0)
		await process_frame
	var after_pinch_zoom := cam.zoom.x
	touch(0, a, false)
	await process_frame
	var bogus := InputEventScreenDrag.new()
	bogus.index = 0
	bogus.position = b + Vector2(1, 0)
	bogus.relative = b + Vector2(1, 0) - a
	_send(bogus)
	await process_frame
	for k in 4:
		var e := InputEventScreenDrag.new()
		e.index = 0
		e.position = b + Vector2(1 + 8 * (k + 1), 0)
		e.relative = Vector2(500, 0)
		_send(e)
		await process_frame
	touch(0, b + Vector2(33, 0), false)
	await process_frame
	check(rig.global_position == home and cam.zoom.x == after_pinch_zoom and after_pinch_zoom > 4.0,
		"lifting a pinch finger (renumbered, bogus motion) leaves zoom (%.2f) and camera (%s) alone" % [cam.zoom.x, rig.global_position])

	# A pinch whose last finger lifts near where it started is not a tap;
	# a plain tap is exactly one.
	await reset(4.0)
	clicks = 0
	a = map_point
	b = map_point + Vector2(80, 0)
	touch(0, a, true)
	touch(1, b, true)
	drag(0, a, a - Vector2(30, 0))
	await process_frame
	touch(0, a - Vector2(30, 0), false)
	touch(1, b, false)
	await process_frame
	var after_pinch := clicks
	touch(0, map_point, true)
	touch(0, map_point, false)
	await process_frame
	check(after_pinch == 0 and clicks == 1 and infos == 0, "pinch fires no tap (%d); a tap fires one map tap (%d), no info (%d)" % [after_pinch, clicks - after_pinch, infos])

	# Long press (Phase 16): a finger held still fires info while still down,
	# and its release is not also a tap.
	clicks = 0
	infos = 0
	touch(0, map_point, true)
	await create_timer(rig.LONG_PRESS_SEC + 0.2).timeout
	var info_while_held := infos
	touch(0, map_point, false)
	await process_frame
	check(info_while_held == 1 and infos == 1 and clicks == 0, "long press fires info once while held (%d), no map tap on release (%d)" % [infos, clicks])

	# A real mouse (not emulated): a drag moves nothing and isn't a click.
	await reset(4.0)
	clicks = 0
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = map_point
	_send(press)
	var motion := InputEventMouseMotion.new()
	motion.position = map_point + Vector2(40, 0)
	motion.relative = Vector2(40, 0)
	_send(motion)
	var release := press.duplicate()
	release.pressed = false
	release.position = map_point + Vector2(40, 0)
	_send(release)
	await process_frame
	check(rig.global_position == home and clicks == 0, "mouse drag doesn't move the camera (%s), no click" % rig.global_position)

	# Mouse buttons: left click is a map tap, right click shows info.
	clicks = 0
	infos = 0
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var down := InputEventMouseButton.new()
		down.button_index = button
		down.pressed = true
		down.position = map_point
		_send(down)
		var up := down.duplicate()
		up.pressed = false
		_send(up)
		await process_frame
	check(clicks == 1 and infos == 1, "left click is a map tap (%d), right click shows info (%d)" % [clicks, infos])

	# Wheel zoom eases to its target instead of jumping.
	await reset(2.0)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = map_point
	_send(wheel)
	var first := cam.zoom.x
	await process_frame
	var eased := cam.zoom.x
	await create_timer(0.8).timeout
	check(first == 2.0 and eased > 2.0 and eased < 2.0 * rig.zoom_factor and is_equal_approx(cam.zoom.x, 2.0 * rig.zoom_factor),
		"wheel zoom eases (2.00 -> %.3f -> %.3f, target %.3f)" % [eased, cam.zoom.x, 2.0 * rig.zoom_factor])

	# Following: the player moves freely inside the zone; past its edge the
	# camera eases along until they are back at the edge - not centred.
	await reset(4.0)
	var zone: Vector2 = root.get_viewport().get_visible_rect().size / cam.zoom * rig.FOLLOW_ZONE
	var home_tile_center: Vector2 = player.position
	player.teleport(home_tile_center)
	for k in 10:
		await process_frame
	var inside_still := rig.global_position == home
	player.teleport(home_tile_center + Vector2(zone.x + 40.0, 0))
	var jump := player.position.x - home.x
	await process_frame
	var first_step := rig.global_position.x - home.x
	await create_timer(1.5).timeout
	var offset := player.position - rig.global_position
	check(inside_still and first_step > 0.0 and first_step < jump - zone.x and absf(offset.x - zone.x) < 0.5 and absf(offset.y) < 0.01,
		"camera still while the player is inside the follow zone; past it, eases (first step %.1f px) until the player is back at the zone edge (offset %.1f, edge %.1f), not locked on" % [first_step, offset.x, zone.x])

	# On-screen keyboard (mobile web): a tap or click on the map releases a
	# focused text field (hiding the keyboard), and so does applying a seed.
	# A stand-in LineEdit off-screen: the real seed field is hidden here.
	var field := LineEdit.new()
	field.position = Vector2(-1000, -1000)
	root.add_child(field)
	var focused := func() -> bool:
		field.grab_focus()
		return root.get_viewport().gui_get_focus_owner() == field
	var had: bool = focused.call()
	touch(0, map_point, true)
	touch(0, map_point, false)
	await process_frame
	var after_tap: Control = root.get_viewport().gui_get_focus_owner()
	var had2: bool = focused.call()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = map_point
	_send(click)
	var click_up := click.duplicate()
	click_up.pressed = false
	_send(click_up)
	await process_frame
	var after_click: Control = root.get_viewport().gui_get_focus_owner()
	var had3: bool = focused.call()
	SeedReload.close_keyboard(world)
	var after_close: Control = root.get_viewport().gui_get_focus_owner()
	check(had and had2 and had3 and after_tap == null and after_click == null and after_close == null,
		"map tap, map click and a seed action release the text field's keyboard focus")
	field.queue_free()

	print("RESULT %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
